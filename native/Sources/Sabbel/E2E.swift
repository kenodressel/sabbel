import AppKit
import AVFoundation
import os
import SabbelCore
import SabbelEngine
import SabbelSystem

/// `Sabbel --e2e` (`make test-e2e`): an end-to-end check on this Mac, a port of
/// `scripts/e2e.py`. The real coordinator, the real model, a real paste.
///
/// The unit tests use fakes, and `make test-model` covers the model on its own.
/// This drives the whole take path the way the menu bar app runs it: the main
/// run loop, the streaming transcription, the paste line, the paste into a real
/// text field, the history write and the hand-back to the main thread, with
/// speech from `say`. Only the key press and the microphone are left out: the
/// hotkey tap ignores synthetic keys on purpose, so the run calls
/// `TakeCoordinator.handle` itself, and the speech is fed in place of the mic.
///
/// Run it from a logged-in desktop session; the terminal needs Accessibility
/// (System Settings → Privacy & Security). It opens a scratch file in TextEdit
/// and closes only that file. The clipboard and ~/.config/sabbel are left as
/// they were: the config dir is a scratch one (`SABBEL_CONFIG_DIR`), the log a
/// scratch file, and the instance lock is never taken, so it runs alongside a
/// running Sabbel.
///
/// Besides e2e.py's checks, three takes differ:
/// - the second runs with the live panel shown: the text must still land in
///   TextEdit, and Sabbel must not be frontmost when Cmd+V is posted;
/// - the third has Finder take the front right before Cmd+V: the text must be
///   held back in the clipboard, with the matching notice;
/// - every take's hotkey release → Cmd+V time must stay within 500 ms.
@MainActor final class E2ERun: NSObject, NSApplicationDelegate {
    private var checks = E2EChecks(output: { print($0) })

    private var log: RuntimeLog!
    private var paths: SabbelPaths!
    private var coordinator: TakeCoordinator!
    private var menuBar: MenuBar!
    private var ui: RecordingUI!
    private var audio: FedAudioSource!
    private let base = SystemPasteEnvironment()
    private var paste: RecordingPasteEnvironment!
    private let recognizer = RecognizerSlot()
    /// Every line the coordinator and the injector logged.
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    private var ticks: [TimeInterval] = []
    private var tickTimer: Timer?
    private var takeToken = E2ETakeToken()

    private var doc: URL!
    private var docRef: String { "(first document whose path is \"\(doc.path)\")" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // stdout is a pipe under make: print each line as it happens.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Permissions.accessibilityGranted(prompt: false) else {
            Self.abort("This terminal has no Accessibility permission, so nothing can be "
                       + "pasted. Grant it in System Settings → Privacy & Security.")
        }
        if NSWorkspace.shared.frontmostApplication?.localizedName == "loginwindow" {
            Self.abort("The screen is locked. Unlock it: nothing can be pasted to a lock screen.")
        }
        Task {
            await Self.checkAutomation()
            print("Hands off the Mac for ~30s: the takes paste into TextEdit, and typing,\n"
                  + "copying or switching apps meanwhile would land in the test.")
            await run()
        }
    }

    /// The run sends Apple events to TextEdit and Finder. The first time, macOS
    /// asks for Automation consent; probing here makes that prompt appear while
    /// the user is still at the keyboard, not halfway through a take (where an
    /// unanswered prompt would stall the paste line). A refusal fails fast.
    /// Probing TextEdit launches it if it is not running; the run opens it anyway.
    private static func checkAutomation() async {
        for app in ["Finder", "TextEdit"] {
            let result = await runTool("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to get name"])
            if let problem = E2ERules.automationProblem(app: app, status: result.status, stderr: result.error) {
                abort(problem)
            }
        }
    }

    private static func abort(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    // MARK: setup

    private func run() async {
        let saved = base.captureClipboard()
        var opened = false
        do {
            try await setUp()
            try await drive(opened: &opened)
        } catch {
            checks.check(false, "driver crashed", String(reflecting: error))
        }
        await finish(opened: opened, saved: saved)
    }

    private func setUp() async throws {
        let scratch = try Self.makeScratchDir()
        // Before anything reads the paths: history on, in a scratch config dir.
        let configDir = scratch.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data("[history]\nenabled = true\n".utf8).write(to: configDir.appendingPathComponent("config.toml"))
        setenv("SABBEL_CONFIG_DIR", configDir.path, 1)
        let paths = SabbelPaths.current()
        guard paths.configDir.standardizedFileURL == configDir.standardizedFileURL else {
            Self.abort("SABBEL_CONFIG_DIR was not honoured (\(paths.configDir.path)); refusing to touch it.")
        }
        self.paths = paths

        let logURL = scratch.appendingPathComponent("sabbel-runtime.log")
        let log = RuntimeLog(url: logURL)
        self.log = log
        print("Scratch dir \(scratch.path) (runtime log: \(logURL.lastPathComponent))")
        let lines = self.lines
        let tee: @Sendable (String) -> Void = { line in
            log.info(line)
            lines.withLock { $0.append(line) }
        }
        log.info("Sabbel e2e starting (v\(AppDelegate.version), \(EngineInfo.description))")

        let settings = SabbelSettings.load(paths: paths, log: tee)
        let speech = try await Self.synthesiseSpeech(into: scratch)
        // The key comes up a moment after the last word.
        audio = FedAudioSource(samples: speech + [Float](repeating: 0, count: 4_800))
        doc = scratch.appendingPathComponent(E2ERules.documentName)
        try Data().write(to: doc)

        paste = RecordingPasteEnvironment(base: base)
        let menuBar = MenuBar(version: AppDelegate.version, paths: paths, historyEnabled: settings.historyEnabled,
                              historyMaxBytes: settings.historyMaxBytes, notifier: Notifier(log: tee, notificationCenter: false),
                              updates: nil, log: tee)
        let ui = RecordingUI(menuBar: menuBar)
        let slot = recognizer
        let coordinator = TakeCoordinator(
            settings: settings, paths: paths, audio: audio, focus: SystemFocusProbe(),
            injector: Injector(env: paste, ownPID: getpid(), log: tee),
            makeTranscriber: { StreamingTranscriber(recognizer: slot) }, ui: ui, log: tee)
        menuBar.coordinator = coordinator
        ui.coordinator = coordinator
        self.menuBar = menuBar
        self.ui = ui
        self.coordinator = coordinator
        // Accessibility was checked above, and the microphone is not used.
        coordinator.permissionsReady = true

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticks.append(Self.now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        loadModel()
    }

    private func loadModel() {
        let slot = recognizer
        let coordinator = self.coordinator!
        let log = self.log!
        let progress = LoadProgressBox()
        Task.detached(priority: .userInitiated) {
            do {
                let parakeet = try await ParakeetRecognizer.load(progress: { event in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            // A late report must never put the app back into "loading".
                            guard case .loading = coordinator.modelState else { return }
                            coordinator.modelState = progress.value.state(after: event)
                        }
                    }
                })
                slot.set(parakeet)
                log.info("Model loaded")
                await MainActor.run { coordinator.modelState = .ready }
            } catch {
                log.error("Model load failed: \(String(reflecting: error))")
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                await MainActor.run { coordinator.modelState = .failed(message) }
            }
        }
    }

    // MARK: the takes

    private func drive(opened: inout Bool) async throws {
        let deadline = Self.now + E2ERules.modelTimeout
        while case .loading = coordinator.modelState {
            if Self.now > deadline {
                checks.check(false, "model loaded", "not ready after \(Int(E2ERules.modelTimeout))s")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if case .failed(let message) = coordinator.modelState {
            checks.check(false, "model loaded", message)
            return
        }
        try await Task.sleep(for: .seconds(1))  // let the last status land

        print("status")
        let early = ui.statuses.filter { $0.status == "Ready" && !$0.modelReady }
        checks.check(early.isEmpty, "no \"Ready\" before the model loaded",
                     ui.statuses.map(\.status).joined(separator: " → "))
        checks.check(ui.statuses.last?.status == "Ready", "\"Ready\" once loaded", ui.statuses.last?.status ?? "nothing shown")

        let (status, _, _) = await Self.runTool("/usr/bin/open", ["-a", "TextEdit", doc.path])
        guard status == 0 else { throw E2EError.openFailed(status) }
        opened = true

        let runs = E2ERules.runs(environment: ProcessInfo.processInfo.environment)
        var passed = 0, interruptions = 0
        while passed < runs {
            let kind = E2ERules.kind(ofTake: passed)
            let scenario = switch kind {
            case .plain: ""
            case .livePanel: " (live panel open)"
            case .focusLost: " (Finder takes the front right before Cmd+V)"
            }
            print("take \(passed + 1)/\(runs)\(scenario)")
            _ = await Self.osa("tell application \"TextEdit\" to set text of \(docRef) to \"\"")
            if kind == .livePanel { menuBar.showLiveText() }

            var target: FocusTarget?
            var inFront = false
            for _ in 0..<100 {
                _ = await Self.osa("tell application \"TextEdit\" to activate")
                target = NSWorkspace.shared.frontmostApplication.map {
                    FocusTarget(pid: $0.processIdentifier, name: $0.localizedName)
                }
                let front = await Self.osa("tell application \"TextEdit\" to get name of front window")
                if target?.name == "TextEdit" && front == doc.lastPathComponent {
                    inFront = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard inFront, let target else {
                // Every later take would fail the same way, slowly.
                checks.check(false, "TextEdit in front with the scratch file", String(describing: target))
                return
            }
            try await Task.sleep(for: .milliseconds(500))

            _ = base.writeTransient(E2ERules.sentinel)
            ui.notices.removeAll()
            let seen = lines.withLock { $0.count }
            var thief: (@Sendable () -> Void)?
            if kind == .focusLost {
                let env = base
                thief = { Self.bringFinderToFront(env) }
            }
            paste.beginTake(stealFocus: thief)

            // Press, speak, release.
            let start = Self.now
            coordinator.handle(.start)
            let fedBy = start + Double(audio.sampleCount) / 16_000 + 5
            while !audio.fed && Self.now < fedBy { try await Task.sleep(for: .milliseconds(10)) }
            let release = Self.now
            coordinator.handle(.stop)

            let token = takeToken.begin()
            Task {
                await self.coordinator.waitUntilIdle()
                self.takeToken.finished(token)
            }
            while !(takeToken.isIdle && coordinator.icon == .idle) && Self.now - release <= E2ERules.takeTimeout {
                try await Task.sleep(for: .milliseconds(50))
            }
            let done = Self.now
            try await Task.sleep(for: .milliseconds(300))  // the paste lands a moment after it is posted

            let record = paste.record()
            let logged = lines.withLock { Array($0[seen...]) }
            let outcome = logged.lazy.compactMap { line in
                line.hasPrefix("Inject outcome: ") ? InjectOutcome(rawValue: String(line.dropFirst(16))) : nil
            }.last
            guard let outcome else {
                checks.check(false, "take finished",
                             "no paste within \(Int(E2ERules.takeTimeout))s (status: \(coordinator.status))")
                return
            }
            let spoken = record.writes.last ?? ""
            let clipboard = base.clipboardString()
            let history = (try? String(contentsOf: paths.historyLog, encoding: .utf8)) ?? ""
            let gap = E2ERules.longestGapMS(ticks, from: start, to: done)

            checks.check(E2ERules.expectedWords.isSubset(of: E2ERules.words(spoken)), "transcribed the speech",
                         Self.repr(spoken))
            checks.check(!spoken.isEmpty && history.contains(spoken), "saved to history")
            checks.check(record.writesOnMainThread.last == false, "pasted off the main thread",
                         record.writeQueues.last ?? "nothing pasted")
            checks.check(gap < E2ERules.maxMainThreadGapMS, "main thread stayed responsive",
                         "longest pause \(Int(gap.rounded())) ms")
            checks.check(coordinator.icon == .idle, "back to idle", String(describing: coordinator.icon))
            if let commandV = record.commandV.first {
                let ms = (commandV.at - release) * 1000
                log.info("e2e take \(passed + 1): release → Cmd+V \(Int(ms.rounded())) ms")
                checks.check(E2ERules.finishLatencyOK(ms: ms), "finish latency",
                             "\(Int(ms.rounded())) ms from release to Cmd+V")
            } else {
                log.info("e2e take \(passed + 1): no Cmd+V posted")
            }

            if E2ERules.isInterruption(kind: kind, outcome: outcome, frontmostPID: record.lastFrontmostPID,
                                       targetPID: target.pid, ownPID: getpid(), interruptions: interruptions) {
                // Not Sabbel's doing: something else took the front while the take
                // ran (you, or an app grabbing focus). Sabbel must then hold the
                // text back — check that, and go again.
                interruptions += 1
                print("  ----  \(Self.appName(record.lastFrontmostPID)) came to the front mid-take; "
                      + "checking the fallback, then retrying")
                checks.check(clipboard == spoken, "fallback: text left in the clipboard", Self.repr(clipboard))
                checks.check(ui.notices == [.textCopiedFocusChanged], "fallback: told the user where the text went",
                             String(describing: ui.notices))
                continue
            }

            let text = await Self.osa("tell application \"TextEdit\" to get text of \(docRef)")
            if kind == .focusLost {
                let caughtLate = logged.contains { $0.hasPrefix("Focus lost right before Cmd+V") }
                checks.check(outcome == .focusChanged && record.stoleFocus && caughtLate,
                             "focus lost right before Cmd+V",
                             "outcome \(outcome.rawValue), \(Self.appName(record.lastFrontmostPID)) in front")
                checks.check(record.commandV.isEmpty && text.isEmpty, "focus lost: nothing pasted", Self.repr(text))
                checks.check(clipboard == spoken, "focus lost: text left in the clipboard", Self.repr(clipboard))
                checks.check(ui.notices == [.textCopiedFocusChanged], "focus lost: told the user where the text went",
                             String(describing: ui.notices))
                passed += 1
                continue
            }

            checks.check(outcome == .pasted, "pasted", outcome.rawValue)
            checks.check(text == spoken, "text landed in the document", Self.repr(text))
            checks.check(clipboard == E2ERules.sentinel, "clipboard restored", Self.repr(clipboard))
            checks.check(ui.notices.isEmpty, "no notification", String(describing: ui.notices))
            if kind == .livePanel {
                let front = record.commandV.first?.frontmostPID
                let open = menuBar.livePanelOpen
                checks.check(open && front != nil && front != getpid() && text == spoken, "live panel open",
                             "panel \(open ? "open" : "closed"), \(Self.appName(front)) in front at Cmd+V")
            }
            passed += 1
        }
    }

    // MARK: teardown

    private func finish(opened: Bool, saved: ClipboardSnapshot) async {
        // A take still on the paste line (one that timed out) must not paste
        // into whatever is in front once the scratch document is closed.
        paste?.disarm()
        tickTimer?.invalidate()
        if opened {
            // Only the scratch document: never quit TextEdit or touch another document.
            _ = await Self.osa("tell application \"TextEdit\" to close \(docRef) saving no")
        }
        if E2ERules.shouldRestoreClipboard(current: base.clipboardString(), written: paste?.allWrites ?? []) {
            base.restoreClipboard(saved)
        } else {
            print("Clipboard changed during the run — left as it is.")
        }
        print(checks.summary)
        exit(checks.exitCode)
    }

    // MARK: helpers

    private enum E2EError: Error, CustomStringConvertible {
        case sayFailed(Int32)
        case openFailed(Int32)

        var description: String {
            switch self {
            case .sayFailed(let s): "say exited with \(s)"
            case .openFailed(let s): "open -a TextEdit exited with \(s)"
            }
        }
    }

    private nonisolated static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Python's repr for the detail column.
    private static func repr(_ text: String?) -> String { text.map { String(reflecting: $0) } ?? "None" }

    private static func appName(_ pid: Int32?) -> String {
        guard let pid else { return "pid None" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// A fresh directory under $TMPDIR, by its real path: TextEdit reports a
    /// document's path with /private, and the document is found by that path.
    private static func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let real = realpath(dir.path, nil) else { return dir }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    private static func synthesiseSpeech(into dir: URL) async throws -> [Float] {
        let wav = dir.appendingPathComponent("phrase.wav")
        let (status, _, _) = await runTool("/usr/bin/say", ["-o", wav.path, "--data-format=LEI16@16000", E2ERules.phrase])
        guard status == 0 else { throw E2EError.sayFailed(status) }
        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Runs on the paste line, at the injector's first modifier check: Finder
    /// takes the front, and only once it is frontmost does the paste go on.
    private nonisolated static func bringFinderToFront(_ env: SystemPasteEnvironment) {
        _ = runToolSync("/usr/bin/osascript", ["-e", "tell application \"Finder\" to activate"])
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?.processIdentifier
        let deadline = now + 3
        while now < deadline {
            if let finder, env.frontmostPID() == finder { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// AppleScript's stdout, trimmed; errors read as "".
    private static func osa(_ script: String) async -> String {
        await runTool("/usr/bin/osascript", ["-e", script]).output
    }

    /// Off the main thread and off the concurrency pool, which the recognizer uses.
    private static func runTool(_ path: String, _ args: [String]) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: runToolSync(path, args)) }
        }
    }

    private nonisolated static func runToolSync(_ path: String, _ args: [String])
        -> (status: Int32, output: String, error: String) {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", String(describing: error)) }
        // Both are a line or two; neither pipe can fill up while the other is read.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output, String(decoding: errData, as: UTF8.self))
    }
}

/// The coordinator's UI in the e2e run: the real menu bar and live panel, with
/// every status recorded. Notices are recorded instead of posted: a notice is
/// itself a result worth checking, and banners would pile up on every run.
/// The model-load progress state, owned by the main actor.
@MainActor final class LoadProgressBox {
    var value = ModelLoadProgress()
}

@MainActor final class RecordingUI: SabbelUI {
    private let menuBar: MenuBar
    weak var coordinator: TakeCoordinator?
    var notices: [Notice] = []
    /// Each status change, with whether the model was ready when it was shown.
    private(set) var statuses: [(status: String, modelReady: Bool)] = []

    init(menuBar: MenuBar) { self.menuBar = menuBar }

    func show(_ icon: IconState, status: String) {
        let ready = coordinator?.modelState == .ready
        if statuses.last.map({ $0.status != status || $0.modelReady != ready }) ?? true {
            statuses.append((status, ready))
        }
        menuBar.show(icon, status: status)
    }

    func notify(_ notice: Notice) { notices.append(notice) }

    func live(_ text: LiveText, masked: Bool) { menuBar.live(text, masked: masked) }
}

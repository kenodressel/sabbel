import AppKit
import os
import SabbelCore
import SabbelEngine
import SabbelSystem

/// Startup and wiring. The behaviour lives in `TakeCoordinator`; this only
/// binds it to the system and runs the startup sequence:
///
/// 1. the single-instance lock (shared with the Python app), else exit;
/// 2. the runtime log and the settings;
/// 3. the coordinator;
/// 4. the permission poll, which starts the hotkey once both are granted;
/// 5. in parallel, the model load;
/// 6. the update check, when due.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opened only once the instance lock is held: a refused second launch must
    /// never touch the running instance's log (R23).
    private var log: RuntimeLog!
    private let instanceLock = SingleInstanceLock()
    private let recognizer = RecognizerSlot()
    private var coordinator: TakeCoordinator?
    private var menuBar: MenuBar?
    private var tap: HotkeyTap?
    private var hotkey = HotkeyStateMachine()
    private var loggedModelDecile = -1
    private var modelLoad = ModelLoadProgress()

    /// `SabbelVersion` from Info.plist; the unbundled binary is `dev`.
    static var version: String {
        let value = Bundle.main.infoDictionary?["SabbelVersion"] as? String
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            FileHandle.standardError.write(Data("Sabbel is already running. Exiting.\n".utf8))
            exit(0)
        }
        let log = RuntimeLog()
        self.log = log
        let info: @Sendable (String) -> Void = { log.info($0) }
        let version = Self.version
        info("Sabbel starting (v\(version), \(EngineInfo.description))")

        let paths = SabbelPaths.current()
        let settings = SabbelSettings.load(paths: paths, log: info)
        info("Settings: config dir \(paths.configDir.path)")
        info("Settings: hotkey=\(settings.hotkeyName) min_duration_seconds=\(settings.minDuration) "
             + "history_enabled=\(settings.historyEnabled) history_max_bytes=\(settings.historyMaxBytes) "
             + "audio_device=\(settings.audioDevice ?? "System Default") "
             + "text_tidy=\(settings.tidyText) text_app_rules=\(settings.appRules) "
             + "overlay_style=\(settings.overlayStyle.rawValue)")

        let notifier = Notifier(log: info)
        notifier.requestAuthorization()
        let updates = version == "dev" ? nil
            : UpdateChecker(version: version, throttle: UpdateThrottle(stateURL: paths.updateCheckJSON), log: info)
        let menuBar = MenuBar(version: version, paths: paths, historyEnabled: settings.historyEnabled,
                              historyMaxBytes: settings.historyMaxBytes, notifier: notifier, updates: updates,
                              overlayStyle: settings.overlayStyle, log: info)
        let slot = recognizer
        let coordinator = TakeCoordinator(
            settings: settings, paths: paths, audio: MicCapture(log: info), focus: SystemFocusProbe(),
            injector: Injector(env: SystemPasteEnvironment(), ownPID: getpid(), log: info),
            makeTranscriber: { StreamingTranscriber(recognizer: slot) }, ui: menuBar,
            pipeline: .standard(settings: settings, paths: paths, log: info), log: info)
        menuBar.coordinator = coordinator
        self.menuBar = menuBar
        self.coordinator = coordinator

        pollPermissions(hotkey: settings.hotkey)
        loadModel()
        if let updates {
            Task {
                if let latest = await updates.check() { menuBar.announceUpdate(latest) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log?.info("Sabbel shutting down")
        tap?.stop()
        instanceLock.release()
    }

    // MARK: permissions and hotkey

    /// Every second until Accessibility and the Microphone are granted, then
    /// starts the hotkey tap. The missing one is shown as the status.
    private func pollPermissions(hotkey spec: HotkeySpec) {
        Task {
            var gate = PermissionGate()
            var lastStatus: String?
            while true {
                let step = gate.step(accessibility: { Permissions.accessibilityGranted(prompt: $0) },
                                     microphone: { Permissions.microphoneStatus() })
                switch step {
                case .waiting(let status, let requestMicrophone):
                    if status != lastStatus { log.info("Waiting for permissions: \(status)") }
                    lastStatus = status
                    coordinator?.showStatus(status)
                    if requestMicrophone {
                        Task.detached { _ = await Permissions.requestMicrophone() }
                    }
                case .ready:
                    if startHotkey(spec) {
                        coordinator?.permissionsReady = true
                        log.info("Permissions ready; hotkey started")
                        return
                    }
                    // Trusted, yet the tap could not be created: try again next second.
                    if lastStatus != "Hotkey unavailable" { log.error("Could not create the hotkey event tap") }
                    lastStatus = "Hotkey unavailable"
                    coordinator?.showStatus("Hotkey unavailable")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startHotkey(_ spec: HotkeySpec) -> Bool {
        let log: RuntimeLog = self.log
        let tap = HotkeyTap(spec: spec, log: { log.info($0) }) { [weak self] input, time in
            // Main queue, not a Task: keys must reach the state machine in the order they happened.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleKey(input, at: time) }
            }
        }
        guard tap.start() else { return false }
        self.tap = tap
        return true
    }

    private func handleKey(_ input: KeyInput, at time: TimeInterval) {
        if let action = hotkey.handle(input, at: time) { coordinator?.handle(action) }
    }

    // MARK: model

    private func loadModel() {
        let slot = recognizer
        let log: RuntimeLog = self.log
        let started = Date()
        log.info("Loading model: \(EngineInfo.description)")
        // The delegate lives as long as the app, so the task holds it strongly.
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let parakeet = try await ParakeetRecognizer.load(progress: { event in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.modelProgress(event) }
                    }
                })
                slot.set(parakeet)
                log.info(String(format: "Model loaded in %.1fs", Date().timeIntervalSince(started)))
                await modelLoaded()
            } catch {
                log.error("Model load failed: \(String(reflecting: error))")
                await modelFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }

    private func modelLoaded() {
        coordinator?.modelState = .ready
        log.info("Ready")
    }

    /// The coordinator posts the `modelFailed` notice when the state turns `.failed`.
    private func modelFailed(_ message: String) {
        coordinator?.modelState = .failed(message)
    }

    /// Download and load progress. Ignored once the model is ready or failed,
    /// so a late progress report can never put the app back into "loading".
    private func modelProgress(_ event: ModelLoadEvent) {
        guard let coordinator, case .loading = coordinator.modelState else { return }
        let state = modelLoad.state(after: event)
        coordinator.modelState = state
        if case .loading(let fraction?) = state {
            let decile = Int((fraction * 10).rounded(.down))
            if decile > loggedModelDecile {
                loggedModelDecile = decile
                log.info("Model download \(decile * 10)%")
            }
        }
    }
}

/// The recognizer the takes use; filled in once the model has loaded. The
/// coordinator refuses takes until then, so `recognize` is never reached empty.
final class RecognizerSlot: Recognizer, Sendable {
    private struct NotLoaded: Error {}
    private let loaded = OSAllocatedUnfairLock<(any Recognizer)?>(initialState: nil)

    func set(_ recognizer: any Recognizer) { loaded.withLock { $0 = recognizer } }

    func recognize(_ samples: [Float]) async throws -> [TimedWord] {
        guard let recognizer = loaded.withLock({ $0 }) else { throw NotLoaded() }
        return try await recognizer.recognize(samples)
    }
}

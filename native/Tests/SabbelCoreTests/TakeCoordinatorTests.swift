import Foundation
import Testing
@testable import SabbelCore

/// Ports of the `SabbelApp` tests in `tests/test_app.py`, plus the streaming
/// cases the Python app never had.
@MainActor
final class Harness {
    let dir: URL
    let paths: SabbelPaths
    let audio = FakeAudioSource()
    let focus: FakeFocusProbe
    let env = FakePasteEnvironment()
    let ui = FakeUI()
    let recognizers: RecognizerQueue
    let coordinator: TakeCoordinator
    /// The coordinator's clock, in seconds; tests advance it to set a hold time.
    let clock = LockedBox<TimeInterval>(0)

    static let target = FocusTarget(pid: 101, name: "Editor")

    /// One word, "hello", inside the first 0.4 s of every take.
    static func hello(delay: TimeInterval = 0) -> FakeRecognizer {
        FakeRecognizer(script: [TimedWord(text: "hello", start: 0.1, end: 0.4)], mangle: .none, delay: delay)
    }

    init(settings: SabbelSettings = SabbelSettings(),
         focus: FakeFocusProbe = FakeFocusProbe(),
         recognizers: [FakeRecognizer] = [Harness.hello()],
         modelState: ModelState = .ready,
         permissionsReady: Bool = true,
         pipeline: TextPipeline = .identity) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sabbel-coordinator-\(UUID().uuidString)", isDirectory: true)
        paths = SabbelPaths(configDir: dir)
        self.focus = focus
        let queue = RecognizerQueue(recognizers)
        self.recognizers = queue
        coordinator = TakeCoordinator(
            settings: settings, paths: paths, audio: audio, focus: focus,
            injector: Injector(env: env, ownPID: focus.ownPID),
            makeTranscriber: { StreamingTranscriber(recognizer: queue.take()) },
            ui: ui, pipeline: pipeline, errorClearDelay: .milliseconds(30), now: { [clock] in clock.value })
        coordinator.modelState = modelState
        coordinator.permissionsReady = permissionsReady
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// FakeRecognizer's audio: every sample is its index, so it is loud and never silent.
    static func speech(_ seconds: Double) -> [Float] {
        FakeRecognizer.audio(from: 0, count: Int(seconds * 16_000))
    }

    /// Press, capture `samples`, release.
    func take(_ samples: [Float] = Harness.speech(0.75)) {
        coordinator.handle(.start)
        audio.send(samples)
        coordinator.handle(.stop)
    }

    var history: String? { try? String(contentsOf: paths.historyLog, encoding: .utf8) }

    var pasted: [String] {
        env.calls.compactMap { if case .writeTransient(let t) = $0 { return t } else { return nil } }
    }

    var commandVTargets: [Int32?] {
        env.calls.compactMap { if case .postCommandV(let pid) = $0 { return .some(pid) } else { return nil } }
    }
}

@MainActor
@Suite struct TakeCoordinatorTests {
    // MARK: model and readiness

    @Test func failedModelBlocksRecording() {
        let h = Harness(modelState: .failed("x"))
        h.coordinator.handle(.start)
        #expect(h.ui.notices.last == .modelFailed("x"))
        #expect(h.audio.startCount == 0)
        #expect(h.ui.icon == .failed)
        #expect(h.ui.status == "Model failed — restart Sabbel")
    }

    @Test func modelFailureNotifiesOnceWhenItHappens() {
        let h = Harness(modelState: .loading(progress: nil))
        h.coordinator.modelState = .failed("boom")
        #expect(h.ui.notices == [.modelFailed("boom")])
        h.coordinator.modelState = .failed("boom")
        #expect(h.ui.notices == [.modelFailed("boom")])
    }

    @Test func loadingModelBlocksRecording() {
        let h = Harness(modelState: .loading(progress: 0.3))
        h.coordinator.handle(.start)
        #expect(h.ui.notices == [.modelLoading])
        #expect(h.audio.startCount == 0)
    }

    @Test func readyOnlyWhenModelReady() {
        let h = Harness(modelState: .loading(progress: nil), permissionsReady: false)
        h.coordinator.permissionsReady = true
        #expect(h.ui.status == "Loading model...")
        #expect(!h.ui.statuses.contains("Ready"))
        h.coordinator.modelState = .ready
        #expect(h.ui.status == "Ready")
        #expect(h.ui.icon == .idle)
    }

    @Test func downloadProgressShowsIntegerPercent() {
        let h = Harness(modelState: .loading(progress: nil))
        h.coordinator.modelState = .loading(progress: 0.427)
        #expect(h.ui.status == "Downloading model… 42%")
        #expect(h.ui.icon == .working)
    }

    @Test func missingPermissionsLeaveTheStatusToTheApp() {
        let h = Harness(modelState: .loading(progress: nil), permissionsReady: false)
        h.coordinator.showStatus("Accessibility missing")
        h.coordinator.modelState = .loading(progress: 0.5)
        h.coordinator.modelState = .ready
        #expect(h.ui.status == "Accessibility missing")
        #expect(!h.ui.statuses.contains("Ready"))
        h.coordinator.permissionsReady = true
        #expect(h.ui.status == "Ready")
    }

    @Test func permissionsNeverOverwriteAModelFailure() {
        let h = Harness(modelState: .failed("x"), permissionsReady: false)
        h.coordinator.permissionsReady = true
        #expect(h.ui.status == "Model failed — restart Sabbel")
        #expect(!h.ui.statuses.contains("Ready"))
    }

    // MARK: cancel

    @Test func comboCancelIsSilent() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.audio.send(Harness.speech(0.75))
        h.coordinator.handle(.cancel(.combo))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.notices.isEmpty)
        #expect(h.audio.stopCount == 1)
        #expect(h.ui.icon == .idle)
        #expect(h.env.calls.isEmpty)
    }

    @Test func escapeCancelNotifies() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.audio.send(Harness.speech(0.75))
        h.coordinator.handle(.cancel(.escape))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.notices == [.cancelled])
        #expect(h.ui.icon == .idle)
        #expect(h.env.calls.isEmpty)
    }

    @Test func stopWithoutCaptureQueuesNothing() async {
        let h = Harness()
        h.audio.startError = FakeAudioSource.StartFailure()
        h.coordinator.handle(.start)
        h.coordinator.handle(.stop)
        await h.coordinator.waitUntilIdle()
        #expect(h.env.calls.isEmpty)
        #expect(h.audio.stopCount == 0)
    }

    // MARK: rejections

    @Test func tooShortShowsErrorWithoutNotice() async {
        let h = Harness()
        h.take(Harness.speech(0.2))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Too short") && $0.status == "Too short" })
        #expect(h.ui.notices.isEmpty)
        #expect(h.env.calls.isEmpty)
    }

    @Test func deadStreamShowsNoSignal() async {
        let h = Harness()
        h.take([Float](repeating: 0, count: 16_000))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("No signal") && $0.status == "No signal" })
        #expect(h.ui.notices == [.deadStream])
        #expect(h.env.calls.isEmpty)
    }

    /// The capture died before its first buffer: the key was held for a second
    /// but not one sample arrived. That is no signal, not a short take.
    @Test func noSamplesOverALongHoldIsNoSignal() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.clock.value += 1.0
        h.coordinator.handle(.stop)
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("No signal") && $0.status == "No signal" })
        #expect(h.ui.notices == [.deadStream])
        #expect(h.env.calls.isEmpty)
    }

    @Test func noSamplesOverAShortHoldIsTooShort() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.clock.value += 0.2
        h.coordinator.handle(.stop)
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Too short") })
        #expect(h.ui.notices.isEmpty)
    }

    @Test func noSpeechShowsNoAudio() async {
        let h = Harness()
        h.take([Float](repeating: 0.001, count: 16_000))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("No audio") && $0.status == "No audio" })
        #expect(h.ui.notices == [.noAudio])
        #expect(h.env.calls.isEmpty)
    }

    @Test func rejectedTakeStillClosesTheStream() async {
        let recognizer = Harness.hello()
        let h = Harness(recognizers: [recognizer])
        h.take(Harness.speech(0.2))
        await h.coordinator.waitUntilIdle()
        // finish() ran its final recognition, so the transcriber's stream closed.
        #expect(recognizer.calls.count == 1)
    }

    @Test func emptyTextIsNotRecognized() async {
        let h = Harness(recognizers: [FakeRecognizer(script: [], mangle: .none)])
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Not recognized") && $0.status == "Not recognized" })
        #expect(h.ui.notices.isEmpty)
        #expect(h.env.calls.isEmpty)
    }

    @Test func recognizerFailureShowsError() async {
        let h = Harness(recognizers: [FakeRecognizer(script: [], mangle: .none, failingCalls: [0])])
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Error") && $0.status == "Error" })
        #expect(h.env.calls.isEmpty)
    }

    @Test func errorClearsToReadyAfterTheDelay() async {
        let h = Harness()
        h.take(Harness.speech(0.2))
        await h.coordinator.waitUntilIdle()
        #expect(await eventually { h.ui.icon == .idle })
        #expect(h.ui.status == "Ready")
    }

    // MARK: outcomes

    private static func historyOn() -> SabbelSettings {
        var s = SabbelSettings()
        s.historyEnabled = true
        return s
    }

    @Test func pastedIsSavedWithoutNotice() async {
        let h = Harness(settings: Self.historyOn())
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["hello"])
        #expect(h.history?.contains("hello\n") == true)
        #expect(h.ui.notices.isEmpty)
        #expect(h.ui.icon == .idle)
        #expect(h.ui.status == "Ready")
    }

    @Test func leftInClipboardIsSavedAndNotified() async {
        let h = Harness(settings: Self.historyOn())
        h.env.focusedElementAnswer = { _, _ in
            FocusedElement(role: "AXImage", subrole: nil, hasSelectedTextRange: false,
                           valueSettable: false, selectedTextSettable: false)
        }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.history?.contains("hello") == true)
        #expect(h.ui.notices == [.textCopiedNoField])
    }

    @Test func focusChangedIsSavedAndNotified() async {
        let h = Harness(settings: Self.historyOn())
        h.env.frontmostPIDAnswer = { _, _ in 999 }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.history?.contains("hello") == true)
        #expect(h.ui.notices == [.textCopiedFocusChanged])
    }

    @Test func refusedSecureIsNotSaved() async {
        let h = Harness(settings: Self.historyOn())
        h.env.focusedElementAnswer = { _, _ in
            FocusedElement(role: "AXTextField", subrole: "AXSecureTextField", hasSelectedTextRange: true,
                           valueSettable: true, selectedTextSettable: true)
        }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.history == nil)
        #expect(h.ui.notices == [.discardedSecure])
    }

    @Test func historyOffWritesNothing() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["hello"])
        #expect(!FileManager.default.fileExists(atPath: h.paths.historyLog.path))
    }

    @Test func historyToggleTakesEffect() async {
        let h = Harness()
        h.coordinator.historyEnabled = true
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.history?.contains("hello") == true)
    }

    // MARK: focus and live text

    @Test func secureAtStartMasksLiveText() async {
        let h = Harness(focus: FakeFocusProbe([(Harness.target, true)]),
                        recognizers: [FakeRecognizer(script: FakeRecognizer.script(until: 2.5), mangle: .none)])
        h.take(Harness.speech(2.5))
        await h.coordinator.waitUntilIdle()
        #expect(await eventually { h.ui.lives.contains { !$0.text.settled.isEmpty || !$0.text.provisional.isEmpty } })
        #expect(!h.ui.lives.isEmpty)
        #expect(h.ui.lives.allSatisfy { $0.masked })
    }

    @Test func secureAtStartIsNeverPastedOrSaved() async {
        let recognizer = Harness.hello()
        var settings = SabbelSettings()
        settings.historyEnabled = true
        // Secure when the take starts; a normal field by paste time (the fake
        // paste environment reports no focused element at all).
        let h = Harness(settings: settings, focus: FakeFocusProbe([(Harness.target, true)]),
                        recognizers: [recognizer])
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.env.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.paths.historyLog.path))
        #expect(h.ui.notices == [.discardedSecure])
        #expect(h.ui.icon == .idle)
        // finish() still ran, so the take's stream closed.
        #expect(recognizer.calls.count == 1)
    }

    @Test func liveTextIsForwardedUnmasked() async {
        let h = Harness(recognizers: [FakeRecognizer(script: FakeRecognizer.script(until: 2.5), mangle: .none)])
        h.take(Harness.speech(2.5))
        await h.coordinator.waitUntilIdle()
        #expect(await eventually { h.ui.lives.contains { !$0.text.settled.isEmpty || !$0.text.provisional.isEmpty } })
        #expect(h.ui.lives.allSatisfy { !$0.masked })
    }

    @Test func ownPidTargetIsNeverPastedInto() async {
        let h = Harness(focus: FakeFocusProbe([(FocusTarget(pid: 4_242, name: "Sabbel"), false)], ownPID: 4_242))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.commandVTargets == [nil])
    }

    /// Sabbel is still frontmost when the take pastes (a click on its notification
    /// banner): the text stays on the clipboard, with a notice, and is saved.
    @Test func sabbelFrontmostAtPasteLeavesTextInClipboard() async {
        let h = Harness(settings: Self.historyOn(),
                        focus: FakeFocusProbe([(FocusTarget(pid: 4_242, name: "Sabbel"), false)], ownPID: 4_242))
        h.env.frontmostPIDAnswer = { _, _ in 4_242 }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.commandVTargets.isEmpty)
        #expect(h.env.currentString == "hello")
        #expect(h.ui.notices == [.textCopiedNoField])
        #expect(h.history?.contains("hello") == true)
    }

    // MARK: text pipeline

    @Test func pipelineRewritesWhatIsPastedAndSaved() async {
        let h = Harness(settings: Self.historyOn(), pipeline: TextPipeline([{ text, _ in text.uppercased() }]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["HELLO"])
        #expect(h.history?.contains("HELLO\n") == true)
        #expect(h.history?.contains("hello") == false)
    }

    @Test func pipelineSeesTheTakesTarget() async {
        let seen = LockedBox<[FocusTarget?]>([])
        let h = Harness(pipeline: TextPipeline([{ text, target in seen.mutate { $0.append(target) }; return text }]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(seen.value == [Harness.target])
    }

    @Test func textEmptiedByThePipelineIsNotRecognized() async {
        let h = Harness(settings: Self.historyOn(), pipeline: TextPipeline([{ _, _ in " " }]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Not recognized") })
        #expect(h.env.calls.isEmpty)
        #expect(h.history == nil)
    }

    @Test func injectGetsTheTakesTarget() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.commandVTargets == [101])
    }

    // MARK: microphone

    @Test func micStartFailureShowsMicError() async {
        let h = Harness()
        h.audio.startError = FakeAudioSource.StartFailure()
        h.coordinator.handle(.start)
        #expect(h.ui.icon == .error("Mic error"))
        #expect(h.ui.status == "Mic error")
        #expect(await eventually { h.ui.icon == .idle })
        #expect(h.ui.status == "Ready")
    }

    @Test func micFallbackNotifiesOncePerDevice() async {
        var settings = SabbelSettings()
        settings.audioDevice = "USB Mic"
        let h = Harness(settings: settings)
        h.audio.missingDevice = "USB Mic"
        for _ in 0..<2 {
            h.coordinator.handle(.start)
            h.coordinator.handle(.cancel(.combo))
        }
        #expect(h.audio.devices == ["USB Mic", "USB Mic"])
        #expect(h.ui.notices == [.micFallback("USB Mic")])
    }

    @Test func micFallbackNotifiesAgainAfterTheMicCameBack() {
        let h = Harness()
        h.audio.missingDevice = "USB Mic"
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.combo))
        h.audio.missingDevice = nil
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.combo))
        h.audio.missingDevice = "USB Mic"
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.combo))
        #expect(h.ui.notices == [.micFallback("USB Mic"), .micFallback("USB Mic")])
    }

    @Test func choosingAMicUsesItAndResetsTheFallbackNotice() {
        let h = Harness()
        h.audio.missingDevice = "USB Mic"
        h.coordinator.audioDevice = "USB Mic"
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.combo))
        // Picking another mic and then the missing one again asks anew.
        h.coordinator.audioDevice = "Desk Mic"
        h.coordinator.audioDevice = "USB Mic"
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.combo))
        #expect(h.audio.devices == ["USB Mic", "USB Mic"])
        #expect(h.ui.notices == [.micFallback("USB Mic"), .micFallback("USB Mic")])
    }

    @Test func captureEndingEarlyStillFinishesTake() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.audio.send(Harness.speech(0.75))
        // The device went away: no more samples arrive, then the user releases.
        try? await Task.sleep(for: .milliseconds(50))
        h.coordinator.handle(.stop)
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["hello"])
        #expect(h.ui.icon == .idle)
    }

    // MARK: order and threads

    @Test func overlappingTakesPasteInOrderToOwnTargets() async {
        let slowA = FakeRecognizer(script: [TimedWord(text: "alpha", start: 0.1, end: 0.4)], mangle: .none, delay: 0.3)
        let fastB = FakeRecognizer(script: [TimedWord(text: "bravo", start: 0.1, end: 0.4)], mangle: .none)
        let h = Harness(focus: FakeFocusProbe([(FocusTarget(pid: 101, name: "A"), false),
                                               (FocusTarget(pid: 202, name: "B"), false)]),
                        recognizers: [slowA, fastB])
        h.take()
        #expect(h.ui.icon == .working)
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["alpha", "bravo"])
        #expect(h.commandVTargets == [101, 202])
        #expect(h.ui.icon == .idle)
    }

    @Test func recordingIconSurvivesAnEarlierTakeFinishing() async {
        let slowA = FakeRecognizer(script: [TimedWord(text: "alpha", start: 0.1, end: 0.4)], mangle: .none, delay: 0.1)
        let h = Harness(recognizers: [slowA, Harness.hello()])
        h.take()
        h.coordinator.handle(.start)
        #expect(h.ui.icon == .recording)
        await h.coordinator.waitUntilIdle()
        #expect(h.pasted == ["alpha"])
        #expect(h.ui.icon == .recording)
        h.coordinator.handle(.cancel(.combo))
        #expect(h.ui.icon == .idle)
    }

    @Test func pasteRunsOffMainActor() async {
        let h = Harness()
        let onMain = LockedBox<[Bool]>([])
        h.env.onCall = { call, _ in
            if case .postCommandV = call { onMain.mutate { $0.append(Thread.isMainThread) } }
        }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(onMain.value == [false])
    }

    @Test func recordingShowsRecordingThenWorking() async {
        let h = Harness()
        h.coordinator.handle(.start)
        #expect(h.ui.icon == .recording)
        #expect(h.ui.status == "Ready")
        h.audio.send(Harness.speech(0.75))
        h.coordinator.handle(.stop)
        #expect(h.ui.icon == .working)
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.icon == .idle)
    }
}

@Suite struct NoticeTests {
    @Test func copyMatchesTheApp() {
        let cases: [(Notice, String, String)] = [
            (.modelLoading, "Model still loading", "Please wait. The icon will change to 🎙 when Sabbel is ready."),
            (.modelFailed("bad"), "Model could not be loaded", "bad — details in /tmp/sabbel-runtime.log"),
            (.cancelled, "Recording cancelled", "Escape pressed — the dictation was discarded."),
            (.deadStream, "Microphone delivered no signal", "Check that the mic isn't muted and input volume isn't zero."),
            (.noAudio, "No audio detected", "No speech was detected in the last recording."),
            (.micFallback("USB"), "Mic 'USB' not found", "Using system default. Pick another mic from the Sabbel menu."),
            (.textCopiedNoField, "Text copied to clipboard", "No text field detected. Paste manually with Cmd+V."),
            (.textCopiedFocusChanged, "Text copied to clipboard",
             "You switched apps while it was transcribing. Paste with Cmd+V."),
            (.discardedSecure, "Dictation discarded", "Sabbel does not type into password fields."),
            (.diagnosticsCopied(true), "Diagnostics copied", "Paste them into your bug report."),
            (.diagnosticsCopied(false), "Could not copy", "Send /tmp/sabbel-runtime.log instead."),
            (.historyCleared, "History cleared", ""),
            (.updateAvailable("1.2.0"), "Update v1.2.0 available", "Click 'Update' in the Sabbel menu for details."),
        ]
        for (notice, subtitle, message) in cases {
            #expect(notice.subtitle == subtitle)
            #expect(notice.message == message)
        }
    }

    @Test func modelFailureMessageKeepsOnly160Characters() {
        let long = String(repeating: "x", count: 300)
        #expect(Notice.modelFailed(long).message == String(repeating: "x", count: 160) + " — details in /tmp/sabbel-runtime.log")
    }
}

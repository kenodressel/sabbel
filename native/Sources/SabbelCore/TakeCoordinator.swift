import Foundation

/// What the menu bar icon shows.
public enum IconState: Equatable, Sendable { case idle, recording, working, error(String), failed }

/// Where the speech model is. The app sets it as loading progresses.
public enum ModelState: Equatable, Sendable { case loading(progress: Double?), ready, failed(String) }

/// The microphone, as the coordinator sees it.
public protocol AudioSource: AnyObject, Sendable {
    /// Starts capture; returns the name of a chosen mic that was missing (fell back to default), if any.
    func start(device: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws -> String?
    func stop()
}

/// Reads the app and field that have focus when a take starts.
public protocol FocusProbe: Sendable {
    /// The frontmost app, and whether its focused element is a password field.
    func capture() -> (target: FocusTarget?, secure: Bool)
    /// Sabbel's own pid.
    var ownPID: Int32 { get }
}

/// The menu bar, notifications and live window.
@MainActor public protocol SabbelUI: AnyObject {
    func show(_ icon: IconState, status: String)
    func notify(_ notice: Notice)
    /// `masked`: the take started in a password field, so the text must not be shown.
    func live(_ text: LiveText, masked: Bool)
}

/// The app's behaviour: one take from hotkey press to pasted text. Port of `SabbelApp`.
///
/// - A take's transcriber, statistics and focus target are created at press
///   time and travel with it, so a second press can never take over the first
///   take's target while that one is still transcribing.
/// - Released takes are pasted one at a time, in take order, off the main actor
///   (`PasteLine`): waiting out held modifiers and polling for the paste froze
///   the menu bar for up to 3 s when it ran on the main thread.
@MainActor
public final class TakeCoordinator {
    /// The take being recorded.
    private struct Capture {
        let transcriber: StreamingTranscriber
        let samples: AsyncStream<[Float]>.Continuation
        let feeder: Task<TakeStats, Never>
        let live: Task<Void, Never>
        let target: FocusTarget?
        let secure: Bool
    }

    private let audio: any AudioSource
    private let focus: any FocusProbe
    private let ui: any SabbelUI
    private let makeTranscriber: @Sendable () -> StreamingTranscriber
    private let errorClearDelay: Duration
    private let log: (@Sendable (String) -> Void)?
    private let jobs: AsyncStream<PasteJob>.Continuation

    /// The app sets it as loading progresses.
    public var modelState: ModelState = .loading(progress: nil) {
        didSet { modelStateChanged(from: oldValue) }
    }

    /// Accessibility and Microphone are granted and the hotkey is live. Until
    /// then the status line belongs to the app (see `showStatus`).
    public var permissionsReady = false {
        didSet { render() }
    }

    /// The menu toggle. Only changes behaviour; the caller persists it with `Preferences.save`.
    public var historyEnabled: Bool

    /// The microphone chosen in the menu, nil for the system default. Choosing
    /// another one forgets which missing mic the user was already told about.
    public var audioDevice: String? {
        didSet { if audioDevice != oldValue { notifiedMissingDevice = nil } }
    }

    /// What the menu bar shows right now (also for "Copy diagnostics").
    public private(set) var icon: IconState = .working
    public private(set) var status = "Starting"

    private var shown = false
    private var appStatus = "Starting"
    private var capture: Capture?
    private var nextTakeID = 0
    /// Only the newest take's live text reaches the window.
    private var liveTakeID: Int?
    /// Released takes not yet pasted or rejected.
    private var pending = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var errorText: String?
    private var errorClear: Task<Void, Never>?
    private var notifiedMissingDevice: String?

    /// - Parameters:
    ///   - errorClearDelay: how long an error stays in the menu bar before it
    ///     clears back to idle.
    ///   - log: receives the decisions `app.py` logs, never the dictated text.
    public init(settings: SabbelSettings, paths: SabbelPaths, audio: any AudioSource, focus: any FocusProbe,
                injector: Injector, makeTranscriber: @escaping @Sendable () -> StreamingTranscriber,
                ui: any SabbelUI, errorClearDelay: Duration = .seconds(2),
                log: (@Sendable (String) -> Void)? = nil) {
        self.audio = audio
        self.focus = focus
        self.ui = ui
        self.makeTranscriber = makeTranscriber
        self.errorClearDelay = errorClearDelay
        self.log = log
        historyEnabled = settings.historyEnabled
        audioDevice = settings.audioDevice

        let (stream, jobs) = AsyncStream.makeStream(of: PasteJob.self)
        self.jobs = jobs
        let line = PasteLine(injector: injector,
                             history: HistoryLog(url: paths.historyLog, maxBytes: settings.historyMaxBytes),
                             minDuration: settings.minDuration, log: log)
        let deliver: @Sendable (TakeResult) async -> Void = { [weak self] result in
            await self?.finished(result)
        }
        Task.detached(priority: .userInitiated) { await line.run(stream, deliver: deliver) }
        render()
    }

    deinit { jobs.finish() }

    /// A status line the app owns: "Accessibility missing", "Microphone missing".
    /// Shown while `permissionsReady` is false.
    public func showStatus(_ text: String) {
        appStatus = text
        render()
    }

    public func handle(_ action: HotkeyAction) {
        switch action {
        case .start: start()
        case .stop: stop()
        case .cancel(let reason): cancel(reason)
        }
    }

    /// Returns once every released take has been pasted or rejected and shown.
    public func waitUntilIdle() async {
        guard pending > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: takes

    private func start() {
        switch modelState {
        case .failed(let message):
            info("Recording blocked: model failed to load")
            ui.notify(.modelFailed(message))
            return
        case .loading:
            info("Recording blocked: model still loading")
            ui.notify(.modelLoading)
            return
        case .ready:
            break
        }
        guard capture == nil else { return }
        info("Recording start requested")

        // Snapshot the target app now: transcription takes seconds and the user
        // often switches windows while it runs.
        let focused = focus.capture()
        var target = focused.target
        if target?.pid == focus.ownPID {
            // Sabbel's own window (the live panel) is never the destination. With
            // no target the injector judges whatever field is frontmost at paste time.
            target = nil
        }

        let transcriber = makeTranscriber()
        let (samples, sink) = AsyncStream.makeStream(of: [Float].self)
        let missing: String?
        do {
            missing = try audio.start(device: audioDevice) { sink.yield($0) }
        } catch {
            info("Recorder error: \(error)")
            sink.finish()
            showError("Mic error")
            return
        }
        if let missing {
            if missing != notifiedMissingDevice {
                notifiedMissingDevice = missing
                ui.notify(.micFallback(missing))
            }
        } else {
            notifiedMissingDevice = nil
        }

        // One serial consumer per take: `append` must see the buffers in order,
        // and the stats must count every one of them.
        let feeder = Task.detached(priority: .userInitiated) { () -> TakeStats in
            var stats = TakeStats()
            for await buffer in samples {
                stats.add(buffer)
                await transcriber.append(buffer)
            }
            return stats
        }

        nextTakeID += 1
        let id = nextTakeID
        liveTakeID = id
        let secure = focused.secure
        ui.live(LiveText(settled: "", provisional: ""), masked: secure)
        let live = Task { [weak self] in
            for await text in transcriber.updates {
                guard let self else { return }
                if self.liveTakeID == id { self.ui.live(text, masked: secure) }
            }
        }

        capture = Capture(transcriber: transcriber, samples: sink, feeder: feeder, live: live,
                          target: target, secure: secure)
        // A new take replaces an error still on display.
        clearError()
        render()
    }

    private func stop() {
        guard let take = capture else {
            info("Recording stop ignored — capture never started")
            return
        }
        capture = nil
        info("Recording stop requested")
        audio.stop()
        take.samples.finish()
        pending += 1
        jobs.yield(PasteJob(transcriber: take.transcriber, feeder: take.feeder, target: take.target,
                            saveHistory: historyEnabled))
        render()
    }

    /// Drop the audio, transcribe nothing.
    ///
    /// Two very different events land here. A combo cancel is ⌥-typing and
    /// happens dozens of times a day, so it stays silent. Escape is a deliberate
    /// abort, and staying silent there reads as a bug: the user spoke and got
    /// nothing back, with no sign the app meant it.
    private func cancel(_ reason: CancelReason) {
        guard let take = capture else { return }
        capture = nil
        info("Recording cancelled (\(reason))")
        audio.stop()
        take.samples.finish()
        take.feeder.cancel()
        take.live.cancel()
        ui.live(LiveText(settled: "", provisional: ""), masked: take.secure)
        if reason == .escape { ui.notify(.cancelled) }
        render()
    }

    private func finished(_ result: TakeResult) {
        pending -= 1
        switch result {
        case .rejected(.tooShort):
            showError("Too short")
        case .rejected(.deadStream):
            showError("No signal")
            ui.notify(.deadStream)
        case .rejected(.noSpeech):
            showError("No audio")
            ui.notify(.noAudio)
        case .rejected(.accept):
            render()
        case .failed:
            showError("Error")
        case .notRecognized:
            showError("Not recognized")
        case .injected(let outcome):
            if let notice = Self.notice(for: outcome) { ui.notify(notice) }
            render()
        }
        if pending == 0 {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    private static func notice(for outcome: InjectOutcome) -> Notice? {
        switch outcome {
        case .pasted: nil
        case .leftInClipboard: .textCopiedNoField
        case .focusChanged: .textCopiedFocusChanged
        case .refusedSecure: .discardedSecure
        }
    }

    // MARK: status

    private func modelStateChanged(from old: ModelState) {
        if case .failed(let message) = modelState, modelState != old {
            // Deliberately not an error that clears: that would claim "Ready"
            // after two seconds while every hotkey press is refused.
            clearError()
            ui.notify(.modelFailed(message))
        }
        render()
    }

    /// Shows `text` in the menu bar and clears it after `errorClearDelay`.
    private func showError(_ text: String) {
        info("Sabbel error: \(text)")
        clearError()
        errorText = text
        let delay = errorClearDelay
        errorClear = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.errorText = nil
            self.render()
        }
        render()
    }

    private func clearError() {
        errorClear?.cancel()
        errorClear = nil
        errorText = nil
    }

    /// The status line when nothing more specific is showing. Never "Ready"
    /// while the model is loading or failed, so the menu never claims the app
    /// works while every press is refused.
    private var baseStatus: String {
        guard permissionsReady else { return appStatus }
        switch modelState {
        case .loading(let progress?):
            let percent = min(100, max(0, Int((progress * 100 + 1e-6).rounded(.down))))
            return "Downloading model… \(percent)%"
        case .loading(nil): return "Loading model..."
        case .ready: return "Ready"
        case .failed: return "Model failed — restart Sabbel"
        }
    }

    /// Derives icon and status from the state, in priority order: a failed
    /// model, recording (the user must always see the mic is live), an error,
    /// work in progress (takes or the model loading), idle.
    private func render() {
        let next: (IconState, String)
        if case .failed = modelState {
            next = (.failed, "Model failed — restart Sabbel")
        } else if capture != nil {
            next = (.recording, baseStatus)
        } else if let errorText {
            next = (.error(errorText), errorText)
        } else if pending > 0 || modelState != .ready {
            next = (.working, baseStatus)
        } else {
            next = (.idle, baseStatus)
        }
        guard !shown || next.0 != icon || next.1 != status else { return }
        shown = true
        (icon, status) = next
        ui.show(icon, status: status)
    }

    private func info(_ message: String) { log?(message) }
}

/// A released take on its way to the paste line.
struct PasteJob: Sendable {
    let transcriber: StreamingTranscriber
    /// Ends when capture has stopped and every buffer was appended.
    let feeder: Task<TakeStats, Never>
    let target: FocusTarget?
    let saveHistory: Bool
}

/// What became of a released take.
enum TakeResult: Sendable {
    case rejected(TakeVerdict)
    /// The final recognition threw.
    case failed
    case notRecognized
    case injected(InjectOutcome)
}

/// Finishes, judges, pastes and saves released takes one at a time, in take order.
///
/// Its executor is a dedicated serial queue, so the injector's blocking waits
/// (held modifiers, paste verification) never occupy the main thread or a
/// thread of the shared concurrency pool.
actor PasteLine {
    private let queue = DispatchSerialQueue(label: "com.sabbel.paste", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let injector: Injector
    private let history: HistoryLog
    private let minDuration: TimeInterval
    private let log: (@Sendable (String) -> Void)?

    init(injector: Injector, history: HistoryLog, minDuration: TimeInterval, log: (@Sendable (String) -> Void)?) {
        self.injector = injector
        self.history = history
        self.minDuration = minDuration
        self.log = log
    }

    /// The single consumer: a job's result is delivered before the next job
    /// starts, so pastes and their notices keep take order.
    func run(_ jobs: AsyncStream<PasteJob>, deliver: @Sendable (TakeResult) async -> Void) async {
        for await job in jobs {
            await deliver(await process(job))
        }
    }

    private func process(_ job: PasteJob) async -> TakeResult {
        let stats = await job.feeder.value
        let verdict = stats.verdict(minDuration: minDuration)
        log?("Processing take: duration=\(String(format: "%.3f", stats.duration))s verdict=\(verdict)")

        // Judged before the text is awaited, but a rejected take still finishes,
        // so its transcriber's live stream closes.
        guard verdict == .accept else {
            _ = try? await job.transcriber.finish()
            return .rejected(verdict)
        }

        let text: String
        do {
            text = try await job.transcriber.finish()
        } catch {
            log?("Transcription error: \(error)")
            return .failed
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log?("Recording rejected: empty transcription")
            return .notRecognized
        }

        log?("Transcription succeeded: chars=\(text.count)")
        let outcome = injector.inject(text, target: job.target)
        log?("Inject outcome: \(outcome.rawValue)")
        // Only once the outcome is known: a dictation refused by a password field
        // must not end up on disk either.
        if outcome != .refusedSecure && job.saveHistory {
            do {
                try history.append(text)
            } catch {
                log?("Failed to save to history: \(error)")
            }
        }
        return .injected(outcome)
    }
}

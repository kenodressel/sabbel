import Dispatch
import Foundation
import os

/// The rules of the app's `--e2e` run, a port of `scripts/e2e.py`: its
/// constants and the decisions that need no Mac to test.
public enum E2ERules {
    public static let phrase = "Hello world, this is a dictation test."
    public static let expectedWords: Set<String> = ["hello", "world", "test"]
    public static let defaultRuns = 3
    /// A first run downloads the model.
    public static let modelTimeout: TimeInterval = 600
    public static let takeTimeout: TimeInterval = 30
    /// One take keeps the recognizer busy for seconds; the main thread must not notice.
    public static let maxMainThreadGapMS = 250.0
    /// Takes interrupted by another app taking focus are retried, up to this many.
    public static let maxInterruptions = 3
    /// Hotkey release to Cmd+V posted.
    public static let maxFinishLatencyMS = 500.0
    public static let sentinel = "sabbel-e2e clipboard sentinel"
    public static let documentName = "e2e-target.txt"

    /// What a take does besides dictating into TextEdit.
    public enum TakeKind: Equatable, Sendable {
        case plain
        /// Runs with the live panel shown.
        case livePanel
        /// Another app (Finder) takes the front right before Cmd+V.
        case focusLost
    }

    /// `RUNS` from the environment, as in e2e.py, but never fewer than the
    /// three takes the live-panel and focus-loss scenarios need.
    public static func runs(environment: [String: String]) -> Int {
        max(defaultRuns, environment["RUNS"].flatMap { Int($0) } ?? defaultRuns)
    }

    /// The scenario of the take with this index among the takes that counted
    /// (interrupted takes are retried under the same index).
    public static func kind(ofTake index: Int) -> TakeKind {
        switch index {
        case 1: .livePanel
        case 2: .focusLost
        default: .plain
        }
    }

    /// e2e.py's `words`: whitespace-split, `.,!?` stripped, lowercased.
    public static func words(_ text: String) -> Set<String> {
        let strip = CharacterSet(charactersIn: ".,!?")
        return Set(text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: strip).lowercased() })
    }

    /// The longest pause between main-thread ticks inside `from...to`, in ms;
    /// infinity when fewer than two ticks fall inside.
    public static func longestGapMS(_ ticks: [TimeInterval], from: TimeInterval, to: TimeInterval) -> Double {
        let window = ticks.filter { from <= $0 && $0 <= to }
        guard window.count > 1 else { return .infinity }
        return 1000 * zip(window.dropFirst(), window).map { $0 - $1 }.max()!
    }

    /// Not Sabbel's doing: something else took the front while the take ran
    /// (the user, or an app grabbing focus). Sabbel must then hold the text back;
    /// the run checks that and goes again. The focus-loss take steals focus on
    /// purpose, so its outcome is its result and it is never retried. Sabbel
    /// itself in front (`ownPID`) is a failure to report, never a retry.
    public static func isInterruption(kind: TakeKind, outcome: InjectOutcome?, frontmostPID: Int32?,
                                      targetPID: Int32?, ownPID: Int32, interruptions: Int) -> Bool {
        kind != .focusLost && outcome == .focusChanged && frontmostPID != targetPID
            && frontmostPID != ownPID && interruptions < maxInterruptions
    }

    /// Only put the old clipboard back over the run's own writes. Anything else
    /// is a copy made during the run, and clobbering it loses it.
    public static func shouldRestoreClipboard(current: String?, written: [String]) -> Bool {
        current == nil || current == sentinel || written.contains(current!)
    }

    public static func finishLatencyOK(ms: Double) -> Bool { ms <= maxFinishLatencyMS }
}

/// PASS/FAIL bookkeeping, printed the way e2e.py prints it.
public struct E2EChecks {
    public private(set) var failures: [String] = []
    private let output: (String) -> Void

    public init(output: @escaping (String) -> Void) { self.output = output }

    /// Prints and returns `  PASS  label — detail`; a failure is remembered.
    @discardableResult
    public mutating func check(_ ok: Bool, _ label: String, _ detail: String = "") -> String {
        let line = "  \(ok ? "PASS" : "FAIL")  \(label)" + (detail.isEmpty ? "" : " — \(detail)")
        output(line)
        if !ok { failures.append(label) }
        return line
    }

    public var summary: String {
        let failed = failures.count
        let list = failures.map { "'\($0)'" }.joined(separator: ", ")
        return "\n\(failed > 0 ? "FAILED" : "PASSED"): \(failed) failed check(s)" + (failed > 0 ? " — [\(list)]" : "")
    }

    public var exitCode: Int32 { failures.isEmpty ? 0 : 1 }
}

/// What one take's paste did, as `RecordingPasteEnvironment` saw it.
public struct E2EPasteRecord: Sendable {
    public struct CommandV: Sendable {
        /// `now()` of the environment right after Cmd+V was posted.
        public let at: TimeInterval
        /// The frontmost app when it was posted.
        public let frontmostPID: Int32?
    }

    /// Texts the injector put on the clipboard.
    public var writes: [String] = []
    public var writesOnMainThread: [Bool] = []
    /// The dispatch queue each write ran on.
    public var writeQueues: [String] = []
    public var commandV: [CommandV] = []
    /// The last frontmost pid the injector was told.
    public var lastFrontmostPID: Int32?
    /// The focus thief ran.
    public var stoleFocus = false
}

/// The injector's paste environment in the `--e2e` run: forwards to the real
/// one, records what the take did, and for the focus-loss take hands the front
/// to another app at the first `modifiersHeld()` call — after the injector's
/// first focus check, before the one right before Cmd+V.
public final class RecordingPasteEnvironment: PasteEnvironment, @unchecked Sendable {
    private struct State {
        var take = E2EPasteRecord()
        var all: [String] = []
        var thief: (@Sendable () -> Void)?
    }

    private let base: any PasteEnvironment
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(base: any PasteEnvironment) { self.base = base }

    /// Starts a new take's record. `stealFocus` runs once, on the take's first
    /// `modifiersHeld()` call, and must return once the other app is in front.
    public func beginTake(stealFocus: (@Sendable () -> Void)?) {
        state.withLock {
            $0.take = E2EPasteRecord()
            $0.thief = stealFocus
        }
    }

    /// The current take's record.
    public func record() -> E2EPasteRecord { state.withLock { $0.take } }

    /// Every text the injector wrote during the run.
    public var allWrites: [String] { state.withLock { $0.all } }

    // MARK: PasteEnvironment

    public func frontmostPID() -> Int32? {
        let pid = base.frontmostPID()
        state.withLock { $0.take.lastFrontmostPID = pid }
        return pid
    }

    public func modifiersHeld() -> Bool {
        let thief: (@Sendable () -> Void)? = state.withLock {
            let thief = $0.thief
            $0.thief = nil
            if thief != nil { $0.take.stoleFocus = true }
            return thief
        }
        thief?()
        return base.modifiersHeld()
    }

    public func writeTransient(_ text: String) -> Int {
        let main = Thread.isMainThread
        let queue = String(cString: __dispatch_queue_get_label(nil))
        state.withLock {
            $0.take.writes.append(text)
            $0.take.writesOnMainThread.append(main)
            $0.take.writeQueues.append(queue)
            $0.all.append(text)
        }
        return base.writeTransient(text)
    }

    public func postCommandV(to pid: Int32?) {
        let front = base.frontmostPID()
        base.postCommandV(to: pid)
        let at = base.now()
        state.withLock { $0.take.commandV.append(.init(at: at, frontmostPID: front)) }
    }

    public func focusedElement() -> FocusedElement? { base.focusedElement() }
    public func focusedValue() -> String? { base.focusedValue() }
    public func captureClipboard() -> ClipboardSnapshot { base.captureClipboard() }
    public func restoreClipboard(_ snapshot: ClipboardSnapshot) { base.restoreClipboard(snapshot) }
    public func clipboardChangeCount() -> Int { base.clipboardChangeCount() }
    public func clipboardString() -> String? { base.clipboardString() }
    public func sleep(_ seconds: TimeInterval) { base.sleep(seconds) }
    public func now() -> TimeInterval { base.now() }
}

/// An `AudioSource` that plays fixed samples (speech from `say`) in place of
/// the microphone: 100 ms chunks, each delivered once it would have been
/// recorded, so the streaming transcriber sees a take at the pace of a real one.
public final class FedAudioSource: AudioSource, @unchecked Sendable {
    private struct State {
        /// Bumped by every start and stop; a feed that sees another value has ended.
        var generation = 0
        var fed = false
    }

    private let samples: [Float]
    private let chunk: Int
    private let sampleRate: Double
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(samples: [Float], chunk: Int = 1_600, sampleRate: Double = 16_000) {
        self.samples = samples
        self.chunk = chunk
        self.sampleRate = sampleRate
    }

    public var sampleCount: Int { samples.count }

    /// Every sample of the current take has been delivered.
    public var fed: Bool { state.withLock { $0.fed } }

    public func start(device: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws -> String? {
        let generation = state.withLock {
            $0.generation += 1
            $0.fed = false
            return $0.generation
        }
        let samples = self.samples, chunk = self.chunk, seconds = Double(chunk) / sampleRate
        let state = self.state
        Thread.detachNewThread {
            let begin = ProcessInfo.processInfo.systemUptime
            for (i, offset) in stride(from: 0, to: samples.count, by: chunk).enumerated() {
                let due = begin + Double(i + 1) * seconds
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // Delivered under the lock, so nothing arrives once stop() has returned.
                let live = state.withLock { s -> Bool in
                    guard s.generation == generation else { return false }
                    onSamples(Array(samples[offset..<min(offset + chunk, samples.count)]))
                    return true
                }
                if !live { return }
            }
            state.withLock { if $0.generation == generation { $0.fed = true } }
        }
        return nil
    }

    public func stop() {
        state.withLock { $0.generation += 1 }
    }
}

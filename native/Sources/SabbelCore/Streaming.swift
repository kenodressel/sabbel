import Foundation

/// One recognised word with its times in seconds.
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The speech model, as the streaming transcriber sees it.
public protocol Recognizer: Sendable {
    /// Words with times relative to samples[0], 16 kHz mono.
    func recognize(_ samples: [Float]) async throws -> [TimedWord]
}

/// What the live window shows: the settled text, which is final, followed by the
/// current guess for the rest, shown as provisional.
public struct LiveText: Equatable, Sendable {
    public let settled: String
    public let provisional: String

    public init(settled: String, provisional: String) {
        self.settled = settled
        self.provisional = provisional
    }
}

/// Transcribes a take while it is being spoken, so that on release only the
/// unsettled tail is left to recognise (Palaver's local-agreement design).
///
/// - Time is audio time: "now" is the audio appended so far. There is no wall
///   clock in here.
/// - Every `step` seconds of new audio, a pass re-recognises the audio from
///   `keepFrom` to now.
/// - A word settles once two consecutive passes agree on it, or once it ended
///   more than `settleAge` seconds before now. Settled text is final.
/// - Only the audio from `keepFrom = max(0, settledEnd - finalContext, now - window)`
///   on is kept, so memory and per-pass compute do not grow with the take, not
///   even through long silence. Cutting at `now - window` loses no words: since
///   `settleAge < window`, every word that ended before then is already settled,
///   so what is dropped there is silence or settled audio.
/// - `finish()` recognises the audio from `keepFrom` once more (the unsettled
///   tail plus `finalContext` of left-hand context) and that result replaces the
///   tail, so the pasted text does not depend on how the window happened to fall.
/// - A pass whose recognizer throws changes nothing but the pass clock: the next
///   attempt comes `step` seconds of audio later.
public actor StreamingTranscriber {
    private let recognizer: any Recognizer
    private let settleAge: TimeInterval
    private let finalContext: TimeInterval
    private let sampleRate: Double
    private let stepSamples: Int
    private let windowSamples: Int

    // State, all times absolute in the take.
    private var settled: [TimedWord] = []
    /// The end of the last settled word (0 at the start).
    private var settledEnd: TimeInterval = 0
    /// The last pass's unsettled words.
    private var previous: [TimedWord] = []
    /// The audio from `keptStart` to now; everything before it is dropped.
    private var kept: [Float] = []
    /// Absolute sample index of `kept[0]`, i.e. `keepFrom` in samples.
    private var keptStart = 0
    /// Total samples appended: now = totalSamples / sampleRate.
    private var totalSamples = 0
    /// `totalSamples` when the last pass was attempted (it may have failed).
    private var lastPassSamples = 0

    /// A pass is awaiting the recognizer. The actor is reentrant across that
    /// await, so this, not the actor, is what keeps two passes from overlapping.
    private var passInFlight = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishing = false
    /// The one final recognition; a second `finish()` awaits it instead of
    /// recognising again.
    private var finishTask: Task<String, any Error>?

    private var _passCount = 0
    private let continuation: AsyncStream<LiveText>.Continuation

    /// The live text after every pass; finishes when `finish()` returns or throws.
    /// Only the newest value is buffered: a reader that falls behind skips to it.
    public nonisolated let updates: AsyncStream<LiveText>

    public init(recognizer: any Recognizer, window: TimeInterval = 10, step: TimeInterval = 1,
                settleAge: TimeInterval = 3, finalContext: TimeInterval = 3, sampleRate: Double = 16_000) {
        self.recognizer = recognizer
        self.settleAge = settleAge
        self.finalContext = finalContext
        self.sampleRate = sampleRate
        self.stepSamples = max(1, Int((step * sampleRate).rounded()))
        self.windowSamples = Int((window * sampleRate).rounded())
        let (stream, continuation) = AsyncStream.makeStream(of: LiveText.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        self.updates = stream
        self.continuation = continuation
    }

    /// Samples currently held (from `keepFrom` to now).
    public var keptSampleCount: Int { kept.count }

    /// Passes that completed (a pass whose recognizer threw does not count).
    public var passCount: Int { _passCount }

    /// Buffers `samples` and, when `step` seconds of new audio have arrived since
    /// the last pass and no pass is running, runs one and waits for it. Appends
    /// that arrive during a pass only buffer; the next due pass runs on a later
    /// append.
    public func append(_ samples: [Float]) async {
        kept.append(contentsOf: samples)
        totalSamples += samples.count
        guard !finishing, !passInFlight, totalSamples - lastPassSamples >= stepSamples else { return }
        await runPass()
    }

    /// Waits for a running pass, recognises the kept audio once more and returns
    /// the whole take's text. Finishes `updates`, also when it throws. Calling it
    /// again (also concurrently) returns the same result without recognising again.
    public func finish() async throws -> String {
        if let running = finishTask { return try await running.value }
        finishing = true
        let task = Task { try await self.finishOnce() }
        finishTask = task
        return try await task.value
    }

    private func finishOnce() async throws -> String {
        defer { continuation.finish() }
        while passInFlight {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        // The final recognition counts as in flight, like a pass.
        passInFlight = true
        defer { becomeIdle() }

        if _passCount == 0 {
            return join(kept.isEmpty ? [] : try await recognizer.recognize(kept))
        }
        let fromSamples = keepFromSamples(now: totalSamples)
        guard fromSamples < totalSamples else { return join(settled) }
        let offset = Double(fromSamples) / sampleRate
        let words = try await recognizer.recognize(Array(kept[(fromSamples - keptStart)...]))
        let tail = words
            .map { shifted($0, by: offset) }
            .filter { !isSettledAgain($0) }
        return join(settled + tail)
    }

    // MARK: pass

    private func runPass() async {
        passInFlight = true
        defer { becomeIdle() }

        let nowSamples = totalSamples
        let passStartSamples = keepFromSamples(now: nowSamples)
        let audio = Array(kept[(passStartSamples - keptStart)..<(nowSamples - keptStart)])
        // The pass clock advances whether or not the recognizer succeeds, so a
        // failing recognizer is retried once per step, not on every append.
        lastPassSamples = nowSamples
        let words: [TimedWord]
        do {
            words = try await recognizer.recognize(audio)
        } catch {
            return  // no pass: agreement state and audio unchanged
        }

        let now = Double(nowSamples) / sampleRate
        let passStart = Double(passStartSamples) / sampleRate
        var candidates = words
            .map { shifted($0, by: passStart) }
            .filter { !isSettledAgain($0) }

        // The longest common prefix with the previous pass settles…
        var settleCount = 0
        while settleCount < min(candidates.count, previous.count),
              Self.normalized(candidates[settleCount].text) == Self.normalized(previous[settleCount].text) {
            settleCount += 1
        }
        // …and so does everything up to the last word that ended long enough ago.
        if let lastOld = candidates.lastIndex(where: { $0.end < now - settleAge }) {
            settleCount = max(settleCount, lastOld + 1)
        }

        if settleCount > 0 {
            settled.append(contentsOf: candidates[..<settleCount])
            settledEnd = candidates[settleCount - 1].end
            candidates.removeFirst(settleCount)
        }
        previous = candidates
        dropAudio(before: keepFromSamples(now: nowSamples))
        _passCount += 1
        continuation.yield(LiveText(settled: join(settled), provisional: join(candidates)))
    }

    /// `keepFrom` in absolute samples for the given now: never before the audio
    /// still held, never after now.
    private func keepFromSamples(now nowSamples: Int) -> Int {
        let afterSettled = Int(((settledEnd - finalContext) * sampleRate).rounded(.down))
        let keepFrom = max(0, afterSettled, nowSamples - windowSamples)
        return min(max(keptStart, keepFrom), nowSamples)
    }

    private func becomeIdle() {
        passInFlight = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func dropAudio(before keepFrom: Int) {
        let drop = min(kept.count, keepFrom - keptStart)
        guard drop > 0 else { return }
        kept.removeFirst(drop)
        keptStart += drop
    }

    // MARK: words

    /// Each pass re-recognises from `settledEnd - finalContext`, so it sees the
    /// last settled words again. A word whose midpoint is at or before
    /// `settledEnd` is one of them, and is dropped. The midpoint, not the end:
    /// timestamps move with the model's frame grid (Parakeet: 80 ms frames, the
    /// grid shifting with each pass's start offset), so the same word's end can
    /// land a frame later than it did when it settled.
    ///
    /// A word can also come back later than that by more than half its length, and
    /// then it is the same word as the last settled one starting before `settledEnd`:
    /// short words ("the", "und") duplicated at the settle boundary otherwise.
    private func isSettledAgain(_ w: TimedWord) -> Bool {
        if (w.start + w.end) / 2 <= settledEnd { return true }
        if let last = settled.last, w.start < settledEnd + 0.16, Self.normalized(w.text) == Self.normalized(last.text) {
            return true
        }
        return false
    }

    private func shifted(_ w: TimedWord, by offset: TimeInterval) -> TimedWord {
        TimedWord(text: w.text, start: w.start + offset, end: w.end + offset)
    }

    /// How words are compared for agreement: lowercased, without leading and
    /// trailing punctuation (and whitespace), so "Fox." agrees with "fox".
    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// Words joined with single spaces, trimmed.
    private func join(_ words: [TimedWord]) -> String {
        words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

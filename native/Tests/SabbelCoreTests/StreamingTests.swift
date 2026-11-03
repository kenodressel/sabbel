import Foundation
import Testing
@testable import SabbelCore

/// Streaming transcription with local agreement, against `FakeRecognizer`.
///
/// Time is audio time: the transcriber's "now" is the audio appended so far, so
/// these tests feed audio as fast as they like and stay deterministic.
@Suite struct StreamingTests {
    static let rate = 16_000

    /// Feeds index-valued audio (see `FakeRecognizer.audio`) in fixed chunks.
    struct Feeder {
        var position = 0

        mutating func feed(_ t: StreamingTranscriber, seconds: Double, chunk: Double = 0.1,
                           afterEach: (Int) async -> Void = { _ in }) async {
            let total = Int((seconds * Double(StreamingTests.rate)).rounded())
            let per = Int((chunk * Double(StreamingTests.rate)).rounded())
            var fed = 0
            while fed < total {
                let n = min(per, total - fed)
                await t.append(FakeRecognizer.audio(from: position, count: n))
                position += n
                fed += n
                await afterEach(position)
            }
        }
    }

    /// Which child of `bounded`'s race finished first. A distinct case, not a nested
    /// optional: `T` is itself optional at the call sites, so a `nil` from the timer
    /// would be indistinguishable from `op` returning `nil`.
    private enum Race<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    /// Runs `op`, but records an issue and returns nil instead of hanging the suite
    /// when it takes longer than `seconds`. `op` must honour cancellation.
    static func bounded<T: Sendable>(_ seconds: Double = 2,
                                     sourceLocation: SourceLocation = #_sourceLocation,
                                     _ op: @escaping @Sendable () async -> T) async -> T? {
        let winner: Race<T> = await withTaskGroup(of: Race<T>.self) { group in
            group.addTask { .finished(await op()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch winner {
        case .finished(let value):
            return value
        case .timedOut:
            Issue.record("timed out after \(seconds) s", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// The newest `LiveText`, or nil once the stream has finished with nothing buffered.
    /// Bounded: a missing update fails the test instead of hanging it.
    private func latest(_ t: StreamingTranscriber,
                        sourceLocation: SourceLocation = #_sourceLocation) async -> LiveText? {
        let stream = t.updates
        let value = await Self.bounded(sourceLocation: sourceLocation) { () async -> LiveText? in
            var it = stream.makeAsyncIterator()
            return await it.next()
        }
        return value ?? nil
    }

    /// Waits (bounded) until the fake's next recognize call has started; returns its index.
    private func entered(_ fake: FakeRecognizer,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> Int? {
        let stream = fake.entered
        let value = await Self.bounded(sourceLocation: sourceLocation) { () async -> Int? in
            var it = stream.makeAsyncIterator()
            return await it.next()
        }
        return value ?? nil
    }

    private func joined(_ words: [TimedWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    /// "The quick brown fox jumps over the dog", all spoken within 2 s.
    static let fox: [TimedWord] = [
        TimedWord(text: "the", start: 0.00, end: 0.20),
        TimedWord(text: "quick", start: 0.25, end: 0.40),
        TimedWord(text: "brown", start: 0.45, end: 0.60),
        TimedWord(text: "fox", start: 0.65, end: 0.90),
        TimedWord(text: "jumps", start: 1.10, end: 1.40),
        TimedWord(text: "over", start: 1.45, end: 1.60),
        TimedWord(text: "the", start: 1.65, end: 1.75),
        TimedWord(text: "dog", start: 1.80, end: 1.95),
    ]

    // MARK: the brief's cases

    @Test func shortTakeIsOneFullPass() async throws {
        let script = FakeRecognizer.script(until: 0.5, wordLength: 0.2, gap: 0.05)
        let fake = FakeRecognizer(script: script, mangle: .none)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 0.6)

        let text = try await t.finish()

        #expect(fake.calls == [FakeRecognizer.Call(startSample: 0, sampleCount: 9_600)])
        #expect(text == "w0 w1")
        #expect(await t.passCount == 0)
    }

    @Test func agreedPrefixSettles() async throws {
        // Pass 1 (now 1 s) sees "the quick brown foxx" (unstable tail),
        // pass 2 (now 2 s) sees "the quick brown fox jumps over the dogx".
        let fake = FakeRecognizer(script: Self.fox, mangle: .unstableTail)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 2.0)

        #expect(await t.passCount == 2)
        #expect(await latest(t) == LiveText(settled: "the quick brown", provisional: "fox jumps over the dogx"))
    }

    @Test func agreementIgnoresCaseAndPunctuation() async throws {
        // Pass 1 says "The quick, brown fox." and pass 2 says it plainly: all four agree.
        let fake = FakeRecognizer(script: Self.fox, mangle: .custom({ index, words in
            guard index == 0 else { return words }
            let styled = ["The", "quick,", "\"brown\"", "fox."]
            return words.enumerated().map { i, w in
                TimedWord(text: i < styled.count ? styled[i] : w.text, start: w.start, end: w.end)
            }
        }))
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 2.0)

        #expect(await latest(t) == LiveText(settled: "the quick brown fox", provisional: "jumps over the dog"))
    }

    @Test func oldWordsSettleWithoutAgreement() async throws {
        // w0 0.0–0.3, w1 0.4–0.7, w2 0.8–1.1, … Odd calls mangle every word, so no
        // two passes ever agree; only age settles.
        // - pass 4 (now 4 s, mangled) settles the words ending before 1 s: w0x w1x;
        // - pass 5 (now 5 s, clean) settles the words ending before 2 s: w2 w3 w4.
        let fake = FakeRecognizer(script: FakeRecognizer.script(until: 30), mangle: .everyWordOnOddCalls)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()

        await feeder.feed(t, seconds: 3.0)
        #expect(await latest(t) == LiveText(settled: "", provisional: "w0 w1 w2 w3 w4 w5 w6"))

        await feeder.feed(t, seconds: 2.0)
        #expect(await t.passCount == 5)
        #expect(await latest(t) == LiveText(settled: "w0x w1x w2 w3 w4", provisional: "w5 w6 w7 w8 w9 w10 w11"))
    }

    /// Timestamps move by up to ±80 ms per word and call (Parakeet's frame grid).
    /// Words are 0.4 s long with 0.1 s gaps: then a settled word seen again always
    /// has its midpoint at or before `settledEnd` (0.2 s > 2 × 0.08 s), and the next
    /// word never does.
    static let jitter: TimeInterval = 0.08

    @Test func finalTextEqualsScript() async throws {
        let script = FakeRecognizer.script(until: 44.4, wordLength: 0.4, gap: 0.1)
        let fake = FakeRecognizer(script: script, mangle: .unstableTail, jitter: Self.jitter)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 45)

        let text = try await t.finish()

        #expect(text == joined(script))
        #expect(await t.passCount == 45)
        #expect(fake.orderViolations == 0)
    }

    @Test func finishOnlyTranscribesTail() async throws {
        let fake = FakeRecognizer(script: FakeRecognizer.script(until: 59.4), mangle: .unstableTail)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 60)

        _ = try await t.finish()

        let last = try #require(fake.calls.last)
        let seconds = Double(last.sampleCount) / Double(Self.rate)
        #expect(seconds <= 3 + 1 + 1 + 1)  // settleAge + step + finalContext + 1
        #expect(last.startSample + last.sampleCount == 60 * Self.rate)
    }

    @Test func longTakeKeepsBoundedAudio() async throws {
        let script = FakeRecognizer.script(until: 599.4)
        let fake = FakeRecognizer(script: script, mangle: .unstableTail)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        var maxKept = 0
        await feeder.feed(t, seconds: 600) { _ in
            maxKept = max(maxKept, await t.keptSampleCount)
        }

        #expect(maxKept <= Self.rate * (10 + 1))
        #expect(await t.passCount == 600)
        #expect(try await t.finish() == joined(script))
    }

    @Test func passesNeverOverlap() async throws {
        let script = FakeRecognizer.script(until: 4.0)
        let fake = FakeRecognizer(script: script, mangle: .unstableTail, delay: 0.3)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 0.9)

        // The append that reaches 1 s runs a pass. While it is inside recognize,
        // 2.5 s more arrive (passes fall due at 2 s and 3 s): they only buffer.
        let chunk = FakeRecognizer.audio(from: feeder.position, count: Self.rate / 10)
        feeder.position += Self.rate / 10
        let pass = Task { await t.append(chunk) }
        #expect(await entered(fake) == 0)
        await feeder.feed(t, seconds: 2.5)
        #expect(fake.calls.count == 1)
        await pass.value

        await feeder.feed(t, seconds: 1.0)  // the next due pass runs on a later append
        let text = try await t.finish()

        #expect(fake.maxInFlight == 1)
        #expect(fake.calls.count == 3)
        #expect(fake.orderViolations == 0)
        #expect(text == joined(script))
    }

    // MARK: concurrency and failure contract

    @Test func finishWaitsForInFlightPass() async throws {
        let fake = FakeRecognizer(script: FakeRecognizer.script(until: 0.8), mangle: .none, delay: 0.2)
        let t = StreamingTranscriber(recognizer: fake)
        let pass = Task { await t.append(FakeRecognizer.audio(from: 0, count: Self.rate)) }
        #expect(await entered(fake) == 0)  // the pass is now inside recognize

        let text = try await t.finish()
        await pass.value

        #expect(fake.maxInFlight == 1)
        #expect(fake.calls.count == 2)
        #expect(await t.passCount == 1)
        #expect(text == "w0 w1")
    }

    @Test func failedPassChangesNothingAndIsRetriedNextStep() async throws {
        let script = FakeRecognizer.script(until: 2.6)
        let fake = FakeRecognizer(script: script, mangle: .unstableTail, failingCalls: [1])
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()

        await feeder.feed(t, seconds: 1.0)  // pass at 1 s succeeds
        let afterFirst = await latest(t)

        await feeder.feed(t, seconds: 1.0)  // pass at 2 s throws
        #expect(fake.calls.count == 2)
        #expect(await t.passCount == 1)

        await feeder.feed(t, seconds: 0.9)  // the pass clock advanced: no retry on these appends
        #expect(fake.calls.count == 2)

        await feeder.feed(t, seconds: 0.1)  // next due step, 3 s: retried, agreeing with pass 1
        #expect(fake.calls.count == 3)
        #expect(await t.passCount == 2)
        // w0 agreed between the passes at 1 s and 3 s, so the failure left `previous` alone.
        #expect(afterFirst == LiveText(settled: "", provisional: "w0 w1x"))
        #expect(await latest(t) == LiveText(settled: "w0", provisional: "w1 w2 w3 w4 w5"))

        #expect(try await t.finish() == joined(script))
    }

    @Test func longSilenceKeepsBoundedAudio() async throws {
        // 5 s of speech, then 120 s in which the fake hears no words.
        let script = FakeRecognizer.script(until: 5)
        let fake = FakeRecognizer(script: script, mangle: .unstableTail)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        var maxKept = 0
        await feeder.feed(t, seconds: 125) { _ in
            maxKept = max(maxKept, await t.keptSampleCount)
        }

        let text = try await t.finish()

        #expect(maxKept <= Self.rate * (10 + 1))
        let last = try #require(fake.calls.last)
        #expect(last.sampleCount <= Self.rate * 11)
        #expect(last.startSample + last.sampleCount == 125 * Self.rate)
        #expect(text == joined(script))
    }

    @Test func finalTextEqualsScriptAcrossSilenceGap() async throws {
        // Speech until 10 s, 30 s of silence, speech again from 40 s to 70 s, with jitter.
        let before = FakeRecognizer.script(until: 10, wordLength: 0.4, gap: 0.1)
        let after = FakeRecognizer.script(until: 30, wordLength: 0.4, gap: 0.1).enumerated().map { i, w in
            TimedWord(text: "v\(i)", start: w.start + 40, end: w.end + 40)
        }
        let script = before + after
        let fake = FakeRecognizer(script: script, mangle: .unstableTail, jitter: Self.jitter)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 71)

        #expect(try await t.finish() == joined(script))
        #expect(fake.orderViolations == 0)
    }

    @Test func finishRethrowsAndClosesUpdates() async throws {
        let fake = FakeRecognizer(script: [], mangle: .none, failingCalls: [0])
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 0.5)

        await #expect(throws: FakeRecognizer.Failure.self) { try await t.finish() }
        #expect(await latest(t) == nil)
    }

    @Test func updatesFinishAfterFinish() async throws {
        let fake = FakeRecognizer(script: Self.fox, mangle: .none)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 2.5)

        #expect(try await t.finish() == "the quick brown fox jumps over the dog")
        #expect(await latest(t) != nil)  // the newest pass's text stays buffered
        #expect(await latest(t) == nil)
    }

    @Test func concurrentFinishesShareOneFinalRecognition() async throws {
        let script = FakeRecognizer.script(until: 0.5, wordLength: 0.2, gap: 0.05)
        let fake = FakeRecognizer(script: script, mangle: .none, delay: 0.2)
        let t = StreamingTranscriber(recognizer: fake)
        var feeder = Feeder()
        await feeder.feed(t, seconds: 0.6)

        async let a = t.finish()
        async let b = t.finish()
        let (first, second) = try await (a, b)

        #expect(first == "w0 w1")
        #expect(second == "w0 w1")
        #expect(fake.calls.count == 1)
        #expect(fake.maxInFlight == 1)
    }
}

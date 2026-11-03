import Foundation
@testable import SabbelCore

/// A scripted stand-in for the speech model.
///
/// - It is built from a script of "what the true words are", each with absolute
///   times in the take.
/// - The audio fed to the transcriber must be `FakeRecognizer.audio(from:count:)`:
///   every sample's value is its absolute index in the take. That is how the fake
///   knows where a span starts (`samples[0]`), and lets it check that the span is
///   one contiguous, correctly ordered piece of the take (`samples.last`).
/// - `recognize` returns the script's words that lie wholly inside the span,
///   shifted to be relative to `samples[0]`, optionally mangled by `mangle`.
/// - Thread-safe: every stored property is read and written under one lock; the
///   optional delay is a real `Task.sleep`, so concurrent calls really overlap.
final class FakeRecognizer: Recognizer, @unchecked Sendable {
    struct Call: Equatable {
        let startSample: Int
        let sampleCount: Int
    }

    enum Mangle: Sendable {
        /// Words come back exactly as scripted.
        case none
        /// The last word is mangled when it ends within `tailMargin` of the span's
        /// end, as a model's unstable tail is when a word sits at the cut.
        case unstableTail
        /// Every word is mangled on every odd call (index 1, 3, …), so two
        /// consecutive passes never agree.
        case everyWordOnOddCalls
        /// Any rewrite of the call's relative words, given the call index.
        case custom(@Sendable (Int, [TimedWord]) -> [TimedWord])
    }

    static let tailMargin: TimeInterval = 0.5

    /// The audio of `count` samples starting at absolute sample `from`.
    static func audio(from: Int, count: Int) -> [Float] {
        (from..<(from + count)).map { Float($0) }
    }

    /// Distinct words `w0`, `w1`, … of `wordLength` s with `gap` s between them,
    /// the last one ending no later than `until`.
    static func script(until: TimeInterval, wordLength: TimeInterval = 0.3,
                       gap: TimeInterval = 0.1) -> [TimedWord] {
        var words: [TimedWord] = []
        var i = 0
        while true {
            let start = Double(i) * (wordLength + gap)
            let end = start + wordLength
            if end > until { break }
            words.append(TimedWord(text: "w\(i)", start: start, end: end))
            i += 1
        }
        return words
    }

    static func mangled(_ w: TimedWord) -> TimedWord {
        TimedWord(text: w.text + "x", start: w.start, end: w.end)
    }

    private let script: [TimedWord]
    private let mangle: Mangle
    private let delay: TimeInterval
    private let sampleRate: Double
    private let failingCalls: Set<Int>

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _orderViolations = 0

    struct Failure: Error {}

    init(script: [TimedWord], mangle: Mangle = .unstableTail, delay: TimeInterval = 0,
         failingCalls: Set<Int> = [], sampleRate: Double = 16_000) {
        self.script = script
        self.mangle = mangle
        self.delay = delay
        self.failingCalls = failingCalls
        self.sampleRate = sampleRate
    }

    var calls: [Call] { lock.withLock { _calls } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    /// Calls whose samples were not one contiguous run of the take in order.
    var orderViolations: Int { lock.withLock { _orderViolations } }

    func recognize(_ samples: [Float]) async throws -> [TimedWord] {
        let startSample = samples.first.map { Int($0) } ?? 0
        let contiguous = samples.last.map { Int($0) == startSample + samples.count - 1 } ?? true
        let index: Int = lock.withLock {
            _calls.append(Call(startSample: startSample, sampleCount: samples.count))
            if !contiguous { _orderViolations += 1 }
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            return _calls.count - 1
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        lock.withLock { _inFlight -= 1 }
        if failingCalls.contains(index) { throw Failure() }

        let spanStart = Double(startSample) / sampleRate
        let spanLength = Double(samples.count) / sampleRate
        let lower = spanStart - 1e-6
        let upper = spanStart + spanLength + 1e-6
        let inside: [TimedWord] = script.filter { w in w.start >= lower && w.end <= upper }
        var words: [TimedWord] = inside.map { w in
            TimedWord(text: w.text, start: w.start - spanStart, end: w.end - spanStart)
        }

        switch mangle {
        case .none:
            break
        case .unstableTail:
            if let last = words.last, last.end > spanLength - Self.tailMargin {
                words[words.count - 1] = Self.mangled(last)
            }
        case .everyWordOnOddCalls:
            if index % 2 == 1 { words = words.map(Self.mangled) }
        case .custom(let rewrite):
            words = rewrite(index, words)
        }
        return words
    }
}

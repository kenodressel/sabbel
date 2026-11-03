import Testing
@testable import SabbelCore

@Suite struct TakeStatsTests {
    private func stats(_ value: Float, seconds: Double, chunks: Int = 1) -> TakeStats {
        var s = TakeStats()
        let total = Int(seconds * 16_000)
        let per = total / chunks
        for _ in 0..<chunks { s.add([Float](repeating: value, count: per)) }
        return s
    }

    @Test func emptyIsTooShort() {
        #expect(TakeStats().verdict(minDuration: 0.5) == .tooShort)
    }

    @Test func shortTakeIsTooShortEvenWhenLoud() {
        #expect(stats(0.1, seconds: 0.4).verdict(minDuration: 0.5) == .tooShort)
    }

    @Test func exactZerosAreDeadStream() {
        #expect(stats(0, seconds: 1).verdict(minDuration: 0.5) == .deadStream)
    }

    @Test func quietNoiseIsNoSpeech() {
        #expect(stats(0.002, seconds: 1).verdict(minDuration: 0.5) == .noSpeech)
    }

    @Test func speechIsAccepted() {
        #expect(stats(0.004, seconds: 1).verdict(minDuration: 0.5) == .accept)
    }

    @Test func chunkingDoesNotChangeVerdict() {
        #expect(stats(0.004, seconds: 1, chunks: 10).verdict(minDuration: 0.5) == .accept)
        #expect(stats(0.004, seconds: 1, chunks: 10).duration == 1)
    }

    /// The key was held long enough but the mic never delivered a buffer: the
    /// capture died before it started, which is a dead stream, not a short take.
    @Test func noSamplesOverALongHoldIsDeadStream() {
        #expect(TakeStats().verdict(minDuration: 0.5, heldFor: 1.0) == .deadStream)
        #expect(TakeStats().verdict(minDuration: 0.5, heldFor: 0.5) == .deadStream)
    }

    @Test func noSamplesOverAShortHoldIsTooShort() {
        #expect(TakeStats().verdict(minDuration: 0.5, heldFor: 0.2) == .tooShort)
    }

    /// Some audio arrived: the hold time does not override the sample count.
    @Test func fewSamplesOverALongHoldIsStillTooShort() {
        #expect(stats(0.1, seconds: 0.2).verdict(minDuration: 0.5, heldFor: 2.0) == .tooShort)
    }
}

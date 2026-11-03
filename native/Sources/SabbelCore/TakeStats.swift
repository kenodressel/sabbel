import Foundation

public enum TakeVerdict: Equatable, Sendable { case accept, tooShort, deadStream, noSpeech }

/// Incremental statistics of one recorded take, so a 10-minute take never needs
/// its whole buffer. Port of recorder.is_valid_duration / is_dead_stream / has_speech.
public struct TakeStats: Sendable {
    private let sampleRate: Double
    private var count = 0
    private var sumSquares: Double = 0
    private var maxAbs: Float = 0

    public init(sampleRate: Double = 16_000) { self.sampleRate = sampleRate }

    public mutating func add(_ samples: [Float]) {
        count += samples.count
        for x in samples {
            sumSquares += Double(x) * Double(x)
            let a = abs(x)
            if a > maxAbs { maxAbs = a }
        }
    }

    public var duration: TimeInterval { Double(count) / sampleRate }

    /// Checked in order: too short, dead stream (exact digital silence, i.e. the
    /// mic delivered nothing), no speech (RMS not strictly above the threshold).
    ///
    /// `heldFor` is how long the hotkey was held. A hold of at least
    /// `minDuration` that produced no sample at all is a capture that died
    /// before its first buffer: a dead stream, not a short take. Without the
    /// hold time it would read as "Too short", with no notice to say the mic failed.
    public func verdict(minDuration: TimeInterval, heldFor: TimeInterval = 0, rmsThreshold: Float = 0.003) -> TakeVerdict {
        if count == 0 && heldFor >= minDuration { return .deadStream }
        if count < Int(minDuration * sampleRate) || count == 0 { return .tooShort }
        if maxAbs == 0 { return .deadStream }
        let rms = (sumSquares / Double(count)).squareRoot()
        return Float(rms) > rmsThreshold ? .accept : .noSpeech
    }
}

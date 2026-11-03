import Foundation
import os

/// The loudness of an audio buffer for the overlay's level bars.
public enum AudioLevel {
    /// At or below this the bars are flat.
    public static let floorDB: Double = -50
    /// At or above this the bars are full.
    public static let ceilingDB: Double = -10

    /// RMS in dBFS, mapped linearly from `floorDB`…`ceilingDB` to 0…1 and
    /// clamped. Silence, an empty buffer and garbage (NaN, ±inf) read as 0.
    public static func level(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms.isFinite, rms > 0 else { return 0 }
        return level(dB: 20 * log10(rms))
    }

    /// `dB` mapped to 0…1; NaN reads as 0.
    public static func level(dB: Double) -> Double {
        guard !dB.isNaN else { return 0 }
        return min(1, max(0, (dB - floorDB) / (ceilingDB - floorDB)))
    }
}

/// Lets a level through at most `maxRate` times a second. A level arriving
/// too soon is held back, and the next one that passes is the loudest seen
/// since, so a short peak still shows.
public struct LevelThrottle: Sendable {
    public static let maxRate: Double = 20

    private let interval: TimeInterval
    private var last: TimeInterval?
    private var held: Double = 0

    public init(maxRate: Double = LevelThrottle.maxRate) { interval = 1 / maxRate }

    /// The level to deliver now, or nil when it is too soon after the last one.
    public mutating func offer(_ level: Double, at now: TimeInterval) -> Double? {
        held = max(held, level)
        if let last, now - last < interval { return nil }
        last = now
        defer { held = 0 }
        return held
    }
}

/// One take's level meter, fed from the audio callback. The work per buffer is
/// a sum of squares and an uncontended lock, so it never holds up the tap.
public final class LevelMeter: Sendable {
    private let throttle = OSAllocatedUnfairLock(initialState: LevelThrottle())
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }

    /// The buffer's level, if one is due.
    public func measure(_ samples: [Float]) -> Double? {
        let level = AudioLevel.level(of: samples)
        let time = now()
        return throttle.withLock { $0.offer(level, at: time) }
    }
}

/// The overlay's level bars: the most recent levels, newest last, smoothed so
/// the row moves like a wave rather than flickering.
public struct LevelBars: Equatable, Sendable {
    public static let count = 14
    /// The height of a bar in silence, and of the frozen row after release.
    public static let rest: Double = 0.12

    public private(set) var values: [Double]

    public init() { values = Array(repeating: Self.rest, count: Self.count) }

    /// Adds a level on the right; the oldest drops off the left. Rising
    /// quickly and falling slowly reads as speech rather than noise.
    public mutating func push(_ level: Double) {
        let target = Self.rest + (1 - Self.rest) * min(1, max(0, level.isNaN ? 0 : level))
        let previous = values[values.count - 1]
        let weight = target > previous ? 0.7 : 0.35
        values.removeFirst()
        values.append(previous + (target - previous) * weight)
    }

    /// Back to a flat row.
    public mutating func reset() { self = LevelBars() }
}

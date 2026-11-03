import Foundation

/// One delivered dictation, as the Recent menu lists it.
public struct RecentDictation: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The final text, after the pipeline.
    public let text: String
    public let date: Date
    /// The name of the app the take started in.
    public let appName: String?

    public init(id: UUID = UUID(), text: String, date: Date, appName: String?) {
        self.id = id
        self.text = text
        self.date = date
        self.appName = appName
    }

    /// The text on one line for a menu item: newlines and runs of blanks become
    /// one space, and a text longer than `limit` characters ends in "…".
    public func title(limit: Int = 50) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        return line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Notes · 14:05" (or just the time when the app is unknown).
    public func subtitle(calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard let appName, !appName.isEmpty else { return time }
        return "\(appName) · \(time)"
    }
}

/// The last delivered dictations, newest first. Memory only: nothing here is
/// ever written to disk, and it is gone when the app quits.
public struct RecentDictations: Equatable, Sendable {
    public private(set) var entries: [RecentDictation] = []
    /// How many entries are kept; 0 keeps nothing.
    public private(set) var limit: Int

    public init(limit: Int = 10) { self.limit = max(0, limit) }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(_ entry: RecentDictation) {
        guard limit > 0 else { return }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func clear() { entries.removeAll() }
}

/// The audio of one take, as the 16 kHz samples the coordinator receives, kept
/// so the take can be recognised again. Everything past `capacity` is dropped.
///
/// Written by the take's feeder task and read once the take has finished, hence
/// the lock.
public final class TakeAudio: @unchecked Sendable {
    /// 10 minutes at 16 kHz.
    public static let defaultCapacity = 10 * 60 * 16_000

    private let lock = NSLock()
    private var buffer: [Float] = []
    public let capacity: Int

    public init(capacity: Int = TakeAudio.defaultCapacity) { self.capacity = max(0, capacity) }

    public func append(_ samples: [Float]) {
        lock.withLock {
            let room = capacity - buffer.count
            guard room > 0 else { return }
            buffer.append(contentsOf: samples.prefix(room))
        }
    }

    public var samples: [Float] { lock.withLock { buffer } }
    public var count: Int { lock.withLock { buffer.count } }
}

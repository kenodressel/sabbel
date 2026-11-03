import Foundation

/// Append-only dictation history. Rotates once to `<name>.1` when the existing
/// file is larger than `maxBytes` before an append. Port of app._append_history.
public struct HistoryLog: Sendable {
    private let url: URL
    private let maxBytes: Int
    private let now: @Sendable () -> Date

    public init(url: URL, maxBytes: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.maxBytes = maxBytes
        self.now = now
    }

    private var backupURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
    }

    public func append(_ text: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
            try fm.moveItem(at: url, to: backupURL)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = Data("--- \(f.string(from: now())) ---\n\(text)\n\n".utf8)
        if fm.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: entry)
        } else {
            try entry.write(to: url)
        }
    }

    public func clear() throws {
        let fm = FileManager.default
        for u in [url, backupURL] where fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
    }
}

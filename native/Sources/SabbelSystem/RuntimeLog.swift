import Foundation

/// Append-only runtime log, line format `2026-11-03 14:05:07,123 INFO Ready`
/// (Python's `"%(asctime)s %(levelname)s %(message)s"`).
///
/// Logging must never take the app down, so every failure is swallowed.
public final class RuntimeLog: @unchecked Sendable {
    public static let defaultURL = URL(fileURLWithPath: "/tmp/sabbel-runtime.log")

    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter

    /// Truncates the file at init when it is larger than `truncateAbove` bytes.
    public init(url: URL = RuntimeLog.defaultURL, truncateAbove: Int = 5_000_000) {
        self.url = url
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        self.formatter = f
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > truncateAbove {
            try? Data().write(to: url)
        }
    }

    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Data("\(formatter.string(from: Date())) \(level) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

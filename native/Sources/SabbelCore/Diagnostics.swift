import Foundation

/// Everything a bug report needs, in one pasteable block.
///
/// The v0.4.0 report that started all this was a screenshot of "Model failed
/// - restart Sabbel". The actual error existed only in a log the UI never
/// mentions, so nobody could act on it. Every lookup here is guarded: a
/// diagnostics button that crashes is worse than none at all.
public func buildDiagnostics(version: String, status: String, macOS: String, engine: String,
                             configURL: URL, logURL: URL, logLines: Int = 40) -> String {
    var lines = ["Sabbel v\(version)", "status: \(status)", "macOS: \(macOS)", "engine: \(engine)"]

    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: configURL.path, isDirectory: &isDir), !isDir.boolValue {
        if let data = try? Data(contentsOf: configURL) {
            lines.append("config.toml: present (\(configURL.path))")
            lines.append("--- config.toml ---")
            lines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("config.toml: unreadable (\(configURL.path))")
        }
    } else {
        lines.append("config.toml: none (\(configURL.path))")
    }

    lines.append("--- last \(logLines) lines of \(logURL.path) ---")
    if let data = try? Data(contentsOf: logURL) {
        let text = String(decoding: data, as: UTF8.self)
        var tail = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if tail.last == "" { tail.removeLast() }
        let last = Array(tail.suffix(max(logLines, 0)))
        lines.append(contentsOf: last.isEmpty ? ["(log is empty)"] : last)
    } else {
        lines.append("(no log file)")
    }
    return lines.joined(separator: "\n")
}

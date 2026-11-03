import Testing
import Foundation
@testable import SabbelCore

@Suite struct DiagnosticsTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @Test func carriesWhatABugReportNeeds() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let cfg = d.appendingPathComponent("config.toml")
        let log = d.appendingPathComponent("log")
        try "[general]\nhotkey = \"alt_r\"\n".write(to: cfg, atomically: true, encoding: .utf8)
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let text = buildDiagnostics(version: "1.0.0", status: "Ready", macOS: "15.0 (arm64)", engine: "parakeet",
                                    configURL: cfg, logURL: log)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "Sabbel v1.0.0")
        #expect(text.contains("status: Ready"))
        #expect(text.contains("macOS: 15.0 (arm64)"))
        #expect(text.contains("engine: parakeet"))
        #expect(text.contains("config.toml: present (\(cfg.path))"))
        #expect(text.contains("--- config.toml ---\n[general]\nhotkey = \"alt_r\""))
        #expect(text.contains("--- last 40 lines of \(log.path) ---\nline 61\n"))
        #expect(text.hasSuffix("line 100"))
        #expect(!text.contains("line 60\n"))
    }
    @Test func missingFiles() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let cfg = d.appendingPathComponent("nope.toml"), log = d.appendingPathComponent("nolog")
        let text = buildDiagnostics(version: "dev", status: "x", macOS: "m", engine: "e", configURL: cfg, logURL: log)
        #expect(text.contains("config.toml: none (\(cfg.path))"))
        #expect(!text.contains("--- config.toml ---"))
        #expect(text.hasSuffix("(no log file)"))
    }
    @Test func emptyLogAndUnreadableConfig() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let log = d.appendingPathComponent("log"); try "".write(to: log, atomically: true, encoding: .utf8)
        let cfg = d.appendingPathComponent("config.toml"); try "x".write(to: cfg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cfg.path)
        let text = buildDiagnostics(version: "1", status: "x", macOS: "m", engine: "e", configURL: cfg, logURL: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cfg.path)
        #expect(text.contains("config.toml: unreadable (\(cfg.path))"))
        #expect(text.hasSuffix("(log is empty)"))
    }
}

import Testing
import Foundation
@testable import SabbelCore

@Suite struct HistoryLogTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sabbel-hist-\(UUID().uuidString)")
    }

    private func fixedDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 3; c.hour = 9; c.minute = 5; c.second = 7
        return Calendar.current.date(from: c)!
    }

    @Test func writesExactFormatAndCreatesDirectory() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("history.log")
        let d = fixedDate()
        try HistoryLog(url: url, maxBytes: 1000, now: { d }).append("Hallo Welt")
        #expect(try String(contentsOf: url, encoding: .utf8)
                == "--- 2026-11-03 09:05:07 ---\nHallo Welt\n\n")
    }

    @Test func umlautsRoundTrip() throws {
        let url = tempDir().appendingPathComponent("history.log")
        try HistoryLog(url: url, maxBytes: 1000).append("Grüße äöüß")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Grüße äöüß"))
    }

    @Test func rotatesWhenOverMaxBytes() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("history.log")
        let backup = dir.appendingPathComponent("history.log.1")
        let log = HistoryLog(url: url, maxBytes: 10)   // any entry exceeds this
        try log.append("first")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        try log.append("second")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("first"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("second"))
        try log.append("third")   // replaces the old backup
        let b = try String(contentsOf: backup, encoding: .utf8)
        #expect(b.contains("second") && !b.contains("first"))
        let cur = try String(contentsOf: url, encoding: .utf8)
        #expect(cur.contains("third") && !cur.contains("second"))
    }

    @Test func clearRemovesBothFilesAndToleratesNone() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("history.log")
        let log = HistoryLog(url: url, maxBytes: 10)
        try log.clear()
        try log.append("x"); try log.append("y"); try log.append("z")
        try log.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".1"))
    }
}

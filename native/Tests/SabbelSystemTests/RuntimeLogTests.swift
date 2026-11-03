import Foundation
import Testing
@testable import SabbelSystem

@Suite struct RuntimeLogTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-log-\(UUID()).log")
    }

    @Test func lineFormat() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let log = RuntimeLog(url: url)
        log.info("Ready")
        log.error("Boom")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        for l in lines {
            #expect(l.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d{3} (INFO|ERROR) .+$"#, options: .regularExpression) != nil)
        }
        #expect(lines[0].hasSuffix(" INFO Ready"))
        #expect(lines[1].hasSuffix(" ERROR Boom"))
    }

    @Test func truncatesLargeFileAtInit() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: 500).write(to: url)
        _ = RuntimeLog(url: url, truncateAbove: 100)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func keepsSmallFile() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: 50).write(to: url)
        _ = RuntimeLog(url: url, truncateAbove: 100)
        #expect(try Data(contentsOf: url).count == 50)
    }

    @Test func unwritablePathDoesNotCrash() {
        let log = RuntimeLog(url: URL(fileURLWithPath: "/nonexistent-dir-\(UUID())/x.log"))
        log.info("a")
        log.error("b")
    }
}

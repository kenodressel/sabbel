import Foundation
import Testing
@testable import SabbelSystem

@Suite struct SingleInstanceTests {
    @Test func secondLockFailsUntilRelease() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-lock-\(UUID()).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SingleInstanceLock(url: url), second = SingleInstanceLock(url: url)
        #expect(first.acquire())
        #expect(!second.acquire())
        first.release()
        #expect(second.acquire())
        second.release()
    }

    @Test func writesPid() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-lock-\(UUID()).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = SingleInstanceLock(url: url)
        #expect(lock.acquire())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "\(getpid())\n")
        lock.release()
    }
}

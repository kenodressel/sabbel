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
}

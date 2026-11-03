import Testing
import Foundation
@testable import SabbelCore

@Suite struct UpdatesTests {
    @Test func parsesCommonForms() {
        #expect(AppVersion.parse("1.2.3") == AppVersion.parse("v1.2.3"))
        #expect(AppVersion.parse("1.2") == AppVersion.parse("1.2.0"))
        #expect(AppVersion.parse("1") == AppVersion.parse("1.0.0"))
        #expect(AppVersion.parse("  1.2.3+build.5  ") == AppVersion.parse("1.2.3"))
        #expect(AppVersion.parse("1.2.3+build-5") == AppVersion.parse("1.2.3"))
    }
    @Test func rejectsGarbage() {
        for s in ["dev", "", "not.a.version", "1..2", "v", "-rc1"] { #expect(AppVersion.parse(s) == nil) }
    }
    @Test func prereleaseSortsBelowRelease() {
        #expect(AppVersion.parse("1.2.3-rc1")! < AppVersion.parse("1.2.3")!)
        #expect(AppVersion.parse("1.2.3-beta.2")! < AppVersion.parse("1.2.3")!)
        #expect(AppVersion.parse("1.2.3")! < AppVersion.parse("1.2.10")!)
    }
    @Test func isNewerCompares() {
        #expect(isNewer("0.2.0", than: "0.1.5"))
        #expect(isNewer("1.0.0", than: "0.5.2"))
        #expect(!isNewer("0.1.5", than: "0.1.5"))
        #expect(!isNewer("0.1.4", than: "0.1.5"))
        #expect(!isNewer("1.2.3-rc1", than: "1.2.3"))
        #expect(isNewer("1.2.3", than: "1.2.3-rc1"))
        #expect(!isNewer("1.0.0", than: "dev"))
        #expect(!isNewer("garbage", than: "1.0.0"))
    }
    @Test func latestTagStripsV() {
        #expect(latestTag(fromReleaseJSON: Data(#"{"tag_name":"v1.0.1"}"#.utf8)) == "1.0.1")
        #expect(latestTag(fromReleaseJSON: Data(#"{"tag_name":"1.0.1"}"#.utf8)) == "1.0.1")
        #expect(latestTag(fromReleaseJSON: Data("{}".utf8)) == nil)
        #expect(latestTag(fromReleaseJSON: Data("nope".utf8)) == nil)
    }
    @Test func endpoints() {
        #expect(Endpoints.releasePage("1.0.1").absoluteString == "https://github.com/kenodressel/sabbel/releases/tag/v1.0.1")
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-upd-\(UUID().uuidString)")
    }
    @Test func throttle() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/update-check.json")
        let t = UpdateThrottle(stateURL: url)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(t.isDue(now: now))
        t.record(now: now.addingTimeInterval(-3600))
        #expect(!t.isDue(now: now))
        t.record(now: now.addingTimeInterval(-25 * 3600))
        #expect(t.isDue(now: now))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Double]
        #expect(obj?["last_check"] == now.timeIntervalSince1970 - 25 * 3600)
        try Data("{not json".utf8).write(to: url)
        #expect(t.isDue(now: now))
    }
    @Test func recordSwallowsWriteErrors() {
        UpdateThrottle(stateURL: URL(fileURLWithPath: "/dev/null/x/y.json")).record(now: Date())
    }
}

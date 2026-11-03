import Foundation
import Testing
import SabbelCore
@testable import SabbelSystem

/// Counts fetches and answers with a canned result.
private final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URLRequest] = []
    private let result: Result<Data, any Error>

    init(_ result: Result<Data, any Error>) { self.result = result }

    var calls: [URLRequest] { lock.withLock { _calls } }

    func fetch(_ request: URLRequest) async throws -> Data {
        lock.withLock { _calls.append(request) }
        return try result.get()
    }
}

private struct Offline: Error {}

private func release(_ tag: String) -> Data { Data(#"{"tag_name": "\#(tag)"}"#.utf8) }

/// A class suite: each test gets a fresh instance, and `deinit` removes its temp dir.
@Suite final class UpdateCheckerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-update-\(UUID())")

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func throttle() -> UpdateThrottle {
        UpdateThrottle(stateURL: dir.appendingPathComponent("update-check.json"))
    }

    private func checker(version: String, _ throttle: UpdateThrottle, _ fake: FakeFetch) -> UpdateChecker {
        let now = self.now
        return UpdateChecker(version: version, throttle: throttle, fetch: { try await fake.fetch($0) }, now: { now })
    }

    @Test func devBuildNeverFetches() async {
        let fake = FakeFetch(.success(release("v9.9.9")))
        let t = throttle()
        #expect(await checker(version: "dev", t, fake).check() == nil)
        #expect(await checker(version: "dev", t, fake).check(force: true) == nil)
        #expect(fake.calls.isEmpty)
        #expect(t.isDue(now: now))
    }

    @Test func notDueDoesNotFetch() async {
        let fake = FakeFetch(.success(release("v9.9.9")))
        let t = throttle()
        t.record(now: now.addingTimeInterval(-3600))
        #expect(await checker(version: "1.0.0", t, fake).check() == nil)
        #expect(fake.calls.isEmpty)
    }

    @Test func forcedCheckIgnoresTheThrottle() async {
        let fake = FakeFetch(.success(release("v1.1.0")))
        let t = throttle()
        t.record(now: now.addingTimeInterval(-3600))
        #expect(await checker(version: "1.0.0", t, fake).check(force: true) == "1.1.0")
        #expect(fake.calls.count == 1)
    }

    @Test func dueFetchesThenRecordsAndReportsNewer() async throws {
        let fake = FakeFetch(.success(release("v1.1.0")))
        let t = throttle()
        #expect(await checker(version: "1.0.0", t, fake).check() == "1.1.0")
        #expect(fake.calls.count == 1)
        #expect(!t.isDue(now: now))

        let request = try #require(fake.calls.first)
        #expect(request.url == Endpoints.latestRelease)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.v3+json")
        #expect(request.timeoutInterval == 5)
    }

    @Test func sameTagReportsNothing() async {
        let fake = FakeFetch(.success(release("v1.0.0")))
        let t = throttle()
        #expect(await checker(version: "1.0.0", t, fake).check() == nil)
        #expect(fake.calls.count == 1)
        #expect(!t.isDue(now: now))
    }

    @Test func unparseableBodyDoesNotRecord() async {
        let fake = FakeFetch(.success(Data(#"{"message": "Not Found"}"#.utf8)))
        let t = throttle()
        #expect(await checker(version: "1.0.0", t, fake).check() == nil)
        #expect(fake.calls.count == 1)
        #expect(t.isDue(now: now))
    }

    @Test func fetchErrorDoesNotRecord() async {
        let fake = FakeFetch(.failure(Offline()))
        let t = throttle()
        #expect(await checker(version: "1.0.0", t, fake).check() == nil)
        #expect(fake.calls.count == 1)
        #expect(t.isDue(now: now))
    }

    @Test func nonSuccessStatusIsAFetchError() {
        let url = Endpoints.latestRelease
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let limited = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(throws: Never.self) { try UpdateChecker.validate(ok) }
        #expect(throws: UpdateChecker.HTTPStatusError.self) { try UpdateChecker.validate(limited) }
    }
}

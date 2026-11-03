import Foundation
import SabbelCore

/// The once-a-day check for a newer GitHub release (`_check_for_update` in `sabbel/app.py`).
///
/// Failures are silent apart from the log: no network, a rate limit or a
/// GitHub outage must never show up as an error in the menu bar.
public final class UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    /// A non-2xx answer, e.g. GitHub's 403 rate limit. Counts as a failed fetch.
    struct HTTPStatusError: Error, CustomStringConvertible {
        let status: Int
        var description: String { "HTTP \(status)" }
    }

    private let version: String
    private let throttle: UpdateThrottle
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    public init(version: String, throttle: UpdateThrottle, fetch: @escaping Fetch = UpdateChecker.fetchWithURLSession,
                now: @escaping @Sendable () -> Date = Date.init, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.version = version
        self.throttle = throttle
        self.fetch = fetch
        self.now = now
        self.log = log
    }

    static func request() -> URLRequest {
        var request = URLRequest(url: Endpoints.latestRelease, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Returns the latest version when it is newer than this build, else nil.
    ///
    /// - `dev` builds never check.
    /// - Unless `force` (the menu's "Check for updates"), only when the throttle says it is due.
    /// - The check is recorded only once a fetch returned a tag, so an offline
    ///   launch (or a garbled answer) tries again next time instead of waiting a day.
    public func check(force: Bool = false) async -> String? {
        guard version != "dev" else { return nil }
        let started = now()
        guard force || throttle.isDue(now: started) else { return nil }
        let data: Data
        do {
            data = try await fetch(Self.request())
        } catch {
            log("Update check failed: \(error)")
            return nil
        }
        guard let latest = latestTag(fromReleaseJSON: data) else {
            log("Update check: no tag in the response")
            return nil
        }
        throttle.record(now: started)
        guard isNewer(latest, than: version) else { return nil }
        log("Update available: v\(latest) (current: v\(version))")
        return latest
    }

    static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(status: http.statusCode)
        }
    }

    /// An ephemeral session: no cookies or cache on disk for a single GET.
    public static let fetchWithURLSession: Fetch = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }
}

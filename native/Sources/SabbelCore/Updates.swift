import Foundation

/// A sortable app version. A prerelease sorts below its release (SemVer), so
/// `1.2.3-rc1 < 1.2.3`.
public struct AppVersion: Comparable, Sendable {
    let parts: [Int]          // always three components
    let isRelease: Bool

    /// Handles `1.2.3`, `v1.2.3`, `1.2` (padded to `1.2.0`), `1.2.3-rc1`
    /// (prerelease), `1.2.3+build.5` (metadata ignored). `dev` and garbage give `nil`.
    public static func parse(_ s: String) -> AppVersion? {
        var t = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        while t.hasPrefix("v") { t = t.dropFirst() }
        // Metadata after "+" is ignored entirely; a "-" before it marks a prerelease.
        let noMeta = t.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let halves = noMeta.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0]
        let prerelease = halves.count > 1
        if core.isEmpty { return nil }
        var nums: [Int] = []
        for p in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        return AppVersion(parts: nums, isRelease: !prerelease)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
        return !a.isRelease && b.isRelease
    }
}

/// True iff `latest` parses to a strictly newer version than `current`.
/// Unparseable input (e.g. a `dev` build) is never "newer".
public func isNewer(_ latest: String, than current: String) -> Bool {
    guard let l = AppVersion.parse(latest), let c = AppVersion.parse(current) else { return false }
    return l > c
}

/// `tag_name` from a GitHub release JSON, without a leading "v".
public func latestTag(fromReleaseJSON data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = obj["tag_name"] as? String else { return nil }
    let t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return t.isEmpty ? nil : t
}

public enum Endpoints {
    public static let latestRelease = URL(string: "https://api.github.com/repos/kenodressel/sabbel/releases/latest")!
    public static func releasePage(_ v: String) -> URL {
        URL(string: "https://github.com/kenodressel/sabbel/releases/tag/v\(v)")!
    }
}

/// Once-a-day throttle for the update check. State file format is the Python
/// app's: `{"last_check": <unix seconds>}`.
public struct UpdateThrottle: Sendable {
    public let stateURL: URL
    public let interval: TimeInterval

    public init(stateURL: URL, interval: TimeInterval = 86_400) {
        self.stateURL = stateURL
        self.interval = interval
    }

    /// Missing, unreadable or corrupt state means due.
    public func isDue(now: Date) -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        guard let last = obj["last_check"] as? NSNumber else { return obj["last_check"] == nil }
        return now.timeIntervalSince1970 - last.doubleValue >= interval
    }

    /// Best effort: creates the directory, swallows write errors.
    public func record(now: Date) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["last_check": now.timeIntervalSince1970])
            try data.write(to: stateURL)
        } catch {
            // The check simply runs again next time.
        }
    }
}

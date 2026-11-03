import Foundation

/// Where Sabbel's user files live: `$SABBEL_CONFIG_DIR`, else `~/.config/sabbel`.
public struct SabbelPaths: Sendable {
    public let configDir: URL

    public init(configDir: URL) { self.configDir = configDir }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> SabbelPaths {
        if let dir = environment["SABBEL_CONFIG_DIR"], !dir.isEmpty {
            return SabbelPaths(configDir: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SabbelPaths(configDir: home.appendingPathComponent(".config/sabbel", isDirectory: true))
    }

    public var configTOML: URL { configDir.appendingPathComponent("config.toml") }
    public var preferencesJSON: URL { configDir.appendingPathComponent("preferences.json") }
    public var historyLog: URL { configDir.appendingPathComponent("history.log") }
    public var updateCheckJSON: URL { configDir.appendingPathComponent("update-check.json") }
    public var glossary: URL { configDir.appendingPathComponent("glossary.txt") }
}

/// User-authored settings from `config.toml`, overlaid with `preferences.json`.
///
/// Both files are user data: they live outside the app bundle and survive every
/// reinstall, upgrade and restart. A value the running build cannot use must
/// therefore never be fatal. The pre-0.4.0 README told users to pin
/// `[model] repo = "mlx-community/whisper-large-v3-turbo"`, and once Parakeet
/// replaced Whisper that same line refused every transcription for good, with
/// "restart Sabbel" as the only (useless) advice.
///
/// So every value is validated here and a bad one is dropped in favour of its
/// default, loudly in the log but without taking the rest of the file, or the
/// app, down with it. Keys of the Python app that no longer exist
/// (`[model]`, `[injection]`) are ignored the same way. Nothing is written back.
public struct SabbelSettings: Equatable, Sendable {
    public var hotkey: HotkeySpec = .default
    public var hotkeyName: String = "alt_r"
    public var minDuration: TimeInterval = 0.5
    /// FluidAudio refuses audio shorter than this, so a smaller minimum would
    /// only turn "Too short" into a recognition error.
    public static let minDurationFloor: TimeInterval = 0.3
    public var historyEnabled = false
    public var historyMaxBytes = 1_000_000
    /// How many recent dictations the menu keeps in memory; 0 turns the feature off.
    public var recentLimit = 10
    public var audioDevice: String? = nil
    /// Remove fillers ("ähm", "uh") and accidental repeats before pasting.
    public var tidyText = true
    /// Per-app formatting, e.g. no trailing period in chat and terminal apps.
    public var appRules = true

    public init() {}

    private static let known: [String: Set<String>] = [
        "general": ["hotkey"], "audio": ["min_duration_seconds"],
        "history": ["enabled", "max_bytes", "recent"],
        "text": ["tidy", "app_rules"],
    ]
    private static let obsolete: [String: Set<String>] = [
        "model": ["repo"], "injection": ["pre_paste_delay", "post_paste_delay"],
    ]

    public static func load(paths: SabbelPaths, log: (String) -> Void) -> SabbelSettings {
        var s = SabbelSettings()
        s.applyTOML(paths.configTOML, log: log)
        s.applyPreferences(paths.preferencesJSON)
        return s
    }

    private mutating func applyTOML(_ url: URL, log: (String) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let doc: MiniTOML.Document
        do {
            doc = try MiniTOML.parse(String(contentsOf: url, encoding: .utf8))
        } catch {
            log("Ignoring \(url.path), using defaults (\(error))")
            return
        }

        for (section, values) in doc.sorted(by: { $0.key < $1.key }) {
            if Self.known[section] == nil && Self.obsolete[section] == nil {
                log("Ignoring unknown section [\(section)] in \(url.path)")
                continue
            }
            for key in values.keys.sorted()
            where !(Self.known[section]?.contains(key) ?? false) {
                log("Ignoring \(Self.obsolete[section]?.contains(key) == true ? "obsolete" : "unknown") key [\(section)] \(key) in \(url.path): ignored")
            }
        }

        func reject(_ section: String, _ key: String, _ raw: TOMLValue, _ why: String, _ fallback: Any) {
            log("Ignoring [\(section)] \(key) = \(raw) in \(url.path) (\(why)); using the default \(fallback)")
        }

        if let raw = doc["general"]?["hotkey"] {
            if case .string(let v) = raw, case let name = v.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty, let spec = HotkeySpec.parse(name) {
                hotkey = spec
                hotkeyName = name
            } else {
                reject("general", "hotkey", raw, "expected a known key name", hotkeyName)
            }
        }
        if let raw = doc["audio"]?["min_duration_seconds"] {
            switch raw {
            case .integer(let i) where Double(i) >= Self.minDurationFloor: minDuration = Double(i)
            case .float(let d) where d.isFinite && d >= Self.minDurationFloor: minDuration = d
            default: reject("audio", "min_duration_seconds", raw, "expected a finite number >= \(Self.minDurationFloor)", minDuration)
            }
        }
        if let raw = doc["history"]?["enabled"] {
            if case .bool(let b) = raw { historyEnabled = b }
            else { reject("history", "enabled", raw, "expected true or false", historyEnabled) }
        }
        if let raw = doc["history"]?["max_bytes"] {
            if case .integer(let i) = raw, i > 0 { historyMaxBytes = i }
            else { reject("history", "max_bytes", raw, "expected a whole number > 0", historyMaxBytes) }
        }
        if let raw = doc["history"]?["recent"] {
            if case .integer(let i) = raw, (0...50).contains(i) { recentLimit = i }
            else { reject("history", "recent", raw, "expected a whole number from 0 to 50", recentLimit) }
        }
        if let raw = doc["text"]?["tidy"] {
            if case .bool(let b) = raw { tidyText = b }
            else { reject("text", "tidy", raw, "expected true or false", tidyText) }
        }
        if let raw = doc["text"]?["app_rules"] {
            if case .bool(let b) = raw { appRules = b }
            else { reject("text", "app_rules", raw, "expected true or false", appRules) }
        }
    }

    /// Menu toggles win over config.toml. A corrupt file or a wrong-typed value is
    /// ignored, as in the Python app.
    private mutating func applyPreferences(_ url: URL) {
        let prefs = Preferences.read(at: url)
        if let flag = prefs["history_enabled"], Preferences.isBool(flag) {
            historyEnabled = (flag as? Bool) ?? historyEnabled
        }
        if let device = prefs["audio_device"] {
            if device is NSNull { audioDevice = nil }
            else if let name = device as? String { audioDevice = name }
        }
    }
}

/// Runtime-toggled preferences, stored apart from the hand-edited `config.toml`.
public enum Preferences {
    /// An unreadable or non-object file reads as empty.
    static func read(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Read-merge-write; `nil` stores JSON null.
    public static func save(_ key: String, _ value: Any?, at url: URL) throws {
        var prefs = read(at: url)
        prefs[key] = value ?? NSNull()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

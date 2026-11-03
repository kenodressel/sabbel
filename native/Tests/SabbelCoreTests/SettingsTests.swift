import Foundation
import Testing
@testable import SabbelCore

private func makeDir() -> SabbelPaths {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return SabbelPaths(configDir: url)
}

private func load(toml: String? = nil, prefs: String? = nil) -> (SabbelSettings, [String]) {
    let p = makeDir()
    if let toml { try! toml.write(to: p.configTOML, atomically: true, encoding: .utf8) }
    if let prefs { try! prefs.write(to: p.preferencesJSON, atomically: true, encoding: .utf8) }
    nonisolated(unsafe) var lines: [String] = []
    let s = SabbelSettings.load(paths: p, log: { lines.append($0) })
    return (s, lines)
}

@Suite struct SettingsTests {
    @Test func defaultsWithoutFiles() {
        let (s, log) = load()
        #expect(s == SabbelSettings())
        #expect(s.hotkeyName == "alt_r" && s.hotkey == .default && s.audioDevice == nil)
        #expect(log.isEmpty)
    }

    @Test func tomlValues() {
        let (s, log) = load(toml: """
        [general]
        hotkey = "f5"   # push to talk
        [audio]
        min_duration_seconds = 1.0
        [history]
        enabled = true
        max_bytes = 2000
        """)
        #expect(s.hotkeyName == "f5")
        #expect(s.hotkey == HotkeySpec.parse("f5"))
        #expect(s.minDuration == 1.0 && s.historyEnabled && s.historyMaxBytes == 2000)
        #expect(log.isEmpty)
    }

    @Test func textSwitchesDefaultOnAndCanBeTurnedOff() {
        #expect(SabbelSettings().tidyText && SabbelSettings().appRules && SabbelSettings().voiceCommands)
        let (s, log) = load(toml: "[text]\ntidy = false\napp_rules = false\nvoice_commands = false")
        #expect(!s.tidyText && !s.appRules && !s.voiceCommands)
        #expect(log.isEmpty)
    }

    @Test func minDurationAtTheFloorIsAccepted() {
        let (s, log) = load(toml: "[audio]\nmin_duration_seconds = 0.3")
        #expect(s.minDuration == 0.3)
        #expect(log.isEmpty)
    }

    @Test(arguments: [
        ("[general]\nhotkey = \"bogus\"", "hotkey"),
        ("[audio]\nmin_duration_seconds = 0", "min_duration_seconds"),
        ("[audio]\nmin_duration_seconds = true", "min_duration_seconds"),
        ("[audio]\nmin_duration_seconds = nan", "min_duration_seconds"),
        // FluidAudio rejects audio shorter than 0.3 s, so a shorter minimum would let such takes through.
        ("[audio]\nmin_duration_seconds = 0.2", "min_duration_seconds"),
        ("[audio]\nmin_duration_seconds = 0.29", "min_duration_seconds"),
        ("[history]\nmax_bytes = -1", "max_bytes"),
        ("[history]\nmax_bytes = 1.5", "max_bytes"),
        ("[history]\nenabled = \"yes\"", "enabled"),
        ("[text]\ntidy = 1", "tidy"),
        ("[text]\napp_rules = \"no\"", "app_rules"),
        ("[text]\nvoice_commands = 1", "voice_commands"),
    ])
    func invalidValueFallsBackAndKeepsOthers(toml: String, key: String) {
        let extra = key == "hotkey" ? "" : "[general]\nhotkey = \"f5\"\n"
        let (s, log) = load(toml: extra + toml)
        var expected = SabbelSettings()
        if key != "hotkey" { expected.hotkey = HotkeySpec.parse("f5")!; expected.hotkeyName = "f5" }
        #expect(s == expected)
        #expect(log.count == 1 && log[0].contains(key))
    }

    @Test func obsoleteKeysAreIgnoredWithLog() {
        let (s, log) = load(toml: "[model]\nrepo = \"x\"\n[injection]\npre_paste_delay = 0.1\n")
        #expect(s == SabbelSettings())
        #expect(log.count == 2 && log.allSatisfy { $0.contains("ignored") })
    }

    @Test func unknownSectionAndKeyAreLoggedNotFatal() {
        let (s, log) = load(toml: "[dictionary]\nfoo = 1\n[general]\nlanguage = \"de\"\nhotkey = \"f5\"\n")
        #expect(s.hotkeyName == "f5")
        #expect(log.count == 2)
    }

    @Test func unparseableTomlGivesDefaults() {
        let (s, log) = load(toml: "[general\nhotkey = \"f5\"")
        #expect(s == SabbelSettings())
        #expect(log.count == 1)
    }

    @Test func preferencesOverrideToml() {
        #expect(load(toml: "[history]\nenabled = false", prefs: #"{"history_enabled": true}"#).0.historyEnabled)
        #expect(!load(toml: "[history]\nenabled = true", prefs: #"{"history_enabled": false}"#).0.historyEnabled)
    }

    @Test func audioDevice() {
        #expect(load(prefs: #"{"audio_device": "Dell WD22 Mic"}"#).0.audioDevice == "Dell WD22 Mic")
        #expect(load(prefs: #"{"audio_device": null}"#).0.audioDevice == nil)
    }

    @Test func corruptOrWrongTypedPreferencesIgnored() {
        #expect(load(toml: "[history]\nenabled = true", prefs: "{not json").0.historyEnabled)
        let (s, _) = load(toml: "[history]\nenabled = true", prefs: #"{"history_enabled": "no", "audio_device": 3}"#)
        #expect(s.historyEnabled && s.audioDevice == nil)
        #expect(load(toml: "[history]\nenabled = false", prefs: #"{"history_enabled": 1}"#).0.historyEnabled == false)
    }

    @Test func saveKeepsOtherKeysAndWritesNull() throws {
        let p = makeDir()
        let url = p.configDir.appendingPathComponent("sub/preferences.json")
        try Preferences.save("history_enabled", true, at: url)
        try Preferences.save("audio_device", "Mic", at: url)
        try Preferences.save("audio_device", nil, at: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["history_enabled"] as? Bool == true)
        #expect(obj["audio_device"] is NSNull)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n") && text.range(of: "audio_device")!.lowerBound < text.range(of: "history_enabled")!.lowerBound)
    }

    @Test func saveOverCorruptFileTreatsItAsEmpty() throws {
        let p = makeDir()
        try "garbage".write(to: p.preferencesJSON, atomically: true, encoding: .utf8)
        try Preferences.save("a", 1, at: p.preferencesJSON)
        #expect(Preferences.read(at: p.preferencesJSON)["a"] as? Int == 1)
    }

    @Test func paths() {
        let p = SabbelPaths.current(environment: ["SABBEL_CONFIG_DIR": "/x"])
        #expect(p.historyLog.path == "/x/history.log")
        #expect(p.configTOML.path == "/x/config.toml" && p.preferencesJSON.path == "/x/preferences.json")
        #expect(p.updateCheckJSON.path == "/x/update-check.json")
        #expect(SabbelPaths.current(environment: [:]).configDir.path.hasSuffix("/.config/sabbel"))
    }
}

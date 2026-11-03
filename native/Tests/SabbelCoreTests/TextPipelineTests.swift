import Foundation
import Testing
@testable import SabbelCore

@Suite struct TextPipelineTests {
    @Test func identityLeavesTextAlone() {
        #expect(TextPipeline.identity.process("Hallo Welt.", target: nil) == "Hallo Welt.")
    }

    @Test func stagesRunInOrder() {
        let pipeline = TextPipeline([{ text, _ in text + "a" }, { text, _ in text + "b" }])
        #expect(pipeline.process("x", target: nil) == "xab")
    }

    @Test func stagesSeeTheTarget() {
        let slack = FocusTarget(pid: 7, name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let pipeline = TextPipeline([{ text, target in target?.bundleID == slack.bundleID ? "slack" : text }])
        #expect(pipeline.process("x", target: slack) == "slack")
        #expect(pipeline.process("x", target: nil) == "x")
    }

    @Test func standardRunsGlossaryThenTidyThenAppRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SabbelPaths(configDir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Kubernetes: Kuber Netties\n".write(to: paths.glossary, atomically: true, encoding: .utf8)
        let pipeline = TextPipeline.standard(settings: SabbelSettings(), paths: paths, log: { _ in })
        let slack = FocusTarget(pid: 7, name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        #expect(pipeline.process("Ähm, wir nutzen Kuber Netties.", target: slack) == "Wir nutzen Kubernetes")
        #expect(pipeline.process("Ähm, wir nutzen Kuber Netties.", target: nil) == "Wir nutzen Kubernetes.")

        var off = SabbelSettings()
        off.tidyText = false
        off.appRules = false
        let plain = TextPipeline.standard(settings: off, paths: paths, log: { _ in })
        #expect(plain.process("Ähm, wir nutzen Kuber Netties.", target: slack) == "Ähm, wir nutzen Kubernetes.")
    }
}

@Suite struct VoiceCommandPipelineTests {
    private func standard(_ settings: SabbelSettings) -> TextPipeline {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-pipeline-\(UUID().uuidString)")
        return TextPipeline.standard(settings: settings, paths: SabbelPaths(configDir: dir), log: { _ in })
    }

    @Test func commandsRunAfterTheGlossaryAndBeforeTidyAndAppRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sabbel-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SabbelPaths(configDir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Kubernetes: Kuber Netties\n".write(to: paths.glossary, atomically: true, encoding: .utf8)
        let pipeline = TextPipeline.standard(settings: SabbelSettings(), paths: paths, log: { _ in })
        let slack = FocusTarget(pid: 7, name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        #expect(pipeline.process("Ähm, Kuber Netties, neue Zeile, läuft.", target: slack) == "Kubernetes\nläuft")
        #expect(pipeline.process("Ähm, Kuber Netties, neue Zeile, läuft.", target: nil) == "Kubernetes\nläuft.")
    }

    @Test func switchedOffLeavesCommandsAlone() {
        var off = SabbelSettings()
        off.voiceCommands = false
        #expect(standard(off).process("Eins, neue Zeile, zwei", target: nil) == "Eins, neue Zeile, zwei")
        #expect(standard(SabbelSettings()).process("Eins, neue Zeile, zwei", target: nil) == "Eins\nzwei")
    }

    @Test func lineBreaksSurviveTidy() {
        #expect(standard(SabbelSettings()).process("Eins. Neue Zeile. Äh, zwei. Neuer Absatz. Drei", target: nil)
                == "Eins.\nZwei.\n\nDrei")
    }
}

import Testing
import Foundation
@testable import SabbelCore

@Suite struct AppRulesTests {
    private func target(_ id: String?) -> FocusTarget { FocusTarget(pid: 1, name: "App", bundleID: id) }
    private let slack = "com.tinyspeck.slackmacgap"
    private func run(_ text: String, _ id: String? = "com.tinyspeck.slackmacgap") -> String {
        AppRules.stage(text, target(id))
    }

    @Test func slackDropsThePeriod() { #expect(run("Das passt so.") == "Das passt so") }
    @Test func mailKeepsIt() { #expect(run("Das passt so.", "com.apple.mail") == "Das passt so.") }
    @Test func nilTargetKeepsIt() {
        #expect(AppRules.stage("Hallo.", nil) == "Hallo.")
        #expect(AppRules.stage("Hallo.", FocusTarget(pid: 1, name: nil)) == "Hallo.")
    }
    @Test func prefixEntryMatches() {
        #expect(run("Fertig.", "com.jetbrains.intellij") == "Fertig")
        #expect(run("Fertig.", "com.jetbrainsx") == "Fertig.")
    }
    @Test func otherEndingsStay() {
        for t in ["Wirklich?", "Super!", "Mal sehen...", "Mal sehen…", "Ohne Punkt"] {
            #expect(run(t) == t)
        }
    }
    @Test func abbreviationsStay() {
        for t in ["Das ist z. B.", "also d. h.", "und u. a.", "Obst usw.", "Use e.g.", "that is i.e.",
                  "Siehe ETC.", "bis ca.", "Herr Dr.", "Nr."] {
            #expect(run(t) == t)
        }
    }
    @Test func onlyTheFinalPeriodGoes() {
        #expect(run("Eins. Zwei. Drei.") == "Eins. Zwei. Drei")
        #expect(run("Das war z. B. gut.") == "Das war z. B. gut")
    }
    @Test func trailingWhitespaceIsKept() {
        #expect(run("Hallo. ") == "Hallo ")
        #expect(run("Hallo.\n") == "Hallo\n")
        #expect(run("Hallo ") == "Hallo ")
        #expect(run("usw. ") == "usw. ")
    }
    @Test func emptyAndLonePeriod() {
        #expect(run("") == "")
        #expect(run(".") == "")
    }
    @Test func standardPipelineHonoursTheSetting() {
        var settings = SabbelSettings()
        let paths = SabbelPaths(configDir: URL(fileURLWithPath: "/nonexistent-sabbel-test"))
        let t = target(slack)
        #expect(TextPipeline.standard(settings: settings, paths: paths, log: { _ in })
            .process("Hi.", target: t) == "Hi")
        settings.appRules = false
        #expect(TextPipeline.standard(settings: settings, paths: paths, log: { _ in })
            .process("Hi.", target: t) == "Hi.")
    }
}

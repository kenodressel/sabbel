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
}

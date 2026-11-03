import Testing
import SabbelCore
@testable import SabbelSystem

@Suite struct LiveDisplayTests {
    @Test func settledThenProvisionalWithOneSpace() {
        let parts = LiveDisplay.parts(LiveText(settled: "hello there", provisional: "general"), masked: false)
        #expect(parts.settled == "hello there")
        #expect(parts.provisional == " general")
    }

    @Test func onlyProvisionalHasNoLeadingSpace() {
        let parts = LiveDisplay.parts(LiveText(settled: "", provisional: "hello"), masked: false)
        #expect(parts.settled == "")
        #expect(parts.provisional == "hello")
    }

    @Test func maskedTextIsNeverShown() {
        let parts = LiveDisplay.parts(LiveText(settled: "hunter2", provisional: "secret"), masked: true)
        #expect(parts.settled == "•••")
        #expect(parts.provisional == "")
        let onlyProvisional = LiveDisplay.parts(LiveText(settled: "", provisional: "secret"), masked: true)
        #expect(onlyProvisional.settled == "•••")
        #expect(onlyProvisional.provisional == "")
    }

    @Test func emptyMaskedTakeShowsNothing() {
        let parts = LiveDisplay.parts(LiveText(settled: "", provisional: ""), masked: true)
        #expect(parts.settled == "")
        #expect(parts.provisional == "")
    }
}

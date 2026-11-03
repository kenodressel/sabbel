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

    // MARK: tail

    @Test func shortTextIsKept() {
        let parts = LiveDisplay.tail(("hello there", " general"), limit: 40)
        #expect(parts == ("hello there", " general"))
    }

    @Test func longTextKeepsTheNewestWholeWords() {
        let parts = LiveDisplay.tail(("one two three four five", " six seven"), limit: 18)
        // "four five six seven" would be 19; "five six seven" fits after a cut inside "four".
        #expect(parts.settled == "…five")
        #expect(parts.provisional == " six seven")
    }

    @Test func cutOnABoundaryKeepsTheWord() {
        let parts = LiveDisplay.tail(("alpha beta gamma", ""), limit: 10)
        #expect(parts == ("…beta gamma", ""))
    }

    @Test func longProvisionalDropsAllSettledText() {
        let parts = LiveDisplay.tail(("old words", " new provisional words"), limit: 18)
        #expect(parts.settled == "")
        #expect(parts.provisional == "…provisional words")
    }

    @Test func oneHugeWordIsCutHard() {
        let word = String(repeating: "x", count: 30)
        let parts = LiveDisplay.tail((word, ""), limit: 10)
        #expect(parts.settled == "…" + String(repeating: "x", count: 10))
    }

    @Test func maskedTextStaysMasked() {
        let masked = LiveDisplay.parts(LiveText(settled: String(repeating: "secret ", count: 50), provisional: "x"),
                                       masked: true)
        #expect(LiveDisplay.tail(masked, limit: 150) == ("•••", ""))
    }
}

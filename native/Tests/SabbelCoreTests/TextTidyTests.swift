import Foundation
import Testing
@testable import SabbelCore

@Suite struct TextTidyTests {
    private func tidy(_ s: String) -> String { TextTidy.tidy(s).text }

    @Test(arguments: [
        ("Ähm, ich glaube das.", "Ich glaube das."),
        ("Das ist, äh, gut.", "Das ist gut."),
        ("Das ist äh gut.", "Das ist gut."),
        ("Gut, ähm.", "Gut."),
        ("Ähm.", ""),
        ("Gut ähm.", "Gut."),
        ("Äh, ähm, gut.", "Gut."),
        ("Hmm, mhm, öh, öhm, ehm.", ""),
    ])
    func germanFillers(input: String, expected: String) {
        #expect(tidy(input) == expected)
    }

    @Test(arguments: [
        ("Uh, I think so.", "I think so."),
        ("I think, uhm, so.", "I think so."),
        ("It is uhh fine.", "It is fine."),
        ("Erm, well.", "Well."),
        ("Um, I think so.", "I think so."),
        ("So, um, yes.", "So yes."),
        ("That is it, um.", "That is it."),
    ])
    func englishFillers(input: String, expected: String) {
        #expect(tidy(input) == expected)
    }

    @Test func umIsKeptAsAGermanWord() {
        #expect(tidy("Wir treffen uns um 5 Uhr.") == "Wir treffen uns um 5 Uhr.")
        #expect(tidy("Ich gehe, um zu gehen.") == "Ich gehe, um zu gehen.")
        #expect(tidy("Er kam um zu gehen") == "Er kam um zu gehen")
        // A hesitation right after the preposition keeps the preposition.
        #expect(tidy("Es geht um, äh, die Planung.") == "Es geht um die Planung.")
        #expect(tidy("Es geht um. Danke.") == "Es geht um. Danke.")
    }

    @Test func caseInsensitiveWholeWordsOnly() {
        #expect(tidy("ÄHM, gut.") == "Gut.")
        #expect(tidy("Hmmm ist kein Wort, Ehmann und Uhr bleiben.") == "Hmmm ist kein Wort, Ehmann und Uhr bleiben.")
    }

    @Test func neverLeavesStrayPunctuationOrSpaces() {
        for input in ["Ähm, ja.", "Ja, ähm, nein.", "Ja ähm nein", "Ja, ähm.", "Ähm, ähm, ja"] {
            let out = tidy(input)
            #expect(!out.contains("  "))
            #expect(!out.contains(" ,") && !out.contains(" ."))
            #expect(!out.hasPrefix(",") && !out.hasPrefix(" "))
        }
    }

    @Test func multipleSentences() {
        #expect(tidy("Ähm, ich glaube das. Äh, wirklich. Das ist, ähm, gut!")
                == "Ich glaube das. Wirklich. Das ist gut!")
    }

    @Test func collapsesRepeatedRuns() {
        #expect(tidy("at the at the store") == "at the store")
        #expect(tidy("Ich glaube ich glaube das.") == "Ich glaube das.")
        #expect(tidy("we should go to we should go to the shop") == "we should go to the shop")
        #expect(tidy("one two three four one two three four five") == "one two three four five")
        #expect(tidy("At the At the end") == "At the end")
    }

    @Test func collapsesAcrossAComma() {
        #expect(tidy("ich glaube, ich glaube das") == "ich glaube das")
        #expect(tidy("ich glaube, ich glaube, dass es geht") == "ich glaube, dass es geht")
        #expect(tidy("Ich glaube ich glaube.") == "Ich glaube.")
    }

    @Test func fiveWordRepeatIsLeftAlone() {
        let text = "a b c d e a b c d e"
        #expect(tidy(text) == text)
    }

    @Test func singleWordDoublesAreKept() {
        #expect(tidy("Leute, die die Regeln kennen") == "Leute, die die Regeln kennen")
        #expect(tidy("Das, das stimmt") == "Das, das stimmt")
        #expect(tidy("Es ist sehr sehr gut") == "Es ist sehr sehr gut")
    }

    @Test func repeatsDoNotCrossSentences() {
        let text = "Ich gehe. Ich gehe nicht."
        #expect(tidy(text) == text)
        #expect(tidy("at the. At the end") == "at the. At the end")
    }

    @Test func fillerBetweenRepeatsStillCollapses() {
        #expect(tidy("at the äh at the store") == "at the store")
    }

    @Test func cleanTextIsByteIdentical() {
        for text in ["", "  ", "Hallo Welt.", "  Zwei  Leerzeichen\nund Zeilen. ", "Wir sind um 5 da,   okay?"] {
            #expect(tidy(text) == text)
        }
    }

    @Test func otherWhitespaceSurvives() {
        #expect(tidy("Erste Zeile.\nÄhm, zweite  Zeile.\n") == "Erste Zeile.\nZweite  Zeile.\n")
    }

    @Test func countsAreReported() {
        let r = TextTidy.tidy("Äh, at the at the store, ähm.")
        #expect(r.fillersRemoved == 2)
        #expect(r.repeatsCollapsed == 1)
    }

    @Test func standardPipelineHonoursTheSetting() {
        var settings = SabbelSettings()
        settings.tidyText = true
        let on = TextPipeline.standard(settings: settings, paths: SabbelPaths(configDir: URL(fileURLWithPath: "/nonexistent")), log: { _ in })
        #expect(on.process("Ähm, gut.", target: nil) == "Gut.")
        settings.tidyText = false
        let off = TextPipeline.standard(settings: settings, paths: SabbelPaths(configDir: URL(fileURLWithPath: "/nonexistent")), log: { _ in })
        #expect(off.process("Ähm, gut.", target: nil) == "Ähm, gut.")
    }
}

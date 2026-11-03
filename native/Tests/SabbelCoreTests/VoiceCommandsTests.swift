import Foundation
import Testing
@testable import SabbelCore

@Suite struct VoiceCommandsTests {
    // MARK: formatting

    @Test(arguments: [
        ("Hallo zusammen. Neue Zeile. Wie geht's?", "Hallo zusammen.\nWie geht's?"),
        ("Punkt eins, neue Zeile, Punkt zwei", "Punkt eins\nPunkt zwei"),
        ("Punkt eins, neue Zeile, Punkt zwei.", "Punkt eins\nPunkt zwei."),
        ("Hallo Max. Neuer Absatz. Ich schreibe dir.", "Hallo Max.\n\nIch schreibe dir."),
        ("Hello team. New line. How are you?", "Hello team.\nHow are you?"),
        ("Hello team. New paragraph. How are you?", "Hello team.\n\nHow are you?"),
        ("first, new line, second", "first\nsecond"),
        ("NEUE ZEILE", "\n"),
        ("eins neue   Zeile zwei", "eins\nzwei"),
        // The next word stays as the recognizer wrote it.
        ("Gut, neue Zeile, danke", "Gut\ndanke"),
        ("Gut. Neue Zeile. Danke", "Gut.\nDanke"),
        ("Hallo. Neue Zeile.", "Hallo.\n"),
    ])
    func formattingExamples(input: String, expected: String) {
        #expect(VoiceCommands.formatting(input) == expected)
    }

    @Test func severalCommands() {
        #expect(VoiceCommands.formatting("A, neue Zeile, B, neue Zeile, C") == "A\nB\nC")
        #expect(VoiceCommands.formatting("A. Neue Zeile. Neue Zeile. B") == "A.\n\nB")
        #expect(VoiceCommands.formatting("A. Neuer Absatz. B. Neue Zeile. C") == "A.\n\nB.\nC")
    }

    @Test(arguments: ["Der Zeilenumbruch ist kaputt", "Ich tippe newline ein", "Eine neue Zeilenzahl", "renew line item",
                      "Das ist eine neue Zeitung", "new lines are fine", "neue Zeilen"])
    func commandInsideAWordIsNotACommand(text: String) {
        #expect(VoiceCommands.formatting(text) == text)
    }

    @Test func textWithoutCommandsIsByteIdentical() {
        let text = "Hallo,  Welt.\n\nZweite Zeile …"
        #expect(VoiceCommands.formatting(text) == text)
    }

    // MARK: send

    @Test(arguments: [
        ("Das ist gut, press enter", "Das ist gut"),
        ("Das ist gut. Press enter.", "Das ist gut."),
        ("Das passt, send message", "Das passt"),
        ("Send message.", ""),
        ("Bis später, Enter drücken.", "Bis später"),
        ("Passt so, und Enter drücken", "Passt so"),
        ("Passt so. Return drücken!", "Passt so."),
        ("Fertig, press return.", "Fertig"),
        ("Done and press enter", "Done"),
        ("Press Enter", ""),
    ])
    func sendAtTheEnd(input: String, expected: String) {
        let result = VoiceCommands.extractSend(input)
        #expect(result.send)
        #expect(result.text == expected)
    }

    @Test(arguments: [
        "Ich werde es senden.", "Bitte press enter nicht vergessen", "Send message bitte",
        "Das Abschicken dauert", "Der Abschickenknopf", "Ich muss nur senden", "pressenter", "",
    ])
    func sendNotAtTheEndIsIgnored(text: String) {
        let result = VoiceCommands.extractSend(text)
        #expect(!result.send)
        #expect(result.text == text)
    }

    @Test func ordinaryVerbsAtTheEndDoNotSend() {
        for text in ["Ich werde die Mail morgen abschicken.", "Kannst du das senden?", "Ich will das abschicken"] {
            #expect(VoiceCommands.extractSend(text) == (text, false))
        }
    }
}

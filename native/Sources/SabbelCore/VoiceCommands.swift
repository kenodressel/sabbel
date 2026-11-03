import Foundation

/// Spoken commands in a dictation, German and English.
///
/// - Formatting ("neue Zeile", "new paragraph") becomes a line break anywhere
///   in the text; the recognizer's punctuation around it is cleaned up.
/// - The send command ("press enter", "Enter drücken") counts only at the very end
///   of a dictation: it is cut off and reported, and the paste line presses
///   Return after the paste.
///
/// Pure and case-insensitive, whole words only. Text without a command comes
/// back byte-identical.
public enum VoiceCommands {
    /// Punctuation the recognizer puts after a command, which the command takes with it.
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]

    private static let formattingPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(neue\s+zeile|new\s+line|neuer\s+absatz|new\s+paragraph)(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive])

    // The comma (not a sentence end) and spaces before it go with it, as does a
    // leading "und"/"and". Ordinary verbs ("senden", "abschicken") are left
    // out: German puts the verb last, so "… morgen abschicken." would send.
    private static let sendPattern = try! NSRegularExpression(
        pattern: #"(?:[ \t]*,)?\s*(?<![\p{L}\p{N}])(?:(?:und|and)\s+)?"#
            + #"(?:press\s+(?:enter|return)|send\s+message|(?:enter|return)\s+drücken)(?![\p{L}\p{N}])[\s.,;:!?…]*$"#,
        options: [.caseInsensitive])

    /// Replaces "neue Zeile" / "new line" with `\n` and "neuer Absatz" /
    /// "new paragraph" with `\n\n`. A command takes the whitespace around it, the
    /// punctuation right after it and a comma right before it; a sentence end
    /// before it stays. The next word is left as the recognizer wrote it.
    public static func formatting(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        let matches = formattingPattern.matches(in: text, range: whole)
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            out += text[cursor..<range.lowerBound]
            // Spaces before it, then a comma, then the spaces before that. A line
            // break from an earlier command is never trimmed.
            trimSpaces(&out)
            if out.last == "," {
                out.removeLast()
                trimSpaces(&out)
            }
            let word = text[range].lowercased()
            out += word.hasPrefix("neuer") || word.hasSuffix("paragraph") ? "\n\n" : "\n"

            var next = range.upperBound
            while next < text.endIndex, text[next].isWhitespace || trailing.contains(text[next]) {
                next = text.index(after: next)
            }
            cursor = next
        }
        out += text[cursor...]
        return out
    }

    /// Cuts a send command off the end of `text`. `send` tells the paste line to
    /// press Return after the paste; the text may be empty (a send-only dictation).
    public static func extractSend(_ text: String) -> (text: String, send: Bool) {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = sendPattern.firstMatch(in: text, range: whole),
              let range = Range(match.range, in: text) else { return (text, false) }
        return (String(text[..<range.lowerBound]), true)
    }

    private static func trimSpaces(_ s: inout String) {
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
    }

    /// The `TextPipeline` stage.
    public static let stage: TextPipeline.Stage = { text, _ in formatting(text) }
}

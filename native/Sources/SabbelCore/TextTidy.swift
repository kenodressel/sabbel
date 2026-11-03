/// The tidy-up stage: removes spoken fillers ("ähm", "uh") and accidental
/// repeats of two to four words ("at the at the") from a dictation.
///
/// Pure and conservative: text without fillers or repeats comes back
/// byte-identical, and a single repeated word is never touched, because German
/// relative clauses ("Leute, die die Regeln kennen") and emphasis ("sehr sehr")
/// produce real doubles.
public enum TextTidy {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var fillersRemoved: Int
        public var repeatsCollapsed: Int
    }

    /// Fillers that are removed wherever they stand as a whole word.
    private static let fillers: Set<String> = [
        "äh", "ähm", "öh", "öhm", "ehm", "hm", "hmm", "mhm",
        "uh", "uhm", "uhh", "erm",
    ]

    private static let punctuation: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]
    private static let sentenceEnd: Set<Character> = [".", "!", "?", "…"]

    /// One whitespace-separated word: `head` is the word with any leading
    /// punctuation, `trail` the punctuation after it, `sep` the whitespace
    /// before it.
    private struct Token {
        var sep: String
        var head: String
        var trail: String
    }

    /// The stage function; `log` receives counts only, never text.
    public static func stage(log: @escaping @Sendable (String) -> Void) -> TextPipeline.Stage {
        return { text, _ in
            let result = tidy(text)
            if result.fillersRemoved > 0 || result.repeatsCollapsed > 0 {
                log("Tidy: \(result.fillersRemoved) fillers, \(result.repeatsCollapsed) repeats")
            }
            return result.text
        }
    }

    public static func tidy(_ text: String) -> Result {
        var (tokens, tail) = tokenize(text)
        let fillersRemoved = removeFillers(&tokens)
        let repeatsCollapsed = collapseRepeats(&tokens)
        if fillersRemoved == 0 && repeatsCollapsed == 0 {
            return Result(text: text, fillersRemoved: 0, repeatsCollapsed: 0)
        }
        if tokens.isEmpty {
            return Result(text: "", fillersRemoved: fillersRemoved, repeatsCollapsed: repeatsCollapsed)
        }
        let joined = tokens.map { $0.sep + $0.head + $0.trail }.joined() + tail
        return Result(text: joined, fillersRemoved: fillersRemoved, repeatsCollapsed: repeatsCollapsed)
    }

    // MARK: - Tokens

    private static func tokenize(_ text: String) -> ([Token], String) {
        var tokens: [Token] = []
        var sep = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var head = word
            var trail = ""
            while let last = head.last, punctuation.contains(last) {
                trail.insert(last, at: trail.startIndex)
                head.removeLast()
            }
            tokens.append(Token(sep: sep, head: head, trail: trail))
            sep = ""
            word = ""
        }
        for ch in text {
            if ch.isWhitespace {
                flush()
                sep.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        return (tokens, sep)
    }

    // MARK: - Fillers

    private static func isFiller(_ t: Token) -> Bool {
        let word = t.head.lowercased()
        if fillers.contains(word) { return true }
        // "um" is a common German word ("um 5 Uhr"); only a comma or the end of
        // a sentence right after it marks it as a hesitation.
        return word == "um" && !t.trail.isEmpty
    }

    private static func endsSentence(_ t: Token?) -> Bool {
        guard let t else { return true }
        return t.trail.contains { sentenceEnd.contains($0) }
    }

    private static func removeFillers(_ tokens: inout [Token]) -> Int {
        var removed = 0
        var i = 0
        while i < tokens.count {
            guard isFiller(tokens[i]) else {
                i += 1
                continue
            }
            let filler = tokens[i]
            let prev: Token? = i > 0 ? tokens[i - 1] : nil
            let atSentenceStart = endsSentence(prev)
            let wasCapitalised = filler.head.first?.isUppercase ?? false

            if !filler.trail.isEmpty && filler.trail != "," {
                // "Gut, ähm." -> "Gut.": the sentence mark moves to the word before.
                if i > 0 && !endsSentence(prev) {
                    tokens[i - 1].trail = filler.trail
                }
            } else if filler.trail == "," {
                // "Das ist, äh, gut" -> "Das ist gut": a filler set off by commas takes both.
                if i > 0 && prev?.trail == "," {
                    tokens[i - 1].trail = ""
                }
            }

            // Drop the filler, and give the next word the filler's spacing.
            if i + 1 < tokens.count {
                tokens[i + 1].sep = filler.sep
                if atSentenceStart && wasCapitalised, let first = tokens[i + 1].head.first, first.isLetter {
                    tokens[i + 1].head = String(first).uppercased() + tokens[i + 1].head.dropFirst()
                }
            }
            tokens.remove(at: i)
            removed += 1
            // Re-check from the word before: a filler may now follow a new sentence start.
            if i > 0 { i -= 1 }
        }
        return removed
    }

    // MARK: - Repeats

    private static func key(_ t: Token) -> String { t.head.lowercased() }

    /// True when tokens[i..<i+n] repeats as tokens[i+n..<i+2n], ignoring case and
    /// a comma between the runs, and neither run crosses a sentence boundary.
    private static func repeats(_ tokens: [Token], at i: Int, length n: Int) -> Bool {
        guard i + 2 * n <= tokens.count else { return false }
        for k in 0..<n {
            let a = tokens[i + k]
            let b = tokens[i + n + k]
            guard key(a) == key(b), a.head.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
            if k < n - 1 {
                if !a.trail.isEmpty || !b.trail.isEmpty { return false }
            } else if !(a.trail.isEmpty || a.trail == ",") {
                return false
            }
        }
        return true
    }

    private static func collapseRepeats(_ tokens: inout [Token]) -> Int {
        var collapsed = 0
        var i = 0
        while i < tokens.count {
            var found = false
            for n in stride(from: 4, through: 2, by: -1) where repeats(tokens, at: i, length: n) {
                // Keep the first run (it carries any sentence-start capital) and
                // the punctuation that followed the second.
                tokens[i + n - 1].trail = tokens[i + 2 * n - 1].trail
                tokens.removeSubrange((i + n)..<(i + 2 * n))
                collapsed += 1
                found = true
                break
            }
            if !found { i += 1 }
        }
        return collapsed
    }
}

import Foundation

/// Replacement rules for terms the recognizer misspells ("Git Hub" -> "GitHub").
///
/// File format, one entry per line (see `template`):
///     Kubernetes                  a term alone fixes its casing
///     GitHub: Git Hub, git hab    each alias becomes the term
/// `#` starts a comment at the start of a line or after whitespace.
///
/// Matching is case-insensitive, diacritic-sensitive and whole-word only (a
/// match is never preceded or followed by a letter or digit). Whitespace in an
/// alias matches any run of whitespace. One left-to-right pass; at each
/// position the longest alias wins and replaced text is not matched again.
public struct Glossary: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let words: [[Character]]  // alias split on whitespace, each lowercased per character
        let term: String
    }

    private let rulesByFirst: [Character: [Rule]]

    /// Number of alias rules (a line with n aliases counts n times).
    public let count: Int

    public static let empty = Glossary(rules: [])

    private init(rules: [Rule]) {
        var index: [Character: [Rule]] = [:]
        for rule in rules { index[rule.words[0][0], default: []].append(rule) }
        rulesByFirst = index
        count = rules.count
    }

    /// The file a fresh "Edit Glossary…" starts from.
    public static let template = """
        # Sabbel glossary: fixes terms the recognizer gets wrong.
        # Lines starting with # are comments; blank lines are ignored.
        #
        # Kubernetes                      # a term alone fixes its casing: "kubernetes" -> "Kubernetes"
        # GitHub: Git Hub, git hab        # term: aliases, comma-separated -> each alias becomes the term
        # das DAM: das Damm               # an alias may carry context words; the whole match is replaced

        """

    // MARK: parsing

    /// Parses the file's text. Bad lines are skipped and reported in
    /// `warnings`, each naming its line number.
    public static func parse(_ text: String) -> (glossary: Glossary, warnings: [String]) {
        var rules: [Rule] = []
        var warnings: [String] = []
        var seen: [String: Int] = [:]  // normalized alias -> line of the winning rule
        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let term: String
            var aliases: [String]
            if let colon = line.firstIndex(of: ":") {
                term = line[..<colon].trimmingCharacters(in: .whitespaces)
                let rest = line[line.index(after: colon)...]
                aliases = rest.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                term = line
                aliases = [line]
            }
            if term.isEmpty {
                warnings.append("Glossary line \(lineNumber): no term, skipped")
                continue
            }
            if aliases.count == 1, aliases[0].isEmpty {
                warnings.append("Glossary line \(lineNumber): no aliases for \"\(term)\", skipped")
                continue
            }
            for alias in aliases {
                let words = alias.split(whereSeparator: \.isWhitespace)
                    .map { Array($0).map(fold) }
                if words.isEmpty {
                    warnings.append("Glossary line \(lineNumber): empty alias, skipped")
                    continue
                }
                let key = words.map { String($0) }.joined(separator: " ")
                if let first = seen[key] {
                    warnings.append("Glossary line \(lineNumber): alias \"\(alias)\" already defined on line \(first), skipped")
                    continue
                }
                seen[key] = lineNumber
                rules.append(Rule(words: words, term: term))
            }
        }
        return (Glossary(rules: rules), warnings)
    }

    private static func stripComment(_ line: String) -> String {
        var previous: Character?
        for index in line.indices {
            let c = line[index]
            if c == "#", previous == nil || previous!.isWhitespace { return String(line[..<index]) }
            previous = c
        }
        return line
    }

    // MARK: applying

    /// The text with every alias replaced, and how many replacements were made.
    public func apply(_ text: String) -> (text: String, replacements: Int) {
        guard count > 0 else { return (text, 0) }
        let chars = Array(text)
        var out = ""
        var replacements = 0
        var i = 0
        while i < chars.count {
            if let candidates = rulesByFirst[Self.fold(chars[i])], Self.startsWord(chars, at: i) {
                var best: (end: Int, term: String)?
                for rule in candidates {
                    if let end = Self.match(rule, in: chars, at: i), end > (best?.end ?? i) {
                        best = (end, rule.term)
                    }
                }
                if let best {
                    out += best.term
                    replacements += 1
                    i = best.end
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return (out, replacements)
    }

    private static func fold(_ c: Character) -> Character {
        let lower = c.lowercased()
        return lower.count == 1 ? Character(lower) : c
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func startsWord(_ chars: [Character], at i: Int) -> Bool {
        i == 0 || !isWordChar(chars[i - 1])
    }

    /// The end index of a whole-word match of `rule` starting at `start`, or nil.
    private static func match(_ rule: Rule, in chars: [Character], at start: Int) -> Int? {
        var i = start
        for (n, word) in rule.words.enumerated() {
            if n > 0 {
                guard i < chars.count, chars[i].isWhitespace else { return nil }
                while i < chars.count, chars[i].isWhitespace { i += 1 }
            }
            for c in word {
                guard i < chars.count, fold(chars[i]) == c else { return nil }
                i += 1
            }
        }
        if i < chars.count, isWordChar(chars[i]) { return nil }
        return i
    }
}

/// The pipeline stage: the glossary file, re-read whenever its modification
/// date or size changes (one `stat` per take), so edits apply without a restart.
/// Safe to call from any thread.
public final class GlossaryStage: @unchecked Sendable {
    private struct Signature: Equatable { let modified: Date?; let size: Int? }

    private let url: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var glossary = Glossary.empty
    private var loaded: Signature?
    private var hasLoaded = false

    public init(url: URL, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.log = log
    }

    /// `quiet` skips the replacement count, for the live text.
    public func apply(_ text: String, quiet: Bool = false) -> String {
        let current = currentGlossary()
        let (result, replacements) = current.apply(text)
        if replacements > 0, !quiet { log("Glossary: \(replacements) replacements") }
        return result
    }

    private func currentGlossary() -> Glossary {
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let signature = Signature(modified: attributes?[.modificationDate] as? Date,
                                  size: (attributes?[.size] as? NSNumber)?.intValue)
        if hasLoaded, signature == loaded { return glossary }
        hasLoaded = true
        loaded = signature
        guard attributes != nil else {
            glossary = .empty  // no file, no glossary, no noise
            return glossary
        }
        do {
            let data = try Data(contentsOf: url)
            let (parsed, warnings) = Glossary.parse(String(decoding: data, as: UTF8.self))
            glossary = parsed
            log("Glossary: \(parsed.count) entries from \(url.path)")
            for warning in warnings { log(warning) }
        } catch {
            glossary = .empty
            log("Glossary: cannot read \(url.path): \(error.localizedDescription)")
        }
        return glossary
    }
}

extension Glossary {
    /// Writes `template` to `url` unless a file is already there.
    public static func createTemplateIfMissing(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try template.write(to: url, atomically: true, encoding: .utf8)
    }
}

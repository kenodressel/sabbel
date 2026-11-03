import Foundation
import Testing

@testable import SabbelCore

private func fix(_ glossary: String, _ text: String) -> String {
    Glossary.parse(glossary).glossary.apply(text).text
}

struct GlossaryTests {
    @Test func termAloneFixesCasing() {
        #expect(fix("Kubernetes", "wir nutzen kubernetes heute") == "wir nutzen Kubernetes heute")
        #expect(fix("Kubernetes", "KUBERNETES") == "Kubernetes")
    }

    @Test func aliasIsReplaced() {
        #expect(fix("GitHub: Git Hub, git hab", "auf git hab und Git Hub") == "auf GitHub und GitHub")
    }

    @Test func multiWordAliasMatchesAnyWhitespace() {
        #expect(fix("Kubernetes: Kuber Netties", "Kuber   Netties und Kuber\n\tNetties") == "Kubernetes und Kubernetes")
        #expect(fix("Kubernetes: Kuber Netties", "KuberNetties") == "KuberNetties")
    }

    @Test func contextAliasLeavesLoneWord() {
        let g = "das DAM: das Damm"
        #expect(fix(g, "das Damm ist offen") == "das DAM ist offen")
        #expect(fix(g, "der Damm ist offen") == "der Damm ist offen")
    }

    @Test func wholeWordsOnly() {
        #expect(fix("Hub", "Hubert hat einen Hub") == "Hubert hat einen Hub")
        #expect(fix("GitHub: Git Hub", "Git Hubert") == "Git Hubert")
        #expect(fix("GitHub", "GitHubs und github2") == "GitHubs und github2")
        #expect(fix("GitHub: hub", "ein hub") == "ein GitHub")
    }

    @Test func punctuationIsKept() {
        #expect(fix("GitHub: Git Hub", "Git Hub, Git Hub. (Git Hub) „Git Hub“!") == "GitHub, GitHub. (GitHub) „GitHub“!")
    }

    @Test func matchIsCaseInsensitive() {
        #expect(fix("GitHub: git hub", "GIT HUB und Git hub") == "GitHub und GitHub")
    }

    @Test func umlautsAndEszettAreLetters() {
        #expect(fix("Bar: bar", "Bär bar Bärbel") == "Bär Bar Bärbel")
        #expect(fix("Maße: mase", "Maßes mase") == "Maßes Maße")
        #expect(fix("Ü: x", "äx x üx") == "äx Ü üx")
        #expect(fix("Müll: mull", "Müll mull") == "Müll Müll")  // diacritics matter
        #expect(fix("Straße", "STRASSE straße") == "STRASSE Straße")  // ß is not ss
    }

    @Test func longestAliasWins() {
        let g = "Git: git\nGitHub Actions: git hub\nGitHub: git hub actions"
        #expect(fix(g, "git hub actions") == "GitHub")
        #expect(fix(g, "git hub") == "GitHub Actions")
        #expect(fix("A: b\nC: b c", "b c") == "C")
    }

    @Test func replacedTextIsNotMatchedAgain() {
        #expect(fix("b: a\nc: b", "a") == "b")  // not rewritten on to "c"
        #expect(fix("b: a\nc: b", "a b") == "b c")
        #expect(fix("GitHub: Git Hub\nHub: GitHub", "Git Hub") == "GitHub")
    }

    @Test func commentsBlankLinesAndTrailingComments() {
        let g = "# comment\n\n  # indented\nGitHub: Git Hub # trailing\nC#: see sharp\nKubernetes   # fix casing\n"
        let (glossary, warnings) = Glossary.parse(g)
        #expect(warnings.isEmpty)
        #expect(glossary.count == 3)
        #expect(glossary.apply("git hub, see sharp, kubernetes").text == "GitHub, C#, Kubernetes")
    }

    @Test func badLinesAreSkippedWithLineNumbers() {
        let g = "GitHub: Git Hub\n: orphan\nTerm:\nOther: a,, b\nok"
        let (glossary, warnings) = Glossary.parse(g)
        #expect(warnings.count == 3)
        #expect(warnings[0].contains("line 2"))
        #expect(warnings[1].contains("line 3"))
        #expect(warnings[2].contains("line 4"))
        #expect(glossary.apply("Git Hub a b ok").text == "GitHub Other Other ok")
    }

    @Test func duplicateAliasFirstWins() {
        let (glossary, warnings) = Glossary.parse("One: x\nTwo: X")
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("line 2"))
        #expect(glossary.apply("x").text == "One")
    }

    @Test func emptyGlossaryAndCounts() {
        #expect(Glossary.empty.apply("hallo").text == "hallo")
        #expect(Glossary.parse("A: x\nB: x").glossary.apply("x x").replacements == 2)
    }

    @Test func templateParsesToNothing() {
        let (glossary, warnings) = Glossary.parse(Glossary.template)
        #expect(glossary.count == 0)
        #expect(warnings.isEmpty)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

struct GlossaryStageTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glossary-\(UUID().uuidString)")
            .appendingPathComponent("glossary.txt")
    }

    @Test func missingFileIsEmptyAndSilent() {
        let log = LogBox()
        let stage = GlossaryStage(url: tempFile(), log: log.add)
        #expect(stage.apply("git hub") == "git hub")
        #expect(log.all.isEmpty)
    }

    @Test func picksUpChangedFile() throws {
        let url = tempFile()
        try Glossary.createTemplateIfMissing(at: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = LogBox()
        let stage = GlossaryStage(url: url, log: log.add)
        #expect(stage.apply("git hub") == "git hub")
        try "GitHub: git hub\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(stage.apply("auf git hub") == "auf GitHub")
        try "GitLab: git hub\nKubernetes\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(stage.apply("auf git hub") == "auf GitLab")
        #expect(log.all.filter { $0.hasPrefix("Glossary: 1 entries from") }.count == 1)
        #expect(log.all.filter { $0.hasPrefix("Glossary: 2 entries from") }.count == 1)
        #expect(log.all.contains("Glossary: 1 replacements"))
        // no change, no reload
        let before = log.all.count
        _ = stage.apply("nichts")
        #expect(log.all.count == before)
    }

    @Test func deletedFileBecomesEmpty() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "GitHub: git hub".write(to: url, atomically: true, encoding: .utf8)
        let stage = GlossaryStage(url: url, log: { _ in })
        #expect(stage.apply("git hub") == "GitHub")
        try FileManager.default.removeItem(at: url)
        #expect(stage.apply("git hub") == "git hub")
    }

    @Test func standardPipelineAppliesGlossary() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "GitHub: git hub".write(to: url, atomically: true, encoding: .utf8)
        let paths = SabbelPaths(configDir: url.deletingLastPathComponent())
        let pipeline = TextPipeline.standard(settings: SabbelSettings(), paths: paths, log: { _ in })
        #expect(pipeline.process("git hub", target: nil) == "GitHub")
    }
}

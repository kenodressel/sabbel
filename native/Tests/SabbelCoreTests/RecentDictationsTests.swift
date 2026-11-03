import Foundation
import Testing
@testable import SabbelCore

private func entry(_ text: String, app: String? = nil) -> RecentDictation {
    RecentDictation(text: text, date: Date(timeIntervalSince1970: 0), appName: app)
}

@Suite struct RecentDictationsStoreTests {
    @Test func capsAtTheLimitNewestFirst() {
        var store = RecentDictations(limit: 3)
        for t in ["a", "b", "c", "d"] { store.append(entry(t)) }
        #expect(store.entries.map(\.text) == ["d", "c", "b"])
    }

    @Test func limitZeroKeepsNothing() {
        var store = RecentDictations(limit: 0)
        store.append(entry("a"))
        #expect(store.isEmpty)
    }

    @Test func clearEmpties() {
        var store = RecentDictations(limit: 3)
        store.append(entry("a"))
        store.clear()
        #expect(store.isEmpty)
    }

    @Test func titleIsOneLineAndCutWithAnEllipsis() {
        #expect(entry("one\ntwo  three").title() == "one two three")
        let long = String(repeating: "abcdefghi ", count: 10)
        let title = entry(long).title()
        #expect(title.hasSuffix("…") && title.count <= 51 && !title.contains("\n"))
        #expect(entry("short").title() == "short")
    }

    @Test func subtitleHasAppAndTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(entry("x", app: "Notes").subtitle(calendar: cal) == "Notes · 00:00")
        #expect(entry("x").subtitle(calendar: cal) == "00:00")
    }

    @Test func takeAudioDropsTheRestPastItsCapacity() {
        let audio = TakeAudio(capacity: 5)
        audio.append([1, 2, 3])
        audio.append([4, 5, 6, 7])
        audio.append([8])
        #expect(audio.samples == [1, 2, 3, 4, 5])
        #expect(TakeAudio.defaultCapacity == 9_600_000)
    }
}

@MainActor
@Suite struct RecentCoordinatorTests {
    private static func upper() -> TextPipeline { TextPipeline([{ text, _ in text.uppercased() }]) }

    @Test func deliveredTakeEntersRecentWithProcessedText() async {
        let h = Harness(pipeline: Self.upper())
        h.take()
        await h.coordinator.waitUntilIdle()
        let entries = h.coordinator.recent.entries
        #expect(entries.map(\.text) == ["HELLO"])
        #expect(entries.first?.appName == "Editor")
    }

    @Test func takeLeftInClipboardStillEnters() async {
        let h = Harness()
        h.env.frontmostPIDAnswer = { _, _ in 999 }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.notices == [.textCopiedFocusChanged])
        #expect(h.coordinator.recent.entries.map(\.text) == ["hello"])
    }

    @Test func recentLimitZeroKeepsNothing() async {
        var settings = SabbelSettings()
        settings.recentLimit = 0
        let h = Harness(settings: settings)
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.isEmpty)
        #expect(h.coordinator.retainedSampleCount == 0)
        #expect(!h.coordinator.canRetranscribe)
    }

    @Test func secureTakeIsNeverKept() async {
        let h = Harness(focus: FakeFocusProbe([(Harness.target, true)]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.isEmpty)
        #expect(h.coordinator.retainedSampleCount == 0)
        #expect(!h.coordinator.canRetranscribe)
    }

    @Test func refusedSecureAtPasteTimeIsNotKept() async {
        let h = Harness()
        h.env.frontmostPIDAnswer = { _, _ in 101 }
        h.env.focusedElementAnswer = { _, _ in
            FocusedElement(role: "AXTextField", subrole: "AXSecureTextField", hasSelectedTextRange: true,
                           valueSettable: true, selectedTextSettable: true)
        }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.notices == [.discardedSecure])
        #expect(h.coordinator.recent.isEmpty)
    }

    @Test func retainedAudioIsTheLastTakesAndCapped() async {
        let h = Harness(audioCapacity: 10_000)
        h.take(Harness.speech(0.75))
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.retainedSampleCount == 10_000)

        let big = Harness()
        big.take(Harness.speech(0.75))
        await big.coordinator.waitUntilIdle()
        #expect(big.coordinator.retainedSampleCount == 12_000)
        big.take(Harness.speech(1.0))
        await big.coordinator.waitUntilIdle()
        #expect(big.coordinator.retainedSampleCount == 16_000)
    }

    @Test func retainedAudioIsGoneAfterASecureTake() async {
        let h = Harness(focus: FakeFocusProbe([(Harness.target, false), (Harness.target, true)]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.canRetranscribe)
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.retainedSampleCount == 0)
    }

    @Test func failedRecognitionKeepsTheAudioForRetry() async {
        let failing = FakeRecognizer(script: [], mangle: .none, failingCalls: [0, 1, 2, 3])
        let h = Harness(recognizers: [failing, Harness.hello()], pipeline: Self.upper())
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.isEmpty)
        #expect(h.coordinator.canRetranscribe)

        h.coordinator.retranscribeLast()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.entries.map(\.text) == ["HELLO"])
        #expect(h.env.currentString == "HELLO")
        #expect(h.ui.notices.last == .copiedRecent)
        // Copied, not pasted.
        #expect(h.pasted.isEmpty && h.commandVTargets.isEmpty)
        // A normal copy: not the transient kind.
        #expect(h.env.items.first?.contains { $0.type == "org.nspasteboard.TransientType" } == false)
    }

    @Test func retranscriptionUsesTheOriginalTarget() async {
        let seen = LockedBox<[String?]>([])
        let pipeline = TextPipeline([{ text, target in
            seen.mutate { $0.append(target?.name) }
            return text
        }])
        let h = Harness(pipeline: pipeline)
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.retranscribeLast()
        await h.coordinator.waitUntilIdle()
        #expect(seen.value == ["Editor", "Editor"])
        #expect(h.coordinator.recent.entries.count == 2)
        #expect(h.coordinator.recent.entries.first?.appName == "Editor")
    }

    @Test func emptyRetranscriptionShowsNotRecognized() async {
        let h = Harness(recognizers: [Harness.hello(), FakeRecognizer(script: [], mangle: .none)])
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.retranscribeLast()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.shows.contains { $0.icon == .error("Not recognized") })
        #expect(h.coordinator.recent.entries.count == 1)
    }

    @Test func retranscriptionIsRefusedWhileATakeRuns() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.handle(.start)
        #expect(!h.coordinator.canRetranscribe)
        h.coordinator.retranscribeLast()
        h.coordinator.handle(.cancel(.combo))
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.entries.count == 1)
    }

    @Test func retranscriptionIsRefusedWhileAnotherRuns() async {
        let h = Harness(recognizers: [Harness.hello(), Harness.hello(delay: 0.1)])
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.retranscribeLast()
        #expect(!h.coordinator.canRetranscribe)
        h.coordinator.retranscribeLast()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.recent.entries.count == 2)
    }

    @Test func pasteLastPastesTheNewestThroughTheInjector() async {
        let h = Harness(pipeline: Self.upper())
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.pasteLastDictation()
        #expect(await eventually { h.pasted.count == 2 })
        #expect(h.pasted == ["HELLO", "HELLO"])
        #expect(h.commandVTargets.last == .some(nil))
        // Pasting again does not add an entry.
        #expect(h.coordinator.recent.entries.count == 1)
    }

    @Test func pasteLastWithNothingDoesNothing() async {
        let h = Harness()
        h.coordinator.pasteLastDictation()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.env.calls.isEmpty)
    }

    @Test func copyRecentCopiesAndNotifies() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        h.env.userCopies("other")
        h.coordinator.copyRecent(id: h.coordinator.recent.entries[0].id)
        #expect(h.env.currentString == "hello")
        #expect(h.ui.notices == [.copiedRecent])
    }

    @Test func clearRecentForgetsEntriesAndAudio() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        h.coordinator.clearRecent()
        #expect(h.coordinator.recent.isEmpty)
        #expect(!h.coordinator.canRetranscribe)
    }
}

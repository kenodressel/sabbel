import Foundation
import os
import Testing
@testable import SabbelCore

@Suite struct E2ERulesTests {
    @Test func runsDefaultsToThreeAndNeverGoesBelow() {
        #expect(E2ERules.runs(environment: [:]) == 3)
        #expect(E2ERules.runs(environment: ["RUNS": "5"]) == 5)
        // Takes 2 and 3 carry the live-panel and focus-loss scenarios.
        #expect(E2ERules.runs(environment: ["RUNS": "1"]) == 3)
        #expect(E2ERules.runs(environment: ["RUNS": "many"]) == 3)
    }

    @Test func secondTakeShowsThePanelThirdLosesFocus() {
        #expect(E2ERules.kind(ofTake: 0) == .plain)
        #expect(E2ERules.kind(ofTake: 1) == .livePanel)
        #expect(E2ERules.kind(ofTake: 2) == .focusLost)
        #expect(E2ERules.kind(ofTake: 3) == .plain)
    }

    @Test func wordsAreLowercasedWithoutPunctuation() {
        #expect(E2ERules.words("Hello, World! Is this a test?") == ["hello", "world", "is", "this", "a", "test"])
        #expect(E2ERules.expectedWords.isSubset(of: E2ERules.words(E2ERules.phrase)))
        #expect(E2ERules.words("") == [])
    }

    @Test func longestGapOnlyCountsTicksInsideTheWindow() {
        let ticks: [TimeInterval] = [0, 0.05, 0.1, 0.4, 0.45, 2.0]
        #expect(abs(E2ERules.longestGapMS(ticks, from: 0, to: 0.45) - 300) < 1e-6)
        #expect(abs(E2ERules.longestGapMS(ticks, from: 0.4, to: 1.0) - 50) < 1e-6)
        #expect(E2ERules.longestGapMS(ticks, from: 0.5, to: 1.0) == .infinity)
        #expect(E2ERules.longestGapMS([], from: 0, to: 1) == .infinity)
    }

    @Test func anotherAppTakingFocusIsRetried() {
        #expect(E2ERules.isInterruption(kind: .plain, outcome: .focusChanged, frontmostPID: 7,
                                        targetPID: 3, ownPID: 5, interruptions: 0))
        #expect(E2ERules.isInterruption(kind: .livePanel, outcome: .focusChanged, frontmostPID: nil,
                                        targetPID: 3, ownPID: 5, interruptions: 2))
    }

    @Test func notAnInterruption() {
        // The focus-loss take loses focus on purpose: its outcome is the result, never retried.
        #expect(!E2ERules.isInterruption(kind: .focusLost, outcome: .focusChanged, frontmostPID: 7,
                                         targetPID: 3, ownPID: 5, interruptions: 0))
        // Sabbel in front (its live panel took focus) is Sabbel's doing: a failure, not a retry.
        #expect(!E2ERules.isInterruption(kind: .livePanel, outcome: .focusChanged, frontmostPID: 5,
                                         targetPID: 3, ownPID: 5, interruptions: 0))
        #expect(!E2ERules.isInterruption(kind: .plain, outcome: .focusChanged, frontmostPID: 3,
                                         targetPID: 3, ownPID: 5, interruptions: 0))
        #expect(!E2ERules.isInterruption(kind: .plain, outcome: .focusChanged, frontmostPID: 7,
                                         targetPID: 3, ownPID: 5, interruptions: E2ERules.maxInterruptions))
        #expect(!E2ERules.isInterruption(kind: .plain, outcome: .pasted, frontmostPID: 7,
                                         targetPID: 3, ownPID: 5, interruptions: 0))
        #expect(!E2ERules.isInterruption(kind: .plain, outcome: nil, frontmostPID: 7,
                                         targetPID: 3, ownPID: 5, interruptions: 0))
    }

    @Test func clipboardIsRestoredOnlyOverOurOwnWrites() {
        #expect(E2ERules.shouldRestoreClipboard(current: nil, written: []))
        #expect(E2ERules.shouldRestoreClipboard(current: E2ERules.sentinel, written: []))
        #expect(E2ERules.shouldRestoreClipboard(current: "hello world", written: ["hi", "hello world"]))
        // A copy made during the run: clobbering it would lose it.
        #expect(!E2ERules.shouldRestoreClipboard(current: "the user's copy", written: ["hello world"]))
    }

    @Test func finishLatencyBound() {
        #expect(E2ERules.finishLatencyOK(ms: 500))
        #expect(!E2ERules.finishLatencyOK(ms: 500.1))
    }
}

@Suite struct E2EChecksTests {
    @Test func printsPassAndFailLinesLikeE2EPy() {
        var checks = E2EChecks(output: { _ in })
        #expect(checks.check(true, "pasted") == "  PASS  pasted")
        #expect(checks.check(false, "clipboard restored", "'x'") == "  FAIL  clipboard restored — 'x'")
        #expect(checks.failures == ["clipboard restored"])
    }

    @Test func summaryAndExitCode() {
        var checks = E2EChecks(output: { _ in })
        #expect(checks.summary == "\nPASSED: 0 failed check(s)")
        #expect(checks.exitCode == 0)
        checks.check(false, "a")
        checks.check(true, "b")
        checks.check(false, "c", "detail")
        #expect(checks.summary == "\nFAILED: 2 failed check(s) — ['a', 'c']")
        #expect(checks.exitCode == 1)
    }

    @Test func everyLineGoesToTheOutput() {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        var checks = E2EChecks(output: { line in lines.withLock { $0.append(line) } })
        checks.check(true, "one")
        checks.check(false, "two")
        #expect(lines.withLock { $0 } == ["  PASS  one", "  FAIL  two"])
    }
}

@Suite struct RecordingPasteEnvironmentTests {
    private static let target = FocusTarget(pid: 42, name: "TextEdit")

    /// A fake whose frontmost app can be switched while a paste runs.
    private func fake() -> (FakePasteEnvironment, OSAllocatedUnfairLock<Int32>) {
        let front = OSAllocatedUnfairLock(initialState: Int32(42))
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in front.withLock { $0 } }
        return (env, front)
    }

    @Test func recordsWritesAndTheCommandV() {
        let (base, _) = fake()
        let env = RecordingPasteEnvironment(base: base)
        env.beginTake(stealFocus: nil)
        let outcome = Injector(env: env).inject("hello world", target: Self.target)
        let record = env.record()
        #expect(outcome == .pasted)
        #expect(record.writes == ["hello world"])
        #expect(record.writesOnMainThread == [Thread.isMainThread])
        #expect(record.commandV.count == 1)
        #expect(record.commandV.first?.frontmostPID == 42)
        #expect(record.lastFrontmostPID == 42)
        #expect(!record.stoleFocus)
    }

    @Test func stealsFocusOnTheFirstModifierCheckOnly() {
        let (base, front) = fake()
        // Held for two polls, so the thief would fire again if it were not one-shot.
        base.modifiersHeldAnswer = { n, _ in n < 2 }
        let env = RecordingPasteEnvironment(base: base)
        let steals = OSAllocatedUnfairLock(initialState: 0)
        env.beginTake(stealFocus: {
            steals.withLock { $0 += 1 }
            front.withLock { $0 = 99 }
        })
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let injector = Injector(env: env, log: { line in lines.withLock { $0.append(line) } })
        let outcome = injector.inject("hello world", target: Self.target)
        let record = env.record()

        #expect(outcome == .focusChanged)
        #expect(steals.withLock { $0 } == 1)
        #expect(record.stoleFocus)
        #expect(record.commandV.isEmpty)
        #expect(record.lastFrontmostPID == 99)
        // The second focus check caught it, and the text stayed in the clipboard.
        #expect(lines.withLock { $0 }.contains { $0.hasPrefix("Focus lost right before Cmd+V") })
        #expect(base.currentString == "hello world")
        #expect(!base.didCall { $0 == .restoreClipboard })
    }

    @Test func beginTakeResetsTheTakeButKeepsEveryWrite() {
        let (base, _) = fake()
        let env = RecordingPasteEnvironment(base: base)
        env.beginTake(stealFocus: nil)
        _ = Injector(env: env).inject("first", target: Self.target)
        env.beginTake(stealFocus: nil)
        #expect(env.record().writes.isEmpty)
        #expect(env.record().commandV.isEmpty)
        _ = Injector(env: env).inject("second", target: Self.target)
        #expect(env.record().writes == ["second"])
        #expect(env.allWrites == ["first", "second"])
    }

    @Test func forwardsTheClipboardUntouched() {
        let (base, _) = fake()
        let env = RecordingPasteEnvironment(base: base)
        let snapshot = env.captureClipboard()
        _ = base.writeTransient(E2ERules.sentinel)
        #expect(env.clipboardString() == E2ERules.sentinel)
        env.restoreClipboard(snapshot)
        #expect(base.currentString == "old clip")
        // Only the injector's writes through the wrapper count as its own.
        #expect(env.allWrites.isEmpty)
    }
}

@Suite struct FedAudioSourceTests {
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func feedsEverySampleInMicSizedChunksPacedLikeAMic() async throws {
        let samples = (0..<4_000).map { Float($0) }
        let source = FedAudioSource(samples: samples)
        let got = OSAllocatedUnfairLock(initialState: [[Float]]())
        let started = Date()
        #expect(try source.start(device: "ignored") { chunk in got.withLock { $0.append(chunk) } } == nil)
        #expect(!source.fed)
        try await waitFor(5) { source.fed }
        let elapsed = Date().timeIntervalSince(started)
        let chunks = got.withLock { $0 }
        #expect(source.fed)
        #expect(chunks.map(\.count) == [1_600, 1_600, 800])
        #expect(chunks.flatMap { $0 } == samples)
        // Three chunks of 0.1 s each, delivered once "recorded".
        #expect(elapsed >= 0.29)
    }

    @Test func stopEndsTheFeed() async throws {
        let source = FedAudioSource(samples: [Float](repeating: 0.1, count: 16_000 * 5))
        let count = OSAllocatedUnfairLock(initialState: 0)
        _ = try source.start(device: nil) { _ in count.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(250))
        source.stop()
        let atStop = count.withLock { $0 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(atStop >= 1)
        #expect(count.withLock { $0 } == atStop)
        #expect(!source.fed)
    }

    @Test func aRestartFeedsFromTheBeginning() async throws {
        let source = FedAudioSource(samples: [Float](repeating: 0.1, count: 1_600))
        let count = OSAllocatedUnfairLock(initialState: 0)
        for _ in 0..<2 {
            _ = try source.start(device: nil) { _ in count.withLock { $0 += 1 } }
            try await waitFor(5) { source.fed }
            source.stop()
        }
        #expect(count.withLock { $0 } == 2)
    }
}

@Suite struct E2EFixRoundTests {
    @Test func automationDenialFailsFastNamingTheSetting() {
        #expect(E2ERules.automationProblem(app: "Finder", status: 0, stderr: "") == nil)
        let denied = E2ERules.automationProblem(
            app: "Finder", status: 1,
            stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)")
        #expect(denied?.contains("Finder") == true)
        #expect(denied?.contains("System Settings → Privacy & Security → Automation") == true)
        let other = E2ERules.automationProblem(app: "TextEdit", status: 1, stderr: "execution error: boom (-600)")
        #expect(other?.contains("TextEdit") == true)
        #expect(other?.contains("boom (-600)") == true)
        #expect(other?.contains("Automation") == false)
    }

    @Test func aStaleIdleSignalCannotEndTheNextTake() {
        var token = E2ETakeToken()
        let first = token.begin()
        #expect(!token.isIdle)
        let second = token.begin()  // the first take timed out
        token.finished(first)       // its leftover waiter fires late
        #expect(!token.isIdle)
        token.finished(second)
        #expect(token.isIdle)
    }

    @Test func disarmedEnvironmentTouchesNothing() {
        let base = FakePasteEnvironment()
        base.frontmostPIDAnswer = { _, _ in 42 }
        let env = RecordingPasteEnvironment(base: base)
        env.beginTake(stealFocus: { Issue.record("the thief must not run once disarmed") })
        env.disarm()
        _ = Injector(env: env).inject("late text", target: FocusTarget(pid: 42, name: "TextEdit"))
        #expect(!base.postedCommandV)
        #expect(!base.didCall { if case .writeTransient = $0 { return true } else { return false } })
        #expect(!base.didCall { $0 == .restoreClipboard })
        #expect(base.currentString == "old clip")
        #expect(env.record().commandV.isEmpty)
        // A take begun after teardown stays disarmed.
        env.beginTake(stealFocus: nil)
        _ = Injector(env: env).inject("later", target: nil)
        #expect(!base.postedCommandV)
    }
}

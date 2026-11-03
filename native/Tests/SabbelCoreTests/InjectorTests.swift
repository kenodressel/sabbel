import Foundation
import Testing
@testable import SabbelCore

/// Port of tests/test_injector.py, plus the second focus check right before Cmd+V.
///
/// Everything AppKit/AX/Quartz touches is behind `PasteEnvironment`; these cover
/// the decision logic and the clipboard save/restore contract, which is where the
/// bugs were. The pasteboard (de)serialisation tests of the Python suite
/// (`_capture_pasteboard` / `_restore_pasteboard`) belong to the AppKit adapter.
@Suite struct InjectorTests {
    static let textField = FocusedElement(role: "AXTextField", subrole: nil, hasSelectedTextRange: true,
                                          valueSettable: true, selectedTextSettable: true)
    static let notes = FocusTarget(pid: 42, name: "Notes")

    /// An environment where Notes (pid 42) is frontmost with a text field focused.
    private func notesEnv() -> FakePasteEnvironment {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 42 }
        env.focusedElementAnswer = { _, _ in Self.textField }
        return env
    }

    private func isCommandV(_ c: FakePasteEnvironment.Call) -> Bool {
        if case .postCommandV = c { return true } else { return false }
    }

    private func isRestore(_ c: FakePasteEnvironment.Call) -> Bool { c == .restoreClipboard }

    // MARK: focus target

    @Test func focusTargetActiveWhenPidMatches() {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 42 }
        #expect(Injector(env: env).focusTargetIsActive(Self.notes))
    }

    @Test func focusTargetInactiveWhenPidDiffers() {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 99 }
        #expect(!Injector(env: env).focusTargetIsActive(Self.notes))
    }

    /// No captured target must not block pasting.
    @Test func focusTargetOptimisticWithoutTarget() {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 99 }
        #expect(Injector(env: env).focusTargetIsActive(nil))
    }

    @Test func focusTargetOptimisticWhenPidUnreadable() {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in nil }
        #expect(Injector(env: env).focusTargetIsActive(Self.notes))
    }

    @Test func targetGoneBeforePasteLeavesTextInClipboard() {
        let env = notesEnv()
        env.frontmostPIDAnswer = { _, _ in 99 }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .focusChanged)
        #expect(env.count(.writeTransient("hallo")) == 1)
        #expect(env.currentString == "hallo")
        #expect(!env.postedCommandV)
        #expect(!env.didCall(isRestore))
        #expect(!env.didCall { $0 == .focusedElement })
    }

    // MARK: secure fields

    @Test func refusesSecureField() {
        let env = notesEnv()
        env.focusedElementAnswer = { _, _ in
            FocusedElement(role: "AXTextField", subrole: "AXSecureTextField", hasSelectedTextRange: true,
                           valueSettable: true, selectedTextSettable: true)
        }
        let countBefore = env.changeCount

        let result = Injector(env: env).inject("hunter2", target: Self.notes)

        #expect(result == .refusedSecure)
        // Crucially, nothing is written to the clipboard either.
        #expect(!env.didCall { if case .writeTransient = $0 { return true } else { return false } })
        #expect(!env.didCall { $0 == .captureClipboard })
        #expect(!env.postedCommandV)
        #expect(env.changeCount == countBefore)
        #expect(env.currentString == "old clip")
    }

    @Test(arguments: [
        ("AXSecureTextField", true), ("AXTextField", false), (nil, false), ("AXSECURETEXTFIELD", true),
    ] as [(String?, Bool)])
    func isSecureReadsSubrole(subrole: String?, expected: Bool) {
        let element = FocusedElement(role: "AXTextField", subrole: subrole, hasSelectedTextRange: true,
                                     valueSettable: true, selectedTextSettable: true)
        #expect(Injector.isSecure(element) == expected)
    }

    @Test func unreadableElementIsNotSecure() {
        #expect(!Injector.isSecure(nil))
    }

    // MARK: text-field detection

    @Test func nonTextFieldLeavesTextInClipboard() {
        let env = notesEnv()
        env.focusedElementAnswer = { _, _ in
            FocusedElement(role: "AXImage", subrole: nil, hasSelectedTextRange: false,
                           valueSettable: false, selectedTextSettable: false)
        }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .leftInClipboard)
        #expect(!env.didCall(isRestore))
        #expect(env.currentString == "hallo")
    }

    @Test func canAcceptPasteDecisions() {
        func el(_ role: String?, range: Bool = false, value: Bool = false, selected: Bool = false) -> FocusedElement {
            FocusedElement(role: role, subrole: nil, hasSelectedTextRange: range,
                           valueSettable: value, selectedTextSettable: selected)
        }
        // Can't read the focused element (Electron apps, etc.): optimistic.
        #expect(Injector.canAcceptPaste(nil))
        // Each positive signal beats a non-text role.
        #expect(Injector.canAcceptPaste(el("AXGroup", range: true)))
        #expect(Injector.canAcceptPaste(el("AXGroup", value: true)))
        #expect(Injector.canAcceptPaste(el("AXGroup", selected: true)))
        for role in ["AXWebArea", "AXImage", "AXGroup", "AXToolbar", "AXMenuBar",
                     "AXScrollArea", "AXSplitGroup", "AXTable", "AXOutline"] {
            #expect(!Injector.canAcceptPaste(el(role)), "\(role)")
        }
        // Unknown situation: optimistic.
        #expect(Injector.canAcceptPaste(el("AXButton")))
        #expect(Injector.canAcceptPaste(el(nil)))
    }

    // MARK: unreadable focus (Electron, terminals)

    /// Electron/terminals expose no AXValue — polling them would stall every paste.
    ///
    /// Regression guard: an earlier version polled for the full verify_timeout on
    /// every dictation into Slack or VS Code, turning a 150ms paste into 2s.
    @Test func unreadableFocusPastesOptimisticallyWithFixedDelay() throws {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 42 }
        env.focusedElementAnswer = { _, _ in nil }
        env.focusedValueAnswer = { _, _ in nil }

        let result = Injector(env: env, verifyTimeout: 5.0).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(env.count(.focusedValue) == 1)  // read once before, never polled
        let pasted = try #require(env.time(of: isCommandV))
        let restored = try #require(env.time(of: isRestore))
        #expect(abs(pasted - 0.05) < 1e-9)
        #expect(abs(restored - pasted - 0.15) < 1e-9)
        #expect(env.currentString == "old clip")
    }

    // MARK: modifier release

    @Test func waitForModifiersReturnsImmediatelyWhenClear() {
        let env = FakePasteEnvironment()
        env.modifiersHeldAnswer = { _, _ in false }
        #expect(Injector(env: env).waitForModifiersReleased(timeout: 1.0))
        #expect(env.clock == 0)
    }

    /// Right Option still down must not turn Cmd+V into Cmd+Opt+V.
    @Test func waitForModifiersTimesOutWhenHeld() {
        let env = FakePasteEnvironment()
        env.modifiersHeldAnswer = { _, _ in true }
        #expect(!Injector(env: env).waitForModifiersReleased(timeout: 0.05, poll: 0.01))
        #expect(env.clock >= 0.05 - 1e-9)
    }

    @Test func waitForModifiersClearsMidWait() {
        let env = FakePasteEnvironment()
        env.modifiersHeldAnswer = { n, _ in n == 0 }
        #expect(Injector(env: env).waitForModifiersReleased(timeout: 1.0, poll: 0.001))
    }

    @Test func commandVWaitsForHeldModifiers() throws {
        let env = notesEnv()
        env.modifiersHeldAnswer = { _, t in t < 0.3 }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        let pasted = try #require(env.time(of: isCommandV))
        #expect(pasted >= 0.3)
        #expect(pasted < 2.0)
        // The clipboard is touched only once the modifiers are up.
        let captured = try #require(env.time(of: { $0 == .captureClipboard }))
        #expect(captured >= 0.3)
    }

    @Test func modifiersHeldPastTimeoutPastesAnyway() throws {
        let env = notesEnv()
        env.modifiersHeldAnswer = { _, _ in true }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        let pasted = try #require(env.time(of: isCommandV))
        #expect(pasted >= 2.0)
    }

    // MARK: paste confirmation and restore

    @Test func restoresSnapshotAfterPaste() throws {
        let original: [[String: Data]] = [
            ["public.png": Data("img".utf8), FakePasteEnvironment.stringType: Data("txt".utf8)],
            ["public.rtf": Data("rtf".utf8)],
        ]
        let env = FakePasteEnvironment(clipboard: original)
        env.frontmostPIDAnswer = { _, _ in 42 }
        env.focusedElementAnswer = { _, _ in Self.textField }
        env.focusedValueAnswer = { n, _ in n == 0 ? "" : "hallo" }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(env.count(.restoreClipboard) == 1)
        #expect(env.items == original)
        let pasted = try #require(env.index(of: isCommandV))
        let restored = try #require(env.index(of: isRestore))
        #expect(restored > pasted)
    }

    /// A readable field must be waited on rather than restored after 150ms.
    @Test func readableFieldPollsUntilPasteLands() throws {
        let env = notesEnv()
        // Read 0 is the "before" value; polls 1 and 2 see nothing yet, poll 3 sees the paste.
        env.focusedValueAnswer = { n, _ in n < 3 ? "vorher" : "vorher hallo" }

        let result = Injector(env: env, verifyTimeout: 5.0).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(env.count(.focusedValue) == 4)
        #expect(env.count(.restoreClipboard) == 1)
    }

    @Test func fieldContainingTextRestoresBeforeVerifyTimeout() throws {
        let env = notesEnv()
        env.focusedValueAnswer = { _, t in t < 0.2 ? "vorher" : "vorher hallo" }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        let pasted = try #require(env.time(of: isCommandV))
        let restored = try #require(env.time(of: isRestore))
        #expect(restored >= 0.2)
        #expect(restored - pasted < 1.0)
        #expect(env.currentString == "old clip")
    }

    /// The regression: pasting into iTerm2 worked, but Sabbel reported "no text
    /// field detected", left the transcript in the clipboard and burned 2s doing it.
    @Test func unobservedPasteStillRestoresTheClipboard() throws {
        let env = notesEnv()
        env.focusedValueAnswer = { _, _ in "lesbar" }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        let pasted = try #require(env.time(of: isCommandV))
        let restored = try #require(env.time(of: isRestore))
        #expect(restored - pasted >= 1.0 - 1e-9)
        #expect(restored - pasted < 1.1)
        #expect(env.count(.restoreClipboard) == 1)
        #expect(env.currentString == "old clip")
    }

    // MARK: someone else touched the clipboard

    @Test func skipsRestoreWhenUserCopiedDuringPaste() {
        let env = notesEnv()
        env.focusedValueAnswer = { n, _ in n == 0 ? "" : "hallo" }
        env.onCall = { call, env in
            if case .postCommandV = call { env.userCopies("something the user copied") }
        }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(!env.didCall(isRestore))
        #expect(env.currentString == "something the user copied")
    }

    /// A moved change count alone is not someone else's copy: if the clipboard still
    /// holds our text (e.g. rewritten by the target app), restore as usual.
    @Test func restoresWhenChangeCountMovedButTextIsOurs() {
        let env = notesEnv()
        env.focusedValueAnswer = { n, _ in n == 0 ? "" : "hallo" }
        env.onCall = { call, env in
            if case .postCommandV = call { env.userCopies("hallo") }
        }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(env.count(.restoreClipboard) == 1)
        #expect(env.currentString == "old clip")
    }

    // MARK: Cmd+V destination

    /// Cmd+V goes to the app that was focused when recording started.
    @Test func commandVGoesToTheTarget() {
        let env = notesEnv()
        env.frontmostPIDAnswer = { _, _ in 4242 }

        _ = Injector(env: env).inject("hallo", target: FocusTarget(pid: 4242, name: "Notes"))

        #expect(env.count(.postCommandV(4242)) == 1)
    }

    @Test func commandVWithoutTargetGoesSessionWide() {
        let env = notesEnv()

        _ = Injector(env: env).inject("hallo", target: nil)

        #expect(env.count(.postCommandV(nil)) == 1)
    }

    // MARK: order of operations

    @Test func orderOfOperations() throws {
        let env = FakePasteEnvironment()
        env.frontmostPIDAnswer = { _, _ in 42 }
        env.focusedElementAnswer = { _, _ in Self.textField }
        env.focusedValueAnswer = { _, _ in nil }

        _ = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(env.actions == [
            .frontmostPID, .focusedElement, .modifiersHeld, .captureClipboard, .focusedValue,
            .writeTransient("hallo"), .frontmostPID, .postCommandV(42), .clipboardChangeCount, .restoreClipboard,
        ])
        // The second focus check sits after the pre-paste delay, right before Cmd+V.
        let calls = env.calls
        let commandV = try #require(calls.firstIndex(where: isCommandV))
        #expect(calls[commandV - 1] == .frontmostPID)
        #expect(calls[commandV - 2] == .sleep(0.05))
        #expect(calls[commandV - 3] == .writeTransient("hallo"))
    }

    // MARK: second focus check, right before Cmd+V

    @Test func focusLostRightBeforeCommandV() {
        let env = notesEnv()
        // Frontmost at the start, gone while the user's hand is still leaving the keys.
        env.frontmostPIDAnswer = { _, t in t < 0.2 ? 42 : 99 }
        env.modifiersHeldAnswer = { _, t in t < 0.3 }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .focusChanged)
        #expect(!env.postedCommandV)
        #expect(!env.didCall(isRestore))
        #expect(env.currentString == "hallo")
    }

    @Test func focusLostDuringPrePasteDelay() {
        let env = notesEnv()
        env.frontmostPIDAnswer = { _, t in t < 0.05 ? 42 : 99 }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .focusChanged)
        #expect(!env.postedCommandV)
        #expect(!env.didCall(isRestore))
        #expect(env.currentString == "hallo")
    }

    @Test func secondCheckOptimisticWhenPidUnreadable() {
        let env = notesEnv()
        env.frontmostPIDAnswer = { n, _ in n == 0 ? 42 : nil }

        let result = Injector(env: env).inject("hallo", target: Self.notes)

        #expect(result == .pasted)
        #expect(env.count(.postCommandV(42)) == 1)
    }

    @Test func secondCheckOptimisticWithoutTarget() {
        let env = notesEnv()
        env.frontmostPIDAnswer = { n, _ in n == 0 ? 42 : 99 }

        let result = Injector(env: env).inject("hallo", target: nil)

        #expect(result == .pasted)
        #expect(env.count(.postCommandV(nil)) == 1)
    }

    // MARK: paste observation is a timing signal, not a verdict

    /// iTerm2 exposes the terminal grid with NUL bytes between cells.
    @Test func itermGridValueStillMatches() {
        let env = FakePasteEnvironment()
        env.focusedValueAnswer = { _, _ in "\u{0}\u{0}\u{0}Im\u{0}Sprint\u{0}Planning\u{0}haben\u{0}wir\u{0}\u{0}\u{0}" }
        #expect(Injector(env: env).pasteObserved(before: "vorher", expected: "Im Sprint Planning haben wir"))
    }

    /// Terminals hard-wrap, injecting line breaks into the readback.
    @Test func wrappedTextStillMatches() {
        let env = FakePasteEnvironment()
        env.focusedValueAnswer = { _, _ in "Im Sprint Planning\nhaben wir die\nDeployments besprochen" }
        #expect(Injector(env: env).pasteObserved(
            before: "vorher", expected: "Im Sprint Planning haben wir die Deployments besprochen"))
    }

    /// The signal only decides when to restore the clipboard, so a field that
    /// merely changed is enough — no AX readback is reliable enough for a verdict.
    @Test func anyChangeCountsAsObserved() {
        let env = FakePasteEnvironment()
        env.focusedValueAnswer = { _, _ in "etwas anderes" }
        #expect(Injector(env: env).pasteObserved(before: "vorher", expected: "unauffindbar"))
    }

    @Test func unchangedFieldIsNotObserved() {
        let env = FakePasteEnvironment()
        env.focusedValueAnswer = { _, _ in "vorher" }
        #expect(!Injector(env: env).pasteObserved(before: "vorher", expected: "unauffindbar"))
    }

    @Test func unreadableFieldIsNotObserved() {
        let env = FakePasteEnvironment()
        env.focusedValueAnswer = { _, _ in nil }
        #expect(!Injector(env: env).pasteObserved(before: "vorher", expected: "hallo"))
    }

    @Test func normalizeForMatch() {
        #expect(Injector.normalizeForMatch("Hallo\u{0}Welt\n x") == "Hallo Welt x")
        #expect(Injector.normalizeForMatch("  a\t\tb\r\nc  ") == "a b c")
        #expect(Injector.normalizeForMatch("") == "")
    }
}

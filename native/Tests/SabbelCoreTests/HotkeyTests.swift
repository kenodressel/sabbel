import Testing
@testable import SabbelCore

@Suite struct HotkeyTests {
    private func run(_ steps: [(KeyInput, Double)]) -> [HotkeyAction?] {
        var m = HotkeyStateMachine()
        return steps.map { m.handle($0.0, at: $0.1) }
    }

    @Test func pressStartsReleaseStops() {
        #expect(run([(.hotkeyDown, 0), (.hotkeyUp, 2)]) == [.start, .stop])
    }

    @Test func shortComboIsCancelledQuietly() {
        #expect(run([(.hotkeyDown, 0), (.otherKeyDown, 0.1), (.hotkeyUp, 0.3)])
                == [.start, nil, .cancel(.combo)])
    }

    @Test func longHoldWithStrayKeyIsDictation() {
        #expect(run([(.hotkeyDown, 0), (.otherKeyDown, 0.05), (.hotkeyUp, 12)])
                == [.start, nil, .stop])
    }

    @Test func escapeCancelsAtAnyLength() {
        #expect(run([(.hotkeyDown, 0), (.escapeDown, 30), (.hotkeyUp, 31)])
                == [.start, .cancel(.escape), nil])
    }

    @Test func escapeWhileIdleIsIgnored() {
        #expect(run([(.escapeDown, 0)]) == [nil])
    }

    @Test func autoRepeatDownIsIgnored() {
        #expect(run([(.hotkeyDown, 0), (.hotkeyDown, 0.5)]) == [.start, nil])
    }

    @Test func releaseWithoutPressIsIgnored() {
        #expect(run([(.hotkeyUp, 0)]) == [nil])
    }

    @Test func parsesNames() {
        #expect(HotkeySpec.parse("alt_r") == HotkeySpec(keyCode: 61, isModifier: true))
        #expect(HotkeySpec.parse("alt") == HotkeySpec(keyCode: 58, isModifier: true))
        #expect(HotkeySpec.parse("alt_l") == HotkeySpec(keyCode: 58, isModifier: true))
        for (n, c) in [("cmd_r", 54), ("cmd", 55), ("ctrl", 59), ("ctrl_r", 62),
                       ("shift", 56), ("shift_r", 60), ("caps_lock", 57)] as [(String, UInt16)] {
            #expect(HotkeySpec.parse(n) == HotkeySpec(keyCode: c, isModifier: true))
        }
        #expect(HotkeySpec.parse("f5") == HotkeySpec(keyCode: 96, isModifier: false))
        #expect(HotkeySpec.parse("f13") == HotkeySpec(keyCode: 105, isModifier: false))
        #expect(HotkeySpec.parse("space") == HotkeySpec(keyCode: 49, isModifier: false))
        #expect(HotkeySpec.parse("a") == HotkeySpec(keyCode: 0, isModifier: false))
        #expect(HotkeySpec.parse("esc") == nil)
        #expect(HotkeySpec.parse("") == nil)
        #expect(HotkeySpec.parse("bogus") == nil)
        #expect(HotkeySpec.default == HotkeySpec.parse("alt_r"))
    }
}

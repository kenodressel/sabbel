import CoreGraphics
import Testing
import SabbelCore
@testable import SabbelSystem

@Suite struct HotkeyMappingTests {
    let alt = HotkeySpec.parse("alt_r")!
    let f5 = HotkeySpec.parse("f5")!

    private func map(_ type: CGEventType, _ code: UInt16, _ flags: CGEventFlags = [], synthetic: Bool = false,
                     spec: HotkeySpec, down: inout Bool) -> KeyInput? {
        HotkeyEventMapper.map(type: type, keyCode: code, flags: flags, isSynthetic: synthetic, spec: spec, hotkeyIsDown: &down)
    }

    @Test func modifierToggles() {
        var down = false
        #expect(map(.flagsChanged, 61, .maskAlternate, spec: alt, down: &down) == .hotkeyDown)
        #expect(down)
        #expect(map(.flagsChanged, 61, [], spec: alt, down: &down) == .hotkeyUp)
        #expect(!down)
    }

    @Test func otherModifierKeycodeIgnored() {
        var down = false
        #expect(map(.flagsChanged, 58, .maskAlternate, spec: alt, down: &down) == nil)
        #expect(!down)
    }

    @Test func plainKeyDownUp() {
        var down = false
        #expect(map(.keyDown, 96, spec: f5, down: &down) == .hotkeyDown)
        #expect(map(.keyUp, 96, spec: f5, down: &down) == .hotkeyUp)
    }

    @Test func escapeAndOther() {
        var down = false
        #expect(map(.keyDown, 53, spec: alt, down: &down) == .escapeDown)
        #expect(map(.keyDown, 0, spec: alt, down: &down) == .otherKeyDown)
    }

    @Test func syntheticIgnored() {
        var down = false
        #expect(map(.flagsChanged, 61, .maskAlternate, synthetic: true, spec: alt, down: &down) == nil)
        #expect(map(.keyDown, 0, synthetic: true, spec: alt, down: &down) == nil)
    }

    @Test func keyUpOfOtherKeyIgnored() {
        var down = false
        #expect(map(.keyUp, 0, spec: alt, down: &down) == nil)
        #expect(map(.keyUp, 0, spec: f5, down: &down) == nil)
    }

    @Test func flagForKeycode() {
        var down = false
        let cmdR = HotkeySpec.parse("cmd_r")!
        #expect(map(.flagsChanged, 54, .maskCommand, spec: cmdR, down: &down) == .hotkeyDown)
        // A different modifier flag alone does not count as down.
        var d2 = false
        #expect(map(.flagsChanged, 54, .maskAlternate, spec: cmdR, down: &d2) == .hotkeyUp)
    }
}

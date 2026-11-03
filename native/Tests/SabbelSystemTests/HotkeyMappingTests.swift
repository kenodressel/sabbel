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

    @Test func autoRepeatPassesThrough() {
        var down = false
        #expect(map(.keyDown, 96, spec: f5, down: &down) == .hotkeyDown)
        #expect(map(.keyDown, 96, spec: f5, down: &down) == .hotkeyDown)
    }

    @Test func capsLockMapping() {
        let caps = HotkeySpec.parse("caps_lock")!
        var down = false
        #expect(map(.flagsChanged, 57, .maskAlphaShift, spec: caps, down: &down) == .hotkeyDown)
        #expect(map(.flagsChanged, 57, [], spec: caps, down: &down) == .hotkeyUp)
    }

    @Test func isModifierDown() {
        #expect(HotkeyEventMapper.isModifierDown(keyCode: 61, flags: .maskAlternate))
        #expect(!HotkeyEventMapper.isModifierDown(keyCode: 61, flags: .maskCommand))
        #expect(!HotkeyEventMapper.isModifierDown(keyCode: 96, flags: .maskAlternate))
    }

    // MARK: re-sync after the tap was disabled

    /// The release happened while the tap was disabled: the state machine still
    /// thinks the key is held, so the re-sync must deliver the lost release.
    @Test func resyncAfterAMissedReleaseEmitsHotkeyUp() {
        #expect(HotkeyEventMapper.resync(wasDown: true, isDownNow: false) == .hotkeyUp)
    }

    @Test func resyncEmitsNothingWhenTheStateMatches() {
        #expect(HotkeyEventMapper.resync(wasDown: true, isDownNow: true) == nil)
        #expect(HotkeyEventMapper.resync(wasDown: false, isDownNow: false) == nil)
        // A press missed while disabled is not replayed: starting a take late would clip it anyway.
        #expect(HotkeyEventMapper.resync(wasDown: false, isDownNow: true) == nil)
    }

    /// A non-modifier hotkey's held state is tracked too, so a re-sync can tell it was down.
    @Test func plainKeyTracksDownState() {
        var down = false
        _ = map(.keyDown, 96, spec: f5, down: &down)
        #expect(down)
        _ = map(.keyUp, 96, spec: f5, down: &down)
        #expect(!down)
        // Other keys leave it alone.
        _ = map(.keyDown, 96, spec: f5, down: &down)
        _ = map(.keyUp, 0, spec: f5, down: &down)
        #expect(down)
    }
}

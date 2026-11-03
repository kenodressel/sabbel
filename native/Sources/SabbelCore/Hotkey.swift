import Foundation

/// An input the hotkey state machine cares about, already classified by the event source.
public enum KeyInput: Equatable, Sendable {
    case hotkeyDown, hotkeyUp, escapeDown, otherKeyDown
}

public enum CancelReason: Equatable, Sendable { case combo, escape }

public enum HotkeyAction: Equatable, Sendable { case start, stop, cancel(CancelReason) }

/// Push-to-talk hotkey with combo detection.
///
/// On a German (and most non-US) layout the right Option key is a live
/// character modifier: ⌥L types @, ⌥E an accent, and so on. Treating every
/// press as dictation means normal typing fires a burst of sub-second
/// recordings that get rejected as "too short", each flashing an error.
///
/// So recording still starts on press (waiting for a hold threshold would
/// clip the first word), but if any other key arrives before release, the
/// press was a character combo, not dictation, and the audio is discarded.
///
/// That verdict is passed at *release*, not at the stray keystroke: typing a
/// combo takes a fraction of a second, so a long hold is dictation no matter
/// what got brushed during it. Judging at press time cost two real dictations
/// of 12s and 18s, each killed by a key that landed in the first 66ms.
///
/// Escape is the deliberate way out, and it works at any hold length.
public struct HotkeyStateMachine: Sendable {
    /// Above this hold time a press is dictation, whatever else was typed during it.
    /// Measured against real usage: 36 genuine ⌥-combos spanned 0.142s-0.486s, while
    /// dictations wrongly discarded as combos ran 12s and 18s. 1.0s sits twice above
    /// the longest combo and an order of magnitude below the shortest dictation.
    public static let comboMaxHold: TimeInterval = 1.0

    private let comboMaxHold: TimeInterval
    private var recording = false
    // Tracked separately from `recording`: Escape clears `recording` while the
    // key is still down, and a non-modifier hotkey keeps auto-repeating until
    // it is actually released.
    private var hotkeyDown = false
    private var combo = false
    private var pressTime: TimeInterval = 0

    public init(comboMaxHold: TimeInterval = HotkeyStateMachine.comboMaxHold) {
        self.comboMaxHold = comboMaxHold
    }

    public mutating func handle(_ input: KeyInput, at time: TimeInterval) -> HotkeyAction? {
        switch input {
        case .hotkeyDown:
            guard !hotkeyDown else { return nil }
            hotkeyDown = true
            recording = true
            combo = false
            pressTime = time
            return .start
        case .escapeDown:
            guard recording else { return nil }
            recording = false
            combo = false
            return .cancel(.escape)
        case .otherKeyDown:
            if recording { combo = true }
            return nil
        case .hotkeyUp:
            hotkeyDown = false
            guard recording else { return nil }
            recording = false
            let hold = time - pressTime
            let wasCombo = combo
            combo = false
            if wasCombo && hold < comboMaxHold { return .cancel(.combo) }
            return .stop
        }
    }
}

/// A hotkey as the event source sees it: a macOS virtual key code.
public struct HotkeySpec: Equatable, Sendable {
    public let keyCode: UInt16
    /// Modifier keys are delivered as flagsChanged events, not keyDown/keyUp.
    public let isModifier: Bool

    public static let `default` = HotkeySpec(keyCode: 61, isModifier: true)  // alt_r

    /// Parses a hotkey name like `alt_r`, `f5`, `space` or `a`.
    /// Single letters and digits are ANSI layout *positions* (`kVK_ANSI_*`),
    /// not characters: on other layouts the same code is a different letter.
    /// Escape is reserved for cancelling and is never a valid hotkey.
    public static func parse(_ name: String) -> HotkeySpec? {
        if let code = modifiers[name] { return HotkeySpec(keyCode: code, isModifier: true) }
        if let code = plain[name] { return HotkeySpec(keyCode: code, isModifier: false) }
        return nil
    }

    private static let modifiers: [String: UInt16] = [
        "alt": 58, "alt_l": 58, "alt_r": 61,
        "cmd": 55, "cmd_l": 55, "cmd_r": 54,
        "ctrl": 59, "ctrl_l": 59, "ctrl_r": 62,
        "shift": 56, "shift_l": 56, "shift_r": 60,
        "caps_lock": 57,
    ]

    private static let plain: [String: UInt16] = {
        var m: [String: UInt16] = [
            "space": 49, "tab": 48, "enter": 36, "backspace": 51,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
            "f18": 79, "f19": 80, "f20": 90,
        ]
        let ansi: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6),
            ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14),
            ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34),
            ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23),
            ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ]
        for (k, v) in ansi { m[k] = v }
        return m
    }()
}

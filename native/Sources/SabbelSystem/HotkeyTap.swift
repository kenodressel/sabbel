@preconcurrency import CoreGraphics
import Foundation
import SabbelCore

public enum HotkeyEventMapper {
    /// The device-independent flag that belongs to a modifier keycode.
    private static func flag(forKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case 58, 61: .maskAlternate
        case 54, 55: .maskCommand
        case 59, 62: .maskControl
        case 56, 60: .maskShift
        case 57: .maskAlphaShift
        default: nil
        }
    }

    /// Whether the flag belonging to `keyCode` is set in `flags`.
    public static func isModifierDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let f = flag(forKeyCode: keyCode) else { return false }
        return flags.contains(f)
    }

    /// Pure mapping of one CGEvent's fields to the state machine's input.
    /// `hotkeyIsDown` carries modifier state across flagsChanged events, and
    /// tracks a non-modifier hotkey's held state for `resync`.
    public static func map(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isSynthetic: Bool,
                           spec: HotkeySpec, hotkeyIsDown: inout Bool) -> KeyInput? {
        // Events posted by another process (our own Cmd+V, text expanders, automation) must not
        // look like typing. The tap computes this like pynput's `injected`: source unix pid != 0.
        if isSynthetic { return nil }
        switch type {
        case .flagsChanged:
            guard spec.isModifier, keyCode == spec.keyCode, let flag = flag(forKeyCode: keyCode) else { return nil }
            if flags.contains(flag) && !hotkeyIsDown {
                hotkeyIsDown = true
                return .hotkeyDown
            }
            hotkeyIsDown = false
            return .hotkeyUp
        case .keyDown:
            if !spec.isModifier && keyCode == spec.keyCode {
                hotkeyIsDown = true
                return .hotkeyDown
            }
            return keyCode == 53 ? .escapeDown : .otherKeyDown
        case .keyUp:
            if !spec.isModifier && keyCode == spec.keyCode {
                hotkeyIsDown = false
                return .hotkeyUp
            }
            return nil
        default:
            return nil
        }
    }

    /// What to emit when the tap comes back after being disabled.
    ///
    /// Events were missed while it was off. A release among them would leave
    /// the state machine holding a take open: the next press is ignored as
    /// auto-repeat and the release after it stops a take that recorded for
    /// minutes. So a hotkey the tap believed down but that is up now gets its
    /// release delivered. A missed press is not replayed: the take would start
    /// late and clip its first words anyway.
    public static func resync(wasDown: Bool, isDownNow: Bool) -> KeyInput? {
        wasDown && !isDownNow ? .hotkeyUp : nil
    }

    /// Whether the hotkey is physically held right now: modifiers from the
    /// session's flag state, other keys from the session's key state.
    static func isPhysicallyDown(_ spec: HotkeySpec) -> Bool {
        if spec.isModifier {
            return isModifierDown(keyCode: spec.keyCode, flags: CGEventSource.flagsState(.combinedSessionState))
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(spec.keyCode))
    }
}

/// Listen-only global key tap, run on its own thread's run loop.
public final class HotkeyTap: @unchecked Sendable {
    private let spec: HotkeySpec
    private let log: @Sendable (String) -> Void
    private let onInput: @Sendable (KeyInput, TimeInterval) -> Void

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var hotkeyIsDown = false

    public init(spec: HotkeySpec, log: @escaping @Sendable (String) -> Void,
                onInput: @escaping @Sendable (KeyInput, TimeInterval) -> Void) {
        self.spec = spec
        self.log = log
        self.onInput = onInput
    }

    deinit { stop() }

    /// False if the tap can't be created (no permission).
    public func start() -> Bool {
        lock.lock()
        guard tap == nil else { lock.unlock(); return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            lock.unlock()
            return false
        }
        tap = port
        hotkeyIsDown = false

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let rl = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self?.lock.lock()
            self?.runLoop = rl
            self?.lock.unlock()
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }
        thread.name = "sabbel.hotkey-tap"
        self.thread = thread
        thread.start()
        lock.unlock()
        // The thread takes the lock to publish its run loop, so wait with it released.
        ready.wait()
        return true
    }

    public func stop() {
        lock.lock()
        let port = tap, rl = runLoop
        tap = nil; runLoop = nil; thread = nil
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let rl { CFRunLoopStop(rl) }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("Hotkey tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabling")
            lock.lock()
            let port = tap
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // Events were missed while disabled; re-sync so a lost release neither
            // costs the next press nor stretches the open take (see `resync`).
            let down = HotkeyEventMapper.isPhysicallyDown(spec)
            let missed = HotkeyEventMapper.resync(wasDown: hotkeyIsDown, isDownNow: down)
            hotkeyIsDown = down
            log("Hotkey tap re-synced: hotkey \(down ? "down" : "up")\(missed != nil ? ", delivering the missed release" : "")")
            if let missed { onInput(missed, ProcessInfo.processInfo.systemUptime) }
            return
        }
        let synthetic = event.getIntegerValueField(.eventSourceUnixProcessID) != 0
        // The tap callback runs on a single run-loop thread, so hotkeyIsDown needs no lock.
        guard let input = HotkeyEventMapper.map(
            type: type, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags, isSynthetic: synthetic, spec: spec, hotkeyIsDown: &hotkeyIsDown) else { return }
        onInput(input, ProcessInfo.processInfo.systemUptime)
    }
}

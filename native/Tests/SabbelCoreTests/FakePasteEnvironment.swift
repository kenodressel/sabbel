import Foundation
@testable import SabbelCore

/// A scripted stand-in for the AppKit/AX/Quartz side of pasting.
///
/// - Every protocol call is appended to `log` together with the fake clock's
///   value at that moment, so tests can assert order ("restore after Cmd+V"),
///   absence ("no postCommandV") and timing ("Cmd+V only after 0.3 s").
/// - Answers are closures of `(callIndex, now)`, where `callIndex` counts the
///   calls of *that* method starting at 0, so an answer can change per call or
///   once the clock passes a point.
/// - `sleep` advances the clock instead of sleeping.
/// - The clipboard is modelled: `writeTransient` and `restoreClipboard` replace
///   its items and bump the change count, `userCopies` simulates another writer.
/// - Thread-safe: every stored property (answers, `onCall`, log, clock, clipboard)
///   is read and written under one lock; answers and `onCall` run outside it.
final class FakePasteEnvironment: PasteEnvironment, @unchecked Sendable {
    enum Call: Equatable {
        case frontmostPID
        case focusedElement
        case focusedValue
        case modifiersHeld
        case captureClipboard
        case restoreClipboard
        case writeTransient(String)
        case clipboardChangeCount
        case clipboardString
        case postCommandV(Int32?)
        case postReturn(Int32?)
        case sleep(TimeInterval)
        case now
    }

    static let stringType = "public.utf8-plain-text"

    private let lock = NSLock()

    /// Run `body` under the lock. Never nest: `NSLock` is not recursive.
    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }

    // MARK: scripted answers

    private var _frontmostPIDAnswer: (Int, TimeInterval) -> Int32? = { _, _ in nil }
    private var _focusedElementAnswer: (Int, TimeInterval) -> FocusedElement? = { _, _ in nil }
    private var _focusedValueAnswer: (Int, TimeInterval) -> String? = { _, _ in nil }
    private var _modifiersHeldAnswer: (Int, TimeInterval) -> Bool = { _, _ in false }
    private var _onCall: ((Call, FakePasteEnvironment) -> Void)?

    var frontmostPIDAnswer: (Int, TimeInterval) -> Int32? {
        get { locked { _frontmostPIDAnswer } }
        set { locked { _frontmostPIDAnswer = newValue } }
    }
    var focusedElementAnswer: (Int, TimeInterval) -> FocusedElement? {
        get { locked { _focusedElementAnswer } }
        set { locked { _focusedElementAnswer = newValue } }
    }
    var focusedValueAnswer: (Int, TimeInterval) -> String? {
        get { locked { _focusedValueAnswer } }
        set { locked { _focusedValueAnswer = newValue } }
    }
    var modifiersHeldAnswer: (Int, TimeInterval) -> Bool {
        get { locked { _modifiersHeldAnswer } }
        set { locked { _modifiersHeldAnswer = newValue } }
    }
    /// Runs after a call has been recorded (outside the answer), e.g. to have the
    /// "user" copy something mid-paste.
    var onCall: ((Call, FakePasteEnvironment) -> Void)? {
        get { locked { _onCall } }
        set { locked { _onCall = newValue } }
    }

    // MARK: state

    private var _log: [(call: Call, at: TimeInterval)] = []
    private var _clock: TimeInterval = 0
    private var _changeCount = 1
    private var _items: [[PasteboardFlavor]]
    private var counts: [String: Int] = [:]

    var log: [(call: Call, at: TimeInterval)] { locked { _log } }
    var clock: TimeInterval { locked { _clock } }
    var changeCount: Int { locked { _changeCount } }
    var items: [[PasteboardFlavor]] { locked { _items } }

    init(clipboard: [[PasteboardFlavor]] = [[PasteboardFlavor(FakePasteEnvironment.stringType, Data("old clip".utf8))]]) {
        _items = clipboard
    }

    // MARK: test helpers

    var calls: [Call] { log.map(\.call) }

    /// Calls other than the bookkeeping ones (`now`, `sleep`), for order assertions.
    var actions: [Call] {
        calls.filter {
            switch $0 {
            case .now, .sleep: return false
            default: return true
            }
        }
    }

    var currentString: String? {
        items.first?.data(for: Self.stringType).flatMap { String(data: $0, encoding: .utf8) }
    }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    func didCall(_ predicate: (Call) -> Bool) -> Bool { calls.contains(where: predicate) }

    var postedCommandV: Bool {
        didCall { if case .postCommandV = $0 { return true } else { return false } }
    }

    /// Clock value at the first matching call, if any.
    func time(of predicate: (Call) -> Bool) -> TimeInterval? {
        log.first { predicate($0.call) }?.at
    }

    func index(of predicate: (Call) -> Bool) -> Int? { actions.firstIndex(where: predicate) }

    /// Another writer (the user, a clipboard manager) puts `text` on the clipboard.
    func userCopies(_ text: String) {
        locked {
            _items = [[PasteboardFlavor(Self.stringType, Data(text.utf8))]]
            _changeCount += 1
        }
    }

    // MARK: recording

    private func record(_ call: Call, key: String) -> (Int, TimeInterval) {
        let result: (Int, TimeInterval) = locked {
            _log.append((call, _clock))
            let n = counts[key, default: 0]
            counts[key] = n + 1
            return (n, _clock)
        }
        onCall?(call, self)
        return result
    }

    // MARK: PasteEnvironment

    func frontmostPID() -> Int32? {
        let (n, t) = record(.frontmostPID, key: "frontmostPID")
        return frontmostPIDAnswer(n, t)
    }

    func focusedElement() -> FocusedElement? {
        let (n, t) = record(.focusedElement, key: "focusedElement")
        return focusedElementAnswer(n, t)
    }

    func focusedValue() -> String? {
        let (n, t) = record(.focusedValue, key: "focusedValue")
        return focusedValueAnswer(n, t)
    }

    func modifiersHeld() -> Bool {
        let (n, t) = record(.modifiersHeld, key: "modifiersHeld")
        return modifiersHeldAnswer(n, t)
    }

    func captureClipboard() -> ClipboardSnapshot {
        _ = record(.captureClipboard, key: "captureClipboard")
        return ClipboardSnapshot(items: items)
    }

    func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        _ = record(.restoreClipboard, key: "restoreClipboard")
        locked {
            _items = snapshot.items
            _changeCount += 1
        }
    }

    func writeTransient(_ text: String) -> Int {
        _ = record(.writeTransient(text), key: "writeTransient")
        return locked {
            _items = [[
                PasteboardFlavor(Self.stringType, Data(text.utf8)),
                PasteboardFlavor("org.nspasteboard.TransientType", Data()),
                PasteboardFlavor("org.nspasteboard.AutoGeneratedType", Data()),
            ]]
            _changeCount += 1
            return _changeCount
        }
    }

    func clipboardChangeCount() -> Int {
        _ = record(.clipboardChangeCount, key: "clipboardChangeCount")
        return changeCount
    }

    func clipboardString() -> String? {
        _ = record(.clipboardString, key: "clipboardString")
        return currentString
    }

    func postCommandV(to pid: Int32?) {
        _ = record(.postCommandV(pid), key: "postCommandV")
    }

    func postReturn(to pid: Int32?) {
        _ = record(.postReturn(pid), key: "postReturn")
    }

    func sleep(_ seconds: TimeInterval) {
        _ = record(.sleep(seconds), key: "sleep")
        locked { _clock += seconds }
    }

    func now() -> TimeInterval {
        _ = record(.now, key: "now")
        return clock
    }
}

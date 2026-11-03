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
        case sleep(TimeInterval)
        case now
    }

    static let stringType = "public.utf8-plain-text"

    private let lock = NSRecursiveLock()

    // MARK: scripted answers

    var frontmostPIDAnswer: (Int, TimeInterval) -> Int32? = { _, _ in nil }
    var focusedElementAnswer: (Int, TimeInterval) -> FocusedElement? = { _, _ in nil }
    var focusedValueAnswer: (Int, TimeInterval) -> String? = { _, _ in nil }
    var modifiersHeldAnswer: (Int, TimeInterval) -> Bool = { _, _ in false }
    /// Runs after a call has been recorded (outside the answer), e.g. to have the
    /// "user" copy something mid-paste.
    var onCall: ((Call, FakePasteEnvironment) -> Void)?

    // MARK: state

    private(set) var log: [(call: Call, at: TimeInterval)] = []
    private(set) var clock: TimeInterval = 0
    private(set) var changeCount = 1
    private(set) var items: [[String: Data]]
    private var counts: [String: Int] = [:]

    init(clipboard: [[String: Data]] = [[FakePasteEnvironment.stringType: Data("old clip".utf8)]]) {
        items = clipboard
    }

    // MARK: test helpers

    var calls: [Call] { lock.withLock { log.map(\.call) } }

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
        lock.withLock { items.first?[Self.stringType].flatMap { String(data: $0, encoding: .utf8) } }
    }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    func didCall(_ predicate: (Call) -> Bool) -> Bool { calls.contains(where: predicate) }

    var postedCommandV: Bool {
        didCall { if case .postCommandV = $0 { return true } else { return false } }
    }

    /// Clock value at the first matching call, if any.
    func time(of predicate: (Call) -> Bool) -> TimeInterval? {
        lock.withLock { log.first { predicate($0.call) }?.at }
    }

    func index(of predicate: (Call) -> Bool) -> Int? { actions.firstIndex(where: predicate) }

    /// Another writer (the user, a clipboard manager) puts `text` on the clipboard.
    func userCopies(_ text: String) {
        lock.withLock {
            items = [[Self.stringType: Data(text.utf8)]]
            changeCount += 1
        }
    }

    // MARK: recording

    private func record(_ call: Call, key: String) -> (Int, TimeInterval) {
        let result: (Int, TimeInterval) = lock.withLock {
            log.append((call, clock))
            let n = counts[key, default: 0]
            counts[key] = n + 1
            return (n, clock)
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
        return lock.withLock { ClipboardSnapshot(items: items) }
    }

    func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        _ = record(.restoreClipboard, key: "restoreClipboard")
        lock.withLock {
            items = snapshot.items
            changeCount += 1
        }
    }

    func writeTransient(_ text: String) -> Int {
        _ = record(.writeTransient(text), key: "writeTransient")
        return lock.withLock {
            items = [[
                Self.stringType: Data(text.utf8),
                "org.nspasteboard.TransientType": Data(),
                "org.nspasteboard.AutoGeneratedType": Data(),
            ]]
            changeCount += 1
            return changeCount
        }
    }

    func clipboardChangeCount() -> Int {
        _ = record(.clipboardChangeCount, key: "clipboardChangeCount")
        return lock.withLock { changeCount }
    }

    func clipboardString() -> String? {
        _ = record(.clipboardString, key: "clipboardString")
        return currentString
    }

    func postCommandV(to pid: Int32?) {
        _ = record(.postCommandV(pid), key: "postCommandV")
    }

    func sleep(_ seconds: TimeInterval) {
        _ = record(.sleep(seconds), key: "sleep")
        lock.withLock { clock += seconds }
    }

    func now() -> TimeInterval {
        _ = record(.now, key: "now")
        return lock.withLock { clock }
    }
}

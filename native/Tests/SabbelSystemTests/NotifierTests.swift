import Foundation
import Testing
import SabbelCore
@testable import SabbelSystem

@Suite struct NotifierTests {
    @Test func notifierMapsNotice() {
        let mic = Notifier.content(for: .micFallback("Yeti"))
        #expect(mic.title == "Sabbel")
        #expect(mic.subtitle == "Mic 'Yeti' not found")
        #expect(mic.body == "Using system default. Pick another mic from the Sabbel menu.")

        let cleared = Notifier.content(for: .historyCleared)
        #expect(cleared.title == "Sabbel")
        #expect(cleared.subtitle == "History cleared")
        #expect(cleared.body == "")

        for notice: Notice in [.modelLoading, .cancelled, .updateAvailable("1.2.0"), .diagnosticsCopied(false)] {
            let c = Notifier.content(for: notice)
            #expect(c.title == "Sabbel")
            #expect(c.subtitle == notice.subtitle)
            #expect(c.body == notice.message)
        }
    }
}

@Suite struct RecordOnlyNotifierTests {
    @Test func neverReachesNotificationCenter() {
        let lines = LockedLines()
        let notifier = Notifier(log: { lines.append($0) }, notificationCenter: false)
        notifier.requestAuthorization()
        notifier.post(.historyCleared)
        #expect(!notifier.usesNotificationCenter)
        #expect(lines.all.contains { $0.contains("History cleared") })
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

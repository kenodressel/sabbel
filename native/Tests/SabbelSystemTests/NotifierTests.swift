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

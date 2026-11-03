import AppKit
import SabbelCore
import SabbelSystem
import SwiftUI

/// The newest take's live text, as the panel shows it.
@MainActor final class LiveModel: ObservableObject {
    @Published var settled = ""
    @Published var provisional = ""
}

struct LiveTextView: View {
    @ObservedObject var model: LiveModel
    private let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                (Text(model.settled).foregroundColor(.primary) + Text(model.provisional).foregroundColor(.secondary))
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id(bottom)
            }
            // Keep the newest words in view as the text grows.
            .onChange(of: model.settled + model.provisional) {
                proxy.scrollTo(bottom, anchor: .bottom)
            }
        }
        .frame(minWidth: 280, minHeight: 120)
    }
}

/// Structurally unable to take focus: whatever is clicked, it never becomes
/// the key or main window, so keystrokes keep going to the app being dictated into.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A window that shows the take as it is transcribed, without ever taking focus.
///
/// It is non-activating and never made key: the dictation must keep landing in
/// the app the user is typing into. Opened only from "Show Live Text", never by a take.
@MainActor final class LivePanel {
    private let model = LiveModel()
    private var panel: NonKeyPanel?

    /// Updates the text whether or not the panel is open, so opening it shows the current take.
    func update(_ text: LiveText, masked: Bool) {
        let parts = LiveDisplay.parts(text, masked: masked)
        if model.settled != parts.settled { model.settled = parts.settled }
        if model.provisional != parts.provisional { model.provisional = parts.provisional }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NonKeyPanel {
        let panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Sabbel — Live Text"
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // A normal window (R24), available on every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LiveTextView(model: model))
        panel.center()
        return panel
    }
}

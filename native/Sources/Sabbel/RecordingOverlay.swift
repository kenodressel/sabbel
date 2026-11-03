import AppKit
import SabbelCore
import SabbelSystem
import SwiftUI

/// What the overlay view renders. `phase` keeps the last visible phase while
/// the panel fades out, so the capsule does not collapse mid-fade.
@MainActor final class OverlayModel: ObservableObject {
    @Published var phase: OverlayPhase = .hidden
    @Published var bars = LevelBars()
    @Published var settled = ""
    @Published var provisional = ""
    let showsText: Bool

    init(showsText: Bool) { self.showsText = showsText }
}

private enum OverlayLayout {
    static let height: CGFloat = 36
    static let radius: CGFloat = height / 2
    static let maxWidth: CGFloat = 560
    static let padding: CGFloat = 14
    /// Room around the capsule for its shadow and the width spring.
    static let margin: CGFloat = 28
    /// The capsule's bottom edge above the screen's visible frame.
    static let lift: CGFloat = 72
    static let panelSize = NSSize(width: maxWidth + 2 * margin, height: 160)
    /// Characters of live text kept: about two lines at 560 pt.
    static let textLimit = 150
}

/// The floating capsule shown during a take: from key-down until shortly after
/// the result. Never takes focus and never sees a click.
@MainActor final class RecordingOverlay {
    private var machine: OverlayMachine
    private let model: OverlayModel
    private var panel: NonKeyPanel?
    private var expiry: Task<Void, Never>?
    /// Bumped on every show and hide, so a fade that finishes late never hides a newer take.
    private var generation = 0
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(style: OverlayStyle) {
        machine = OverlayMachine(style: style)
        model = OverlayModel(showsText: style == .text)
    }

    func handle(_ event: TakeEvent) {
        guard machine.style != .off else { return }
        let before = machine.phase
        machine.handle(event, at: clock())
        guard machine.phase != before else { return }
        switch machine.phase {
        case .recording:
            model.bars.reset()
            if !before.isVisible { place() }
        case .finishing:
            model.bars.reset()
        case .hidden, .result:
            break
        }
        render()
    }

    func level(_ level: Double) {
        guard case .recording = machine.phase else { return }
        model.bars.push(level)
    }

    func live(_ text: LiveText, masked: Bool) {
        guard model.showsText else { return }
        let parts = LiveDisplay.tail(LiveDisplay.parts(text, masked: masked), limit: OverlayLayout.textLimit)
        if model.settled != parts.settled { model.settled = parts.settled }
        if model.provisional != parts.provisional { model.provisional = parts.provisional }
    }

    private func render() {
        expiry?.cancel()
        expiry = nil
        guard machine.phase.isVisible else {
            hide()
            return
        }
        if panel?.isVisible == true {
            model.phase = machine.phase
        } else {
            // Appearing: start in the new shape rather than springing from the last take's.
            var appear = Transaction()
            appear.disablesAnimations = true
            withTransaction(appear) { model.phase = machine.phase }
        }
        show()
        if let hideAt = machine.hideAt {
            let delay = max(0, hideAt - clock())
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.machine.tick(at: self.clock())
                // Hides, or waits out the rest should the sleep end a hair early.
                self.render()
            }
        }
    }

    // MARK: panel

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation += 1
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        let fade = OverlayMachine.fadeDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade))
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Bottom centre of the screen with the mouse pointer.
    private func place() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = OverlayLayout.panelSize
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: visible.minY + OverlayLayout.lift - OverlayLayout.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func makePanel() -> NonKeyPanel {
        let panel = NonKeyPanel(contentRect: NSRect(origin: .zero, size: OverlayLayout.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow; the window's would outline the transparent frame.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: OverlayView(model: model))
        // The panel keeps its size; the capsule animates inside it.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

// MARK: views

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsText: Bool {
        guard model.showsText, !(model.settled.isEmpty && model.provisional.isEmpty) else { return false }
        switch model.phase {
        case .recording, .finishing: return true
        case .hidden, .result: return false
        }
    }

    /// Changes whenever the capsule changes shape, to spring its width.
    private var shapeKey: Int {
        let phase = switch model.phase {
        case .hidden: 0
        case .recording: 1
        case .finishing: 2
        case .result: 3
        }
        return phase * 2 + (showsText ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { row }
                .frame(height: OverlayLayout.height)
            if showsText {
                (Text(model.settled).foregroundColor(.primary) + Text(model.provisional).foregroundColor(.secondary))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OverlayLayout.maxWidth - 2 * OverlayLayout.padding, alignment: .leading)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, OverlayLayout.padding)
        .background(CapsuleBackground())
        .overlay(
            RoundedRectangle(cornerRadius: OverlayLayout.radius, style: .circular)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, OverlayLayout.margin)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: shapeKey)
    }

    /// Recording and finishing share one row, so the bars sink to the low row
    /// in place and the spinner takes the dot's spot.
    @ViewBuilder private var row: some View {
        if case .result(let result) = model.phase {
            Image(systemName: result.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(result.kind == .error ? Color(nsColor: .systemRed) : .primary)
            Text(result.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        } else {
            ZStack {
                if case .finishing = model.phase {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    RecordingDot(pulsing: !reduceMotion)
                }
            }
            .frame(width: 10, height: 10)
            LevelBarsView(values: model.bars.values, animated: !reduceMotion)
            ElapsedView(phase: model.phase)
        }
    }
}

/// `m:ss` since the take started; frozen once released.
private struct ElapsedView: View {
    let phase: OverlayPhase

    var body: some View {
        switch phase {
        case .recording(let since):
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                label(ProcessInfo.processInfo.systemUptime - since)
            }
        case .finishing(let elapsed):
            label(elapsed)
        case .hidden, .result:
            label(0)
        }
    }

    private func label(_ seconds: TimeInterval) -> some View {
        Text(OverlayMachine.elapsed(seconds))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// The red recording dot, breathing gently unless Reduce Motion is on.
private struct RecordingDot: View {
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemRed))
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct LevelBarsView: View {
    let values: [Double]
    let animated: Bool
    private let tallest: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(values.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: max(2.5, tallest * values[index]))
            }
        }
        .frame(height: tallest)
        .animation(animated ? .easeOut(duration: 0.1) : nil, value: values)
    }
}

/// HUD material blurring what is behind the window, cut to the capsule, over
/// a soft shadow.
private struct CapsuleBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OverlayLayout.radius, style: .circular)
                .fill(Color.black.opacity(0.3))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            HUDMaterial()
        }
    }
}

private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: OverlayLayout.radius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle: the corners stay round at any size.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

import AppKit
import ApplicationServices
import SabbelCore

/// `FocusProbe` on NSWorkspace and Accessibility.
///
/// It runs on the main actor at every hotkey press, so each AX call is bounded:
/// an app that hangs must not freeze the menu bar for AX's default 6 s.
public struct SystemFocusProbe: FocusProbe {
    /// Upper bound for each Accessibility call, in seconds.
    static let axTimeout: Float = 0.25

    public init() {}

    public var ownPID: Int32 { getpid() }

    /// The target comes from NSWorkspace whatever AX says; an AX failure
    /// (Electron apps, no permission, a timeout) means "not secure".
    public func capture() -> (target: FocusTarget?, secure: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, false) }
        let pid = app.processIdentifier
        let target = FocusTarget(pid: pid, name: app.localizedName)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (target, false) }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return (target, false)
        }
        let probe = FocusedElement(role: nil, subrole: subrole as? String, hasSelectedTextRange: false,
                                   valueSettable: false, selectedTextSettable: false)
        return (target, Injector.isSecure(probe))
    }
}

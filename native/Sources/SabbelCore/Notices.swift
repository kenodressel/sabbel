import Foundation

/// A user notification. The copy is today's app's, word for word (`sabbel/app.py`).
///
/// Each paste outcome has its own wording: telling someone their text is in the
/// clipboard when it was deliberately withheld from a password field is worse
/// than saying nothing.
public enum Notice: Equatable, Sendable {
    case modelLoading
    case modelFailed(String)
    case cancelled
    case deadStream
    case noAudio
    case micFallback(String)
    case textCopiedNoField
    case textCopiedFocusChanged
    case discardedSecure
    case diagnosticsCopied(Bool)
    case historyCleared
    case updateAvailable(String)

    /// The runtime log every "details in …" message points at.
    static let runtimeLogPath = "/tmp/sabbel-runtime.log"

    public var subtitle: String {
        switch self {
        case .modelLoading: "Model still loading"
        case .modelFailed: "Model could not be loaded"
        case .cancelled: "Recording cancelled"
        case .deadStream: "Microphone delivered no signal"
        case .noAudio: "No audio detected"
        case .micFallback(let name): "Mic '\(name)' not found"
        case .textCopiedNoField, .textCopiedFocusChanged: "Text copied to clipboard"
        case .discardedSecure: "Dictation discarded"
        case .diagnosticsCopied(let ok): ok ? "Diagnostics copied" : "Could not copy"
        case .historyCleared: "History cleared"
        case .updateAvailable(let version): "Update v\(version) available"
        }
    }

    public var message: String {
        switch self {
        case .modelLoading: "Please wait. The icon will change to 🎙 when Sabbel is ready."
        // Naming the log is the difference between a screenshot and a report
        // someone can act on.
        case .modelFailed(let m): "\(m.prefix(160)) — details in \(Self.runtimeLogPath)"
        case .cancelled: "Escape pressed — the dictation was discarded."
        case .deadStream: "Check that the mic isn't muted and input volume isn't zero."
        case .noAudio: "No speech was detected in the last recording."
        case .micFallback: "Using system default. Pick another mic from the Sabbel menu."
        case .textCopiedNoField: "No text field detected. Paste manually with Cmd+V."
        case .textCopiedFocusChanged: "You switched apps while it was transcribing. Paste with Cmd+V."
        case .discardedSecure: "Sabbel does not type into password fields."
        case .diagnosticsCopied(let ok): ok ? "Paste them into your bug report." : "Send \(Self.runtimeLogPath) instead."
        case .historyCleared: ""
        case .updateAvailable: "Click 'Update' in the Sabbel menu for details."
        }
    }
}

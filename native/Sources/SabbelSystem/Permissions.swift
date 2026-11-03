import ApplicationServices
import AVFoundation

public enum MicrophonePermission: Sendable { case granted, denied, undetermined }

public enum Permissions {
    /// Whether this process is trusted for Accessibility; `prompt` shows the system dialog when it is not.
    public static func accessibilityGranted(prompt: Bool) -> Bool {
        // The literal is kAXTrustedCheckOptionPrompt (a C global var, not concurrency-safe to reference in Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// The 1 s permission poll's decisions (`_monitor_permissions` in `sabbel/app.py`):
/// Accessibility first, prompting once; then the Microphone, requested once.
public struct PermissionGate: Sendable {
    public enum Step: Equatable, Sendable {
        /// Show `status`; when `requestMicrophone`, ask for the mic now (only ever once).
        case waiting(String, requestMicrophone: Bool)
        case ready
    }

    private var accessibilityPrompted = false
    private var microphoneRequested = false

    public init() {}

    /// - Parameters:
    ///   - accessibility: checks Accessibility, showing the system prompt when passed true.
    ///   - microphone: read only once Accessibility is granted.
    public mutating func step(accessibility: (_ prompt: Bool) -> Bool,
                              microphone: () -> MicrophonePermission) -> Step {
        let prompt = !accessibilityPrompted
        guard accessibility(prompt) else {
            accessibilityPrompted = true
            return .waiting("Accessibility missing", requestMicrophone: false)
        }
        switch microphone() {
        case .granted:
            return .ready
        case .undetermined:
            let request = !microphoneRequested
            microphoneRequested = true
            return .waiting("Microphone missing", requestMicrophone: request)
        case .denied:
            return .waiting("Microphone missing", requestMicrophone: false)
        }
    }
}

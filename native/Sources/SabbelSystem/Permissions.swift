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

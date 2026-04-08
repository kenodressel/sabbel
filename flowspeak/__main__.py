import sys
import time
import Quartz  # Eager import to prevent pyobjc race condition
import HIServices
import AVFoundation

from flowspeak.config import load_config
from flowspeak.app import FlowSpeakApp


def check_accessibility() -> bool:
    """Check accessibility permission, prompt if not granted."""
    options = {HIServices.kAXTrustedCheckOptionPrompt: True}
    return bool(HIServices.AXIsProcessTrustedWithOptions(options))


def check_microphone() -> bool:
    """Check microphone permission, request if not granted."""
    status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
        AVFoundation.AVMediaTypeAudio
    )
    if status == AVFoundation.AVAuthorizationStatusAuthorized:
        return True
    if status == AVFoundation.AVAuthorizationStatusNotDetermined:
        # Request permission — this triggers the system dialog
        print("Requesting microphone permission...")
        granted = [None]
        def handler(g):
            granted[0] = g
        AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVFoundation.AVMediaTypeAudio, handler
        )
        # Wait for user response (up to 30 seconds)
        for _ in range(300):
            if granted[0] is not None:
                return granted[0]
            time.sleep(0.1)
        return False
    # Denied or Restricted
    return False


def main():
    # Check accessibility — wait up to 10 seconds for user to grant
    if not check_accessibility():
        print(
            "⚠ FlowSpeak needs Accessibility permission.\n"
            "  Waiting for permission..."
        )
        for _ in range(10):
            time.sleep(1)
            if check_accessibility():
                break
        else:
            print("  Accessibility not granted. Exiting.")
            sys.exit(1)

    # Check microphone
    if not check_microphone():
        print(
            "⚠ FlowSpeak needs Microphone permission.\n"
            "  Go to: System Settings → Privacy & Security → Microphone\n"
            "  Enable FlowSpeak, then restart."
        )
        sys.exit(1)

    print("✓ Permissions OK. Starting FlowSpeak...")
    config = load_config()
    app = FlowSpeakApp(config)
    app.run()


if __name__ == "__main__":
    main()

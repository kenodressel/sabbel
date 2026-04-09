import time
from pathlib import Path
import Quartz  # Eager import to prevent pyobjc race condition
import HIServices
import AVFoundation

from flowspeak.config import load_config
from flowspeak.app import FlowSpeakApp
from flowspeak.single_instance import SingleInstanceLock


def check_accessibility(prompt: bool = False) -> bool:
    """Check accessibility permission and optionally trigger the system prompt."""
    options = {HIServices.kAXTrustedCheckOptionPrompt: prompt}
    return bool(HIServices.AXIsProcessTrustedWithOptions(options))


def check_microphone(request_if_needed: bool = True) -> bool:
    """Check microphone permission and optionally trigger the system prompt."""
    status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
        AVFoundation.AVMediaTypeAudio
    )
    if status == AVFoundation.AVAuthorizationStatusAuthorized:
        return True
    if status == AVFoundation.AVAuthorizationStatusNotDetermined and request_if_needed:
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


def wait_for_accessibility() -> None:
    """Prompt once, then wait until Accessibility has been granted."""
    if check_accessibility():
        return

    check_accessibility(prompt=True)
    print(
        "⚠ FlowSpeak needs Accessibility permission.\n"
        "  A system dialog or System Settings page should appear.\n"
        "  Grant access and FlowSpeak will continue automatically."
    )
    while not check_accessibility():
        time.sleep(1)


def wait_for_microphone() -> None:
    """Request microphone access and wait until it has been granted."""
    if check_microphone():
        return

    print(
        "⚠ FlowSpeak needs Microphone permission.\n"
        "  A system dialog or System Settings page should appear.\n"
        "  Grant access and FlowSpeak will continue automatically."
    )
    while not check_microphone(request_if_needed=False):
        time.sleep(1)


def main():
    lock = SingleInstanceLock(Path("/tmp/flowspeak.lock"))
    if not lock.acquire():
        print("FlowSpeak is already running. Exiting.")
        return 0

    wait_for_accessibility()
    wait_for_microphone()

    print("✓ Permissions OK. Starting FlowSpeak...")
    config = load_config()
    try:
        app = FlowSpeakApp(config)
    except Exception as exc:
        print(f"Failed to initialize FlowSpeak: {exc}")
        lock.release()
        return 1

    try:
        app.run()
    finally:
        lock.release()


if __name__ == "__main__":
    main()

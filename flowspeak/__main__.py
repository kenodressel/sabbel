import Quartz  # Eager import to prevent pyobjc race condition
import HIServices

from flowspeak.config import load_config
from flowspeak.app import FlowSpeakApp


def check_accessibility_with_prompt() -> bool:
    """Check accessibility permission and show system dialog if not granted."""
    options = {HIServices.kAXTrustedCheckOptionPrompt: True}
    return bool(HIServices.AXIsProcessTrustedWithOptions(options))


def main():
    if not check_accessibility_with_prompt():
        print(
            "\n⚠ FlowSpeak needs Accessibility permission to capture hotkeys.\n"
            "  A system dialog should have appeared.\n"
            "  After granting permission, restart FlowSpeak.\n"
        )
        return

    config = load_config()
    app = FlowSpeakApp(config)
    app.run()


if __name__ == "__main__":
    main()

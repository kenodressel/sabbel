import Quartz  # Eager import to prevent pyobjc race condition

from flowspeak.config import load_config
from flowspeak.app import FlowSpeakApp


def check_accessibility() -> bool:
    return bool(Quartz.AXIsProcessTrusted())


def main():
    if not check_accessibility():
        import rumps
        rumps.alert(
            title="FlowSpeak — Accessibility Required",
            message=(
                "FlowSpeak needs Accessibility permission to capture hotkeys "
                "and paste text.\n\n"
                "Go to: System Settings → Privacy & Security → Accessibility\n"
                "Add and enable your terminal app (e.g., Terminal, iTerm2)."
            ),
        )

    config = load_config()
    app = FlowSpeakApp(config)
    app.run()


if __name__ == "__main__":
    main()

import sys
import types
from unittest.mock import MagicMock, patch

sys.modules.setdefault(
    "AVFoundation",
    types.SimpleNamespace(
        AVCaptureDevice=types.SimpleNamespace(),
        AVMediaTypeAudio="audio",
        AVAuthorizationStatusAuthorized=1,
        AVAuthorizationStatusNotDetermined=0,
    ),
)
sys.modules.setdefault(
    "HIServices",
    types.SimpleNamespace(
        kAXTrustedCheckOptionPrompt="prompt",
        AXIsProcessTrustedWithOptions=lambda _options: True,
    ),
)

from sabbel.app import SabbelApp, _language_menu_title, _normalize_language


def test_normalize_language_accepts_supported_values():
    assert _normalize_language("de") == "de"
    assert _normalize_language("en") == "en"


def test_normalize_language_falls_back_to_auto_for_unknown_values():
    assert _normalize_language(None) is None
    assert _normalize_language("auto") is None
    assert _normalize_language("fr") is None


def test_language_menu_title_matches_language():
    assert _language_menu_title(None) == "Sprache: Auto"
    assert _language_menu_title("de") == "Sprache: Deutsch"
    assert _language_menu_title("en") == "Sprache: English"


@patch("sabbel.app.time.sleep")
@patch("sabbel.app.callAfter", side_effect=lambda fn: fn())
@patch("sabbel.app.check_microphone", return_value=False)
@patch("sabbel.app.check_accessibility", return_value=True)
def test_permission_monitor_does_not_start_hotkey_without_microphone(
    _mock_accessibility,
    _mock_microphone,
    _mock_call_after,
    mock_sleep,
):
    app = SabbelApp.__new__(SabbelApp)
    app._running = True
    app._hotkey_started = False
    app._hotkey = MagicMock()
    app._set_status = MagicMock()

    def stop_loop(_seconds):
        app._running = False

    mock_sleep.side_effect = stop_loop

    app._monitor_permissions()

    app._hotkey.start.assert_not_called()
    assert app._hotkey_started is False
    app._set_status.assert_called_with("Mikrofon fehlt")


@patch("sabbel.app.time.sleep")
@patch("sabbel.app.callAfter", side_effect=lambda fn: fn())
@patch("sabbel.app.check_microphone", return_value=True)
@patch("sabbel.app.check_accessibility", return_value=True)
def test_permission_monitor_starts_hotkey_once_permissions_are_ready(
    _mock_accessibility,
    _mock_microphone,
    _mock_call_after,
    _mock_sleep,
):
    app = SabbelApp.__new__(SabbelApp)
    app._running = True
    app._hotkey_started = False
    app._hotkey = MagicMock()
    app._set_status = MagicMock()

    app._monitor_permissions()

    app._hotkey.start.assert_called_once()
    assert app._hotkey_started is True
    app._set_status.assert_called_with("Bereit")

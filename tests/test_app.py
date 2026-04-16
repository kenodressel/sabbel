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

from sabbel.app import (
    SabbelApp,
    _append_history,
    _language_menu_title,
    _next_language,
    _normalize_language,
)


def test_normalize_language_accepts_supported_values():
    assert _normalize_language("de") == "de"
    assert _normalize_language("en") == "en"


def test_normalize_language_falls_back_to_auto_for_unknown_values():
    assert _normalize_language(None) is None
    assert _normalize_language("auto") is None
    assert _normalize_language("fr") is None


def test_language_menu_title_matches_language():
    assert _language_menu_title(None) == "Language: Auto"
    assert _language_menu_title("de") == "Language: Deutsch"
    assert _language_menu_title("en") == "Language: English"


def test_next_language_cycles_auto_de_en():
    assert _next_language(None) == "de"
    assert _next_language("de") == "en"
    assert _next_language("en") is None


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
    app._set_status.assert_called_with("Microphone missing")


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
    app._set_status.assert_called_with("Ready")


def test_append_history_creates_file_and_appends(tmp_path):
    path = tmp_path / "subdir" / "history.log"

    _append_history(path, "first", max_bytes=10_000)
    _append_history(path, "second", max_bytes=10_000)

    content = path.read_text()
    assert "first" in content
    assert "second" in content
    # Each entry has a timestamp header and trailing blank line
    assert content.count("---") == 4


def test_append_history_rotates_when_over_max_bytes(tmp_path):
    path = tmp_path / "history.log"
    # Pre-fill with >max_bytes so the next call triggers rotation
    path.write_text("x" * 200)

    _append_history(path, "after-rotation", max_bytes=100)

    backup = path.with_name("history.log.1")
    assert backup.exists(), "old content should be rotated to .1"
    assert backup.read_text() == "x" * 200
    # New file contains only the most recent entry
    assert "after-rotation" in path.read_text()
    assert "x" * 200 not in path.read_text()


def test_append_history_replaces_existing_backup(tmp_path):
    path = tmp_path / "history.log"
    backup = path.with_name("history.log.1")
    backup.write_text("stale-backup")
    path.write_text("x" * 200)

    _append_history(path, "new", max_bytes=100)

    # Old backup must be replaced by the rotated current file, not appended
    assert backup.read_text() == "x" * 200


def test_save_to_history_skips_when_disabled(tmp_path):
    app = SabbelApp.__new__(SabbelApp)
    app._config = MagicMock(history_enabled=False, history_max_bytes=1_000_000)
    app._history_path = tmp_path / "history.log"

    app._save_to_history("hello")

    assert not app._history_path.exists()


def test_save_to_history_writes_when_enabled(tmp_path):
    app = SabbelApp.__new__(SabbelApp)
    app._config = MagicMock(history_enabled=True, history_max_bytes=1_000_000)
    app._history_path = tmp_path / "history.log"

    app._save_to_history("hello")

    assert "hello" in app._history_path.read_text()

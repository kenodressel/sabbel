"""Tests for push-to-talk hotkey handling.

The combo cases matter on non-US layouts: right Option is a character
modifier there, so plain typing must not produce dictations.
"""
from unittest.mock import MagicMock

import pytest
from pynput.keyboard import Key, KeyCode

from sabbel.hotkey import HotkeyManager, _parse_hotkey


@pytest.fixture
def hk():
    m = HotkeyManager(
        on_start=MagicMock(),
        on_stop=MagicMock(),
        on_cancel=MagicMock(),
        hotkey="alt_r",
    )
    return m


def test_plain_hold_starts_and_stops(hk):
    hk._on_press(Key.alt_r)
    hk._on_release(Key.alt_r)

    hk._on_start.assert_called_once()
    hk._on_stop.assert_called_once()
    hk._on_cancel.assert_not_called()


def test_option_plus_letter_is_cancelled_not_transcribed(hk):
    """⌥L types @ on a German layout — that must not become a dictation."""
    hk._on_press(Key.alt_r)
    hk._on_press(KeyCode.from_char("l"))
    hk._on_release(KeyCode.from_char("l"))
    hk._on_release(Key.alt_r)

    hk._on_start.assert_called_once()  # started optimistically, no clipping
    hk._on_cancel.assert_called_once()
    hk._on_stop.assert_not_called()


def test_recording_still_starts_immediately_on_press(hk):
    """No hold threshold: waiting to be sure would clip the first word."""
    hk._on_press(Key.alt_r)
    hk._on_start.assert_called_once()


def test_combo_flag_resets_for_next_press(hk):
    hk._on_press(Key.alt_r)
    hk._on_press(KeyCode.from_char("e"))
    hk._on_release(Key.alt_r)
    assert hk._on_cancel.call_count == 1

    hk._on_press(Key.alt_r)
    hk._on_release(Key.alt_r)
    hk._on_stop.assert_called_once()
    assert hk._on_cancel.call_count == 1


def test_autorepeat_of_hotkey_does_not_restart(hk):
    hk._on_press(Key.alt_r)
    hk._on_press(Key.alt_r)
    hk._on_press(Key.alt_r)
    hk._on_start.assert_called_once()


def test_other_key_outside_hold_is_ignored(hk):
    """Typing without the hotkey held must not arm anything."""
    hk._on_press(KeyCode.from_char("a"))
    hk._on_release(KeyCode.from_char("a"))
    hk._on_start.assert_not_called()
    hk._on_cancel.assert_not_called()


def test_release_without_press_is_ignored(hk):
    hk._on_release(Key.alt_r)
    hk._on_stop.assert_not_called()
    hk._on_cancel.assert_not_called()


def test_cancel_defaults_to_stop_when_not_supplied():
    stop = MagicMock()
    m = HotkeyManager(on_start=MagicMock(), on_stop=stop, hotkey="alt_r")
    m._on_press(Key.alt_r)
    m._on_press(KeyCode.from_char("l"))
    m._on_release(Key.alt_r)
    stop.assert_called_once()


def test_parse_hotkey_accepts_names_and_chars():
    assert _parse_hotkey("alt_r") == Key.alt_r
    assert _parse_hotkey("f5") == Key.f5
    assert _parse_hotkey("a") == KeyCode.from_char("a")


def test_parse_hotkey_rejects_unknown():
    with pytest.raises(ValueError, match="Unknown hotkey"):
        _parse_hotkey("nope_key")


# --- injected events --------------------------------------------------------


def test_injected_keystroke_does_not_cancel_dictation(hk):
    """pynput passes `injected`; other tools' synthetic keys must not count.

    Karabiner, text expanders and launchers all post synthetic keystrokes.
    Treating one as a combo would silently discard the dictation in progress.
    """
    hk._on_press(Key.alt_r, False)
    hk._on_press(KeyCode.from_char("v"), True)   # injected by some other tool
    hk._on_release(KeyCode.from_char("v"), True)
    hk._on_release(Key.alt_r, False)

    hk._on_stop.assert_called_once()
    hk._on_cancel.assert_not_called()


def test_injected_hotkey_press_is_ignored(hk):
    hk._on_press(Key.alt_r, True)
    hk._on_start.assert_not_called()


def test_real_pynput_signature_is_accepted(hk):
    """pynput calls on_press(key, injected) positionally — not on_press(key)."""
    hk._on_press(Key.alt_r, False)
    hk._on_release(Key.alt_r, False)
    hk._on_start.assert_called_once()
    hk._on_stop.assert_called_once()

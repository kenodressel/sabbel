"""Tests for push-to-talk hotkey handling.

The combo cases matter on non-US layouts: right Option is a character
modifier there, so plain typing must not produce dictations.
"""
from unittest.mock import MagicMock

import pytest
from pynput.keyboard import Key, KeyCode

from sabbel.hotkey import HotkeyManager, _parse_hotkey


class FakeClock:
    """Monotonic clock under test control — hold durations without sleeping."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def hk(clock):
    m = HotkeyManager(
        on_start=MagicMock(),
        on_stop=MagicMock(),
        on_cancel=MagicMock(),
        hotkey="alt_r",
        clock=clock,
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


# --- combo only wins for short holds ----------------------------------------
#
# Thresholds come from measured data in /tmp/sabbel-runtime.log: 36 genuine
# ⌥-combos spanned 0.142s–0.486s, while two lost dictations ran 12.0s and 18.0s.


def test_long_hold_transcribes_despite_early_stray_key(hk, clock):
    """The real bug: a key brushed 66ms in killed a 12-second dictation.

    The stray key lands well inside any press-time window, so only the hold
    duration can tell typing from dictation.
    """
    hk._on_press(Key.alt_r)
    clock.advance(0.066)
    hk._on_press(KeyCode.from_char("l"))
    clock.advance(11.892)
    hk._on_release(Key.alt_r)

    hk._on_stop.assert_called_once()
    hk._on_cancel.assert_not_called()


def test_longest_measured_combo_is_still_cancelled(hk, clock):
    """0.486s was the longest real ⌥-combo seen — it must stay discarded."""
    hk._on_press(Key.alt_r)
    clock.advance(0.284)
    hk._on_press(KeyCode.from_char("l"))
    clock.advance(0.202)
    hk._on_release(Key.alt_r)

    hk._on_cancel.assert_called_once_with("combo")
    hk._on_stop.assert_not_called()


# --- escape cancels explicitly ----------------------------------------------


def test_escape_cancels_a_long_dictation(hk, clock):
    hk._on_press(Key.alt_r)
    clock.advance(9.0)
    hk._on_press(Key.esc)

    hk._on_cancel.assert_called_once_with("escape")
    hk._on_stop.assert_not_called()


def test_escape_then_hotkey_release_does_not_also_stop(hk, clock):
    """Releasing the still-held hotkey after Escape must not transcribe."""
    hk._on_press(Key.alt_r)
    clock.advance(5.0)
    hk._on_press(Key.esc)
    hk._on_release(Key.esc)
    hk._on_release(Key.alt_r)

    hk._on_cancel.assert_called_once_with("escape")
    hk._on_stop.assert_not_called()


def test_escape_outside_recording_is_ignored(hk):
    hk._on_press(Key.esc)

    hk._on_cancel.assert_not_called()
    hk._on_stop.assert_not_called()


def test_injected_escape_does_not_cancel_dictation(hk, clock):
    """A synthetic Escape from another tool must not discard live dictation."""
    hk._on_press(Key.alt_r, False)
    clock.advance(6.0)
    hk._on_press(Key.esc, True)
    clock.advance(2.0)
    hk._on_release(Key.alt_r, False)

    hk._on_cancel.assert_not_called()
    hk._on_stop.assert_called_once()


def test_recording_restarts_cleanly_after_escape(hk, clock):
    hk._on_press(Key.alt_r)
    clock.advance(4.0)
    hk._on_press(Key.esc)
    hk._on_release(Key.alt_r)

    clock.advance(1.0)
    hk._on_press(Key.alt_r)
    clock.advance(3.0)
    hk._on_release(Key.alt_r)

    assert hk._on_start.call_count == 2
    hk._on_stop.assert_called_once()
    hk._on_cancel.assert_called_once_with("escape")


def test_escape_does_not_let_autorepeat_restart_recording():
    """A held non-modifier hotkey keeps firing press events.

    Escape clears the recording flag while the key is still physically down,
    so the next auto-repeat would otherwise start a second recording the user
    never asked for — right after they cancelled the first.
    """
    clock = FakeClock()
    m = HotkeyManager(
        on_start=MagicMock(),
        on_stop=MagicMock(),
        on_cancel=MagicMock(),
        hotkey="f5",
        clock=clock,
    )
    m._on_press(Key.f5)
    clock.advance(3.0)
    m._on_press(Key.esc)
    clock.advance(0.05)
    m._on_press(Key.f5)   # auto-repeat, key never released
    m._on_press(Key.f5)

    m._on_start.assert_called_once()

    m._on_release(Key.f5)
    m._on_stop.assert_not_called()

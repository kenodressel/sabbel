import logging
import time
from typing import Callable

from pynput.keyboard import Key, KeyCode, Listener

# Above this hold time a press is dictation, whatever else was typed during it.
# Measured against real usage: 36 genuine ⌥-combos spanned 0.142s-0.486s, while
# dictations wrongly discarded as combos ran 12s and 18s. 1.0s sits twice above
# the longest combo and an order of magnitude below the shortest dictation.
COMBO_MAX_HOLD_SECONDS = 1.0


def _parse_hotkey(name: str) -> Key | KeyCode:
    """Parse a hotkey name like 'alt_r', 'f5', or 'a' into a pynput key."""
    try:
        return Key[name]
    except KeyError:
        pass
    if len(name) == 1:
        return KeyCode.from_char(name)
    raise ValueError(f"Unknown hotkey: {name!r}. Use a pynput Key name (alt_r, f5, ctrl, ...) or a single character.")


class HotkeyManager:
    """Push-to-talk hotkey with combo detection.

    On a German (and most non-US) layout the right Option key is a live
    character modifier — ⌥L types @, ⌥E an accent, and so on. Treating every
    press as dictation means normal typing fires a burst of sub-second
    recordings that get rejected as "too short", each flashing an error.

    So recording still starts on press — waiting for a hold threshold would
    clip the first word — but if any other key arrives before release, the
    press was a character combo, not dictation, and the audio is discarded.

    That verdict is passed at *release*, not at the stray keystroke: typing a
    combo takes a fraction of a second, so a long hold is dictation no matter
    what got brushed during it. Judging at press time cost two real dictations
    of 12s and 18s, each killed by a key that landed in the first 66ms.

    Escape is the deliberate way out, and it works at any hold length.
    """

    def __init__(
        self,
        on_start: Callable,
        on_stop: Callable,
        on_cancel: Callable | None = None,
        hotkey: str = "alt_r",
        clock: Callable[[], float] = time.monotonic,
        combo_max_hold: float = COMBO_MAX_HOLD_SECONDS,
    ):
        self._on_start = on_start
        self._on_stop = on_stop
        # Callers that pass no on_cancel opt out of the distinction entirely;
        # swallow the reason so a plain on_stop still fits.
        self._on_cancel = on_cancel or (lambda reason="combo": on_stop())
        self._clock = clock
        self._combo_max_hold = combo_max_hold
        self._hotkey = _parse_hotkey(hotkey)
        self._recording = False
        self._hotkey_down = False
        self._combo = False
        self._press_time = 0.0
        self._listener: Listener | None = None

    def start(self):
        self._listener = Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._listener.daemon = True
        self._listener.start()

    def stop(self):
        if self._listener is not None:
            self._listener.stop()
            self._listener = None

    def _on_press(self, key, injected=False):
        # pynput passes an `injected` flag on macOS. Keystrokes synthesised by
        # other tools (Karabiner, text expanders, launchers) would otherwise
        # count as a combo and silently cancel the dictation in progress.
        if injected:
            return
        if key == self._hotkey:
            # Tracked separately from _recording: Escape clears _recording
            # while the key is still down, and a non-modifier hotkey keeps
            # auto-repeating until it is actually released.
            if not self._hotkey_down:
                logging.info("Hotkey press detected")
                self._hotkey_down = True
                self._recording = True
                self._combo = False
                self._press_time = self._clock()
                self._on_start()
        elif key == Key.esc and self._recording:
            # The deliberate way out — always wins, however long the hold.
            hold = self._clock() - self._press_time
            self._recording = False
            self._combo = False
            logging.info("Escape during hotkey hold (%.3fs) — cancelling", hold)
            self._on_cancel("escape")
        elif self._recording and not self._combo:
            # Another key while the hotkey is held — this may be ⌥+something
            # rather than dictation. Only the hold length at release decides.
            logging.info("Other key during hotkey hold — combo candidate")
            self._combo = True

    def _on_release(self, key, injected=False):
        if injected:
            return
        if key != self._hotkey:
            return
        self._hotkey_down = False
        if not self._recording:
            return
        self._recording = False
        hold = self._clock() - self._press_time
        if self._combo:
            self._combo = False
            if hold < self._combo_max_hold:
                logging.info(
                    "Hotkey released after combo (%.3fs) — discarding recording",
                    hold,
                )
                self._on_cancel("combo")
                return
            logging.info(
                "Other key ignored: %.3fs hold is dictation, not a combo", hold
            )
        logging.info("Hotkey release detected (%.3fs)", hold)
        self._on_stop()

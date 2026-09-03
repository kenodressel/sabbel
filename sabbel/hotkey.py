import logging
from typing import Callable

from pynput.keyboard import Key, KeyCode, Listener


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
    """

    def __init__(
        self,
        on_start: Callable,
        on_stop: Callable,
        on_cancel: Callable | None = None,
        hotkey: str = "alt_r",
    ):
        self._on_start = on_start
        self._on_stop = on_stop
        self._on_cancel = on_cancel or on_stop
        self._hotkey = _parse_hotkey(hotkey)
        self._recording = False
        self._combo = False
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

    def _on_press(self, key, *args):
        if key == self._hotkey:
            if not self._recording:
                logging.info("Hotkey press detected")
                self._recording = True
                self._combo = False
                self._on_start()
        elif self._recording and not self._combo:
            # Another key while the hotkey is held — this is ⌥+something,
            # not dictation.
            logging.info("Other key during hotkey hold — treating as combo")
            self._combo = True

    def _on_release(self, key, *args):
        if key != self._hotkey or not self._recording:
            return
        self._recording = False
        if self._combo:
            self._combo = False
            logging.info("Hotkey released after combo — discarding recording")
            self._on_cancel()
        else:
            logging.info("Hotkey release detected")
            self._on_stop()

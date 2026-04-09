import logging
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
    def __init__(self, on_start: callable, on_stop: callable, hotkey: str = "alt_r"):
        self._on_start = on_start
        self._on_stop = on_stop
        self._hotkey = _parse_hotkey(hotkey)
        self._recording = False
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
        if key == self._hotkey and not self._recording:
            logging.info("Hotkey press detected")
            self._recording = True
            self._on_start()

    def _on_release(self, key, *args):
        if key == self._hotkey and self._recording:
            logging.info("Hotkey release detected")
            self._recording = False
            self._on_stop()

import threading
from pynput.keyboard import Key, Listener


class HotkeyManager:
    def __init__(self, on_start: callable, on_stop: callable):
        self._on_start = on_start
        self._on_stop = on_stop
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
        if key == Key.alt_r and not self._recording:
            self._recording = True
            self._on_start()

    def _on_release(self, key, *args):
        if key == Key.alt_r and self._recording:
            self._recording = False
            self._on_stop()

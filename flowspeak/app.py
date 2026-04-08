import time
import threading
from pathlib import Path
import numpy as np
import rumps
from PyObjCTools.AppHelper import callAfter

from flowspeak.config import FlowSpeakConfig, load_config
from flowspeak.recorder import AudioRecorder
from flowspeak.transcriber import TranscriptionEngine
from flowspeak.hotkey import HotkeyManager
from flowspeak.injector import inject_text
from flowspeak.dictionary import load_dictionary, apply_replacements, get_initial_prompt

_ICONS_DIR = Path(__file__).resolve().parent.parent / "icons"

# Spinner frames for processing animation
_SPINNER = ["◐", "◓", "◑", "◒"]


class FlowSpeakApp(rumps.App):
    def __init__(self, config: FlowSpeakConfig):
        super().__init__(
            name="FlowSpeak",
            title="🎙",
            icon=None,
            template=False,
            quit_button="Quit",
        )
        self._config = config
        self._language = None  # Auto-detect by default

        # Dictionary
        self._dictionary = load_dictionary()

        # Menu — language cycle: Auto → Deutsch → English → Auto
        self._lang_item = rumps.MenuItem("Sprache: Auto")
        self.menu = [self._lang_item, None]

        # Components
        self._recorder = AudioRecorder(
            min_duration_seconds=config.min_duration_seconds,
        )
        self._transcriber = TranscriptionEngine(
            model_repo=config.model_repo,
            min_samples=int(config.min_duration_seconds * 16000),
        )
        self._hotkey = HotkeyManager(
            on_start=self._on_recording_start,
            on_stop=self._on_recording_stop,
        )

        # Worker thread event
        self._transcribe_event = threading.Event()
        self._worker_thread: threading.Thread | None = None
        self._running = True

        # Spinner state
        self._spinner_timer: rumps.Timer | None = None
        self._spinner_index = 0

        # Error reset timer
        self._error_timer: rumps.Timer | None = None

    @rumps.clicked("Sprache: Auto")
    def _toggle_language_auto(self, sender):
        self._cycle_language(sender)

    @rumps.clicked("Sprache: Deutsch")
    def _toggle_language_de(self, sender):
        self._cycle_language(sender)

    @rumps.clicked("Sprache: English")
    def _toggle_language_en(self, sender):
        self._cycle_language(sender)

    def _cycle_language(self, sender):
        if self._language is None:
            self._language = "de"
            sender.title = "Sprache: Deutsch"
        elif self._language == "de":
            self._language = "en"
            sender.title = "Sprache: English"
        else:
            self._language = None
            sender.title = "Sprache: Auto"

    def run(self, **kwargs):
        # Create error reset timer (stopped, reused)
        self._error_timer = rumps.Timer(self._clear_error, 2.0)

        # Start worker thread
        self._worker_thread = threading.Thread(
            target=self._transcription_worker, daemon=True
        )
        self._worker_thread.start()

        # Warm up model
        self.title = "⏳"
        threading.Thread(target=self._warmup, daemon=True).start()

        # Start hotkey listener
        self._hotkey.start()

        # Run main loop (blocks)
        super().run(**kwargs)

    def _warmup(self):
        self._transcriber.warmup()
        callAfter(self._set_idle)

    def _set_idle(self):
        self._stop_spinner()
        self._stop_error_timer()
        self.title = "🎙"

    def _show_error(self, message: str):
        """Show error in menu bar, auto-clear after 2 seconds."""
        self._stop_spinner()
        self.title = f"⚠️ {message}"
        # Restart the error timer
        self._stop_error_timer()
        self._error_timer = rumps.Timer(self._clear_error, 2.0)
        self._error_timer.start()

    def _clear_error(self, timer):
        timer.stop()
        self._set_idle()

    def _stop_error_timer(self):
        if self._error_timer and self._error_timer.is_alive():
            self._error_timer.stop()

    def _on_recording_start(self):
        """Called from pynput thread."""
        self._recorder.start()
        callAfter(self._set_recording)

    def _on_recording_stop(self):
        """Called from pynput thread."""
        self._recorder.stop()
        callAfter(self._set_working)
        self._transcribe_event.set()

    def _set_recording(self):
        self._stop_spinner()
        self._stop_error_timer()
        self.title = "🔴"

    def _set_working(self):
        self._spinner_index = 0
        self._spinner_timer = rumps.Timer(self._spin, 0.15)
        self._spinner_timer.start()

    def _spin(self, timer):
        self.title = _SPINNER[self._spinner_index % len(_SPINNER)]
        self._spinner_index += 1

    def _stop_spinner(self):
        if self._spinner_timer and self._spinner_timer.is_alive():
            self._spinner_timer.stop()
        self._spinner_timer = None

    def _transcription_worker(self):
        while self._running:
            self._transcribe_event.wait()
            self._transcribe_event.clear()

            if not self._running:
                break

            # Reload dictionary each time (hot-reload)
            self._dictionary = load_dictionary()
            initial_prompt = get_initial_prompt(self._dictionary)

            audio = self._recorder.get_audio()

            if not self._recorder.is_valid_duration(audio):
                callAfter(lambda: self._show_error("Zu kurz"))
                continue

            if not self._recorder.has_speech(audio):
                callAfter(lambda: self._show_error("Kein Audio"))
                continue

            try:
                text = self._transcriber.transcribe(
                    audio,
                    language=self._language,
                    initial_prompt=initial_prompt,
                )
            except Exception as e:
                print(f"Transcription error: {e}")
                callAfter(lambda: self._show_error("Fehler"))
                continue

            if not text:
                callAfter(lambda: self._show_error("Nicht erkannt"))
                continue

            # Apply dictionary replacements
            replacements = self._dictionary.get("replacements", {})
            if replacements:
                text = apply_replacements(text, replacements)

            callAfter(lambda t=text: self._do_inject(t))

    def _do_inject(self, text: str):
        inject_text(
            text,
            pre_paste_delay=self._config.pre_paste_delay,
            post_paste_delay=self._config.post_paste_delay,
        )
        self._set_idle()

    def terminate_(self, sender):
        self._running = False
        self._stop_spinner()
        self._stop_error_timer()
        self._transcribe_event.set()
        self._hotkey.stop()
        self._recorder.close()
        super().terminate_(sender)

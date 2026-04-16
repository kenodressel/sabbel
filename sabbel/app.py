import time
import threading
import logging
import numpy as np
import rumps
import sounddevice as sd
from PyObjCTools.AppHelper import callAfter

from sabbel.config import SabbelConfig
from sabbel.recorder import AudioRecorder
from sabbel.transcriber import TranscriptionEngine
from sabbel.hotkey import HotkeyManager
from sabbel.injector import inject_text
from sabbel.dictionary import load_dictionary, apply_replacements, get_initial_prompt
from sabbel.permissions import check_accessibility, check_microphone

# Spinner frames for processing animation
_SPINNER = ["◐", "◓", "◑", "◒"]


def _normalize_language(language: str | None) -> str | None:
    if language in {"de", "en"}:
        return language
    return None


def _language_menu_title(language: str | None) -> str:
    if language == "de":
        return "Sprache: Deutsch"
    if language == "en":
        return "Sprache: English"
    return "Sprache: Auto"


def _next_language(language: str | None) -> str | None:
    if language is None:
        return "de"
    if language == "de":
        return "en"
    return None


class SabbelApp(rumps.App):
    def __init__(self, config: SabbelConfig):
        super().__init__(
            name="Sabbel",
            title="🎙",
            icon=None,
            template=False,
            quit_button="Quit",
        )
        self._config = config
        self._language = _normalize_language(config.language)

        # Dictionary
        self._dictionary = load_dictionary()

        # Menu — language cycle: Auto → Deutsch → English → Auto
        self._status_item = rumps.MenuItem("Status: Starte")
        self._lang_item = rumps.MenuItem(_language_menu_title(self._language))
        self.menu = [self._status_item, self._lang_item, None]
        self._lang_item.set_callback(self._cycle_language)

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
            hotkey=config.hotkey,
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
        self._hotkey_started = False
        self._model_ready = False
        self._permission_thread: threading.Thread | None = None

    def _cycle_language(self, sender):
        self._language = _next_language(self._language)
        sender.title = _language_menu_title(self._language)

    def run(self, **kwargs):
        # Create error reset timer (stopped, reused)
        self._error_timer = rumps.Timer(self._clear_error, 2.0)

        # Start worker thread
        self._worker_thread = threading.Thread(
            target=self._transcription_worker, daemon=True
        )
        self._worker_thread.start()

        # Download + warm up model
        self.title = "⏳"
        self._set_status("Modell wird geladen...")
        threading.Thread(target=self._warmup, daemon=True).start()

        self._permission_thread = threading.Thread(
            target=self._monitor_permissions, daemon=True
        )
        self._permission_thread.start()

        # Run main loop (blocks)
        super().run(**kwargs)

    def _monitor_permissions(self):
        microphone_prompted = False
        accessibility_prompted = False
        while self._running and not self._hotkey_started:
            if not check_accessibility(prompt=not accessibility_prompted):
                accessibility_prompted = True
                callAfter(lambda: self._set_status("Accessibility fehlt"))
                time.sleep(1)
                continue

            if not check_microphone(request_if_needed=not microphone_prompted):
                microphone_prompted = True
                callAfter(lambda: self._set_status("Mikrofon fehlt"))
                time.sleep(1)
                continue

            self._hotkey.start()
            self._hotkey_started = True
            logging.info("Permissions ready; hotkey started")
            callAfter(lambda: self._set_status("Bereit"))

    def _set_status(self, message: str):
        self._status_item.title = f"Status: {message}"

    def _warmup(self):
        self._transcriber.warmup()
        self._model_ready = True
        logging.info("Whisper warmup completed")
        callAfter(self._set_idle)

    def _set_idle(self):
        self._stop_spinner()
        self._stop_error_timer()
        if self._hotkey_started:
            self._set_status("Bereit")
        self.title = "🎙"

    def _show_error(self, message: str):
        """Show error in menu bar, auto-clear after 2 seconds."""
        self._stop_spinner()
        logging.error("Sabbel error: %s", message)
        self._set_status(message)
        self.title = f"⚠️ {message}"
        # Restart the error timer
        self._stop_error_timer()
        self._error_timer = rumps.Timer(self._clear_error, 2.0)
        self._error_timer.start()

    def _notify_model_loading(self):
        try:
            rumps.notification(
                title="Sabbel",
                subtitle="Modell wird noch geladen",
                message="Bitte warte einen Moment. Das Icon wechselt zu 🎙 sobald Sabbel bereit ist.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send model-loading notification")

    def _notify_no_audio(self):
        try:
            rumps.notification(
                title="Sabbel",
                subtitle="Kein Audio erkannt",
                message="Ich habe beim letzten Versuch keine Sprache gehoert.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send no-audio notification")

    def _clear_error(self, timer):
        timer.stop()
        self._set_idle()

    def _stop_error_timer(self):
        if self._error_timer and self._error_timer.is_alive():
            self._error_timer.stop()

    def _on_recording_start(self):
        """Called from pynput thread."""
        if not self._model_ready:
            logging.info("Recording blocked: model still loading")
            callAfter(self._notify_model_loading)
            return
        logging.info("Recording start requested")
        try:
            self._recorder.start()
        except sd.PortAudioError as exc:
            logging.exception("Recorder error")
            callAfter(lambda: self._show_error("Mikrofonfehler"))
            return
        callAfter(self._set_recording)

    def _on_recording_stop(self):
        """Called from pynput thread."""
        logging.info("Recording stop requested")
        self._recorder.stop()
        callAfter(self._set_working)
        self._transcribe_event.set()

    def _set_recording(self):
        self._stop_spinner()
        self._stop_error_timer()
        self.title = "🔴"

    def _set_working(self):
        self._stop_spinner()
        self._spinner_index = 0
        self.title = _SPINNER[0]
        self._spinner_timer = rumps.Timer(self._spin, 0.15)
        self._spinner_timer.start()

    def _spin(self, timer):
        self._spinner_index = (self._spinner_index + 1) % len(_SPINNER)
        self.title = _SPINNER[self._spinner_index]

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
            audio_samples = len(audio)
            audio_duration = audio_samples / 16000 if audio_samples else 0.0
            audio_rms = (
                float(np.sqrt(np.mean(audio ** 2))) if audio_samples else 0.0
            )
            logging.info(
                "Processing recording: samples=%s duration=%.3fs rms=%.5f",
                audio_samples,
                audio_duration,
                audio_rms,
            )

            if not self._recorder.is_valid_duration(audio):
                logging.info("Recording rejected: too short")
                callAfter(lambda: self._show_error("Zu kurz"))
                continue

            if not self._recorder.has_speech(audio):
                logging.info("Recording rejected: no speech detected")
                callAfter(lambda: self._show_error("Kein Audio"))
                callAfter(self._notify_no_audio)
                continue

            try:
                text = self._transcriber.transcribe(
                    audio,
                    language=self._language,
                    initial_prompt=initial_prompt,
                )
            except Exception as e:
                logging.exception("Transcription error")
                callAfter(lambda: self._show_error("Fehler"))
                continue

            if not text:
                logging.info("Recording rejected: empty transcription")
                callAfter(lambda: self._show_error("Nicht erkannt"))
                continue

            # Apply dictionary replacements
            replacements = self._dictionary.get("replacements", {})
            if replacements:
                text = apply_replacements(text, replacements)

            logging.info("Transcription succeeded: chars=%s", len(text))
            callAfter(lambda t=text: self._do_inject(t))

    def _do_inject(self, text: str):
        pasted = inject_text(
            text,
            pre_paste_delay=self._config.pre_paste_delay,
            post_paste_delay=self._config.post_paste_delay,
        )
        if not pasted:
            try:
                rumps.notification(
                    title="Sabbel",
                    subtitle="Text im Clipboard",
                    message="Kein Textfeld erkannt. Mit Cmd+V einfuegen.",
                    sound=False,
                )
            except Exception:
                logging.exception("Failed to send clipboard notification")
        self._set_idle()

    def terminate_(self, sender):
        self._running = False
        self._stop_spinner()
        self._stop_error_timer()
        self._hotkey.stop()
        self._transcribe_event.set()
        if self._worker_thread is not None and self._worker_thread.is_alive():
            self._worker_thread.join(timeout=1.0)
        self._recorder.close()
        super().terminate_(sender)

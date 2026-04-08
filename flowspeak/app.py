import threading
import numpy as np
import rumps
from PyObjCTools.AppHelper import callAfter

from flowspeak.config import FlowSpeakConfig, load_config
from flowspeak.recorder import AudioRecorder
from flowspeak.transcriber import TranscriptionEngine
from flowspeak.hotkey import HotkeyManager
from flowspeak.injector import inject_text


class FlowSpeakApp(rumps.App):
    def __init__(self, config: FlowSpeakConfig):
        super().__init__(
            name="FlowSpeak",
            title=None,
            icon="icons/mic_idle.png",
            template=True,
            quit_button="Quit",
        )
        self._config = config
        self._language = config.language

        # Menu
        self._lang_item = rumps.MenuItem(
            f"Sprache: {'Deutsch' if self._language == 'de' else 'English'}"
        )
        self.menu = [self._lang_item, None]

        # Components (initialized but not started)
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

    @rumps.clicked("Sprache: Deutsch")
    def _toggle_language_de(self, sender):
        self._toggle_language(sender)

    @rumps.clicked("Sprache: English")
    def _toggle_language_en(self, sender):
        self._toggle_language(sender)

    def _toggle_language(self, sender):
        if self._language == "de":
            self._language = "en"
            sender.title = "Sprache: English"
        else:
            self._language = "de"
            sender.title = "Sprache: Deutsch"

    def run(self, **kwargs):
        # Start worker thread
        self._worker_thread = threading.Thread(
            target=self._transcription_worker, daemon=True
        )
        self._worker_thread.start()

        # Warm up model
        self.title = "Loading..."
        threading.Thread(target=self._warmup, daemon=True).start()

        # Start hotkey listener
        self._hotkey.start()

        # Run main loop (blocks)
        super().run(**kwargs)

    def _warmup(self):
        self._transcriber.warmup()
        callAfter(self._set_idle)

    def _set_idle(self):
        self.title = None
        self.icon = "icons/mic_idle.png"

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
        self.icon = "icons/mic_recording.png"
        self.title = "Rec..."

    def _set_working(self):
        self.icon = "icons/mic_working.png"
        self.title = "..."

    def _transcription_worker(self):
        while self._running:
            self._transcribe_event.wait()
            self._transcribe_event.clear()

            if not self._running:
                break

            audio = self._recorder.get_audio()

            if not self._recorder.is_valid_duration(audio):
                callAfter(self._set_idle)
                continue

            try:
                text = self._transcriber.transcribe(audio, language=self._language)
            except Exception as e:
                print(f"Transcription error: {e}")
                callAfter(self._set_idle)
                continue

            if text:
                callAfter(
                    lambda t=text: self._do_inject(t)
                )
            else:
                callAfter(self._set_idle)

    def _do_inject(self, text: str):
        inject_text(
            text,
            pre_paste_delay=self._config.pre_paste_delay,
            post_paste_delay=self._config.post_paste_delay,
        )
        self._set_idle()

    def terminate_(self, sender):
        self._running = False
        self._transcribe_event.set()
        self._hotkey.stop()
        self._recorder.close()
        super().terminate_(sender)

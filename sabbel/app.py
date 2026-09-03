import time
import queue
import threading
import logging
import subprocess
from datetime import datetime
from pathlib import Path
import numpy as np
import rumps
import sounddevice as sd
import objc
from Foundation import NSObject
from PyObjCTools.AppHelper import callAfter

from sabbel.config import SabbelConfig
from sabbel.recorder import AudioRecorder, list_input_devices
from sabbel.transcriber import TranscriptionEngine
from sabbel.hotkey import HotkeyManager
from sabbel import injector
from sabbel.injector import capture_focus_target, inject_text
from sabbel.permissions import check_accessibility, check_microphone
from sabbel.preferences import load_preferences, save_preference

# Spinner frames for processing animation
_SPINNER = ["◐", "◓", "◑", "◒"]


class _MicMenuDelegate(NSObject):
    """NSMenuDelegate that asks the app to rebuild the mic submenu before display."""

    def initWithCallback_(self, callback):
        self = objc.super(_MicMenuDelegate, self).init()
        if self is None:
            return None
        self._callback = callback
        return self

    def menuWillOpen_(self, menu):
        try:
            self._callback()
        except Exception:
            logging.exception("Mic menu refresh failed")


def _build_mic_menu_spec(devices: list[dict], selected: str | None) -> list[dict]:
    """Build a structured spec for the Microphone submenu.

    Pure function so the build logic is testable without instantiating rumps.

    Args:
        devices: from `list_input_devices()`, may be empty.
        selected: persisted user preference (device name) or `None` for default.

    Returns:
        A list of items, each a dict with a `"kind"` discriminator:
          - `{"kind": "device", "name": str | None, "label": str, "checked": bool}`
          - `{"kind": "separator"}`
          - `{"kind": "offline", "label": str}`  (non-clickable header)
    """
    device_names = {d["name"] for d in devices}
    spec: list[dict] = []

    saved_offline = selected is not None and selected not in device_names
    if saved_offline:
        spec.append({"kind": "offline", "label": f"Saved: {selected} (offline)"})
        spec.append({"kind": "separator"})

    # Default is active either when explicitly chosen (selected is None) or
    # when the saved device is offline (fell back at runtime).
    default_active = selected is None or saved_offline
    spec.append({
        "kind": "device",
        "name": None,
        "label": "System Default",
        "checked": default_active,
    })

    if devices:
        spec.append({"kind": "separator"})
        for d in sorted(devices, key=lambda x: x["name"].lower()):
            spec.append({
                "kind": "device",
                "name": d["name"],
                "label": d["name"],
                "checked": (d["name"] == selected),
            })

    return spec


_UPDATE_CHECK_INTERVAL_SECONDS = 24 * 3600
_UPDATE_STATE_PATH = Path.home() / ".config" / "sabbel" / "update-check.json"
_RELEASES_LATEST_URL = (
    "https://api.github.com/repos/kenodressel/sabbel/releases/latest"
)


def _parse_version(s: str) -> tuple | None:
    """Parse a version string to a sortable tuple.

    Handles:
      - "1.2.3"           → ((1, 2, 3), 1)   # release
      - "v1.2.3"          → ((1, 2, 3), 1)
      - "1.2"             → ((1, 2, 0), 1)   # padded to 3 parts
      - "1.2.3-rc1"       → ((1, 2, 3), 0)   # prereleases sort < release
      - "1.2.3+build.5"   → ((1, 2, 3), 1)   # build metadata ignored
      - "dev" / garbage   → None

    The second tuple element (0 for prerelease, 1 for release) makes
    "1.2.3-rc1" < "1.2.3", matching SemVer ordering.
    """
    if not isinstance(s, str):
        return None
    core = s.strip().lstrip("v").split("-", 1)[0].split("+", 1)[0]
    if not core:
        return None
    try:
        parts = [int(p) for p in core.split(".")]
    except ValueError:
        return None
    while len(parts) < 3:
        parts.append(0)
    is_prerelease = "-" in s
    return (tuple(parts), 0 if is_prerelease else 1)


def _is_newer(latest: str, current: str) -> bool:
    """True iff `latest` parses to a strictly newer version than `current`."""
    l = _parse_version(latest)
    c = _parse_version(current)
    if l is None or c is None:
        return False
    return l > c


def _should_check_update(state_path: Path, now: float, interval: float) -> bool:
    """Read throttle state and decide whether we're due for a check."""
    if not state_path.exists():
        return True
    try:
        import json as _json
        data = _json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        return True
    last = data.get("last_check", 0)
    try:
        return (now - float(last)) >= interval
    except (TypeError, ValueError):
        return True


def _record_update_check(state_path: Path, now: float) -> None:
    try:
        import json as _json
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(
            _json.dumps({"last_check": now}), encoding="utf-8"
        )
    except Exception:
        logging.debug("Failed to record update check", exc_info=True)


def _append_history(path: Path, text: str, max_bytes: int) -> None:
    """Append `text` to the history file, rotating once if it would grow
    past `max_bytes`. Rotation keeps exactly one backup at `path.1`.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.stat().st_size > max_bytes:
        backup = path.with_name(path.name + ".1")
        if backup.exists():
            backup.unlink()
        path.rename(backup)
    # Force UTF-8 — the py2app bundle launches without a UTF-8 locale, so
    # Python's default open() falls back to ASCII and crashes on any umlaut.
    with open(path, "a", encoding="utf-8") as f:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        f.write(f"--- {ts} ---\n{text}\n\n")


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

        # History (opt-in; toggleable via menu, persisted to preferences.json)
        self._history_path = Path.home() / ".config" / "sabbel" / "history.log"
        prefs = load_preferences()
        self._history_enabled = prefs.get("history_enabled", config.history_enabled)
        self._audio_device: str | None = prefs.get("audio_device")

        from sabbel import __version__
        self._version = __version__
        self._latest_version: str | None = None
        self._status_item = rumps.MenuItem("Status: Starting")
        self._version_item = rumps.MenuItem(f"v{__version__}")
        menu_items: list = [self._status_item]

        # History submenu: always visible so users can discover the feature.
        # "Save history" is a checkable toggle that writes to preferences.json.
        history_item = rumps.MenuItem("History")
        self._history_toggle = rumps.MenuItem(
            "Save history", callback=self._toggle_history
        )
        self._history_toggle.state = 1 if self._history_enabled else 0
        history_item.add(self._history_toggle)
        history_item.add(rumps.MenuItem("Open log", callback=self._open_history))
        history_item.add(rumps.MenuItem("Clear log", callback=self._clear_history))
        menu_items.append(history_item)
        # Maps menu-item label → device name (None for "System Default").
        # Built by _rebuild_mic_menu; consumed by _on_mic_select.
        self._mic_device_map: dict[str, str | None] = {}
        # Microphone submenu — built fresh on every menu-open via NSMenuDelegate.
        # Initial population is deferred until after `self.menu = menu_items`
        # because rumps only attaches the backing NSMenu when the MenuItem is
        # added to a parent menu — calling .clear() before then explodes.
        self._mic_menu = rumps.MenuItem("Microphone")
        menu_items.append(self._mic_menu)
        self._mic_manual_refresh = False
        self._notified_missing_device: str | None = None
        # Update check only makes sense on built releases, not local dev runs.
        if self._version != "dev":
            self._update_item = rumps.MenuItem(
                "Check for updates", callback=self._on_update_click
            )
            menu_items.append(self._update_item)
        else:
            self._update_item = None
        menu_items.extend([None, self._version_item])
        self.menu = menu_items
        self._rebuild_mic_menu()
        self._mic_delegate = None  # Hold ref so PyObjC doesn't release it.
        self._attach_mic_menu_delegate()

        # Components
        self._recorder = AudioRecorder(
            min_duration_seconds=config.min_duration_seconds,
            device=self._audio_device,
        )
        self._transcriber = TranscriptionEngine(
            model_repo=config.model_repo,
            min_samples=int(config.min_duration_seconds * 16000),
        )
        self._hotkey = HotkeyManager(
            on_start=self._on_recording_start,
            on_stop=self._on_recording_stop,
            on_cancel=self._on_recording_cancel,
            hotkey=config.hotkey,
        )

        # Worker thread event
        # Finished takes, each carrying its own audio AND the app that was
        # focused when it started. A shared slot would let a second press
        # overwrite the first take's target while it is still transcribing.
        self._takes: queue.Queue = queue.Queue()
        self._worker_thread: threading.Thread | None = None
        self._running = True

        # Spinner state
        self._spinner_timer: rumps.Timer | None = None
        self._spinner_index = 0

        # Error reset timer
        self._error_timer: rumps.Timer | None = None
        self._hotkey_started = False
        self._model_ready = False
        # App captured at record start; the transcription is pasted back there.
        self._focus_target: dict | None = None
        # True only between a successful recorder start and its stop, so a
        # release that follows a blocked start doesn't queue an empty buffer.
        self._capturing = False
        # Sticky: the model never loaded, so no amount of waiting fixes it.
        self._model_failed = False
        self._permission_thread: threading.Thread | None = None

    def _attach_mic_menu_delegate(self):
        """Hook NSMenuDelegate.menuWillOpen_ so the device list refreshes
        on every menu-open. If anything in this PyObjC plumbing fails,
        fall back to a manual 'Refresh devices' item appended to the submenu.
        """
        try:
            ns_menu = self._mic_menu._menuitem.submenu()
            if ns_menu is None:
                raise RuntimeError("No submenu present yet")
            delegate = _MicMenuDelegate.alloc().initWithCallback_(
                self._rebuild_mic_menu
            )
            ns_menu.setDelegate_(delegate)
            self._mic_delegate = delegate
        except Exception:
            logging.warning(
                "NSMenuDelegate hookup failed, falling back to manual refresh",
                exc_info=True,
            )
            self._mic_manual_refresh = True
            self._add_mic_refresh_item()

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
        self._set_status("Loading model...")
        threading.Thread(target=self._warmup, daemon=True).start()

        self._permission_thread = threading.Thread(
            target=self._monitor_permissions, daemon=True
        )
        self._permission_thread.start()

        # Background update check (throttled, skipped on dev builds)
        if self._update_item is not None:
            threading.Thread(target=self._check_for_update, daemon=True).start()

        # Run main loop (blocks)
        super().run(**kwargs)

    def _monitor_permissions(self):
        microphone_prompted = False
        accessibility_prompted = False
        while self._running and not self._hotkey_started:
            if not check_accessibility(prompt=not accessibility_prompted):
                accessibility_prompted = True
                callAfter(lambda: self._set_status("Accessibility missing"))
                time.sleep(1)
                continue

            if not check_microphone(request_if_needed=not microphone_prompted):
                microphone_prompted = True
                callAfter(lambda: self._set_status("Microphone missing"))
                time.sleep(1)
                continue

            self._hotkey.start()
            self._hotkey_started = True
            logging.info("Permissions ready; hotkey started")
            callAfter(lambda: self._set_status("Ready"))

    def _set_status(self, message: str):
        self._status_item.title = f"Status: {message}"

    def _warmup(self):
        try:
            self._transcriber.warmup()
        except Exception as exc:
            # Runs on a daemon thread: without this the thread dies silently,
            # _model_ready stays False, and the app sits at "Loading model..."
            # forever while every hotkey press is logged as "blocked".
            logging.exception("Model warmup failed")
            self._model_failed = True
            # Deliberately not _show_error: that auto-clears to "Ready" after
            # two seconds, which would claim the app works while every hotkey
            # press is refused.
            callAfter(self._set_model_failed)
            callAfter(lambda m=str(exc): self._notify_model_failed(m))
            return
        self._model_ready = True
        logging.info("%s warmup completed", type(self._transcriber).__name__)
        callAfter(self._set_idle)

    def _set_model_failed(self) -> None:
        """Persistent failure state — survives the error timer."""
        self._stop_spinner()
        self._stop_error_timer()
        self.title = "⚠️"
        self._set_status("Model failed — restart Sabbel")

    def _notify_model_failed(self, message: str) -> None:
        try:
            rumps.notification(
                title="Sabbel",
                subtitle="Model could not be loaded",
                message=message[:200],
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send model failure notification")

    def _save_to_history(self, text: str) -> None:
        if not self._history_enabled:
            return
        try:
            _append_history(
                self._history_path,
                text,
                self._config.history_max_bytes,
            )
        except Exception:
            logging.warning("Failed to save to history", exc_info=True)

    def _toggle_history(self, sender):
        self._history_enabled = not self._history_enabled
        sender.state = 1 if self._history_enabled else 0
        save_preference("history_enabled", self._history_enabled)

    def _open_history(self, _):
        if self._history_path.exists():
            subprocess.Popen(["open", str(self._history_path)])
        else:
            subprocess.Popen(["open", str(self._history_path.parent)])

    def _clear_history(self, _):
        try:
            self._history_path.unlink(missing_ok=True)
            backup = self._history_path.with_name(self._history_path.name + ".1")
            backup.unlink(missing_ok=True)
            rumps.notification(
                title="Sabbel",
                subtitle="History cleared",
                message="",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to clear history")

    def _rebuild_mic_menu(self):
        """Repopulate the Microphone submenu from current device state."""
        # Force PortAudio to re-enumerate so devices connected after Sabbel
        # started (AirPods, dock-mic, USB cameras) become visible. Without
        # this the submenu would reflect the device list from app launch.
        # First call is from __init__ before self._recorder exists; PA was
        # just initialized at import time so no refresh is needed there.
        if hasattr(self, "_recorder"):
            self._recorder.refresh_devices()
        devices = list_input_devices()
        spec = _build_mic_menu_spec(devices=devices, selected=self._audio_device)
        self._mic_device_map.clear()
        # rumps' Menu.clear() crashes when the underlying NSMenu hasn't been
        # created yet — that's the case on the very first build, before any
        # item has been added. Skip clear in that case.
        if len(self._mic_menu) > 0:
            self._mic_menu.clear()
        for item in spec:
            if item["kind"] == "separator":
                self._mic_menu.add(rumps.separator)
                continue
            if item["kind"] == "offline":
                # Greyed/non-clickable header. rumps doesn't auto-disable items
                # without callbacks (they stay enabled but do nothing on click),
                # so we disable via the underlying NSMenuItem explicitly.
                header = rumps.MenuItem(item["label"])
                header._menuitem.setEnabled_(False)
                self._mic_menu.add(header)
                continue
            # device
            menu_item = rumps.MenuItem(
                item["label"],
                callback=self._on_mic_select,
            )
            menu_item.state = 1 if item["checked"] else 0
            self._mic_device_map[item["label"]] = item["name"]
            self._mic_menu.add(menu_item)
        if getattr(self, "_mic_manual_refresh", False):
            self._add_mic_refresh_item()

    def _add_mic_refresh_item(self):
        self._mic_menu.add(rumps.separator)
        self._mic_menu.add(
            rumps.MenuItem(
                "Refresh devices",
                callback=lambda _: self._rebuild_mic_menu(),
            )
        )

    def _on_mic_select(self, sender):
        new_device = self._mic_device_map.get(sender.title)
        if new_device == self._audio_device:
            return
        self._audio_device = new_device
        self._notified_missing_device = None
        self._recorder.set_device(new_device)
        save_preference("audio_device", new_device)
        self._rebuild_mic_menu()

    def _on_update_click(self, _):
        """Click handler for the update menu item.

        If we already know an update is available, open the release page;
        otherwise trigger a forced re-check in the background.
        """
        if self._latest_version:
            subprocess.Popen([
                "open",
                f"https://github.com/kenodressel/sabbel/releases/tag/v{self._latest_version}",
            ])
        else:
            threading.Thread(
                target=lambda: self._check_for_update(force=True),
                daemon=True,
            ).start()

    def _check_for_update(self, force: bool = False) -> None:
        """Query the GitHub Releases API, throttled to once per day."""
        if self._version == "dev":
            return
        now = time.time()
        if not force and not _should_check_update(
            _UPDATE_STATE_PATH, now, _UPDATE_CHECK_INTERVAL_SECONDS
        ):
            return
        try:
            import urllib.request
            import json as _json
            req = urllib.request.Request(
                _RELEASES_LATEST_URL,
                headers={"Accept": "application/vnd.github.v3+json"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = _json.loads(resp.read())
        except Exception:
            logging.debug("Update check failed", exc_info=True)
            return
        _record_update_check(_UPDATE_STATE_PATH, now)
        latest = (data.get("tag_name") or "").lstrip("v")
        if not latest:
            return
        if _is_newer(latest, self._version):
            logging.info(
                "Update available: v%s (current: v%s)", latest, self._version
            )
            callAfter(lambda: self._announce_update(latest))

    def _announce_update(self, latest: str) -> None:
        self._latest_version = latest
        if self._update_item is not None:
            self._update_item.title = f"Update v{latest} available"
        try:
            rumps.notification(
                title="Sabbel",
                subtitle=f"Update v{latest} available",
                message="Click 'Update' in the Sabbel menu for details.",
                sound=False,
            )
        except Exception:
            logging.debug("Update notification failed", exc_info=True)

    def _set_idle(self):
        self._stop_spinner()
        self._stop_error_timer()
        if self._model_failed:
            # Never report "Ready" when every press will be refused.
            return
        if self._hotkey_started:
            self._set_status("Ready")
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
                subtitle="Model still loading",
                message="Please wait. The icon will change to 🎙 when Sabbel is ready.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send model-loading notification")

    def _notify_dead_stream(self) -> None:
        try:
            rumps.notification(
                title="Sabbel",
                subtitle="Microphone delivered no signal",
                message="Check that the mic isn't muted and input volume isn't zero.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send dead-stream notification")

    def _notify_no_audio(self):
        try:
            rumps.notification(
                title="Sabbel",
                subtitle="No audio detected",
                message="No speech was detected in the last recording.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send no-audio notification")

    def _notify_mic_fallback(self, expected_name: str):
        try:
            rumps.notification(
                title="Sabbel",
                subtitle=f"Mic '{expected_name}' not found",
                message="Using system default. Pick another mic from the Sabbel menu.",
                sound=False,
            )
        except Exception:
            logging.exception("Failed to send mic-fallback notification")

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
        # Snapshot the target app now: transcription takes seconds and the user
        # often switches windows while it runs.
        self._focus_target = capture_focus_target()
        try:
            self._recorder.start()
            self._capturing = True
        except sd.PortAudioError:
            logging.exception("Recorder error")
            self._recorder.last_missing_device = None
            callAfter(lambda: self._show_error("Mic error"))
            return
        missing = self._recorder.last_missing_device
        if missing:
            self._recorder.last_missing_device = None
            if missing != self._notified_missing_device:
                self._notified_missing_device = missing
                callAfter(lambda name=missing: self._notify_mic_fallback(name))
        else:
            self._notified_missing_device = None
        callAfter(self._set_recording)

    def _on_recording_stop(self):
        """Called from pynput thread."""
        if not self._capturing:
            logging.info("Recording stop ignored — capture never started")
            return
        self._capturing = False
        logging.info("Recording stop requested")
        self._recorder.stop()
        # Drain here, on the thread that owns the take, so audio and focus
        # target travel together and no second drain can race this one.
        self._takes.put((self._recorder.get_audio(), self._focus_target))
        callAfter(self._set_working)

    def _on_recording_cancel(self):
        """Hotkey was released after a combo — drop the audio, transcribe nothing.

        Called from the pynput thread.
        """
        if not self._capturing:
            return
        self._capturing = False
        self._recorder.stop()
        self._recorder.get_audio()  # drain, so it can't leak into the next take
        callAfter(self._set_idle)

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
            take = self._takes.get()
            if take is None or not self._running:
                break
            audio, target = take

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
                callAfter(lambda: self._show_error("Too short"))
                continue

            if self._recorder.is_dead_stream(audio):
                logging.warning("Capture returned pure silence — mic muted or stream dead")
                callAfter(lambda: self._show_error("No signal"))
                callAfter(self._notify_dead_stream)
                continue

            if not self._recorder.has_speech(audio):
                logging.info("Recording rejected: no speech detected")
                callAfter(lambda: self._show_error("No audio"))
                callAfter(self._notify_no_audio)
                continue

            try:
                text = self._transcriber.transcribe(audio)
            except Exception:
                logging.exception("Transcription error")
                callAfter(lambda: self._show_error("Error"))
                continue

            if not text:
                logging.info("Recording rejected: empty transcription")
                callAfter(lambda: self._show_error("Not recognized"))
                continue

            logging.info("Transcription succeeded: chars=%s", len(text))
            self._save_to_history(text)
            callAfter(lambda t=text, g=target: self._do_inject(t, g))

    # Each outcome needs its own wording — telling someone their text is in the
    # clipboard when we deliberately withheld it from a password field is worse
    # than saying nothing.
    _INJECT_NOTICES = {
        injector.LEFT_IN_CLIPBOARD: (
            "Text copied to clipboard",
            "No text field detected. Paste manually with Cmd+V.",
        ),
        injector.FOCUS_CHANGED: (
            "Text copied to clipboard",
            "You switched apps while it was transcribing. Paste with Cmd+V.",
        ),
        injector.REFUSED_SECURE: (
            "Dictation discarded",
            "Sabbel does not type into password fields.",
        ),
    }

    def _do_inject(self, text: str, target: dict | None = None):
        try:
            outcome = inject_text(
                text,
                pre_paste_delay=self._config.pre_paste_delay,
                post_paste_delay=self._config.post_paste_delay,
                target=target,
            )
        except Exception:
            # Unguarded PyObjC here would leave the spinner running forever.
            logging.exception("Text injection failed")
            self._show_error("Paste failed")
            return
        notice = self._INJECT_NOTICES.get(outcome)
        if notice is not None:
            subtitle, message = notice
            try:
                rumps.notification(
                    title="Sabbel",
                    subtitle=subtitle,
                    message=message,
                    sound=False,
                )
            except Exception:
                logging.exception("Failed to send injection notification")
        self._set_idle()

    def terminate_(self, sender):
        self._running = False
        self._stop_spinner()
        self._stop_error_timer()
        self._hotkey.stop()
        self._takes.put(None)
        if self._worker_thread is not None and self._worker_thread.is_alive():
            self._worker_thread.join(timeout=1.0)
        self._recorder.close()
        super().terminate_(sender)

import sys
import types
from unittest.mock import MagicMock, patch

sys.modules.setdefault(
    "AVFoundation",
    types.SimpleNamespace(
        AVCaptureDevice=types.SimpleNamespace(),
        AVMediaTypeAudio="audio",
        AVAuthorizationStatusAuthorized=1,
        AVAuthorizationStatusNotDetermined=0,
    ),
)
sys.modules.setdefault(
    "HIServices",
    types.SimpleNamespace(
        kAXTrustedCheckOptionPrompt="prompt",
        AXIsProcessTrustedWithOptions=lambda _options: True,
    ),
)

from sabbel.app import (
    SabbelApp,
    _append_history,
    _is_newer,
    _parse_version,
    _record_update_check,
    _should_check_update,
)


@patch("sabbel.app.time.sleep")
@patch("sabbel.app.callAfter", side_effect=lambda fn: fn())
@patch("sabbel.app.check_microphone", return_value=False)
@patch("sabbel.app.check_accessibility", return_value=True)
def test_permission_monitor_does_not_start_hotkey_without_microphone(
    _mock_accessibility,
    _mock_microphone,
    _mock_call_after,
    mock_sleep,
):
    app = SabbelApp.__new__(SabbelApp)
    app._running = True
    app._hotkey_started = False
    app._hotkey = MagicMock()
    app._set_status = MagicMock()

    def stop_loop(_seconds):
        app._running = False

    mock_sleep.side_effect = stop_loop

    app._monitor_permissions()

    app._hotkey.start.assert_not_called()
    assert app._hotkey_started is False
    app._set_status.assert_called_with("Microphone missing")


@patch("sabbel.app.time.sleep")
@patch("sabbel.app.callAfter", side_effect=lambda fn: fn())
@patch("sabbel.app.check_microphone", return_value=True)
@patch("sabbel.app.check_accessibility", return_value=True)
def test_permission_monitor_starts_hotkey_once_permissions_are_ready(
    _mock_accessibility,
    _mock_microphone,
    _mock_call_after,
    _mock_sleep,
):
    app = SabbelApp.__new__(SabbelApp)
    app._running = True
    app._hotkey_started = False
    app._hotkey = MagicMock()
    app._set_status = MagicMock()

    app._monitor_permissions()

    app._hotkey.start.assert_called_once()
    assert app._hotkey_started is True
    app._set_status.assert_called_with("Ready")


def test_append_history_creates_file_and_appends(tmp_path):
    path = tmp_path / "subdir" / "history.log"

    _append_history(path, "first", max_bytes=10_000)
    _append_history(path, "second", max_bytes=10_000)

    content = path.read_text()
    assert "first" in content
    assert "second" in content
    # Each entry has a timestamp header and trailing blank line
    assert content.count("---") == 4


def test_append_history_rotates_when_over_max_bytes(tmp_path):
    path = tmp_path / "history.log"
    # Pre-fill with >max_bytes so the next call triggers rotation
    path.write_text("x" * 200)

    _append_history(path, "after-rotation", max_bytes=100)

    backup = path.with_name("history.log.1")
    assert backup.exists(), "old content should be rotated to .1"
    assert backup.read_text() == "x" * 200
    # New file contains only the most recent entry
    assert "after-rotation" in path.read_text()
    assert "x" * 200 not in path.read_text()


def test_append_history_preserves_umlauts_under_ascii_locale(tmp_path, monkeypatch):
    """Regression: py2app launches without a UTF-8 locale, so every
    text-mode open() that doesn't pass encoding="utf-8" falls back to
    ASCII and crashes on the first umlaut. This was silently losing
    any German transcription from the history log.

    We simulate that environment by intercepting builtins.open and
    forcing ASCII whenever the caller didn't specify an encoding.
    """
    import builtins
    real_open = builtins.open

    def ascii_open(*args, **kwargs):
        mode = kwargs.get("mode") or (args[1] if len(args) > 1 else "r")
        if "b" not in mode and "encoding" not in kwargs:
            kwargs["encoding"] = "ascii"
        return real_open(*args, **kwargs)

    monkeypatch.setattr(builtins, "open", ascii_open)

    path = tmp_path / "history.log"
    _append_history(path, "Säulenzuschläge und Überweisung", max_bytes=10_000)

    content = path.read_text(encoding="utf-8")
    assert "Säulenzuschläge" in content
    assert "Überweisung" in content


def test_append_history_replaces_existing_backup(tmp_path):
    path = tmp_path / "history.log"
    backup = path.with_name("history.log.1")
    backup.write_text("stale-backup")
    path.write_text("x" * 200)

    _append_history(path, "new", max_bytes=100)

    # Old backup must be replaced by the rotated current file, not appended
    assert backup.read_text() == "x" * 200


def test_save_to_history_skips_when_disabled(tmp_path):
    app = SabbelApp.__new__(SabbelApp)
    app._config = MagicMock(history_max_bytes=1_000_000)
    app._history_enabled = False
    app._history_path = tmp_path / "history.log"

    app._save_to_history("hello")

    assert not app._history_path.exists()


def test_save_to_history_writes_when_enabled(tmp_path):
    app = SabbelApp.__new__(SabbelApp)
    app._config = MagicMock(history_max_bytes=1_000_000)
    app._history_enabled = True
    app._history_path = tmp_path / "history.log"

    app._save_to_history("hello")

    assert "hello" in app._history_path.read_text()


def test_toggle_history_flips_state_and_persists(tmp_path):
    from sabbel import app as app_module
    app = SabbelApp.__new__(SabbelApp)
    app._history_enabled = False

    prefs_file = tmp_path / "preferences.json"
    with patch.object(app_module, "save_preference") as mock_save:
        sender = MagicMock(state=0)
        app._toggle_history(sender)

        assert app._history_enabled is True
        assert sender.state == 1
        mock_save.assert_called_once_with("history_enabled", True)

        app._toggle_history(sender)
        assert app._history_enabled is False
        assert sender.state == 0


def test_parse_version_handles_common_forms():
    assert _parse_version("1.2.3") == ((1, 2, 3), 1)
    assert _parse_version("v1.2.3") == ((1, 2, 3), 1)
    assert _parse_version("1.2") == ((1, 2, 0), 1)
    assert _parse_version("1") == ((1, 0, 0), 1)
    # Build metadata and whitespace are stripped
    assert _parse_version("  1.2.3+build.5  ") == ((1, 2, 3), 1)


def test_parse_version_rejects_garbage():
    assert _parse_version("dev") is None
    assert _parse_version("") is None
    assert _parse_version("not.a.version") is None
    assert _parse_version(None) is None


def test_parse_version_prerelease_sorts_below_release():
    assert _parse_version("1.2.3-rc1") == ((1, 2, 3), 0)
    assert _parse_version("1.2.3-beta.2") == ((1, 2, 3), 0)
    assert _parse_version("1.2.3-rc1") < _parse_version("1.2.3")


def test_is_newer_compares_correctly():
    assert _is_newer("0.2.0", "0.1.5")
    assert _is_newer("1.0.0", "0.9.9")
    assert not _is_newer("0.1.5", "0.1.5")
    assert not _is_newer("0.1.4", "0.1.5")
    # Prerelease is never newer than release of same numeric version
    assert not _is_newer("1.2.3-rc1", "1.2.3")
    # But a release is newer than its own prerelease
    assert _is_newer("1.2.3", "1.2.3-rc1")
    # Unparseable versions → False (don't claim an update)
    assert not _is_newer("1.0.0", "dev")
    assert not _is_newer("garbage", "1.0.0")


def test_should_check_update_no_state_file(tmp_path):
    state = tmp_path / "update-check.json"
    assert _should_check_update(state, now=1_000_000.0, interval=86400) is True


def test_should_check_update_respects_interval(tmp_path):
    state = tmp_path / "update-check.json"
    _record_update_check(state, now=1_000_000.0)

    # One second later — still throttled
    assert _should_check_update(state, now=1_000_001.0, interval=86400) is False
    # After the interval — due again
    assert _should_check_update(state, now=1_086_401.0, interval=86400) is True


def test_should_check_update_handles_corrupt_state(tmp_path):
    state = tmp_path / "update-check.json"
    state.write_text("not valid json {{{")

    # Corrupt state → fall through to "check anyway", don't crash
    assert _should_check_update(state, now=1_000_000.0, interval=86400) is True


def test_record_update_check_creates_parent(tmp_path):
    state = tmp_path / "nested" / "update-check.json"

    _record_update_check(state, now=1_234_567.0)

    assert state.exists()
    import json
    assert json.loads(state.read_text())["last_check"] == 1_234_567.0


# --- take handoff: audio and focus target must travel together --------------


def _wired_app():
    """A SabbelApp with just the recording/worker wiring populated."""
    import queue as _queue

    app = SabbelApp.__new__(SabbelApp)
    app._takes = _queue.Queue()
    app._capturing = True
    app._focus_target = {"pid": 1, "name": "Notes"}
    app._recorder = MagicMock()
    app._recorder.get_audio.return_value = "audio-1"
    return app


def test_recording_stop_queues_audio_with_its_own_target():
    app = _wired_app()
    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        app._on_recording_stop()

    audio, target = app._takes.get_nowait()
    assert audio == "audio-1"
    assert target == {"pid": 1, "name": "Notes"}


def test_second_recording_cannot_steal_the_first_takes_target():
    """The regression: a shared slot let take 2 redirect take 1's paste.

    Dictate in Notes, release, switch to Slack and start again while the first
    is still transcribing — take 1 must still be bound to Notes.
    """
    app = _wired_app()
    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        app._on_recording_stop()

        # Take 2 starts in a different app while take 1 is still queued.
        app._focus_target = {"pid": 2, "name": "Slack"}
        app._capturing = True
        app._recorder.get_audio.return_value = "audio-2"
        app._on_recording_stop()

    assert app._takes.get_nowait() == ("audio-1", {"pid": 1, "name": "Notes"})
    assert app._takes.get_nowait() == ("audio-2", {"pid": 2, "name": "Slack"})


def test_recording_stop_without_capture_queues_nothing():
    """A release after a blocked start must not hand the worker an empty take."""
    app = _wired_app()
    app._capturing = False
    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        app._on_recording_stop()
    assert app._takes.empty()


def test_recording_cancel_drops_audio_and_queues_nothing():
    app = _wired_app()
    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        app._on_recording_cancel()

    assert app._takes.empty()
    app._recorder.get_audio.assert_called_once()  # drained, not left behind
    assert app._capturing is False


# --- model failure is sticky ------------------------------------------------


def test_warmup_failure_marks_model_failed():
    app = SabbelApp.__new__(SabbelApp)
    app._transcriber = MagicMock()
    app._transcriber.warmup.side_effect = RuntimeError("no model")
    app._model_ready = False
    app._model_failed = False

    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        app._warmup()

    assert app._model_failed is True
    assert app._model_ready is False


def test_idle_never_reports_ready_after_model_failure():
    """It used to: _show_error's 2s timer cleared to "Ready" while every
    hotkey press was still being refused."""
    app = SabbelApp.__new__(SabbelApp)
    app._model_failed = True
    app._hotkey_started = True
    app._stop_spinner = MagicMock()
    app._stop_error_timer = MagicMock()
    app._set_status = MagicMock()

    app._set_idle()

    app._set_status.assert_not_called()


def test_idle_reports_ready_when_model_is_fine():
    app = SabbelApp.__new__(SabbelApp)
    app._model_failed = False
    app._hotkey_started = True
    app._stop_spinner = MagicMock()
    app._stop_error_timer = MagicMock()
    app._set_status = MagicMock()
    type(app).title = "x"  # rumps property would touch the status item
    try:
        app._set_idle()
    finally:
        del type(app).title

    app._set_status.assert_called_once_with("Ready")


# --- injection outcomes -----------------------------------------------------


def _inject_app():
    app = SabbelApp.__new__(SabbelApp)
    app._config = MagicMock(pre_paste_delay=0, post_paste_delay=0)
    app._set_idle = MagicMock()
    app._show_error = MagicMock()
    return app


def test_secure_field_outcome_does_not_claim_the_clipboard():
    """Telling someone to press Cmd+V is wrong when nothing was copied."""
    from sabbel import injector

    app = _inject_app()
    with patch("sabbel.app.inject_text", return_value=injector.REFUSED_SECURE), \
         patch("sabbel.app.rumps.notification") as note:
        app._do_inject("hunter2", target=None)

    subtitle = note.call_args.kwargs["subtitle"]
    message = note.call_args.kwargs["message"]
    assert "clipboard" not in (subtitle + message).lower()


def test_successful_paste_notifies_nothing():
    from sabbel import injector

    app = _inject_app()
    with patch("sabbel.app.inject_text", return_value=injector.PASTED), \
         patch("sabbel.app.rumps.notification") as note:
        app._do_inject("hallo", target=None)

    note.assert_not_called()
    app._set_idle.assert_called_once()


def test_inject_passes_the_takes_own_target():
    from sabbel import injector

    app = _inject_app()
    target = {"pid": 7, "name": "Notes"}
    with patch("sabbel.app.inject_text", return_value=injector.PASTED) as inject:
        app._do_inject("hallo", target=target)

    assert inject.call_args.kwargs["target"] is target


def test_inject_exception_does_not_leave_the_spinner_running():
    app = _inject_app()
    with patch("sabbel.app.inject_text", side_effect=RuntimeError("pyobjc blew up")):
        app._do_inject("hallo", target=None)

    app._show_error.assert_called_once()


# --- a model repo that had to be ignored ------------------------------------


@patch("sabbel.app.migrate_config", return_value=["[model] repo — not usable"])
def test_warmup_notifies_when_the_configured_model_was_ignored(mock_migrate):
    """Falling back silently turns a stale config.toml into a mystery: the
    app works, but not with the model the user asked for."""
    from sabbel.transcriber import ModelFallback

    app = SabbelApp.__new__(SabbelApp)
    app._transcriber = MagicMock()
    app._transcriber.fallback = ModelFallback(
        "mlx-community/whisper-large-v3-turbo", "No such file or directory"
    )
    app._model_ready = False
    app._model_failed = False
    app._set_idle = MagicMock()
    app._notify_model_fallback = MagicMock()

    with patch("sabbel.app.callAfter", side_effect=lambda fn, *a: fn()):
        app._warmup()

    assert app._model_ready is True
    assert app._model_failed is False
    app._notify_model_fallback.assert_called_once()
    assert (
        app._notify_model_fallback.call_args[0][0].repo
        == "mlx-community/whisper-large-v3-turbo"
    )
    # The stale line is taken out of config.toml, not just ignored in memory.
    mock_migrate.assert_called_once_with(drop=[("model", "repo")])


@patch("sabbel.app.migrate_config")
def test_warmup_stays_quiet_when_the_configured_model_loaded(mock_migrate):
    app = SabbelApp.__new__(SabbelApp)
    app._transcriber = MagicMock()
    app._transcriber.fallback = None
    app._model_ready = False
    app._model_failed = False
    app._set_idle = MagicMock()
    app._notify_model_fallback = MagicMock()

    with patch("sabbel.app.callAfter", side_effect=lambda fn, *a: fn()):
        app._warmup()

    assert app._model_ready is True
    app._notify_model_fallback.assert_not_called()
    mock_migrate.assert_not_called()


def test_model_fallback_notification_names_the_repo_and_the_file():
    from sabbel.transcriber import ModelFallback

    app = SabbelApp.__new__(SabbelApp)
    with patch("sabbel.app.rumps.notification") as mock_notify:
        app._notify_model_fallback(
            ModelFallback("mlx-community/whisper-large-v3-turbo", "boom")
        )

    message = mock_notify.call_args.kwargs["message"]
    assert "mlx-community/whisper-large-v3-turbo" in message
    assert "config.toml" in message


def test_model_fallback_notification_says_when_the_line_was_removed():
    """Telling the user to edit a file Sabbel already fixed wastes their time."""
    from sabbel.transcriber import ModelFallback

    app = SabbelApp.__new__(SabbelApp)
    with patch("sabbel.app.rumps.notification") as mock_notify:
        app._notify_model_fallback(
            ModelFallback("mlx-community/whisper-large-v3-turbo", "boom"),
            migrated=True,
        )

    message = mock_notify.call_args.kwargs["message"]
    assert "config.toml.bak" in message
    assert "Remove" not in message


# --- the model must be loaded on the thread that uses it --------------------


def test_model_is_warmed_up_on_the_transcribing_thread():
    """MLX >=0.32 owns streams per thread: a model loaded on one thread cannot
    be evaluated on another.

    Warming up on a throwaway thread while the worker transcribed on its own
    left every non-silent take failing with "There is no Stream(cpu, N) in
    current thread" — silence still returned empty, so the app looked alive
    while producing nothing.
    """
    import queue as _queue
    import threading

    import numpy as np

    threads = {}

    def _remember(name, result):
        def _fn(*_args, **_kwargs):
            threads[name] = threading.get_ident()
            return result

        return _fn

    app = SabbelApp.__new__(SabbelApp)
    app._running = True
    app._takes = _queue.Queue()
    app._recorder = MagicMock()
    app._recorder.is_valid_duration.return_value = True
    app._recorder.is_dead_stream.return_value = False
    app._recorder.has_speech.return_value = True
    app._transcriber = MagicMock()
    app._transcriber.fallback = None
    app._transcriber.warmup.side_effect = _remember("warmup", None)
    app._transcriber.transcribe.side_effect = _remember("transcribe", "Hallo Welt")
    app._model_ready = False
    app._model_failed = False
    app._save_to_history = MagicMock()

    app._takes.put((np.zeros(16000, dtype=np.float32), {"pid": 1, "name": "Notes"}))
    app._takes.put(None)

    with patch("sabbel.app.callAfter", lambda fn, *a: None):
        worker = threading.Thread(target=app._transcription_worker)
        worker.start()
        worker.join(timeout=5)

    assert not worker.is_alive()
    assert "warmup" in threads, "the worker never warmed the model up itself"
    assert threads["warmup"] == threads["transcribe"], (
        "model loaded on a different thread than it is evaluated on"
    )


def test_run_does_not_warm_up_on_a_separate_thread():
    """The warmup thread is what bound the model to a thread nobody used."""
    import inspect

    source = inspect.getsource(SabbelApp.run)
    assert "self._warmup" not in source, (
        "run() must not spawn warmup; the transcription worker owns the model"
    )

# Audio Input Selection — Design

**Date:** 2026-05-13
**Status:** Approved (pending user review of spec)

## Problem

When a laptop is connected to a docking station, Sabbel can become unusable: the OS may route the system-default microphone to the internal mic while audio output goes to the dock, leaving the user unable to record properly. There is currently no way to override the input device — `AudioRecorder` calls `sd.InputStream(...)` without a `device=` parameter, so it always uses the system default.

Users need to pick which microphone Sabbel listens to, and switch between mics without restarting the app or editing TOML.

## Goals

- Let users select the input device from the menu bar at runtime.
- Persist the selection across restarts.
- Gracefully fall back to the system default when the chosen device is unavailable (dock unplugged, USB headset disconnected) — Sabbel must stay usable.
- Make the menu reflect the current set of devices live, without manual refresh, when possible.

## Non-Goals

- No TOML config entry for device selection. Device choice is runtime state (like the history toggle), not user-edited configuration.
- No per-device audio settings (gain, sample rate). Sabbel keeps its fixed 16 kHz / mono / float32 pipeline.
- No automatic device switching based on context (e.g., "use dock mic when docked"). User picks explicitly.

## Design

### Device identification & persistence

- **Identifier:** device name (string, e.g., `"Dell WD22 Mic"`). Names are stable across reboots and replugs under macOS Core Audio; device indices are not.
- **Storage:** `~/.config/sabbel/preferences.json` under key `"audio_device"`. Value is either a string (device name) or `null` (= system default).
- **No TOML entry:** intentionally omitted. Device selection is runtime state, parallel to `history_enabled`.

### Recorder changes (`sabbel/recorder.py`)

New module-level helper:

```python
def list_input_devices() -> list[dict]:
    """Return [{"name": str, "index": int}, ...] for input-capable devices."""
```

Wraps `sd.query_devices()`, keeps only entries with `max_input_channels > 0`, returns minimal records.

`AudioRecorder` changes:

- New constructor parameter: `device: str | None = None`
- New instance field: `self._device: str | None` (current selection)
- New instance field: `self.last_fallback: str | None` (the *expected* name when the most recent `start()` had to fall back; consumed by the app to drive a one-shot notification)
- New method: `set_device(name: str | None) -> None` — stores the selection and closes the cached stream so the next `start()` rebuilds with the new device.
- `start()` resolves the name to an index via `sd.query_devices()`:
  - **Exact** name match (case-sensitive). Substring matching causes false positives because "Microphone" appears in many device names.
  - If not found: open the stream with `device=None` (system default) and set `self.last_fallback = self._device`.
  - If found or `self._device is None`: `last_fallback = None`.

### Menu UI (`sabbel/app.py`)

Submenu under the top-level Sabbel menu:

```
Microphone ▶
├── ✓ System Default
├── ─────
├──   MacBook Pro Microphone
├── ✓ Dell WD22 Mic
└──   USB Headset
```

If the saved device is currently offline, a non-clickable header item is added at the top of the submenu:

```
Microphone ▶
├──   Saved: Dell WD22 Mic (offline)
├── ─────
├── ✓ System Default
├── ─────
└──   MacBook Pro Microphone
```

Implementation:

- App holds `self._mic_menu = rumps.MenuItem("Microphone")`.
- `_rebuild_mic_menu()` enumerates `list_input_devices()`, prepends "System Default" (`None`), separator, then devices alphabetically. Checkmark (`state = 1`) sits on the active selection.
- `_on_mic_select(sender)` reads the device name from a per-item mapping (built during `_rebuild_mic_menu`), calls `recorder.set_device(name)`, persists via `save_preference("audio_device", name)`, then rebuilds the submenu so the checkmark moves.
- The "Saved: X (offline)" item is only added when `preferences["audio_device"]` names a device not currently in `list_input_devices()`. It has no callback (rumps shows it greyed).

### Live refresh via NSMenuDelegate

- On app start, attach an `NSMenuDelegate` to the underlying `NSMenu` of `_mic_menu`. The delegate's `menuWillOpen_:` triggers `callAfter(self._rebuild_mic_menu)`.
- The delegate is a small `NSObject` subclass held as an instance attribute of `SabbelApp` so Python refcounts keep it alive.
- The hook reaches into `rumps`-internal `_menuitem.submenu()` — undocumented but stable. Wrap the entire hookup in `try/except`; on failure, fall back to appending a manual `Refresh devices` item to the submenu (callback = `_rebuild_mic_menu`).

### Fallback flow

**Scenario 1 — saved device missing at `start()`:**
- `recorder.start()` resolves name → not found → opens with `device=None`, sets `last_fallback`.
- App's `_on_recording_start` (after the `start()` call) checks `recorder.last_fallback`; if set, schedules a notification via `callAfter`: *"Mic '<name>' not found — using system default"*.
- App clears `recorder.last_fallback = None` after sending so subsequent recordings in the same session don't spam.
- Recording proceeds normally.

**Scenario 2 — saved device offline across the whole session:**
- Pref is kept, scenario 1 fires once per app launch.
- Submenu shows the offline header item; checkmark sits on "System Default" (what's actually active).
- When the device returns, `_rebuild_mic_menu` picks it up on next menu-open and `start()` will use it automatically.

**Scenario 3 — `sd.PortAudioError` opening the stream:**
- Existing handling in `_on_recording_start` applies: "Mic error" badge in the menu bar, auto-clears after 2 s.

### Wire-up at startup

In `SabbelApp.__init__`:

1. Read `preferences["audio_device"]` (default `None`).
2. Pass to `AudioRecorder(min_duration_seconds=..., device=saved_device)`.
3. Build `_mic_menu` once via `_rebuild_mic_menu()`; attach NSMenuDelegate.

## Testing

### Unit tests

New file `tests/test_mic_selection.py` (plus extensions to `tests/test_recorder.py`):

- `list_input_devices()` filters correctly on `max_input_channels > 0` — monkeypatch `sd.query_devices`.
- `AudioRecorder.set_device(name)` closes the cached stream — verify `recorder._stream is None` after the call when a stream was open.
- `AudioRecorder.start()` with an unknown device name → opens `sd.InputStream` with `device=None`, sets `last_fallback` to the expected name. Patch `sd.InputStream` to capture call args.
- `AudioRecorder.start()` with a matching device name → opens `sd.InputStream` with the resolved index, `last_fallback is None`.
- Menu build: given a fake device list, the submenu has the expected items in the expected order, and the active device has `state = 1`. Refactor `_rebuild_mic_menu` so the menu-spec construction is a pure function returning a structure, independent of rumps instantiation.

### Manual test checklist (for PR)

- [ ] With internal mic only: submenu shows "System Default" + "MacBook Pro Microphone"; selection works.
- [ ] Plug in dock, open menu → dock mic appears.
- [ ] Pick dock mic, dictate → text appears, no fallback notification.
- [ ] Unplug dock while Sabbel running, dictate → notification fires once, recording works via default.
- [ ] Restart Sabbel with dock missing → submenu shows "Saved: ... (offline)" header, "System Default" is checked.
- [ ] Replug dock, open menu → offline header disappears, checkmark returns to dock mic, dictating uses dock mic again.

### Explicitly out of scope for tests

NSMenuDelegate hook is not unit-tested (PyObjC in test envs is fragile). Reliability is enforced by the try/except + "Refresh devices" fallback, which *is* testable as a build-output assertion.

## Files Touched

- `sabbel/recorder.py` — add `device` param, `set_device()`, `last_fallback`, `list_input_devices()`.
- `sabbel/app.py` — `_mic_menu`, `_rebuild_mic_menu()`, `_on_mic_select()`, NSMenuDelegate hookup with refresh-item fallback, notification handling in `_on_recording_start`.
- `tests/test_recorder.py` — extend with device-selection tests.
- `tests/test_mic_selection.py` — new file for menu-build pure-function tests.
- `README.md` — short section under Configuration explaining the menu-based mic picker.

No changes to `config.py`, `preferences.py`, packaging, or installer.

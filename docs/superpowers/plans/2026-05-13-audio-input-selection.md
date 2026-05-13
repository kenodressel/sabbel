# Audio Input Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick which microphone Sabbel records from, via the menu bar, with persistence and graceful fallback when the chosen device is offline.

**Architecture:** `AudioRecorder` learns about devices (constructor param + `set_device()` + name→index resolution + `last_fallback` field). The `SabbelApp` builds a `Microphone` submenu, persists the choice to `preferences.json`, attaches an `NSMenuDelegate` for live refresh, and surfaces a notification when a fallback happens. The menu-build is refactored into a pure function for unit testing.

**Tech Stack:** Python, `sounddevice` (PortAudio), `rumps` (NSStatusBar wrapper), `PyObjC` (for `NSMenuDelegate`), `pytest`.

**Spec:** `docs/superpowers/specs/2026-05-13-audio-input-selection-design.md`

---

## File Structure

- **Modify** `sabbel/recorder.py` — add `device` param, `set_device()`, `last_fallback`, module-level `list_input_devices()`.
- **Modify** `sabbel/app.py` — `_mic_menu`, `_rebuild_mic_menu()`, `_on_mic_select()`, NSMenuDelegate, notification in `_on_recording_start`. Refactor menu-build into pure helper `_build_mic_menu_spec()` for testability.
- **Modify** `tests/test_recorder.py` — add tests for device handling.
- **Create** `tests/test_mic_selection.py` — new file for the pure menu-build function.
- **Modify** `README.md` — short section explaining the menu-based picker.

No changes to `config.py`, `preferences.py`, or packaging.

---

### Task 1: Add `list_input_devices()` to recorder module

**Files:**
- Modify: `sabbel/recorder.py` (add module function after the constants)
- Test: `tests/test_recorder.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_recorder.py`:

```python
from unittest.mock import patch

def test_list_input_devices_filters_output_only():
    fake_devices = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
        {"name": "MacBook Pro Speakers", "index": 1, "max_input_channels": 0},
        {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
    ]
    with patch("sabbel.recorder.sd.query_devices", return_value=fake_devices):
        from sabbel.recorder import list_input_devices
        result = list_input_devices()

    assert result == [
        {"name": "MacBook Pro Microphone", "index": 0},
        {"name": "Dell WD22 Mic", "index": 2},
    ]


def test_list_input_devices_handles_query_error():
    with patch("sabbel.recorder.sd.query_devices", side_effect=OSError("PortAudio error")):
        from sabbel.recorder import list_input_devices
        assert list_input_devices() == []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_recorder.py::test_list_input_devices_filters_output_only tests/test_recorder.py::test_list_input_devices_handles_query_error -v`

Expected: FAIL — `ImportError: cannot import name 'list_input_devices' from 'sabbel.recorder'`.

- [ ] **Step 3: Implement `list_input_devices()`**

Add to `sabbel/recorder.py`, after the `BLOCK_SIZE` constant and before `class AudioRecorder`:

```python
import logging


def list_input_devices() -> list[dict]:
    """Return input-capable devices as `[{"name": str, "index": int}, ...]`.

    Filters `sd.query_devices()` to entries with `max_input_channels > 0`.
    Returns `[]` if PortAudio enumeration fails — Sabbel should still work
    via the system default in that case.
    """
    try:
        devices = sd.query_devices()
    except Exception:
        logging.debug("query_devices failed", exc_info=True)
        return []
    result = []
    for d in devices:
        if d.get("max_input_channels", 0) > 0:
            result.append({"name": d["name"], "index": d.get("index", devices.index(d))})
    return result
```

Note: `sd.query_devices()` returns a `DeviceList` of dict-like objects; `.get()` works. The index fallback `devices.index(d)` covers older sounddevice versions that don't include an `index` key.

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_recorder.py::test_list_input_devices_filters_output_only tests/test_recorder.py::test_list_input_devices_handles_query_error -v`

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add sabbel/recorder.py tests/test_recorder.py
git commit -m "recorder: list_input_devices() module helper"
```

---

### Task 2: Add `device` param + `set_device()` + `last_fallback` to `AudioRecorder`

**Files:**
- Modify: `sabbel/recorder.py` (constructor + `start()` + new method)
- Test: `tests/test_recorder.py`

- [ ] **Step 1: Write failing tests for `set_device` and device resolution**

Add to `tests/test_recorder.py`:

```python
def test_set_device_closes_existing_stream():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._device = None
    stream = MagicMock()
    stream.active = True
    recorder._stream = stream

    recorder.set_device("Dell WD22 Mic")

    assert recorder._device == "Dell WD22 Mic"
    stream.stop.assert_called_once()
    stream.close.assert_called_once()
    assert recorder._stream is None


def test_set_device_with_no_active_stream_just_updates():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._device = "Old Mic"
    recorder._stream = None

    recorder.set_device(None)

    assert recorder._device is None
    assert recorder._stream is None


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_resolves_known_device_to_index(mock_input_stream, mock_query):
    mock_query.return_value = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
        {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
    ]
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_fallback = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] == 2
    assert recorder.last_fallback is None


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_unknown_device_falls_back_to_default(mock_input_stream, mock_query):
    mock_query.return_value = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
    ]
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_fallback = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] is None
    assert recorder.last_fallback == "Dell WD22 Mic"


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_with_no_device_pref_uses_system_default(mock_input_stream, mock_query):
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._device = None
    recorder.last_fallback = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] is None
    assert recorder.last_fallback is None
    mock_query.assert_not_called()


def test_constructor_accepts_device_param():
    recorder = AudioRecorder(min_duration_seconds=0.5, device="Dell WD22 Mic")
    assert recorder._device == "Dell WD22 Mic"
    assert recorder.last_fallback is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_recorder.py -v -k "set_device or start_resolves or start_unknown or start_with_no_device or constructor_accepts_device"`

Expected: FAIL — `AttributeError: 'AudioRecorder' object has no attribute 'set_device'`, etc.

- [ ] **Step 3: Implement changes in `sabbel/recorder.py`**

Replace the existing `AudioRecorder.__init__`, `start()`, and add `set_device()`:

```python
class AudioRecorder:
    def __init__(self, min_duration_seconds: float = 0.5, device: str | None = None):
        self._queue: queue.Queue[np.ndarray] = queue.Queue()
        self._min_samples = int(min_duration_seconds * SAMPLE_RATE)
        self._stream: sd.InputStream | None = None
        self._device: str | None = device
        self.last_fallback: str | None = None

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if status:
            print(f"sounddevice status: {status}")
        self._queue.put(indata.copy())

    def _resolve_device(self) -> tuple[int | None, str | None]:
        """Resolve `self._device` to a PortAudio index.

        Returns `(index_or_None, fallback_name_or_None)`.
        - If `self._device is None` → `(None, None)` (system default).
        - If exact name match found → `(index, None)`.
        - If not found → `(None, self._device)` (fallback, caller should notify).
        """
        if self._device is None:
            return (None, None)
        try:
            devices = sd.query_devices()
        except Exception:
            logging.debug("query_devices failed during resolve", exc_info=True)
            return (None, self._device)
        for i, d in enumerate(devices):
            if d.get("max_input_channels", 0) > 0 and d.get("name") == self._device:
                return (d.get("index", i), None)
        return (None, self._device)

    def set_device(self, name: str | None) -> None:
        """Change the input device. Closes the cached stream so the next
        `start()` re-opens with the new selection.
        """
        self._device = name
        if self._stream is not None:
            if self._stream.active:
                self._stream.stop()
            self._stream.close()
            self._stream = None

    def start(self):
        while not self._queue.empty():
            self._queue.get()
        if self._stream is None:
            device_index, fallback = self._resolve_device()
            self.last_fallback = fallback
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=BLOCK_SIZE,
                device=device_index,
                callback=self._audio_callback,
            )
        self._stream.start()
```

Note: `start()` only re-resolves when the stream is being lazily created. If a stream is already cached (same device, recording again), `last_fallback` is not touched — the previous value from the most recent resolve stands until `set_device()` invalidates it.

- [ ] **Step 4: Run all recorder tests**

Run: `uv run pytest tests/test_recorder.py -v`

Expected: PASS — all previously-passing tests still pass, new tests pass.

- [ ] **Step 5: Commit**

```bash
git add sabbel/recorder.py tests/test_recorder.py
git commit -m "recorder: device selection with name→index resolution and fallback"
```

---

### Task 3: Extract menu-build as a pure function with tests

This sets up the data structure the rumps-driven build will consume. Keeping it pure means we can test the order, the checkmarks, and the offline header without ever touching `rumps`.

**Files:**
- Modify: `sabbel/app.py` (add new module-level function)
- Create: `tests/test_mic_selection.py`

- [ ] **Step 1: Write failing tests for `_build_mic_menu_spec`**

Create `tests/test_mic_selection.py`:

```python
from sabbel.app import _build_mic_menu_spec


def test_no_devices_only_default():
    spec = _build_mic_menu_spec(devices=[], selected=None)
    assert spec == [
        {"kind": "device", "name": None, "label": "System Default", "checked": True},
    ]


def test_devices_sorted_alphabetically_with_separator():
    devices = [
        {"name": "USB Headset", "index": 3},
        {"name": "MacBook Pro Microphone", "index": 0},
        {"name": "Dell WD22 Mic", "index": 2},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected=None)
    assert spec == [
        {"kind": "device", "name": None, "label": "System Default", "checked": True},
        {"kind": "separator"},
        {"kind": "device", "name": "Dell WD22 Mic", "label": "Dell WD22 Mic", "checked": False},
        {"kind": "device", "name": "MacBook Pro Microphone", "label": "MacBook Pro Microphone", "checked": False},
        {"kind": "device", "name": "USB Headset", "label": "USB Headset", "checked": False},
    ]


def test_selected_device_present_gets_checkmark():
    devices = [
        {"name": "Dell WD22 Mic", "index": 2},
        {"name": "MacBook Pro Microphone", "index": 0},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected="Dell WD22 Mic")
    labels_checked = [(item.get("label"), item.get("checked")) for item in spec if item["kind"] == "device"]
    assert labels_checked == [
        ("System Default", False),
        ("Dell WD22 Mic", True),
        ("MacBook Pro Microphone", False),
    ]


def test_selected_device_offline_shows_header_and_defaults_checked():
    devices = [
        {"name": "MacBook Pro Microphone", "index": 0},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected="Dell WD22 Mic")
    assert spec[0] == {"kind": "offline", "label": "Saved: Dell WD22 Mic (offline)"}
    assert spec[1] == {"kind": "separator"}
    device_items = [item for item in spec if item["kind"] == "device"]
    assert device_items[0] == {
        "kind": "device", "name": None, "label": "System Default", "checked": True,
    }
    assert {"name": "MacBook Pro Microphone", "label": "MacBook Pro Microphone", "checked": False, "kind": "device"} in device_items
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_mic_selection.py -v`

Expected: FAIL — `ImportError: cannot import name '_build_mic_menu_spec' from 'sabbel.app'`.

- [ ] **Step 3: Implement `_build_mic_menu_spec` in `sabbel/app.py`**

Add as a module-level function near the other helpers (e.g., right after `_next_language`):

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_mic_selection.py -v`

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add sabbel/app.py tests/test_mic_selection.py
git commit -m "app: pure menu-spec builder for mic selection"
```

---

### Task 4: Wire mic submenu into `SabbelApp`

This wires preferences → recorder → submenu render → click callback. NSMenuDelegate live refresh comes in Task 6; for now, the submenu is built once at startup.

**Files:**
- Modify: `sabbel/app.py` (imports, `__init__`, new methods)

- [ ] **Step 1: Update imports at the top of `sabbel/app.py`**

The file already imports from `sabbel.preferences` and `sabbel.recorder`. Update the recorder import to bring in `list_input_devices`:

```python
from sabbel.recorder import AudioRecorder, list_input_devices
```

- [ ] **Step 2: Read saved device in `__init__` before constructing the recorder**

In `SabbelApp.__init__`, locate the line:

```python
        prefs = load_preferences()
        self._history_enabled = prefs.get("history_enabled", config.history_enabled)
```

Immediately after it, add:

```python
        self._audio_device: str | None = prefs.get("audio_device")
```

Then locate the recorder construction:

```python
        self._recorder = AudioRecorder(
            min_duration_seconds=config.min_duration_seconds,
        )
```

Replace with:

```python
        self._recorder = AudioRecorder(
            min_duration_seconds=config.min_duration_seconds,
            device=self._audio_device,
        )
```

- [ ] **Step 3: Build the Microphone submenu in `__init__`**

Locate the History submenu block (the `history_item = rumps.MenuItem("History")` block) and immediately after the line `menu_items.append(history_item)`, add:

```python
        # Microphone submenu — built fresh on every menu-open via NSMenuDelegate (see Task 6).
        self._mic_menu = rumps.MenuItem("Microphone")
        self._rebuild_mic_menu()
        menu_items.append(self._mic_menu)
```

- [ ] **Step 4: Add `_rebuild_mic_menu`, `_on_mic_select`, and the offline-header callback no-op**

Add these methods to the `SabbelApp` class. Pick a position near the other `_history_*` methods for proximity:

```python
    def _rebuild_mic_menu(self):
        """Repopulate the Microphone submenu from current device state."""
        devices = list_input_devices()
        spec = _build_mic_menu_spec(devices=devices, selected=self._audio_device)
        self._mic_menu.clear()
        for item in spec:
            if item["kind"] == "separator":
                self._mic_menu.add(rumps.separator)
                continue
            if item["kind"] == "offline":
                # Non-clickable header: rumps shows items without a callback as greyed.
                header = rumps.MenuItem(item["label"])
                self._mic_menu.add(header)
                continue
            # device
            menu_item = rumps.MenuItem(
                item["label"],
                callback=self._on_mic_select,
            )
            menu_item.state = 1 if item["checked"] else 0
            # Stash the device name so the callback can recover it. rumps gives
            # us `sender.title` but that's the label, which equals the name for
            # real devices but is "System Default" for the None entry.
            menu_item._sabbel_device_name = item["name"]
            self._mic_menu.add(menu_item)

    def _on_mic_select(self, sender):
        new_device = getattr(sender, "_sabbel_device_name", None)
        if new_device == self._audio_device:
            return
        self._audio_device = new_device
        self._recorder.set_device(new_device)
        save_preference("audio_device", new_device)
        self._rebuild_mic_menu()
```

- [ ] **Step 5: Smoke-test the build**

Verify the changes parse and the recorder tests still pass:

Run: `uv run pytest tests/ -v`

Expected: PASS — all tests pass, no import errors. The app-level callbacks aren't unit-tested directly (they touch rumps).

- [ ] **Step 6: Commit**

```bash
git add sabbel/app.py
git commit -m "app: Microphone submenu wired to recorder and preferences"
```

---

### Task 5: Surface fallback notification in `_on_recording_start`

When the saved device is offline at start time, the recorder sets `last_fallback`. We read that after `start()` returns and fire a one-shot notification.

**Files:**
- Modify: `sabbel/app.py` (`_on_recording_start`)

- [ ] **Step 1: Locate `_on_recording_start`**

Current code:

```python
    def _on_recording_start(self):
        """Called from pynput thread."""
        if not self._model_ready:
            logging.info("Recording blocked: model still loading")
            callAfter(self._notify_model_loading)
            return
        logging.info("Recording start requested")
        try:
            self._recorder.start()
        except sd.PortAudioError:
            logging.exception("Recorder error")
            callAfter(lambda: self._show_error("Mic error"))
            return
        callAfter(self._set_recording)
```

- [ ] **Step 2: Add the fallback check after a successful `start()`**

Replace the method body with:

```python
    def _on_recording_start(self):
        """Called from pynput thread."""
        if not self._model_ready:
            logging.info("Recording blocked: model still loading")
            callAfter(self._notify_model_loading)
            return
        logging.info("Recording start requested")
        try:
            self._recorder.start()
        except sd.PortAudioError:
            logging.exception("Recorder error")
            callAfter(lambda: self._show_error("Mic error"))
            return
        fallback = self._recorder.last_fallback
        if fallback:
            self._recorder.last_fallback = None
            callAfter(lambda name=fallback: self._notify_mic_fallback(name))
        callAfter(self._set_recording)
```

- [ ] **Step 3: Add `_notify_mic_fallback`**

Add as a method on `SabbelApp`, near the other `_notify_*` methods:

```python
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
```

- [ ] **Step 4: Run all tests**

Run: `uv run pytest tests/ -v`

Expected: PASS — nothing in the test suite hits this path directly, but the imports and class must still load cleanly.

- [ ] **Step 5: Commit**

```bash
git add sabbel/app.py
git commit -m "app: notify user when saved mic is offline and we fell back"
```

---

### Task 6: NSMenuDelegate live refresh with safe fallback

This is the only part that touches PyObjC. It's wrapped in `try/except`; on any failure we append a manual "Refresh devices" item to the submenu so the feature still works.

**Files:**
- Modify: `sabbel/app.py`

- [ ] **Step 1: Add PyObjC imports at the top of `sabbel/app.py`**

The file already imports from `PyObjCTools.AppHelper`. Add at the import block (keep the others as-is):

```python
import objc
from Foundation import NSObject
```

- [ ] **Step 2: Define a small delegate class at module level**

Add near the top of the file, after the `_SPINNER` constant block but before `_normalize_language`:

```python
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
```

- [ ] **Step 3: Attach the delegate after the submenu is added**

In `SabbelApp.__init__`, after the line `menu_items.append(self._mic_menu)` and **after** `self.menu = menu_items` is assigned (rumps only realizes the underlying `NSMenu` once the menu has been set), add:

```python
        self._mic_delegate = None  # Hold ref so PyObjC doesn't release it.
        self._attach_mic_menu_delegate()
```

Then add the method on `SabbelApp`:

```python
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
                lambda: callAfter(self._rebuild_mic_menu)
            )
            ns_menu.setDelegate_(delegate)
            self._mic_delegate = delegate
        except Exception:
            logging.warning(
                "NSMenuDelegate hookup failed, falling back to manual refresh",
                exc_info=True,
            )
            self._mic_menu.add(rumps.separator)
            self._mic_menu.add(
                rumps.MenuItem("Refresh devices", callback=lambda _: self._rebuild_mic_menu())
            )
```

Note: `callAfter` is needed because `menuWillOpen_` runs on the AppKit main thread but during menu tracking — calling `_mic_menu.clear()`/`add()` while the menu is being displayed is unsupported. `callAfter` defers the rebuild to the next runloop tick.

- [ ] **Step 4: Run all tests**

Run: `uv run pytest tests/ -v`

Expected: PASS — no test exercises the delegate (per spec it's not unit-tested), but the module must still import cleanly.

- [ ] **Step 5: Manual smoke test (Keno, on hardware)**

```bash
make restart
```

Then:
- Open the Sabbel menu → hover `Microphone`. Submenu should show "System Default" + your current devices.
- Plug or unplug a USB mic/dock → close & reopen the menu → list should update.
- Pick a device → checkmark moves, recording uses it.
- If the PyObjC hookup failed silently, the submenu will have a `Refresh devices` item at the bottom — clicking it refreshes. (Confirms the fallback path works.)

- [ ] **Step 6: Commit**

```bash
git add sabbel/app.py
git commit -m "app: NSMenuDelegate-driven live refresh for mic submenu"
```

---

### Task 7: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Microphone" subsection under "Configuration"**

In `README.md`, locate the `## Configuration` section (around line 109). After the existing TOML block and the History paragraph (around line 132, after the privacy note blockquote), add:

```markdown
### Microphone

Click the Sabbel menu → **Microphone** to pick which input device Sabbel records from. The list refreshes every time you open the menu, so plugging in a USB mic or docking station is reflected immediately. The choice persists across restarts.

If the saved device is offline (e.g., dock unplugged), Sabbel falls back to the system default and shows a notification on the next recording. When the device comes back, it's used again automatically — no need to re-pick.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README section for the Microphone picker"
```

---

## Final Verification

- [ ] Run the full test suite: `uv run pytest tests/ -v` — all green.
- [ ] Build the app: `make install-app`. macOS will reset TCC permissions; grant Accessibility + Microphone again.
- [ ] Walk the manual checklist from the spec (Section 4 of `2026-05-13-audio-input-selection-design.md`).

---

## Self-Review Notes

**Spec coverage check:**
- Geräte-Identifikation & Persistenz (name as string, preferences.json) — Task 4 reads pref + Tasks 1-2 use names.
- Recorder changes (device param, set_device, last_fallback, list_input_devices) — Tasks 1-2.
- Menu UI (submenu, alphabetical, System Default, checkmark, offline header) — Tasks 3-4.
- NSMenuDelegate live refresh w/ fallback — Task 6.
- Fallback flow scenarios 1-3 — Task 5 (notification), Task 4 (offline header in build), Task 2 (existing PortAudioError handling preserved).
- Wire-up at startup — Task 4.
- Testing (unit + manual checklist) — Tasks 1-3 cover unit tests; manual checklist appears in Task 6 step 5 and the Final Verification.
- README update — Task 7.

**Placeholder scan:** None found.

**Type consistency:** `_build_mic_menu_spec` return shape is consistent between the test in Task 3 and the consumer in Task 4 (`item["kind"]` dispatch on `"device" | "separator" | "offline"`, `name`/`label`/`checked` fields). `list_input_devices` returns `[{"name": str, "index": int}, ...]` consistently (Tasks 1 → 2 → 3 → 4).

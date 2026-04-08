# FlowSpeak Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local voice dictation menu bar app for macOS that records speech via push-to-talk, transcribes it with mlx-whisper, and pastes the result into the focused app.

**Architecture:** A single Python process with four threads — main thread runs the rumps menu bar app and owns the sounddevice stream + text injection, a pynput daemon thread captures the hotkey, a PortAudio callback thread captures audio into a queue, and a worker thread runs Whisper transcription. Communication via `threading.Event` and `queue.Queue`.

**Tech Stack:** Python 3.10+, mlx-whisper, sounddevice, pynput, rumps, pyobjc (Cocoa + Quartz), numpy

**Spec:** `docs/superpowers/specs/2026-04-08-voice-dictation-design.md`

---

## File Map

```
flowspeak/
├── flowspeak/
│   ├── __init__.py           # Version string
│   ├── __main__.py           # Entry point: python -m flowspeak
│   ├── config.py             # Config dataclass + TOML loading
│   ├── recorder.py           # AudioRecorder: sounddevice InputStream wrapper
│   ├── transcriber.py        # TranscriptionWorker: mlx-whisper wrapper + worker thread
│   ├── injector.py           # inject_text(): NSPasteboard + CGEvent Cmd+V
│   ├── hotkey.py             # HotkeyManager: pynput Listener wrapper
│   └── app.py                # FlowSpeakApp: rumps.App subclass, orchestrates everything
├── tests/
│   ├── __init__.py
│   ├── test_config.py
│   ├── test_recorder.py
│   └── test_transcriber.py
├── icons/
│   ├── mic_idle.png          # 36x36 template icon (idle state)
│   ├── mic_recording.png     # 36x36 template icon (recording state)
│   └── mic_working.png       # 36x36 template icon (transcribing state)
├── pyproject.toml
└── README.md
```

---

## Task 1: Project Scaffold + Config

**Files:**
- Create: `pyproject.toml`
- Create: `flowspeak/__init__.py`
- Create: `flowspeak/__main__.py` (stub)
- Create: `flowspeak/config.py`
- Create: `tests/__init__.py`
- Create: `tests/test_config.py`

- [ ] **Step 1: Create `pyproject.toml`**

```toml
[project]
name = "flowspeak"
version = "0.1.0"
description = "Local voice dictation for macOS"
requires-python = ">=3.10"
dependencies = [
    "mlx-whisper>=0.4.0",
    "sounddevice>=0.5.0",
    "numpy>=1.24",
    "pynput>=1.8.0",
    "rumps>=0.4.0",
    "pyobjc-framework-Cocoa",
    "pyobjc-framework-Quartz",
]

[project.optional-dependencies]
dev = ["pytest>=7.0"]

[project.scripts]
flowspeak = "flowspeak.__main__:main"

[build-system]
requires = ["setuptools>=68.0"]
build-backend = "setuptools.backends._legacy:_Backend"
```

- [ ] **Step 2: Create `flowspeak/__init__.py`**

```python
__version__ = "0.1.0"
```

- [ ] **Step 3: Create `flowspeak/__main__.py` (stub)**

```python
def main():
    print("FlowSpeak starting...")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Write the failing test for config**

Create `tests/__init__.py` (empty file).

Create `tests/test_config.py`:

```python
import pytest
from flowspeak.config import FlowSpeakConfig, load_config


def test_default_config():
    cfg = FlowSpeakConfig()
    assert cfg.language == "de"
    assert cfg.model_repo == "mlx-community/whisper-large-v3-turbo"
    assert cfg.min_duration_seconds == 0.5
    assert cfg.pre_paste_delay == 0.05
    assert cfg.post_paste_delay == 0.15


def test_load_config_missing_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.toml")
    assert cfg.language == "de"


def test_load_config_from_file(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[general]\nlanguage = "en"\n\n'
        '[audio]\nmin_duration_seconds = 1.0\n'
    )
    cfg = load_config(config_file)
    assert cfg.language == "en"
    assert cfg.min_duration_seconds == 1.0
    # Other fields keep defaults
    assert cfg.model_repo == "mlx-community/whisper-large-v3-turbo"


def test_load_config_partial_override(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('[model]\nrepo = "mlx-community/whisper-tiny"\n')
    cfg = load_config(config_file)
    assert cfg.model_repo == "mlx-community/whisper-tiny"
    assert cfg.language == "de"
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_config.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'flowspeak.config'`

- [ ] **Step 6: Implement `flowspeak/config.py`**

```python
from dataclasses import dataclass, fields
from pathlib import Path
import tomllib


@dataclass
class FlowSpeakConfig:
    language: str = "de"
    model_repo: str = "mlx-community/whisper-large-v3-turbo"
    min_duration_seconds: float = 0.5
    pre_paste_delay: float = 0.05
    post_paste_delay: float = 0.15


# Maps TOML paths to dataclass field names
_TOML_MAP = {
    ("general", "language"): "language",
    ("model", "repo"): "model_repo",
    ("audio", "min_duration_seconds"): "min_duration_seconds",
    ("injection", "pre_paste_delay"): "pre_paste_delay",
    ("injection", "post_paste_delay"): "post_paste_delay",
}

_VALID_FIELDS = {f.name for f in fields(FlowSpeakConfig)}


def load_config(path: Path | None = None) -> FlowSpeakConfig:
    if path is None:
        path = Path.home() / ".config" / "flowspeak" / "config.toml"
    if not path.exists():
        return FlowSpeakConfig()

    with open(path, "rb") as f:
        data = tomllib.load(f)

    overrides = {}
    for (section, key), field_name in _TOML_MAP.items():
        if section in data and key in data[section]:
            overrides[field_name] = data[section][key]

    return FlowSpeakConfig(**overrides)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_config.py -v`
Expected: All 4 tests PASS

- [ ] **Step 8: Install project in dev mode**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && pip install -e ".[dev]"`

- [ ] **Step 9: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add pyproject.toml flowspeak/ tests/
git commit -m "feat: project scaffold with config module and tests"
```

---

## Task 2: Audio Recorder

**Files:**
- Create: `flowspeak/recorder.py`
- Create: `tests/test_recorder.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_recorder.py`:

```python
import numpy as np
import pytest
from unittest.mock import patch, MagicMock
from flowspeak.recorder import AudioRecorder


def test_get_audio_empty():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    audio = recorder.get_audio()
    assert isinstance(audio, np.ndarray)
    assert audio.dtype == np.float32
    assert len(audio) == 0


def test_get_audio_assembles_chunks():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()

    # Simulate 3 chunks of 1600 frames each (100ms at 16kHz), shape (1600, 1)
    for _ in range(3):
        chunk = np.random.randn(1600, 1).astype(np.float32)
        recorder._queue.put(chunk)

    audio = recorder.get_audio()
    assert audio.dtype == np.float32
    assert audio.ndim == 1  # flattened
    assert len(audio) == 4800  # 3 * 1600


def test_is_valid_duration():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._min_samples = 8000  # 0.5s at 16kHz

    short_audio = np.zeros(4000, dtype=np.float32)
    assert recorder.is_valid_duration(short_audio) is False

    valid_audio = np.zeros(8000, dtype=np.float32)
    assert recorder.is_valid_duration(valid_audio) is True

    long_audio = np.zeros(16000, dtype=np.float32)
    assert recorder.is_valid_duration(long_audio) is True


def test_get_audio_clears_queue():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._queue.put(np.zeros((1600, 1), dtype=np.float32))

    _ = recorder.get_audio()
    assert recorder._queue.empty()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_recorder.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'flowspeak.recorder'`

- [ ] **Step 3: Implement `flowspeak/recorder.py`**

```python
import queue
import numpy as np
import sounddevice as sd


SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "float32"
BLOCK_SIZE = 1600  # 100ms chunks


class AudioRecorder:
    def __init__(self, min_duration_seconds: float = 0.5):
        self._queue: queue.Queue[np.ndarray] = queue.Queue()
        self._min_samples = int(min_duration_seconds * SAMPLE_RATE)
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCK_SIZE,
            callback=self._audio_callback,
        )

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if status:
            print(f"sounddevice status: {status}")
        self._queue.put(indata.copy())

    def start(self):
        # Clear any stale audio from previous recording
        while not self._queue.empty():
            self._queue.get()
        self._stream.start()

    def stop(self):
        self._stream.stop()

    def get_audio(self) -> np.ndarray:
        chunks = []
        while not self._queue.empty():
            chunks.append(self._queue.get())
        if not chunks:
            return np.array([], dtype=np.float32)
        return np.concatenate(chunks, axis=0).flatten()

    def is_valid_duration(self, audio: np.ndarray) -> bool:
        return len(audio) >= self._min_samples

    def close(self):
        self._stream.close()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_recorder.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add flowspeak/recorder.py tests/test_recorder.py
git commit -m "feat: audio recorder with sounddevice InputStream"
```

---

## Task 3: Transcription Engine

**Files:**
- Create: `flowspeak/transcriber.py`
- Create: `tests/test_transcriber.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_transcriber.py`:

```python
import numpy as np
import pytest
from unittest.mock import patch, MagicMock
from flowspeak.transcriber import TranscriptionEngine


@patch("flowspeak.transcriber.mlx_whisper")
def test_transcribe_returns_text(mock_whisper):
    mock_whisper.transcribe.return_value = {
        "text": "  Hallo Welt  ",
        "segments": [],
        "language": "de",
    }
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    audio = np.random.randn(16000).astype(np.float32)  # 1 second
    result = engine.transcribe(audio, language="de")
    assert result == "Hallo Welt"
    mock_whisper.transcribe.assert_called_once_with(
        audio,
        path_or_hf_repo="mlx-community/whisper-tiny",
        language="de",
    )


@patch("flowspeak.transcriber.mlx_whisper")
def test_transcribe_short_audio_returns_empty(mock_whisper):
    engine = TranscriptionEngine(
        model_repo="mlx-community/whisper-tiny",
        min_samples=8000,
    )
    short_audio = np.zeros(4000, dtype=np.float32)
    result = engine.transcribe(short_audio, language="de")
    assert result == ""
    mock_whisper.transcribe.assert_not_called()


@patch("flowspeak.transcriber.mlx_whisper")
def test_transcribe_empty_audio_returns_empty(mock_whisper):
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    empty_audio = np.array([], dtype=np.float32)
    result = engine.transcribe(empty_audio, language="de")
    assert result == ""
    mock_whisper.transcribe.assert_not_called()


@patch("flowspeak.transcriber.mlx_whisper")
def test_transcribe_whitespace_result_returns_empty(mock_whisper):
    mock_whisper.transcribe.return_value = {
        "text": "   ",
        "segments": [],
        "language": "de",
    }
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    audio = np.random.randn(16000).astype(np.float32)
    result = engine.transcribe(audio, language="de")
    assert result == ""


@patch("flowspeak.transcriber.mlx_whisper")
def test_warmup_transcribes_silence(mock_whisper):
    mock_whisper.transcribe.return_value = {"text": "", "segments": [], "language": "de"}
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    engine.warmup()
    call_args = mock_whisper.transcribe.call_args
    audio_arg = call_args[0][0]
    assert isinstance(audio_arg, np.ndarray)
    assert len(audio_arg) == 16000  # 1 second of silence
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_transcriber.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'flowspeak.transcriber'`

- [ ] **Step 3: Implement `flowspeak/transcriber.py`**

```python
import numpy as np
import mlx_whisper


class TranscriptionEngine:
    def __init__(
        self,
        model_repo: str = "mlx-community/whisper-large-v3-turbo",
        min_samples: int = 8000,
    ):
        self._model_repo = model_repo
        self._min_samples = min_samples

    def transcribe(self, audio: np.ndarray, language: str = "de") -> str:
        if len(audio) < self._min_samples:
            return ""

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._model_repo,
            language=language,
        )
        text = result["text"].strip()
        return text if text else ""

    def warmup(self):
        silence = np.zeros(16000, dtype=np.float32)
        self.transcribe(silence)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/test_transcriber.py -v`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add flowspeak/transcriber.py tests/test_transcriber.py
git commit -m "feat: transcription engine wrapping mlx-whisper"
```

---

## Task 4: Text Injector

**Files:**
- Create: `flowspeak/injector.py`

No unit tests for this module — it requires macOS UI interaction (NSPasteboard, CGEvent). Tested manually.

- [ ] **Step 1: Create `flowspeak/injector.py`**

```python
import time
from AppKit import NSPasteboard, NSPasteboardTypeString
import Quartz


def inject_text(text: str, pre_paste_delay: float = 0.05, post_paste_delay: float = 0.15):
    """Paste text into the focused app by writing to clipboard and simulating Cmd+V.

    Preserves the user's clipboard contents by saving and restoring.
    """
    pb = NSPasteboard.generalPasteboard()

    # Save current clipboard
    old_contents = pb.stringForType_(NSPasteboardTypeString)

    # Set transcribed text on clipboard
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)

    # Wait for pasteboard sync
    time.sleep(pre_paste_delay)

    # Simulate Cmd+V via CGEvent
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    v_down = Quartz.CGEventCreateKeyboardEvent(src, 9, True)   # keycode 9 = 'v'
    v_up = Quartz.CGEventCreateKeyboardEvent(src, 9, False)
    Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_down)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_up)

    # Restore clipboard after paste is consumed by target app
    time.sleep(post_paste_delay)
    pb.clearContents()
    if old_contents is not None:
        pb.setString_forType_(old_contents, NSPasteboardTypeString)
```

- [ ] **Step 2: Quick manual smoke test**

Run:
```bash
cd /Users/keno/dev/temp/wispr-flow-clone
python -c "
from flowspeak.injector import inject_text
import time
print('Pasting in 3 seconds... click a text field!')
time.sleep(3)
inject_text('Hello from FlowSpeak!')
"
```
Expected: "Hello from FlowSpeak!" appears in whatever text field has focus. Previous clipboard contents are restored.

- [ ] **Step 3: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add flowspeak/injector.py
git commit -m "feat: text injector using NSPasteboard + CGEvent"
```

---

## Task 5: Hotkey Manager

**Files:**
- Create: `flowspeak/hotkey.py`

No unit tests — pynput requires macOS Accessibility permission and a real event loop. Tested via integration.

- [ ] **Step 1: Create `flowspeak/hotkey.py`**

```python
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
```

- [ ] **Step 2: Quick manual smoke test**

Run:
```bash
cd /Users/keno/dev/temp/wispr-flow-clone
python -c "
from flowspeak.hotkey import HotkeyManager
import time

def on_start():
    print('>>> Recording started')

def on_stop():
    print('>>> Recording stopped')

hk = HotkeyManager(on_start, on_stop)
hk.start()
print('Hold Right Option to test. Ctrl+C to exit.')
try:
    while True:
        time.sleep(0.1)
except KeyboardInterrupt:
    hk.stop()
"
```
Expected: Holding Right Option prints "Recording started", releasing prints "Recording stopped". Requires Accessibility permission for Terminal.

- [ ] **Step 3: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add flowspeak/hotkey.py
git commit -m "feat: hotkey manager with push-to-talk via pynput"
```

---

## Task 6: Menu Bar Icons

**Files:**
- Create: `icons/mic_idle.png`
- Create: `icons/mic_recording.png`
- Create: `icons/mic_working.png`

- [ ] **Step 1: Generate simple template icons**

We need 36x36 pixel PNG icons (18x18 @2x for Retina) in black — rumps with `template=True` will automatically adapt them to light/dark mode.

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
mkdir -p icons
python -c "
from PIL import Image, ImageDraw

def make_icon(filename, color='black', ring=False, dots=False):
    size = 36
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Mic body
    cx, cy = size // 2, size // 2 - 2
    draw.rounded_rectangle([cx-5, cy-9, cx+5, cy+5], radius=3, fill=color)

    # Mic stand arc
    draw.arc([cx-8, cy-4, cx+8, cy+10], start=0, end=180, fill=color, width=2)

    # Mic stand line
    draw.line([cx, cy+10, cx, cy+14], fill=color, width=2)

    # Mic stand base
    draw.line([cx-4, cy+14, cx+4, cy+14], fill=color, width=2)

    if ring:
        # Recording indicator: circle around mic
        draw.ellipse([2, 2, size-2, size-2], outline=color, width=2)

    if dots:
        # Working indicator: dots below
        for i in range(3):
            x = cx - 6 + i * 6
            draw.ellipse([x-1, cy+16, x+1, cy+18], fill=color)

    img.save(filename)

make_icon('icons/mic_idle.png')
make_icon('icons/mic_recording.png', ring=True)
make_icon('icons/mic_working.png', dots=True)
print('Icons created.')
"
```

Note: This requires `Pillow`. If not available, create simple placeholder PNGs:

```bash
pip install Pillow
```

Then re-run the icon generation script.

- [ ] **Step 2: Verify icons exist**

Run: `ls -la /Users/keno/dev/temp/wispr-flow-clone/icons/`
Expected: Three PNG files, each ~1-2KB

- [ ] **Step 3: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add icons/
git commit -m "feat: menu bar template icons for idle/recording/working states"
```

---

## Task 7: App Shell — Wire Everything Together

**Files:**
- Create: `flowspeak/app.py`
- Modify: `flowspeak/__main__.py`

- [ ] **Step 1: Create `flowspeak/app.py`**

```python
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
```

- [ ] **Step 2: Update `flowspeak/__main__.py`**

```python
import Quartz  # Eager import to prevent pyobjc race condition

from flowspeak.config import load_config
from flowspeak.app import FlowSpeakApp


def check_accessibility() -> bool:
    return bool(Quartz.AXIsProcessTrusted())


def main():
    if not check_accessibility():
        import rumps
        rumps.alert(
            title="FlowSpeak — Accessibility Required",
            message=(
                "FlowSpeak needs Accessibility permission to capture hotkeys "
                "and paste text.\n\n"
                "Go to: System Settings → Privacy & Security → Accessibility\n"
                "Add and enable your terminal app (e.g., Terminal, iTerm2)."
            ),
        )

    config = load_config()
    app = FlowSpeakApp(config)
    app.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/keno/dev/temp/wispr-flow-clone && python -m pytest tests/ -v`
Expected: All tests from Tasks 1-3 still PASS (9 tests total)

- [ ] **Step 4: Manual integration test**

Run:
```bash
cd /Users/keno/dev/temp/wispr-flow-clone
python -m flowspeak
```

Expected behavior:
1. Menu bar icon appears (mic icon)
2. Shows "Loading..." while Whisper model loads (first run downloads ~1.5GB)
3. After loading, icon returns to idle
4. Hold Right Option → icon changes to recording state
5. Speak in German → release key → icon changes to working state
6. Transcribed text is pasted into the focused text field
7. Icon returns to idle
8. Click menu bar icon → shows "Sprache: Deutsch" menu item
9. Click language item → toggles between DE/EN

- [ ] **Step 5: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add flowspeak/app.py flowspeak/__main__.py
git commit -m "feat: wire up app shell — full dictation pipeline working"
```

---

## Task 8: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

```markdown
# FlowSpeak

Local voice dictation for macOS. Hold a key, speak, release — text appears.

All processing runs on your Mac using Apple Silicon GPU acceleration. No cloud, no subscription, works offline.

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon (M1/M2/M3/M4)
- Python 3.10+
- ffmpeg (`brew install ffmpeg`)

## Install

```bash
pip install -e .
```

The first run downloads the Whisper model (~1.5GB) from HuggingFace.

## Usage

```bash
flowspeak
# or
python -m flowspeak
```

1. Grant **Accessibility** permission to your terminal (System Settings → Privacy & Security → Accessibility)
2. Grant **Microphone** permission when prompted
3. Hold **Right Option** to record, release to transcribe and paste
4. Click the menu bar icon to switch between German and English

## Configuration

Create `~/.config/flowspeak/config.toml` to override defaults:

```toml
[general]
language = "de"  # "de" or "en"

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[audio]
min_duration_seconds = 0.5

[injection]
pre_paste_delay = 0.05
post_paste_delay = 0.15
```
```

- [ ] **Step 2: Commit**

```bash
cd /Users/keno/dev/temp/wispr-flow-clone
git add README.md
git commit -m "docs: add README with install and usage instructions"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Push-to-talk dictation (Right Option) → Task 5 (hotkey), Task 7 (app)
- [x] Toggle mode → Not in v1 implementation (spec says secondary, deprioritized). Hotkey manager can be extended later.
- [x] Menu bar presence with states → Task 6 (icons), Task 7 (app)
- [x] Language toggle DE/EN → Task 7 (app menu)
- [x] Text injection with clipboard preservation → Task 4 (injector)
- [x] Config file → Task 1 (config)
- [x] Model warmup → Task 7 (app startup)
- [x] Error handling (permissions, short audio, empty results) → Task 7 (app)

**Placeholder scan:** No TBDs, TODOs, or "implement later" anywhere. All code blocks are complete.

**Type consistency:**
- `AudioRecorder.get_audio()` returns `np.ndarray` — used correctly in Task 7
- `AudioRecorder.is_valid_duration(audio)` takes `np.ndarray` — called correctly in Task 7
- `TranscriptionEngine.transcribe(audio, language)` — signature matches calls in Task 7
- `inject_text(text, pre_paste_delay, post_paste_delay)` — signature matches call in Task 7
- `HotkeyManager(on_start, on_stop)` — callback signatures match Task 7
- `FlowSpeakConfig` field names match `load_config` TOML mapping and `app.py` usage

**Note on toggle mode:** The spec lists `Ctrl+Shift+Space` toggle mode as secondary. The hotkey manager supports only push-to-talk in this plan. Toggle can be added as a follow-up — the `HotkeyManager` class is structured to easily support it by adding a combo key handler.

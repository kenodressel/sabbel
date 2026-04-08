# Voice Dictation Tool for macOS — Design Spec

## Overview

A local, privacy-first voice dictation tool for macOS inspired by Wispr Flow. The user holds a hotkey, speaks, releases the key, and the transcribed text is pasted into whatever app has focus. All processing runs on-device using Apple Silicon GPU acceleration — no cloud APIs, no subscription, works offline.

**Working name**: `flowspeak`

## Requirements

### Functional

- **Push-to-talk dictation**: Hold Right Option key to record, release to transcribe and paste
- **Toggle mode** (secondary): Press a configurable key combo to start, press again to stop
- **Menu bar presence**: Status icon showing idle/recording/transcribing state
- **Language**: German (default), switchable to English via menu bar
- **Text injection**: Transcribed text pasted into the currently focused text field
- **Clipboard preservation**: Save clipboard before paste, restore after

### Non-Functional

- **Latency target**: Under 3 seconds from key release to text appearing (for typical 5-10 second utterances)
- **Memory**: Under 3GB total RSS
- **Privacy**: No audio data leaves the device
- **Offline**: Fully functional without internet (after initial model download)
- **macOS**: Sonoma (14) and newer on Apple Silicon

### Out of Scope (v1)

- LLM-based text formatting/rewriting
- Streaming/live preview while speaking
- Automatic language detection (manual toggle only)
- Custom hotkey configuration UI (hardcoded, changeable in config file)
- Windows/Linux support
- Audio file transcription (live mic only)

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Main Thread                            │
│                                                          │
│  rumps.App (NSApplication run loop)                      │
│  ├── Menu bar icon (idle / recording / transcribing)     │
│  ├── Menu: Language toggle (DE / EN)                     │
│  └── Menu: Quit                                          │
│                                                          │
│  sounddevice.InputStream (created on main thread)        │
│  Text injection (NSPasteboard + CGEvent)                 │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                 pynput Listener Thread                    │
│                                                          │
│  Daemon thread with own CFRunLoop                        │
│  Monitors Key.alt_r press/release                        │
│  Signals recording start/stop via threading.Event        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│               PortAudio Callback Thread                   │
│                                                          │
│  sounddevice callback pushes audio chunks                │
│  into queue.Queue (thread-safe)                          │
│  16kHz, mono, float32, 100ms chunks (1600 frames)        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                Transcription Worker Thread                │
│                                                          │
│  Waits for recording_done event                          │
│  Drains audio queue → numpy array                        │
│  Calls mlx_whisper.transcribe()                          │
│  Dispatches text injection to main thread                │
└──────────────────────────────────────────────────────────┘
```

### Thread Communication

```
pynput thread ──Event──→ Main thread: start/stop InputStream
                         │
PortAudio callback ──Queue──→ Transcription worker: audio chunks
                              │
Transcription worker ──callAfter──→ Main thread: inject text + update icon
```

## Components

### 1. App Shell (`app.py`)

The entry point. Subclasses `rumps.App`.

**Responsibilities:**
- Initialize all components
- Run the NSApplication main loop
- Own the menu bar icon and menu items
- Receive UI update dispatches from other threads

```python
class FlowSpeakApp(rumps.App):
    def __init__(self):
        super().__init__(
            name="FlowSpeak",
            title=None,           # icon only, no text
            icon="icons/mic_idle.png",
            template=True,        # adapts to dark/light mode
            quit_button="Quit",
        )
        self.menu = [
            rumps.MenuItem("Sprache: Deutsch"),
            None,  # separator
        ]
```

**Menu bar states:**
- **Idle**: Default mic icon (template, adapts to light/dark)
- **Recording**: Red/active mic icon + title "Rec..."
- **Transcribing**: Processing icon + title "..."
- **Error**: Warning icon (e.g., mic permission denied)

### 2. Hotkey Manager (`hotkey.py`)

Wraps `pynput.keyboard.Listener`.

**Key mapping:**
- **Push-to-talk**: `Key.alt_r` (Right Option) — hold to record, release to stop
- **Toggle mode**: `Ctrl+Shift+Space` — press to start, press again to stop (secondary, for longer dictation)

**Implementation details:**
- `on_press` fires repeatedly for held keys on macOS (key repeat). Guard with a boolean flag to avoid re-triggering.
- Callbacks run on pynput's daemon thread. Use `threading.Event` to signal the main app — never do heavy work in callbacks.
- pynput **silently fails** without Accessibility permission. On startup, check `AXIsProcessTrusted()` via pyobjc and show a rumps alert if not granted.

```python
from pynput.keyboard import Key, Listener, KeyCode
import objc
import Quartz

def check_accessibility() -> bool:
    """Check if Accessibility permission is granted. Works on macOS 14+."""
    try:
        # macOS 15+: modern API
        return bool(Quartz.CGPreflightListenEventAccess())
    except AttributeError:
        # macOS 14: fallback to AXIsProcessTrusted
        return bool(
            objc.loadBundleFunctions(
                None,
                [("AXIsProcessTrusted", b"Z")],
                "HIServices",
            ) or False
        )
```

### 3. Audio Recorder (`recorder.py`)

Wraps `sounddevice.InputStream`.

**Configuration:**
- Sample rate: 16,000 Hz
- Channels: 1 (mono)
- Dtype: float32
- Block size: 1,600 frames (100ms chunks)
- Latency: default (not latency-critical for dictation)

**Lifecycle:**
1. `InputStream` created once on the main thread at app startup
2. `stream.start()` called when hotkey pressed
3. Audio callback pushes `indata.copy()` into `queue.Queue`
4. `stream.stop()` called when hotkey released
5. Stream object is reused across recordings — no re-creation needed

**Buffer assembly:**
```python
def get_audio(self) -> np.ndarray:
    """Drain queue into a single numpy array for Whisper."""
    chunks = []
    while not self._queue.empty():
        chunks.append(self._queue.get())
    if not chunks:
        return np.array([], dtype='float32')
    return np.concatenate(chunks, axis=0).flatten()
```

The `.flatten()` is required: sounddevice produces shape `(N, 1)`, but mlx-whisper expects a 1-D array.

**Minimum duration guard**: If recording is shorter than 0.5 seconds (8,000 samples), discard it — likely an accidental key press, not intentional speech. Whisper can hallucinate on very short/silent audio.

### 4. Transcription Engine (`transcriber.py`)

Wraps `mlx_whisper.transcribe()`.

**Model**: `mlx-community/whisper-large-v3-turbo` (~1.5GB download, auto-cached in `~/.cache/huggingface/hub/`)

**API call:**
```python
import mlx_whisper

def transcribe(audio: np.ndarray, language: str = "de") -> str:
    if len(audio) < 8000:  # < 0.5s
        return ""
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
        language=language,
    )
    return result["text"].strip()
```

**Threading**: mlx-whisper is NOT thread-safe for concurrent calls, but is fine from a single dedicated worker thread. The transcription worker runs in its own thread and processes requests sequentially.

**Model preloading**: On first launch, the model downloads from HuggingFace (~1.5GB). Subsequent launches use the cached model. The first transcription call triggers model loading into GPU memory (~1-2 seconds). Consider a warmup transcription of silence at startup to avoid cold-start latency on the first real dictation.

**External dependency**: `ffmpeg` is required by mlx-whisper for file-based audio loading. Since we pass numpy arrays directly, ffmpeg is NOT needed at runtime. However, it is an install-time dependency of the package. Document this in setup instructions.

### 5. Text Injector (`injector.py`)

Uses native macOS APIs via pyobjc for maximum reliability.

**Approach**: NSPasteboard for clipboard + CGEvent for Cmd+V simulation. This is the most reliable method on macOS — same APIs native apps use internally.

```python
from AppKit import NSPasteboard, NSPasteboardTypeString
import Quartz
import time

def inject_text(text: str):
    """Paste text into the focused app, preserving clipboard."""
    pb = NSPasteboard.generalPasteboard()

    # 1. Save current clipboard
    old_contents = pb.stringForType_(NSPasteboardTypeString)

    # 2. Set transcribed text
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)

    # 3. Wait for pasteboard sync
    time.sleep(0.05)

    # 4. Simulate Cmd+V via CGEvent
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    v_down = Quartz.CGEventCreateKeyboardEvent(src, 9, True)   # keycode 9 = 'v'
    v_up   = Quartz.CGEventCreateKeyboardEvent(src, 9, False)
    Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_down)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_up)

    # 5. Restore clipboard after paste is consumed
    time.sleep(0.15)
    pb.clearContents()
    if old_contents is not None:
        pb.setString_forType_(old_contents, NSPasteboardTypeString)
```

**Requires**: Accessibility permission for the host process.

**Timing**: The 50ms pre-paste and 150ms post-paste delays are empirical values from the JustDictate reference project. Too short and the paste gets stale clipboard contents or restoration happens before the target app reads the clipboard.

### 6. Configuration (`config.py`)

Simple Python dataclass, loaded from `~/.config/flowspeak/config.toml`.

```toml
[general]
language = "de"           # "de" or "en"

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[hotkey]
push_to_talk = "alt_r"    # Right Option
toggle = "ctrl+shift+space"

[audio]
min_duration_seconds = 0.5

[injection]
pre_paste_delay = 0.05
post_paste_delay = 0.15
```

Falls config file does not exist, use defaults. Config is read at startup only (no hot-reload in v1).

## Data Flow

### Happy Path (Push-to-Talk)

```
1. User holds Right Option
   └─→ pynput on_press fires (pynput thread)
   └─→ Sets recording_active = True
   └─→ Signals main thread: stream.start()
   └─→ UI: icon → recording state

2. User speaks
   └─→ PortAudio callback fires every 100ms (PA thread)
   └─→ Pushes audio chunks into queue.Queue

3. User releases Right Option
   └─→ pynput on_release fires (pynput thread)
   └─→ Sets recording_active = False
   └─→ Signals main thread: stream.stop()
   └─→ UI: icon → transcribing state
   └─→ Signals transcription worker: recording_done

4. Transcription worker wakes up (worker thread)
   └─→ Drains queue → numpy array
   └─→ Checks minimum duration (≥ 0.5s)
   └─→ Calls mlx_whisper.transcribe(audio, language="de")
   └─→ Gets result["text"]

5. Text injection (dispatched to main thread via callAfter)
   └─→ Save clipboard (NSPasteboard)
   └─→ Set transcribed text on clipboard
   └─→ Simulate Cmd+V (CGEvent)
   └─→ Restore clipboard after 150ms
   └─→ UI: icon → idle state
```

### Error Cases

| Scenario | Handling |
|----------|----------|
| No Accessibility permission | Show rumps alert on startup with instructions. Hotkey listener will not receive events. |
| No Microphone permission | sounddevice raises `PortAudioError` on stream.start(). Catch and show alert. |
| Recording too short (< 0.5s) | Discard silently, return to idle state. |
| Whisper transcription returns empty/whitespace | Do not paste. Return to idle. |
| Whisper hallucinates on silence | Minimum duration guard + no_speech_threshold mitigate this. |
| Model not yet downloaded | First transcription triggers download. Show "Downloading model..." in menu bar title. |
| Exception in transcription | Log error, show brief error state in icon, return to idle. |

## Dependencies

### Python Packages

```
mlx-whisper>=0.4.0       # Speech-to-text (Apple Silicon optimized)
sounddevice>=0.5.0       # Audio capture
numpy>=1.24              # Audio buffer handling
pynput>=1.8.0            # Global hotkey listener
rumps>=0.4.0             # macOS menu bar app
pyobjc-framework-Cocoa   # NSPasteboard (clipboard)
pyobjc-framework-Quartz  # CGEvent (keystroke simulation), accessibility check
```

### System Dependencies

- **Python 3.10+** (for modern type hints and match statements)
- **ffmpeg**: Required as install-time dependency of mlx-whisper. Install via `brew install ffmpeg`.
- **macOS 14+ (Sonoma)** on Apple Silicon

### macOS Permissions Required

| Permission | Why | Where to Grant |
|------------|-----|----------------|
| Accessibility | Hotkey capture (pynput) + keystroke injection (CGEvent) | System Settings → Privacy & Security → Accessibility |
| Microphone | Audio recording (sounddevice) | System Settings → Privacy & Security → Microphone |

Both permissions must be granted to the host process: Terminal.app if running from terminal, or the bundled .app if packaged.

## File Structure

```
flowspeak/
├── flowspeak/
│   ├── __init__.py
│   ├── __main__.py       # Entry point: python -m flowspeak
│   ├── app.py            # FlowSpeakApp (rumps.App subclass)
│   ├── hotkey.py          # HotkeyManager (pynput wrapper)
│   ├── recorder.py        # AudioRecorder (sounddevice wrapper)
│   ├── transcriber.py     # TranscriptionEngine (mlx-whisper wrapper)
│   ├── injector.py        # TextInjector (NSPasteboard + CGEvent)
│   └── config.py          # Configuration loading
├── icons/
│   ├── mic_idle.png       # Default state (template image, 18x18 @2x)
│   ├── mic_recording.png  # Recording state
│   └── mic_working.png    # Transcribing state
├── pyproject.toml
└── README.md
```

## Startup Sequence

1. Load config from `~/.config/flowspeak/config.toml` (or use defaults)
2. Import `Quartz` eagerly (prevents pyobjc lazy-loading race condition between rumps and pynput)
3. Check Accessibility permission → alert if missing
4. Create `sounddevice.InputStream` (triggers Microphone permission prompt on first run)
5. Start pynput `Listener` (daemon thread)
6. Start transcription worker thread
7. Warm up Whisper model (transcribe 1 second of silence to preload into GPU memory)
8. Run `rumps.App` main loop (blocks main thread)

## Testing Strategy

### Manual Testing

- Record and transcribe German speech → verify output quality
- Record and transcribe English speech after language switch
- Test push-to-talk with various utterance lengths (1s, 5s, 15s, 30s)
- Test accidental short press (< 0.5s) → should be discarded
- Test clipboard preservation (copy something, dictate, verify original clipboard restored)
- Test in different apps (Safari, VS Code, Slack, Terminal, Notes)
- Test without Accessibility permission → should show alert
- Test without Microphone permission → should show alert

### Unit Tests

- `recorder.py`: Mock sounddevice, verify buffer assembly and minimum duration guard
- `transcriber.py`: Mock mlx_whisper, verify empty/short audio handling
- `injector.py`: Difficult to unit test (requires UI), integration test only
- `config.py`: Test default values, TOML parsing, missing file handling

## Performance Expectations

| Metric | Target | Basis |
|--------|--------|-------|
| Recording start latency | < 50ms | sounddevice.InputStream.start() |
| Audio callback latency | 100ms chunks | blocksize=1600 at 16kHz |
| Transcription (5s audio) | 0.5-1.5s | whisper-large-v3-turbo on M-series |
| Transcription (15s audio) | 1-3s | whisper-large-v3-turbo on M-series |
| Text injection | ~200ms | Clipboard + CGEvent + restore |
| **Total end-to-end (5s utterance)** | **~1-2s** | Sum of above |
| **Total end-to-end (15s utterance)** | **~1.5-3.5s** | Sum of above |
| Memory (idle) | ~1.5-2GB | Model loaded in GPU memory |
| Memory (recording) | +~10MB | Audio buffer |
| Model cold start | ~2-3s | First transcription loads model to GPU |
| Model download (first run) | ~1.5GB | One-time HuggingFace download |

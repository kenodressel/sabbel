# FlowSpeak — Future Work & Research Notes

## Current State (v0.1.0)

Working features:
- Push-to-talk dictation (Right Option key)
- mlx-whisper large-v3-turbo on Apple Silicon
- Auto language detection (cycle: Auto → DE → EN)
- Custom dictionary with initial_prompt + replacements
- Dictionary hot-reload (edit while running)
- Menu bar app with recording/transcribing states
- Clipboard-preserving text injection via CGEvent
- Accessibility permission dialog on first run

Known issues:
- Whisper sometimes hallucinates repeated words on short/noisy audio
- No repetition filter yet (custom regex filters were too aggressive, reverted)

---

## Planned: Auto-Learning Corrections (via Accessibility API)

**Concept**: After pasting text, monitor the target text field for edits. If the user corrects a word, save the mapping to the dictionary automatically.

**Research findings** (validated with working code):
- `AXUIElementCopyAttributeValue(element, "AXFocusedUIElement")` reads the focused text field
- `AXUIElementCopyAttributeValue(focused, "AXValue")` gets the text content
- No extra permissions needed beyond Accessibility (already granted for pynput)
- Works in: TextEdit, Slack, Safari, Chrome, VS Code, Notes
- Polling approach (read every 1s for 15s) is simpler than AXObserver
- **Problem**: In terminals (Claude Code, iTerm), AXValue returns the entire terminal buffer with control characters — makes it hard to find and diff our pasted text

**Implementation was attempted and reverted** because:
1. Terminal AXValue is too noisy (full buffer with escape codes)
2. Character-level diffing produced garbage corrections
3. Word-level diffing with region extraction was fragile
4. Need a better approach — possibly only enable in non-terminal apps

**Code reference**: The removed `correction.py` had working AX API calls. Key imports:
```python
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
)
from AppKit import NSWorkspace

# Get frontmost app PID
pid = NSWorkspace.sharedWorkspace().frontmostApplication().processIdentifier()

# Read focused element's text
app_elem = AXUIElementCreateApplication(pid)
err, focused = AXUIElementCopyAttributeValue(app_elem, "AXFocusedUIElement", None)
err2, value = AXUIElementCopyAttributeValue(focused, "AXValue", None)
```

**Next steps**:
- Detect if target is a terminal (check AXRole, bundle ID) and skip monitoring
- Only monitor in apps with proper AXTextField/AXTextArea elements
- Use word-level diff filtered to words that overlap with pasted text
- Consider a "correction hotkey" as simpler alternative

---

## Planned: Post-Processing LLM (Optional)

**Use case**: Clean up transcription — fix punctuation, remove filler words ("ähm", "äh"), format text properly.

**Research findings**:

Best models for local text cleanup on Apple Silicon:
| Model | Size (4-bit) | Speed (M-series) | German+EN | Notes |
|-------|-------------|-------------------|-----------|-------|
| **Qwen 3.5 2B** | ~1.5GB | 100-120 tok/s | Excellent | Top pick for speed + quality |
| **Gemma 4 E2B** | ~3GB | 60-80 tok/s | Good | Newer arch, 140 languages |
| **Gemma 4 E4B** | ~5GB | 40-60 tok/s | Very good | Better quality, more RAM |
| **Gemma 4 26B-A4B** | ~8-10GB | 30-85 tok/s | Excellent | MoE, only 4B active params |

**Integration approach**:
- Use `mlx-lm` library (same MLX ecosystem as mlx-whisper)
- Load model once at startup, keep in memory
- Simple system prompt: "Clean up this voice transcription. Fix punctuation. Remove filler words. Output only the cleaned text."
- Expected latency: 0.5-1.5s additional per dictation
- Make it toggleable — most dictation doesn't need LLM cleanup

```python
from mlx_lm import load, generate
model, tokenizer = load("mlx-community/Qwen3.5-2B-Instruct-4bit")
# Use tokenizer.apply_chat_template() for instruct models
```

**Decision**: Deferred. Current transcription quality is good enough. Add when users request it.

---

## Planned: Whisper Hallucination Handling

Whisper sometimes produces repeated text ("CR CR CR CR...") on:
- Very short audio segments
- Background noise / silence
- Certain microphone artifacts

**Approaches to investigate**:
- Whisper's built-in `compression_ratio_threshold` (default 2.4) and `no_speech_threshold` (default 0.6) — tried tighter values but they rejected valid speech too aggressively
- Silero VAD pre-filtering — detect if audio actually contains speech before sending to Whisper
- Post-transcription detection — check if output has abnormal repetition ratio, discard if so
- Longer minimum recording duration (current: 0.5s, maybe 1.0s)

---

## Planned: Packaging for Distribution

Options for shipping FlowSpeak as a standalone macOS app:

**py2app** (recommended):
- Creates a proper .app bundle with Info.plist
- Handles Accessibility/Microphone permission dialogs natively
- Can include the Whisper model in the bundle or download on first run
- `NSMicrophoneUsageDescription` in Info.plist for mic permission dialog

**PyInstaller**:
- Cross-platform, but less native on macOS
- Can produce a single .app bundle
- May need manual Info.plist configuration

**Considerations**:
- Model download (~1.5GB) — bundle it or download on first run?
- Code signing — required for Accessibility permission to work properly
- Notarization — required for distribution outside App Store
- Auto-update mechanism
- Icon design (proper .icns file)

---

## Dictionary Feature Details

**Two layers**:

1. **`initial_prompt`**: Biases Whisper toward domain vocabulary. Written as natural sentences, not word lists. 224 token limit (~150-200 words). Put high-priority terms at the end.

2. **`[replacements]`**: Post-transcription regex find-and-replace. Case-insensitive. Applied after Whisper output, before paste.

**Best practices for initial_prompt**:
- Write example sentences, not just word lists
- Match the domain you'll be dictating about
- Code-switch in the prompt if you code-switch when speaking: "Im Sprint-Planning haben wir die OKRs reviewed"
- Put important terms at the end (higher attention weight)

**Wispr Flow comparison**: They do the same two-layer approach — server-side vocabulary bias + client-side string replacement. Their "dictionary" feature maps to our `[replacements]` section.

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

1. Grant **Accessibility** permission when prompted (system dialog appears on first run)
2. Grant **Microphone** permission when prompted
3. Hold **Right Option** to record, release to transcribe and paste
4. Click the menu bar icon to switch language: Auto → Deutsch → English

## Custom Dictionary

Create `~/.config/flowspeak/dictionary.toml` to improve transcription of domain-specific terms:

```toml
[initial_prompt]
# Example sentences with your vocabulary — biases Whisper toward these terms.
# Write natural sentences, not just word lists. Max ~200 words.
text = "Im Sprint-Planning haben wir die OKRs und KPIs reviewed. Das MVP soll bis zum nächsten Standup fertig sein."

[replacements]
# Post-transcription find-and-replace (case-insensitive).
# Fixes terms that Whisper consistently gets wrong.
"kay pee eye" = "KPI"
"oh kay are" = "OKR"
```

The dictionary is hot-reloaded on every dictation — edit it while FlowSpeak is running.

## Configuration

Create `~/.config/flowspeak/config.toml` to override defaults:

```toml
[general]
language = "de"  # "de", "en", or omit for auto-detect

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[audio]
min_duration_seconds = 0.5

[injection]
pre_paste_delay = 0.05
post_paste_delay = 0.15
```

## How It Works

1. **Right Option held** → microphone starts recording (16kHz mono)
2. **Right Option released** → recording stops, audio sent to Whisper
3. **Whisper transcribes** → using mlx-whisper on Apple Silicon GPU
4. **Dictionary applied** → replacements from your dictionary.toml
5. **Text pasted** → clipboard injection via Cmd+V, original clipboard restored

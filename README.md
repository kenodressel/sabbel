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

# FlowSpeak

Local voice dictation for macOS. Hold a key, speak, release — text appears.

Runs entirely on your Mac using Apple Silicon GPU. No cloud, no subscription, works offline.

## Quick Start

```bash
# Install uv if you don't have it
curl -LsSf https://astral.sh/uv/install.sh | sh

# Clone and run
git clone https://github.com/yourname/flowspeak
cd flowspeak
uv run flowspeak
```

First run installs dependencies and downloads the Whisper model (~1.5GB). Subsequent runs start in under a second.

On first launch, macOS will ask for **Accessibility** and **Microphone** permissions.

## Usage

- Hold **Right Option** to record, release to transcribe and paste
- **🎙** idle · **🔴** recording · **◐** processing · **⚠️** error
- Click menu bar icon to cycle language: Auto → Deutsch → English

## Auto-Start on Login

```bash
make autostart          # Enable — starts now + on every login
make stop               # Stop
make restart             # Restart
make autostart-remove   # Disable auto-start
make status              # Check if running
```

## Custom Dictionary

```bash
make setup-dictionary   # Opens the dictionary file in your editor
```

Or edit `~/.config/flowspeak/dictionary.toml` directly:

```toml
[initial_prompt]
# Bias Whisper toward your vocabulary. Write natural sentences.
text = "Im Sprint-Planning haben wir die OKRs und KPIs reviewed."

[replacements]
# Fix terms Whisper gets wrong (case-insensitive find-and-replace).
"kay pee eye" = "KPI"
"oh kay are" = "OKR"
```

Changes are picked up on the next dictation — no restart needed.

## Configuration

Create `~/.config/flowspeak/config.toml`:

```toml
[general]
language = "de"  # "de", "en", or omit for auto-detect

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[audio]
min_duration_seconds = 0.5
```

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon
- [uv](https://docs.astral.sh/uv/) (or Python 3.10+ with pip)

## Logs

```bash
tail -f /tmp/flowspeak.log
```

## License

MIT

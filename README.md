# Sabbel

Lokale Spracherkennung fuer macOS. Taste halten, sprechen, loslassen — Text erscheint.

Laeuft komplett auf deinem Mac mit Apple Silicon GPU. Keine Cloud, kein Abo, funktioniert offline.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kenodressel/sabbel/main/install.sh | sh
```

On first launch, macOS will ask for **Accessibility** and **Microphone** permissions.
The Whisper model (~1.5GB) downloads automatically in the background.

## Usage

- Hold **Right Option** to record, release to transcribe and paste
- **🎙** idle · **🔴** recording · **◐** processing · **⚠️** error
- Click menu bar icon to cycle language: Auto → Deutsch → English

## Custom Dictionary

Edit `~/.config/sabbel/dictionary.toml`:

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

Create `~/.config/sabbel/config.toml`:

```toml
[general]
language = "de"  # "de", "en", or omit for auto-detect

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[audio]
min_duration_seconds = 0.5
```

## Auto-Start on Login

```bash
make autostart          # Enable — starts now + on every login
make stop               # Stop
make restart             # Restart
make autostart-remove   # Disable auto-start
make status              # Check if running
```

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon

## Development

```bash
git clone https://github.com/kenodressel/sabbel
cd sabbel
uv run sabbel            # Run from source
uv run pytest            # Run tests
make build-app           # Build standalone .app with py2app
make install-app         # Install to ~/Applications
```

## Logs

```bash
tail -f /tmp/sabbel-runtime.log
```

## License

MIT

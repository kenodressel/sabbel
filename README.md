# Sabbel

Lokale Spracherkennung fuer macOS. Taste halten, sprechen, loslassen — Text erscheint.

Laeuft komplett auf deinem Mac mit Apple Silicon GPU. Keine Cloud, kein Abo, funktioniert offline.

## Quick Start

```bash
# Install uv if you don't have it
curl -LsSf https://astral.sh/uv/install.sh | sh

# Clone and run
git clone https://github.com/kenodressel/wispr-flow-clone
cd wispr-flow-clone
uv run sabbel
```

First run installs dependencies and downloads the Whisper model (~1.5GB). Subsequent runs start in under a second.

On first launch, macOS will ask for **Accessibility** and **Microphone** permissions.

## Usage

- Hold **Right Option** to record, release to transcribe and paste
- **🎙** idle · **🔴** recording · **◐** processing · **⚠️** error
- Click menu bar icon to cycle language: Auto → Deutsch → English

## Auto-Start on Login

```bash
make build-app           # Build local Sabbel.app
make install-app         # Install Sabbel.app into ~/Applications
make reinstall-app       # Force a fresh install if bundle/launcher changed
make autostart          # Enable — starts now + on every login
make stop               # Stop
make restart             # Restart
make autostart-remove   # Disable auto-start
make status              # Check if running
```

`make autostart` now installs and launches `~/Applications/Sabbel.app`, so macOS permission dialogs
and login-item startup use the app identity instead of `python3.x`.

Important for local development:

- The installed `Sabbel.app` launcher already loads Python code from this workspace.
- That means normal edits to files in `sabbel/` only need `make restart`.
- Reinstalling the app bundle can cause macOS Accessibility/Microphone permissions to be asked again.
- Only use `make reinstall-app` when the app bundle itself changed, for example launcher code, bundle metadata, or packaged resources.

## Signing And Distribution

For local development, the default build uses ad-hoc signing:

```bash
make show-signing
make install-app
```

That is fine for development on one machine, but macOS may treat rebuilt apps as a new identity for
Accessibility/TCC purposes.

For a smoother rollout to other Macs, build and sign the `.app` once with a stable signing identity:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" make install-app
```

Important behavior:

- Users do not need to create their own key if you distribute the signed `.app` you built.
- If users build the app locally themselves, they are creating a different app identity and may get fresh permission prompts.
- Accessibility and Microphone permission still must be approved once per Mac by the user. That cannot be pre-granted by the app.
- Keeping the same bundle identifier and signing identity across updates is what prevents repeated permission churn.

## Custom Dictionary

```bash
make setup-dictionary   # Opens the dictionary file in your editor
```

Or edit `~/.config/sabbel/dictionary.toml` directly:

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

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon
- [uv](https://docs.astral.sh/uv/) (or Python 3.10+ with pip)

## Logs

```bash
tail -f /tmp/sabbel.log
```

## License

MIT

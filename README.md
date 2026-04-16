<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="icons/sabbel-logo.svg" />
    <source media="(prefers-color-scheme: light)" srcset="icons/sabbel-logo-dark.svg" />
    <img src="icons/sabbel-logo.svg" width="120" alt="Sabbel logo" />
  </picture>
</p>

<h1 align="center">Sabbel</h1>

<p align="center">
  <strong>Local voice dictation for macOS — hold a key, speak, release, text appears.</strong>
</p>

<p align="center">
  <a href="https://github.com/kenodressel/sabbel/releases/latest"><img src="https://img.shields.io/github/v/release/kenodressel/sabbel?style=flat&color=blue" alt="Release"></a>
  <a href="https://github.com/kenodressel/sabbel/stargazers"><img src="https://img.shields.io/github/stars/kenodressel/sabbel?style=flat&color=yellow" alt="Stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/kenodressel/sabbel?style=flat" alt="License"></a>
</p>

<p align="center">
  <a href="#why-sabbel">Why Sabbel</a> •
  <a href="#install">Install</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#custom-dictionary">Custom Dictionary</a> •
  <a href="#development">Development</a>
</p>

---

Speaking is 3-4x faster than typing. Sabbel turns your voice into text anywhere on your Mac — powered by Whisper on Apple Silicon, fully offline.

## Why Sabbel

<table>
<tr>
<td width="50%">

### macOS Dictation

- Breaks on mixed language ("Kubernetes" → "communities")
- No custom dictionary
- Times out after 30-60 seconds
- ~10-20% word error rate
- Audio may be sent to Apple servers

</td>
<td width="50%">

### Sabbel

- Handles German + English tech terms in the same sentence
- Custom dictionary with domain-specific vocabulary
- No timeout — dictate as long as you want
- ~2-4% word error rate (Whisper large-v3)
- 100% local, fully offline, nothing leaves your Mac

</td>
</tr>
</table>

**Compared to paid alternatives:**

| | Sabbel | Wispr Flow | Superwhisper |
|---|---|---|---|
| **Price** | Free | $15/month | $8/month |
| **Processing** | Local (Apple Silicon GPU) | Cloud | Local |
| **Open Source** | Yes | No | No |
| **Custom Dictionary** | Yes | Yes | Yes |
| **Privacy** | Audio never leaves your Mac | Audio sent to cloud | Local option |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kenodressel/sabbel/main/install.sh | sh
```

Install without autostart:

```bash
curl -fsSL https://raw.githubusercontent.com/kenodressel/sabbel/main/install.sh | sh -s -- --no-autostart
```

No dependencies, no Python, no package manager. The script downloads `Sabbel.app` and puts it in `~/Applications`.

On first launch:
- macOS asks for **Accessibility** and **Microphone** permissions
- The Whisper model (~1.5GB) downloads automatically in the background

## How It Works

| Action | What happens |
|--------|-------------|
| Hold **Right Option** (⌥) | Recording starts |
| Release **Right Option** (⌥) | Speech is transcribed and pasted into the focused app |

The menu bar icon shows the current state:

| Icon | State |
|------|-------|
| **🎙** | Idle — ready to record |
| **🔴** | Recording |
| **◐** | Processing / transcribing |
| **⚠️** | Error (auto-clears after 2s) |

Click the menu bar icon to cycle the language: **Auto** → **Deutsch** → **English**

## Configuration

Create `~/.config/sabbel/config.toml` to override defaults:

```toml
[general]
language = "de"    # "de", "en", or omit for auto-detect
hotkey = "alt_r"   # Right Option key. Other options: f5, ctrl_r, cmd_r, ...

[model]
repo = "mlx-community/whisper-large-v3-turbo"

[audio]
min_duration_seconds = 0.5

[history]
enabled = false        # Off by default. When true, transcriptions are
                       # appended to ~/.config/sabbel/history.log.
max_bytes = 1000000    # Rotate log to .1 once it grows beyond this.
```

> **⚠️ Privacy note:** History is opt-in because transcriptions can include anything you dictate — including passwords, private notes, or confidential work data. Enable it only if you're comfortable with that trade-off. The log stays on your machine; nothing is uploaded. Use the **History → Clear** menu entry to wipe it.

## Custom Dictionary

Edit `~/.config/sabbel/dictionary.toml` to improve recognition for domain-specific terms:

```toml
[initial_prompt]
# Bias Whisper toward your vocabulary. Write natural sentences.
text = "Im Sprint-Planning haben wir die OKRs und KPIs reviewed."

[replacements]
# Post-transcription find-and-replace (case-insensitive).
"kay pee eye" = "KPI"
"oh kay are" = "OKR"
```

Changes are picked up on the next dictation — no restart needed.

## Auto-Start on Login

If you build from source, you can set up Sabbel as a login item:

```bash
make autostart          # Start now + on every login
make stop               # Stop
make restart             # Restart
make reinstall-app      # Reinstall app bundle after packaging changes
make autostart-remove   # Disable
make status              # Check if running
```

For normal Python code changes, prefer `make restart`. Reinstalling the app bundle can cause macOS to treat it like a fresh app for Accessibility and Microphone permissions, so `make reinstall-app` should only be used after bundle or packaging changes.

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1 or later)

## Development

```bash
git clone https://github.com/kenodressel/sabbel
cd sabbel
uv run sabbel            # Run from source
uv run pytest            # Run tests
make build-app           # Build standalone .app with py2app
make install-app         # Build + install + reset permissions
make restart             # Reload the already installed app during normal dev
make reset-permissions   # Reset Accessibility + Microphone permissions manually
```

Note: `make install-app` automatically resets TCC permissions because each build has a new ad-hoc signature. macOS will prompt for Accessibility and Microphone permissions again on launch.

## Contributing

Contributors are very welcome.

Check the [open issues](https://github.com/kenodressel/sabbel/issues) for things to work on. If you pick something up, mention it in the issue so work doesn't overlap.

## How It's Built

Sabbel is a Python menu bar app built with [rumps](https://github.com/jaredks/rumps). Speech recognition runs locally via [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) on Apple Silicon GPU. The app is packaged as a self-contained `.app` bundle using [py2app](https://github.com/ronaldoussoren/py2app) — Python runtime and all dependencies are embedded, so end users don't need Python installed.

Releases are built automatically on GitHub Actions (Apple Silicon runner) and published as GitHub Releases.

## Logs

```bash
tail -f /tmp/sabbel-runtime.log
```

## License

MIT

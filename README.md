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
  <a href="#development">Development</a>
</p>

---

Speaking is 3-4x faster than typing. Sabbel turns your voice into text anywhere on your Mac — powered by NVIDIA Parakeet on Apple Silicon, fully offline.

## Why Sabbel

<table>
<tr>
<td width="50%">

### macOS Dictation

- Breaks on mixed language ("Kubernetes" → "communities")
- Language must be picked manually
- Times out after 30-60 seconds
- Audio may be sent to Apple servers

</td>
<td width="50%">

### Sabbel

- Handles German + English tech terms in the same sentence
- Auto-detects the language, no manual switching
- No timeout — dictate as long as you want
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
| **Privacy** | Audio never leaves your Mac | Audio sent to cloud | Local option |

Transcription runs at roughly 17x real time on an M-series Mac — 4.6 seconds
of speech came back in 0.27s in local testing.

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
- The Parakeet model (~2.3GB) downloads automatically in the background

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

## Configuration

Create `~/.config/sabbel/config.toml` to override defaults:

```toml
[general]
hotkey = "alt_r"   # Right Option key. Other options: f5, ctrl_r, cmd_r, ...

[model]
repo = "mlx-community/parakeet-tdt-0.6b-v3"

[audio]
min_duration_seconds = 0.5

[history]
enabled = false        # Seed value. The menu toggle is the primary control
                       # and overrides this once flipped.
max_bytes = 1000000    # Rotate log to .1 once it grows beyond this.
```

Nothing in this file can stop Sabbel from starting. A value Sabbel cannot use
is ignored in favour of its default — a malformed file falls back entirely —
and the reason is written to `/tmp/sabbel-runtime.log`.

**Sabbel also cleans the file up after an upgrade.** Entries that are obsolete
or unusable are commented out in place, each with a `# sabbel:` note saying
why, so you aren't warned about the same dead line on every launch:

```toml
[general]
# sabbel: no longer used by this version of Sabbel
# language = "de"
hotkey = "ctrl_r"        # your comments and settings are left alone
```

Your original file is kept as `config.toml.bak` before the first such
rewrite. Only lines Sabbel can locate unambiguously are touched, and the
result has to yield exactly the same effective settings — otherwise the file
is left untouched and the entries are just ignored at load time.

> **Upgrading from a pre-0.4.0 (Whisper) install?** Nothing to do. Sabbel now
> runs Parakeet, so a `[model] repo` pinned to a Whisper model no longer
> loads: Sabbel uses its default model, comments the line out, and tells you.
> `[general] language` and the custom dictionary are gone too, and get the
> same treatment.

**Toggle from the menu bar:** open the Sabbel menu → **History → Save history**. The checkmark persists across restarts (stored in `~/.config/sabbel/preferences.json`), so you don't need to edit TOML. Use **History → Open log** and **History → Clear log** to view or wipe it.

> **⚠️ Privacy note:** History is off by default because transcriptions can include anything you dictate — including passwords, private notes, or confidential work data. Enable it only if you're comfortable with that trade-off. The log stays on your machine; nothing is uploaded.

### Microphone

Click the Sabbel menu → **Microphone** to pick which input device Sabbel records from. The list refreshes every time you open the menu, so plugging in a USB mic or docking station is reflected immediately. The choice persists across restarts.

If the saved device is offline (e.g., dock unplugged), Sabbel falls back to the system default and shows a notification on the next recording. When the device comes back, it's used again automatically — no need to re-pick.

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

Sabbel is a Python menu bar app built with [rumps](https://github.com/jaredks/rumps). Speech recognition runs locally via [parakeet-mlx](https://github.com/senstella/parakeet-mlx) on Apple Silicon GPU. The app is packaged as a self-contained `.app` bundle using [py2app](https://github.com/ronaldoussoren/py2app) — Python runtime and all dependencies are embedded, so end users don't need Python installed.

Releases are built automatically on GitHub Actions (Apple Silicon runner) and published as GitHub Releases.

## Logs and bug reports

Sabbel menu → **Copy diagnostics** puts everything a bug report needs on your
clipboard: version, macOS, MLX version, the model in use, your `config.toml`
if you have one, and the last 40 log lines. That beats a screenshot of the
status line, which never shows the actual error.

It contains no transcribed text — the log records how many characters a take
produced, never what you said.

To follow along live:

```bash
tail -f /tmp/sabbel-runtime.log
```

## License

MIT

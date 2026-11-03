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

Speaking is 3-4x faster than typing. Sabbel turns your voice into text anywhere on your Mac — powered by NVIDIA Parakeet on the Apple Neural Engine, fully offline.

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
| **Processing** | Local (Apple Neural Engine) | Cloud | Local |
| **Open Source** | Yes | No | No |
| **Privacy** | Audio never leaves your Mac | Audio sent to cloud | Local option |

Sabbel transcribes while you speak, so the text is pasted about 50 ms after
you release the key, whether you spoke for five seconds or five minutes. It
uses about 50 MB of memory.

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
- The Parakeet model (~470 MB) downloads automatically in the background

To update, run the install command again. Sabbel tells you when there is a new release: the menu shows **Update vX available**.

Updates keep those permissions, because every release is signed with the same certificate. The one exception is the update from a 0.5.x build: those were not signed with it, so the installer resets the permissions once and macOS asks again, instead of showing them as granted while denying them.

> **Updating from 0.5.x?** The old Python version kept a ~2.3 GB model in
> `~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3`.
> Sabbel no longer uses it, so you can delete that folder.

## How It Works

| Action | What happens |
|--------|-------------|
| Hold **Right Option** (⌥) | Recording starts |
| Release **Right Option** (⌥) | The text is pasted into the focused app |
| Press **Esc** while holding | Cancels the take |

Sabbel transcribes while you speak. Sabbel menu → **Show Live Text** opens a small window that shows the text as it forms, without taking the focus from the app you are dictating into.

The menu bar icon shows the current state:

| Icon | State |
|------|-------|
| **🎙** | Idle — ready to record |
| **🔴** | Recording |
| **◐** | Finishing the last words |
| **⚠️** | Error (clears after 2s) |

## Configuration

Create `~/.config/sabbel/config.toml` to override defaults:

```toml
[general]
hotkey = "alt_r"   # Right Option key. Other options: f5, ctrl_r, cmd_r, ...

[audio]
min_duration_seconds = 0.5

[history]
enabled = false        # Seed value. The menu toggle is the primary control
                       # and overrides this once flipped.
max_bytes = 1000000    # Rotate log to .1 once it grows beyond this.

[text]
tidy = true            # Remove fillers ("ähm", "uh") and accidental repeats.
app_rules = true       # Per-app formatting, e.g. no trailing period in Slack.
voice_commands = true  # Spoken "neue Zeile" / "new paragraph" and "press enter".
```

`app_rules` drops the final full stop in chat, terminal and IDE apps (Slack, Discord, Teams, WhatsApp, Telegram, Signal, Messages; Terminal, iTerm, Ghostty, Warp, kitty, Alacritty, WezTerm; VS Code, Cursor, Zed, JetBrains, Xcode, Windsurf). Question marks, exclamation marks, ellipses and abbreviations ("z. B.", "usw.") keep theirs; other apps are untouched.

`tidy` removes spoken fillers (äh, ähm, öh, hm, mhm, uh, uhm, erm, …) and
accidental repeats of two to four words ("at the at the" becomes "at the").
"um" goes only when it is set off on both sides ("Um, I think", "so, um, yes"),
since it is also a German word ("um 5 Uhr", "es geht um, äh, …"). A single doubled word is always kept.

`voice_commands` turns spoken commands into formatting and a key press, in German
and English, in dictations only. "neue Zeile" / "new line" becomes a line break,
"neuer Absatz" / "new paragraph" a blank line; the punctuation the recognizer puts
around the command goes with it ("Punkt eins, neue Zeile, Punkt zwei" pastes as
two lines). At the very end of a dictation, "press enter", "send message",
"press return", "Enter drücken" or "Return drücken" is cut off and Sabbel presses
Return after the paste (only when the text was really pasted). Saying only the
send command presses Return without pasting. Set it to `false` and everything
is pasted as spoken.

Nothing in this file can stop Sabbel from starting. A value Sabbel cannot use
is ignored in favour of its default — a malformed file falls back entirely —
and the reason is written to `/tmp/sabbel-runtime.log`. Entries from older
versions (`[model] repo`, `[injection]`, `[general] language`) are ignored the
same way; you can delete them.

**Glossary:** the recognizer sometimes misspells English tech terms inside German speech ("Kuber Netties", "Git Hub"). Sabbel menu → **Edit Glossary…** opens `~/.config/sabbel/glossary.txt` (created with a commented template) so you can fix them with replacement rules. Edits apply on the next take, no restart.

```
# Comments and blank lines are ignored.
Kubernetes                  # a term alone fixes its casing
GitHub: Git Hub, git hab    # term: aliases, each alias becomes the term
das DAM: das Damm           # an alias may carry context words
```

Matching ignores case, keeps umlauts significant and only hits whole words ("Hub" inside "Hubert" stays); the longest alias wins. A bad line is skipped and logged with its line number. `sabbel-eval --glossary FILE` applies the same file to every hypothesis.

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
make install-app        # Build and reinstall the app
make autostart-remove   # Disable
make status              # Check if running
```

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1 or later)

## Development

```bash
git clone https://github.com/kenodressel/sabbel
cd sabbel
make test               # Unit tests (no model needed)
make test-model          # Tests against the real Parakeet model (slow)
make test-e2e            # The real app on this Mac: record, transcribe, paste (~30s, hands off)
make build-app           # Build and sign dist/Sabbel.app; VERSION=1.2.3 sets the version
make install-app         # Build + install into ~/Applications
make restart             # Restart the installed app
make reset-permissions   # Reset Accessibility + Microphone permissions manually
```

Building needs Xcode 16.4 or later (the Command Line Tools lack Swift's test frameworks). The Makefile uses `/Applications/Xcode.app`; set `DEVELOPER_DIR` for another location.

Note: `make build-app` signs with `$SABBEL_SIGN_IDENTITY`. If that is unset it uses the "Sabbel Release" certificate when your keychain has it (see below), and signs ad hoc otherwise. `make install-app` and `install.sh` keep the Accessibility and Microphone grants when the installed app and the new one have the same designated requirement ("Sabbel Release" on both sides), and reset them when the installed app is ad hoc signed or signed differently, so macOS asks again. An ad-hoc signature changes with every build, so without the certificate every `make install-app` resets them. `make reset-permissions` resets them by hand.

### Signing releases

macOS ties Accessibility and Microphone grants to the app's code signature. Releases are therefore signed with a stable self-signed certificate, "Sabbel Release", so that grants survive updates. There is no notarization, so the app is not sandboxed or hardened. The maintainer creates the certificate once; CI only imports it.

```bash
# 1. Create a self-signed code-signing certificate (10 years).
cat > /tmp/sabbel-cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Sabbel Release
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config /tmp/sabbel-cert.cnf -keyout sabbel-release.key -out sabbel-release.crt

# 2. Bundle it as a .p12. Use macOS's own /usr/bin/openssl (LibreSSL) throughout:
#    it writes a format `security import` reads; Homebrew OpenSSL 3 needs -legacy for that.
P12_PASSWORD="$(/usr/bin/openssl rand -base64 24)"
/usr/bin/openssl pkcs12 -export -inkey sabbel-release.key -in sabbel-release.crt \
  -name "Sabbel Release" -out sabbel-release.p12 -passout "pass:$P12_PASSWORD"

# 3. Import it locally so `make build-app` finds it, and trust it for code signing
#    (without the trust step a self-signed certificate is not a valid identity).
security import sabbel-release.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PASSWORD" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db sabbel-release.crt
security find-identity -v -p codesigning   # must list "Sabbel Release"

# 4. Store the two secrets for the Release workflow.
base64 < sabbel-release.p12 | gh secret set SABBEL_SIGN_P12
printf '%s' "$P12_PASSWORD" | gh secret set SABBEL_SIGN_P12_PASSWORD
```

Back up `sabbel-release.p12` and its password somewhere safe (a password manager), then delete the loose `.key` and `.crt`. If the certificate is lost, a new one has a different signature and every user has to grant the permissions once more. The Release workflow refuses to publish a tag build that is not signed by "Sabbel Release". Tags containing `-` (for example `v1.0.0-rc.1`) are published as prereleases, which the update check and `install.sh` never pick up on their own. Install one on purpose with `curl -fsSL https://raw.githubusercontent.com/kenodressel/sabbel/main/install.sh | SABBEL_VERSION=v1.0.0-rc.1 sh`.

## Contributing

Contributors are very welcome.

Check the [open issues](https://github.com/kenodressel/sabbel/issues) for things to work on. If you pick something up, mention it in the issue so work doesn't overlap.

## How It's Built

Sabbel is a native Swift menu bar app (Swift Package Manager, in `native/`). Speech recognition runs locally with NVIDIA's Parakeet TDT 0.6b v3 on CoreML via [FluidAudio](https://github.com/FluidInference/FluidAudio), mostly on the Apple Neural Engine. While you hold the key, Sabbel re-transcribes the last ten seconds once a second and settles the words that stay stable, so on release only the last few seconds are left to transcribe. Versions up to 0.5.x were a Python app (rumps, parakeet-mlx, py2app).

Releases are built automatically on GitHub Actions (Apple Silicon runner) and published as GitHub Releases.

## Logs and bug reports

Sabbel menu → **Copy diagnostics** puts everything a bug report needs on your
clipboard: version, macOS, the speech engine and model, your `config.toml`
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

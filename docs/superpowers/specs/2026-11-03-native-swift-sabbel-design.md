# Native Sabbel (Swift) — Design

**Date:** 2026-11-03
**Status:** Approved 2026-11-03

## Why

Sabbel works, but it has two problems.

- **Long dictations feel slow.** The whole take is transcribed only after the
  hotkey is released, so the wait grows with the length of the take. At five
  minutes it is about 5 s, and that is when you notice it most.
- **The stack is heavy.** Python, py2app, MLX and a hand-patched bundle make
  every release fragile. v0.4.x shipped with MLX's thread-owned streams
  broken, and v0.5.0 leaked ~0.5 GB of Metal cache per dictation.

Palaver (`~/dev/temp/meeting-transcribe`) has since shown two ideas worth
bringing over:

- real-time transcription: a sliding window plus local agreement, so words
  settle 2–3 s after they are spoken;
- a glossary.

Keno also wants Sabbel to become a real app instead of a menu bar item only:

- a window with the glossary, recent dictations and a few settings, including
  an optional cloud provider;
- a window that looks good.

So Sabbel becomes a native Swift app, in two phases:

1. **Phase 1:** rebuild the stack in Swift, with real-time transcription.
2. **Phase 2:** glossary, the app's views and design, and the cloud provider.

**This document specifies Phase 1 in full.** Phase 2 is only outlined here,
so that Phase 1 does not paint it into a corner. It gets its own design.

## What the spike showed (2026-11-03)

308 utterances (4–30 s) of Keno's own speech, taken from Palaver's mic
recordings. They are mostly German with English terms mixed in, which is
how Keno dictates. The reference is Palaver's transcript, which is itself
Parakeet MLX, so the comparison leans slightly towards MLX.

| Engine | WER | English terms kept | ms / clip | × realtime |
|---|---|---|---|---|
| Parakeet v3, MLX (Sabbel today) | 7.2 % | 81 % | 289 | 72× |
| Parakeet v3, CoreML via FluidAudio | 7.0 % | 78 % | 136 | 153× |
| Parakeet "ultra", CoreML via FluidAudio | 6.3 % | 78 % | 136 | 153× |
| Apple SpeechTranscriber (de_DE) | 12.1 % | 64 % | 177 | 118× |
| Apple DictationTranscriber (de_DE) | 22.0 % | 43 % | 719 | 29× |

Conclusions:

- **Apple's recogniser is out.** It needs a fixed locale, and it drops English
  terms from German sentences.
- **Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio)
  is as accurate as today and twice as fast.** It runs on the Neural Engine,
  and Swift-native dictation apps already ship on it.
- **The Swift route is not risky.** The spike package builds in about a
  minute. One catch: SwiftPM hangs forever downloading FluidAudio's
  `NemoTextProcessing` binary in this environment. Fetch it with `curl`,
  check its sha256 against the manifest, and point the target at a local
  path.

The spike code is throwaway. It lives in the session scratchpad, not in the
repo.

## Goals (Phase 1)

1. **Same behaviour as today, natively.** Everything Sabbel does for a user
   today keeps working (inventory below).
2. **Fast at any length.** From hotkey release to text pasted takes **≤ 0.5 s,
   whatever the length of the take**, measured on an M-series Mac for takes of
   10 s, 1 min and 5 min.
   - *My call:* the clock stops when Cmd+V is posted. It does not include
     waiting for the user to let go of modifiers, nor confirming the paste or
     restoring the clipboard, which happen after the text is already there.
   - It is measured by a benchmark in the real-model tests: streaming
     recorded audio at real speed, then timing release → final text. The e2e
     test logs the end-to-end figure.
3. **Accuracy not worse than today.** On the spike's clip set, the real-time
   path's final text scores no more than 0.5 points WER worse than the current
   full-pass Parakeet MLX (7.2 %), and keeps at least as many English terms.
   - *My call:* this is a local gate, run by `make eval` against the private
     evaluation set (see "Evaluation set").
4. **Live text in a window.** While dictating, the text appears live in the app
   window. A plain window is enough; the polished design is Phase 2.
   - *My call:* it is a normal window, opened from the menu bar. It never
     opens, comes to the front or takes focus by itself, so a take can never
     change the paste target. If the user has it on screen, they see the text
     live.
   - Sabbel stays a menu bar app (`LSUIElement`) in Phase 1. A Dock icon
     comes with the Phase 2 app, as does the floating overlay.
   - If the field focused when recording starts is a secure field, the live
     view shows only "•••": a dictated password is never shown, pasted,
     copied or saved.
5. **Lighter.** Idle memory is lower than today's ~3 GB, and memory stays
   flat over many takes. Today the real-model test checks that the cache stays
   below 64 MB over 10 takes; Phase 1 needs an equivalent test.
6. **Seamless upgrade.** Existing users update through `install.sh` and the
   in-app update notice as before. Their hotkey, microphone choice, history
   setting and history file carry over.

## Non-goals (Phase 1)

- Glossary, cloud provider, the history and glossary views, the visual design
  and the recording overlay. All of these are Phase 2.
- **Apple Developer ID and notarization.** Keno has no developer account yet,
  so signing follows Palaver's approach (below).
- Intel Macs. Sabbel already requires Apple Silicon.
- Keeping the Python version alive after the switch. It stays in the repo
  only until the Swift version has passed its checks.

## Anti-goals

Any of these makes Phase 1 a failure, even if the feature list is complete:

- dictation that is slower or less accurate than today, for short takes as
  well as long ones;
- text pasted into the wrong app, into a password field, or lost without a
  trace;
- users asked again for Accessibility or Microphone on every update;
- a user's clipboard overwritten or not restored.

## Behaviour to carry over

Taken from today's code (`sabbel/*.py`) and its tests. Each item comes with a
lesson learned the hard way; the docstrings and comments in the Python
modules explain why, and the Swift version keeps those reasons.

### Hotkey (`hotkey.py`)

- **Push-to-talk**, by default on right Option (`alt_r`); the key can be
  configured.
- **Recording starts on press.** Waiting for a hold threshold would clip the
  first word.
- **Combos are not dictation.** If another key arrives before release and the
  hold was under 1 s, it was a character combo (⌥L → @ on a German layout), so
  the take is discarded quietly. Holds longer than 1 s count as dictation no
  matter what was brushed along the way.
- **Escape** cancels a take at any hold length.
- **Synthetic keystrokes are ignored.**

### Recording (`recorder.py`)

- Audio is captured at **16 kHz mono**.
- **Microphone choice** from the menu, stored by device name. If the chosen
  mic is missing, Sabbel falls back to the system default and tells the user.
  The list refreshes when the menu opens.
- **Takes are rejected, each with its own status message:**
  - too short (< 0.5 s);
  - a dead stream: exact silence, meaning the mic is muted or the stream is
    broken, which also gets a notification;
  - no speech (RMS below 0.003);
  - empty transcription.

### Paste (`injector.py`)

- **The focus target** (app and pid) is captured when recording starts.
- **Before pasting,** Sabbel:
  - waits until the user has released all modifiers;
  - checks that the target is still frontmost, or the result is
    `FOCUS_CHANGED`;
  - refuses secure fields (`REFUSED_SECURE`): nothing is pasted, copied or
    saved;
  - detects when there is no text field (`LEFT_IN_CLIPBOARD`).
- **The paste itself:**
  - the text goes on a transient pasteboard item, marked
    `org.nspasteboard.TransientType` / `AutoGeneratedType` so clipboard
    managers skip it;
  - Cmd+V is sent to the target pid;
  - Sabbel watches the focused field's value to confirm the paste landed;
  - then the previous clipboard is restored.
- **New in Phase 1:**
  - re-check focus *immediately* before Cmd+V, not only before waiting for
    modifiers (a suspected race: Cmd+Tab right after a take could lose the
    paste);
  - the e2e test covers this case.
- **Each outcome gets its own notification wording,** as in
  `SabbelApp._INJECT_NOTICES`.
- **Pastes happen in take order and off the main thread.**

### History

- **Off by default.** Toggled from the menu; the setting is
  `history_enabled`.
- **Storage:** appended to `~/.config/sabbel/history.log`, capped at about
  1 MB.
- **What gets saved:**
  - a take is saved once its outcome is known;
  - a refused secure-field take is never saved;
  - a take whose paste failed *is* saved, because it is the only copy left.
- **Menu actions:** open the log and clear it.

### Menu bar and status

- **Icon states:** idle 🎙, recording, and working (spinner).
- **Honest status line:**
  - "Ready" only once the model has loaded;
  - a model failure is shown and blocks recording with a notification;
  - "loading" is shown if the user dictates during warm-up.
- **Error messages** in the status clear on a timer.
- **Copy diagnostics:** versions, permissions, mic, and the tail of the log.
- **Update check:**
  - once a day against the GitHub "latest" release, plus on demand from the
    menu;
  - a newer version is announced with a link and the `install.sh` one-liner.
- **Permissions:**
  - Accessibility and Microphone are monitored;
  - the status says what is missing.
- **Single instance:** a second launch exits.
- **Autostart:** a LaunchAgent, set up by `install.sh` and by
  `make autostart`.

### Configuration

- **Today:** `~/.config/sabbel/config.toml` (validated, a bad value never
  fatal) plus `preferences.json` for runtime choices.
- **In Phase 1, the same files, read on every launch as today** (*my call*):
  - Phase 1 has no settings UI, so `config.toml` stays the way to change the
    hotkey;
  - Swift reads `hotkey`, `history_enabled` and `history_max_bytes` from the
    TOML file;
  - from `preferences.json` it reads `audio_device` and `history_enabled`.
    The menu toggle writes there, and as today it wins over TOML;
  - `model_repo` and the paste delays are ignored, with a log line;
  - Phase 2's settings UI decides where settings live from then on.

## Real-time transcription

- **The aim:** most of the take is transcribed while the user is still
  speaking. On release, only the unsettled tail is left.
- **Palaver's design** (`docs/superpowers/specs/2026-10-28-realtime-pipeline-design.md`
  in meeting-transcribe) was measured on the same speech:
  - every ~1 s, re-transcribe the last ~10 s;
  - a word settles once two passes agree, or once it is older than ~3 s;
  - settled text is final.
- **FluidAudio ships `SlidingWindowAsrManager`,** with `streamAudio`,
  `finish()`, `configureVocabularyBoosting` and per-token updates.
- **The builder decides** between FluidAudio's manager and a port of
  Palaver's agreement logic on top of `AsrManager`. Goals 2 and 3 are the
  bar. Requirements either way:
  - **Final text.** On release, the unsettled tail plus about 1 s of
    left-hand context is transcribed once more, and the result replaces the
    tail. The pasted text must not depend on how the window happened to
    fall.
  - **Live text** in the window is the settled text followed by the current
    guess, shown as provisional.
  - **Rejections stay correct.** Too short, dead stream and no speech still
    reject the take, judged on the whole take as today.
  - **Long takes** of 5 min or more must not grow memory or per-step compute
    with the length of the take.
- **To verify:** the spike's clips cover only up to 30 s. Long-take accuracy
  and latency need a long test set. One option is to concatenate the clips
  into 1–5 min takes.

## Evaluation set

- **The spike's 308 clips are cut from Keno's work meetings.** They, their
  reference texts and any engine output never go into the repo, an issue, CI
  or any upload. Reports quote numbers only, never text.
- **Storage** (*my call*): the clips are kept outside the repo, in
  `~/dev/temp/sabbel-eval/`, together with the scripts that select and score
  them. `make eval` points at that folder through `SABBEL_EVAL_DIR`, and
  refuses to run without it.
- **CI cannot see the private set** (*my call*). Instead, its real-model test
  uses synthetic mixed-language clips:
  - German sentences with English terms, spoken by macOS `say` with a German
    voice;
  - kept in the repo as text and generated at test time.
  
  That catches a regression where English terms are dropped from German
  speech. It does not replace the local gate.

## Distribution and signing

- **Releases work as today:** `Sabbel.zip` attached to a GitHub release on a
  `v*` tag, and `install.sh` unchanged in usage. The app is
  `~/Applications/Sabbel.app` with bundle id `com.sabbel.app`.
- **Signing follows Palaver:**
  - one self-signed **code-signing certificate**, "Sabbel Release", is created
    once and backed up as a `.p12`;
  - every release is signed with it, which keeps the TCC permissions
    (Accessibility, Microphone) across updates;
  - an ad-hoc build gets a new identity every time;
  - the first Swift release is signed differently from the Python builds, so
    users grant permissions once more. The release notes say so.
- **Releases are signed in GitHub Actions** (Keno's decision):
  - the `.p12` and its password are stored as repository secrets;
  - the release job imports them into a temporary keychain, signs, and
    deletes the keychain;
  - a `v*` tag still builds, signs and publishes on its own, as today;
  - the release job refuses to publish an ad-hoc-signed app;
  - dry runs (`workflow_dispatch`) and PR CI sign ad hoc and never publish.
- **No permission reset on update** (*my call*). Today `install.sh` and
  `make install-app` run `tccutil reset` on every install. With a stable
  signature that would throw away the permissions the certificate is meant
  to keep. The reset goes, except for `make reset-permissions`.
- **Local builds** from `make install-app` are signed with "Sabbel Release"
  when the certificate is in the keychain, and ad hoc otherwise, with a
  warning.
- **The first Swift build goes out as a GitHub prerelease** (*my call*).
  `install.sh` only serves "latest", so users do not get it yet. Keno uses it
  for a few days.
  - It becomes "latest" once he says so, and once goals 1–5 have been
    checked: `make test`, `make test-model`, `make test-e2e`, plus
    `make eval` against the private set.
  - Only then is the Python code removed.
- **The model** is downloaded on first launch by FluidAudio, as today. The
  menu shows progress, not just "loading". The old ~2.3 GB MLX model in
  `~/.cache/huggingface` is left alone. The release notes say how to delete
  it.

## Repo and build

- **Same repo.** The Swift package and app live next to `sabbel/` until the
  switch, after which the Python code is removed.
- **The Makefile stays the deploy API.** The same targets exist with the same
  meaning: `build-app`, `install-app`, `test`, `test-model`, `test-e2e`,
  `stop`, `restart`, `status`, `autostart`, `reset-permissions`.
- **CI** builds and tests on GitHub's macOS runners. It runs the real-model
  test with a cached model, as today.
- **Tests:**
  - unit tests for the hotkey state machine, take rejection, paste decisions,
    config import and history rules, using today's Python tests as the
    checklist;
  - a real-model test covering accuracy on a few fixed clips and flat memory
    over 10 takes;
  - an e2e test like `scripts/e2e.py`, pasting `say` output into TextEdit.
    That test must not touch the user's own documents or leave their
    clipboard changed. `scripts/e2e.py` (PR #18) is merged first and is the
    reference for what the Swift e2e test checks.

## Phase 2 outline (separate design)

- **Glossary:**
  - terms Keno uses (names, product words, English terms);
  - used to boost recognition (FluidAudio's CTC vocabulary boosting) and to
    fix variants after recognition, as Palaver's `glossary.py` does;
  - suggestions come from the history: rare words and sound-alikes.
  - This is also where v3 vs "ultra" gets decided.
- **App window:**
  - recent dictations, the glossary and settings;
  - the "cool" design;
  - a recording overlay to experiment with.
- **Cloud provider:**
  - optional, off by default: AssemblyAI, Soniox, Mistral, or an
    OpenAI-compatible service, as in Palaver's `cloud_asr.py`;
  - glossary terms are passed along as key terms;
  - the API key goes in the Keychain.

## Left to the builder

- Project layout (SwiftPM vs Xcode project), the SwiftUI/AppKit split, and the
  concurrency design.
- The real-time engine choice and its parameters, within goals 2 and 3.
- The hotkey mechanism (CGEventTap or similar). It must respect the
  Accessibility / Input Monitoring prompts and ignore synthetic events.
- How CI gets a Swift toolchain new enough for FluidAudio.
- The exact wording of statuses and notifications, keeping today's meaning.

# Native Sabbel (Swift), Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python menu bar app with a native Swift app. It keeps every behaviour users rely on today, and it transcribes while the user speaks, so the text is pasted ≤ 0.5 s after release however long the take.

**Architecture:** One SwiftPM package in `native/`, with four targets:

| Target | Kind | What it holds | Tested how |
|---|---|---|---|
| `SabbelCore` | library | All decisions: hotkey state machine, take rejection, paste logic, settings import, history, update check, streaming agreement, the take coordinator | Unit tests, through protocols with fakes |
| `SabbelEngine` | library | Parakeet via FluidAudio | — |
| `Sabbel` | executable | The AppKit app: thin system adapters behind those protocols | — |
| `sabbel-eval` | executable | Accuracy and latency harness | — |

The Makefile assembles, signs and installs `Sabbel.app`, and stays the only build recipe for CI and for local use.

**Tech Stack:**
- Swift 6.1 via Xcode 16.4. Use Xcode's toolchain, not the Command Line Tools: the CLT ship neither `Testing` nor `XCTest`.
- Swift Testing.
- FluidAudio `0.18.2`, exact.
- AppKit with SwiftUI for the live panel.
- AVAudioEngine and CoreAudio for capture.
- CGEventTap for the hotkey.
- The Accessibility API for paste checks.

**Spec:** `docs/superpowers/specs/2026-11-03-native-swift-sabbel-design.md`. Read it before any task. The Python modules named in each task are the behavioural reference: their docstrings explain *why*, and the Swift code keeps those reasons as comments where the Python has them.

## Global Constraints

**Platform and build**
- Package `swift-tools-version: 6.0`, platform `.macOS(.v14)`. `LSMinimumSystemVersion` is `14.0`. Apple Silicon only.
- Every `swift` invocation runs with `DEVELOPER_DIR` pointing at Xcode. The Makefile sets `DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer` and exports it; CI sets its own Xcode 16.4 path.
- FluidAudio dependency: `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2")`, product `FluidAudio`.
- If `swift build` stalls on "Downloading binary artifact … NemoTextProcessing" with no CPU use for more than 2 minutes, it is an environment problem, not a code problem. Seen in Claude's sandbox; curl fetches the same URL fine. Stop and ask Keno to run that build once outside the sandbox (`! make native-build`). Do not vendor or patch FluidAudio.

**Bundle and files**
- Bundle id `com.sabbel.app`, app name `Sabbel`, installed at `~/Applications/Sabbel.app`. The release asset is `Sabbel.zip` (made with `ditto -ck --keepParent`).
- User files live in `~/.config/sabbel/`: `config.toml`, `preferences.json`, `history.log` (rotated to `history.log.1`) and `update-check.json`. The directory comes from `SABBEL_CONFIG_DIR` when that is set, which is how the e2e test isolates itself; otherwise it is `~/.config/sabbel`.
- Runtime log: `/tmp/sabbel-runtime.log`. Single-instance lock: `/tmp/sabbel.lock`.

**Private data**
- Nothing from `~/dev/temp/sabbel-eval/` (meeting audio, reference texts, outputs) ever goes into the repo, a commit message, an issue, CI, logs pasted anywhere, or a PR. Report numbers only.

**Release and signing**
- Release signing identity: `"Sabbel Release"`, a self-signed code-signing certificate.
- Make variable `SABBEL_SIGN_IDENTITY`. Unset means ad hoc (`-`), with a warning.
- Repo secrets `SABBEL_SIGN_P12` (base64) and `SABBEL_SIGN_P12_PASSWORD`.
- A tag containing `-` (e.g. `v1.0.0-rc.1`) is published as a GitHub **prerelease**. `install.sh` and the in-app update check only ever see "latest".
- The Swift version starts at `1.0.0`. A dev build reports version `dev`, and has no update check.

**Git**
- Work on branch `feat/native-swift`, created from `docs/native-swift-design`.
- The Python app stays untouched and buildable on that branch until Task 14.
- Commits end with the session's attribution lines. Never bypass commit signing.

## Review Focus

1. **The live panel is open when the user presses the hotkey.** The text must still go to the app the user was typing in, never into Sabbel. The panel is a non-activating `NSPanel`, and the coordinator drops a focus target whose pid is Sabbel's own, so the take has no target and the injector judges whatever is frontmost at paste time. If that is still Sabbel (e.g. the user clicked its notification banner), the injector does not paste: the outcome is `.leftInClipboard`, the text stays on the clipboard with the `textCopiedNoField` notice, and history is saved as for that outcome. Tests: Task 10 `ownPidTargetIsNeverPastedInto` and `sabbelFrontmostAtPasteLeavesTextInClipboard`, Injector `sabbelFrontmostAtPasteLeavesTextInClipboard`, Task 13 e2e check "live panel open".
2. **A second take starts while the first is still finishing.** Takes are pasted in order, each into its own target, with independent streaming state. Test: Task 10 `overlappingTakesPasteInOrderToOwnTargets`.
3. **The mic disappears or errors mid-take** (AirPods disconnect, dock unplugged). The take ends with the audio captured so far, the UI goes back to idle, and nothing hangs. A start failure shows "Mic error". Test: Task 10 `micStartFailureShowsMicError` and `captureEndingEarlyStillFinishesTake`.
4. **A 10-minute take.** Kept audio and per-pass compute stay bounded by the window, never by the take length. Test: Task 7 `longTakeKeepsBoundedAudio`.
5. **A take released before the first pass ran** (0.6 s), or one where no word ever settled. The final text is a single full pass over the whole take, exactly as today. Test: Task 7 `shortTakeIsOneFullPass`.

---

### Before Task 1: merge PR #18

`scripts/e2e.py` is the reference for Task 13 (spec, "Repo and build"). PR #18 (`test/e2e-script`) needs one green hands-off run of `make test-e2e` on Keno's Mac. Then merge it after CI and rebase `docs/native-swift-design` on main. This is a manual gate for Keno and the session lead, not for an implementer subagent.

---

### Task 1: Package skeleton, toolchain and CI test job

**Files:**
- Create: `native/Package.swift`, `native/Sources/SabbelCore/SabbelCore.swift`, `native/Sources/SabbelEngine/SabbelEngine.swift`, `native/Sources/Sabbel/main.swift`, `native/Sources/sabbel-eval/main.swift`, `native/Tests/SabbelCoreTests/SmokeTests.swift`, `native/.gitignore` (`.build/`)
- Modify: `Makefile` (new targets `native-build`, `native-test`), `.github/workflows/ci.yml` (new job `native`)

**Interfaces:**
- Produces:
  - targets `SabbelCore` (no dependencies), `SabbelEngine` (→ `SabbelCore`, `FluidAudio`), `Sabbel` (→ both) and `sabbel-eval` (→ both);
  - test targets `SabbelCoreTests` (→ `SabbelCore`) and `SabbelEngineTests` (→ `SabbelEngine`);
  - Make variables `DEVELOPER_DIR` and `SWIFT = swift` (with `--package-path native`).

- [ ] **Step 1: Write the smoke test.** `@Test func coreLinks() { #expect(SabbelCore.name == "SabbelCore") }`
- [ ] **Step 2: Run it.** `make native-test`. Expected: it fails to compile (`SabbelCore.name` is undefined).
- [ ] **Step 3: Create the package, the targets and `public enum SabbelCore { public static let name = "SabbelCore" }`.** `main.swift` in both executables only prints usage for now.
- [ ] **Step 4: Run `make native-build && make native-test`.** Expected: `Build complete!` and `1 test passed`. The first build resolves FluidAudio, about 70 s; see Global Constraints if it stalls.
- [ ] **Step 5: Add a CI job `native`.** Runner `macos-15`. Set `DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer`, then `make native-test`. Push the branch and check that the job is green with `gh run list --workflow CI`.
- [ ] **Step 6: Commit.** `build(native): Swift package skeleton on Xcode's toolchain`

---

### Task 2: Hotkey state machine and hotkey names

Port of `sabbel/hotkey.py` and `tests/test_hotkey.py`, without the event source.

**Files:**
- Create: `native/Sources/SabbelCore/Hotkey.swift`, `native/Tests/SabbelCoreTests/HotkeyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum KeyInput: Equatable, Sendable { case hotkeyDown, hotkeyUp, escapeDown, otherKeyDown }
  public enum CancelReason: Equatable, Sendable { case combo, escape }
  public enum HotkeyAction: Equatable, Sendable { case start, stop, cancel(CancelReason) }
  public struct HotkeyStateMachine: Sendable {
      public static let comboMaxHold: TimeInterval = 1.0
      public init(comboMaxHold: TimeInterval = HotkeyStateMachine.comboMaxHold)
      public mutating func handle(_ input: KeyInput, at time: TimeInterval) -> HotkeyAction?
  }
  public struct HotkeySpec: Equatable, Sendable {
      public let keyCode: UInt16
      public let isModifier: Bool      // delivered as flagsChanged, not keyDown/keyUp
      public static func parse(_ name: String) -> HotkeySpec?
      public static let `default`: HotkeySpec   // alt_r
  }
  ```

- [ ] **Step 1: Write the failing tests.** Each test mirrors a test in `tests/test_hotkey.py`, with times in seconds:
  - `pressStartsReleaseStops`: down@0 → `.start`, up@2 → `.stop`.
  - `shortComboIsCancelledQuietly`: down@0, other@0.1, up@0.3 → `.cancel(.combo)`.
  - `longHoldWithStrayKeyIsDictation`: down@0, other@0.05, up@12 → `.stop`.
  - `escapeCancelsAtAnyLength`: down@0, esc@30 → `.cancel(.escape)`, and the following up → `nil`.
  - `autoRepeatDownIsIgnored`: down@0, down@0.5 → `nil` the second time.
  - `releaseWithoutPressIsIgnored`: up → `nil`.
  - `parsesNames`:
    - `alt_r` → 61 and `alt`/`alt_l` → 58, both modifiers;
    - `cmd_r` 54, `cmd` 55, `ctrl` 59, `ctrl_r` 62, `shift` 56, `shift_r` 60, `caps_lock` 57, all modifiers;
    - `f5` → 96 and `f13` → 105, not modifiers;
    - `space` → 49;
    - `a` → 0 (ANSI position);
    - `esc`, `""` and `bogus` → `nil`.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure, the types are undefined.
- [ ] **Step 3: Implement it in `Hotkey.swift`.** Keep the docstring reasoning from `hotkey.py`, why recording starts on press and why the verdict waits for release, as the type's doc comment.
  - Function keys f1–f20 use the macOS `kVK_F*` codes.
  - Single letters and digits use the `kVK_ANSI_*` codes. These are layout positions; note that in the doc comment.
- [ ] **Step 4: Run `make native-test`.** Expected: all pass.
- [ ] **Step 5: Commit.** `feat(native): hotkey state machine`

---

### Task 3: Take rejection and history log

Port of `recorder.is_valid_duration`, `is_dead_stream` and `has_speech`, and of `app._append_history` and `_clear_history`.

**Files:**
- Create: `native/Sources/SabbelCore/TakeStats.swift`, `native/Sources/SabbelCore/HistoryLog.swift`, `native/Tests/SabbelCoreTests/TakeStatsTests.swift`, `native/Tests/SabbelCoreTests/HistoryLogTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum TakeVerdict: Equatable, Sendable { case accept, tooShort, deadStream, noSpeech }
  public struct TakeStats: Sendable {   // incremental: a 10-minute take never needs its whole buffer
      public init(sampleRate: Double = 16_000)
      public mutating func add(_ samples: [Float])
      public var duration: TimeInterval { get }
      public func verdict(minDuration: TimeInterval, rmsThreshold: Float = 0.003) -> TakeVerdict
  }
  public struct HistoryLog: Sendable {
      public init(url: URL, maxBytes: Int, now: @escaping @Sendable () -> Date = Date.init)
      public func append(_ text: String) throws
      public func clear() throws          // removes history.log and history.log.1
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `TakeStats` (checked in this order: too short, dead stream, no speech):
    - empty → `.tooShort`;
    - 0.4 s of 0.1 with min 0.5 → `.tooShort`;
    - 1 s of exact zeros → `.deadStream`;
    - 1 s of constant 0.002 → `.noSpeech`;
    - 1 s of constant 0.004 → `.accept`;
    - the verdict is the same whether 1 s arrives as one `add` or as ten.
  - `HistoryLog`:
    - with a fixed date `2026-11-03 09:05:07` local time, `append("Hallo Welt")` writes exactly `"--- 2026-11-03 09:05:07 ---\nHallo Welt\n\n"`;
    - text with umlauts round-trips as UTF-8;
    - when the file is larger than `maxBytes` before an append, it is renamed to `history.log.1` (replacing an old one) and the new entry starts a fresh file;
    - `clear()` removes both files and does not throw when neither exists.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement both.** `TakeStats` keeps the count, sum of squares and max |x|. The dead-stream rule needs max |x| == 0 exactly.
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): take rejection and history log`

---

### Task 4: Settings import

The spec section "Configuration": `config.toml` and `preferences.json` are read on every launch. Port of `sabbel/config.py` (validation only, no migration writing) and `sabbel/preferences.py`.

**Files:**
- Create: `native/Sources/SabbelCore/Settings.swift`, `native/Sources/SabbelCore/MiniTOML.swift`, `native/Tests/SabbelCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SabbelPaths: Sendable {
      public let configDir: URL      // $SABBEL_CONFIG_DIR or ~/.config/sabbel
      public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> SabbelPaths
      public var configTOML: URL { get }; public var preferencesJSON: URL { get }
      public var historyLog: URL { get }; public var updateCheckJSON: URL { get }
  }
  public struct SabbelSettings: Equatable, Sendable {
      public var hotkey: HotkeySpec = .default
      public var hotkeyName: String = "alt_r"
      public var minDuration: TimeInterval = 0.5
      public var historyEnabled = false
      public var historyMaxBytes = 1_000_000
      public var audioDevice: String? = nil
      public static func load(paths: SabbelPaths, log: (String) -> Void) -> SabbelSettings
  }
  public enum Preferences {
      public static func save(_ key: String, _ value: Any?, at url: URL) throws  // read-merge-write, nil stores JSON null
  }
  ```

- [ ] **Step 1: Write the failing tests.** Each writes files into a temporary directory.
  - No files → the defaults.
  - TOML that sets values:
    ```toml
    [general]
    hotkey = "f5"
    [audio]
    min_duration_seconds = 1.0
    [history]
    enabled = true
    max_bytes = 2000
    ```
    → those values.
  - Invalid values each fall back to their own default, logged once, and the other keys are still used:
    - `hotkey = "bogus"`;
    - `min_duration_seconds = 0` or `= true`;
    - `max_bytes = -1`;
    - `enabled = "yes"`.
  - `[model] repo = "x"` and `[injection] pre_paste_delay = 0.1` → ignored, with a log line containing `ignored`.
  - Unparseable TOML (`[general` unterminated) → defaults, logged.
  - The `preferences.json` keys:
    - `{"history_enabled": true}` wins over TOML `enabled = false`, and `false` wins over TOML `true`;
    - `{"audio_device": "Dell WD22 Mic"}` is used;
    - `null` → `nil`.
  - `Preferences.save("audio_device", nil, …)` keeps other keys and writes `null`.
  - `SabbelPaths.current(environment: ["SABBEL_CONFIG_DIR": "/x"]).historyLog.path == "/x/history.log"`.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement it.**
  - `MiniTOML` parses only what these keys need: `[section]` headers, `key = value` with basic or literal strings, integers, floats, booleans, and `#` comments. Anything else on a line is a parse error for that line, which the key's validator then reports.
  - Validators follow `config.py`:
    - durations are finite and > 0;
    - the byte count is an integer > 0;
    - a boolean must be an actual boolean;
    - the hotkey must parse with `HotkeySpec.parse`.
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): read config.toml and preferences.json`

---

### Task 5: Paste logic

Port of `sabbel/injector.py` and `tests/test_injector.py`, with one new rule: focus is re-checked immediately before Cmd+V.

**Files:**
- Create: `native/Sources/SabbelCore/Injector.swift`, `native/Tests/SabbelCoreTests/InjectorTests.swift`, `native/Tests/SabbelCoreTests/FakePasteEnvironment.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum InjectOutcome: String, Sendable { case pasted, leftInClipboard, focusChanged, refusedSecure }
  public struct FocusTarget: Equatable, Sendable { public let pid: Int32; public let name: String? }
  public struct FocusedElement: Equatable, Sendable {
      public var role: String?; public var subrole: String?
      public var hasSelectedTextRange: Bool; public var valueSettable: Bool; public var selectedTextSettable: Bool
  }
  public struct ClipboardSnapshot: Sendable { public var items: [[String: Data]] }
  public protocol PasteEnvironment: Sendable {
      func frontmostPID() -> Int32?
      func focusedElement() -> FocusedElement?
      func focusedValue() -> String?
      func modifiersHeld() -> Bool
      func captureClipboard() -> ClipboardSnapshot
      func restoreClipboard(_ snapshot: ClipboardSnapshot)
      func writeTransient(_ text: String) -> Int      // returns the change count
      func clipboardChangeCount() -> Int
      func clipboardString() -> String?
      func postCommandV(to pid: Int32?)
      func sleep(_ seconds: TimeInterval)
      func now() -> TimeInterval
  }
  public struct Injector: Sendable {
      public init(env: any PasteEnvironment, prePasteDelay: TimeInterval = 0.05, postPasteDelay: TimeInterval = 0.15,
                  modifierTimeout: TimeInterval = 2.0, verifyTimeout: TimeInterval = 1.0)
      public func inject(_ text: String, target: FocusTarget?) -> InjectOutcome
      public static func isSecure(_ element: FocusedElement?) -> Bool
      public static func normalizeForMatch(_ text: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests** against a `FakePasteEnvironment`. It records calls in order, has a scripted clock, and has scripted answers that can change per call. Port every case in `tests/test_injector.py`, including:
  - **target gone before paste** → `.focusChanged`, the text written transient, no Cmd+V;
  - **secure field:** subrole `AXSecureTextField` → `.refusedSecure`, nothing written, no Cmd+V;
  - **non-text field:** role `AXImage` with no range and nothing settable → `.leftInClipboard`, the text stays (no restore);
  - **unreadable focus** (Electron) → optimistic paste: `.pasted`, restore after `postPasteDelay`;
  - **modifiers:** held for 0.3 s → Cmd+V only after they clear; held past 2.0 s → paste anyway;
  - **paste confirmation:** the field value changes to contain the text → restore before `verifyTimeout`; the value never changes → restore after 1.0 s, still `.pasted`;
  - **user copied during the paste:** the change count moved and the string differs → no restore, `.pasted`;
  - `normalizeForMatch("Hallo\u{0}Welt\n x") == "Hallo Welt x"`;
  - **new, `focusLostRightBeforeCommandV`:** the frontmost pid matches at the start and changes during the modifier wait → `.focusChanged`, no Cmd+V, and the clipboard holds the text (no restore);
  - **Cmd+V goes to the target:** `postCommandV` receives the target pid.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement `Injector.inject`.**
  - Follow the order of `inject_text`, keeping its comments.
  - Add the second focus check after `writeTransient` and `prePasteDelay`, immediately before `postCommandV`.
  - The non-text roles are the same set as `_NON_TEXT_ROLES`.
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): paste logic, re-checking focus right before Cmd+V`

---

### Task 6: Versions, update check, diagnostics

Port of `_parse_version`, `_is_newer`, `_should_check_update`, `_record_update_check` and `_build_diagnostics`.

**Files:**
- Create: `native/Sources/SabbelCore/Updates.swift`, `native/Sources/SabbelCore/Diagnostics.swift`, `native/Tests/SabbelCoreTests/UpdatesTests.swift`, `native/Tests/SabbelCoreTests/DiagnosticsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AppVersion: Comparable, Sendable { public static func parse(_ s: String) -> AppVersion? }
  public func isNewer(_ latest: String, than current: String) -> Bool
  public func latestTag(fromReleaseJSON data: Data) -> String?        // "tag_name" without a leading "v"
  public struct UpdateThrottle: Sendable {
      public init(stateURL: URL, interval: TimeInterval = 86_400)
      public func isDue(now: Date) -> Bool; public func record(now: Date)
  }
  public enum Endpoints { public static let latestRelease = URL(string: "https://api.github.com/repos/kenodressel/sabbel/releases/latest")!
                          public static func releasePage(_ v: String) -> URL }
  public func buildDiagnostics(version: String, status: String, macOS: String, engine: String,
                               configURL: URL, logURL: URL, logLines: Int = 40) -> String
  ```

- [ ] **Step 1: Write the failing tests.**
  - All the parse cases from the `_parse_version` docstring:
    - `1.2.3`, `v1.2.3` and `1.2` (padded to `1.2.0`) parse;
    - `1.2.3-rc1` < `1.2.3`;
    - `+build` metadata is ignored;
    - `dev` and garbage → `nil`;
    - `isNewer("1.0.0", than: "dev") == false`;
    - `isNewer("1.0.0", than: "0.5.2") == true`.
  - Throttle:
    - no file → due;
    - recorded 1 h ago → not due;
    - recorded 25 h ago → due;
    - a corrupt file → due.
  - `latestTag` of `{"tag_name":"v1.0.1"}` → `"1.0.1"`.
  - Diagnostics:
    - the first line is `Sabbel v<version>`;
    - it includes `status:`, `macOS:` and `engine:`;
    - the config file's content follows a `--- config.toml ---` header when present, and `config.toml: none` when absent;
    - the last 40 log lines follow a `--- last 40 lines of … ---` header;
    - a missing log gives `(no log file)`.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): versions, update throttle, diagnostics`

---

### Task 7: Streaming transcription with local agreement

This is the heart of goal 2. It is tested with a fake recognizer; the real one comes in Task 8.

**Files:**
- Create: `native/Sources/SabbelCore/Streaming.swift`, `native/Tests/SabbelCoreTests/StreamingTests.swift`, `native/Tests/SabbelCoreTests/FakeRecognizer.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct TimedWord: Equatable, Sendable { public let text: String; public let start: TimeInterval; public let end: TimeInterval }
  public protocol Recognizer: Sendable {
      /// Words with times relative to samples[0], 16 kHz mono.
      func recognize(_ samples: [Float]) async throws -> [TimedWord]
  }
  public struct LiveText: Equatable, Sendable { public let settled: String; public let provisional: String }
  public actor StreamingTranscriber {
      public init(recognizer: any Recognizer, window: TimeInterval = 10, step: TimeInterval = 1,
                  settleAge: TimeInterval = 3, finalContext: TimeInterval = 1, sampleRate: Double = 16_000)
      public func append(_ samples: [Float]) async      // may run a pass; never two at once
      public func finish() async throws -> String
      public nonisolated var updates: AsyncStream<LiveText> { get }
      public var keptSampleCount: Int { get }           // for the boundedness test
      public var passCount: Int { get }
  }
  ```
- **The algorithm.** The signatures don't determine it, so it is fixed here:
  - **State:**
    - `settled: [TimedWord]` and `settledEnd: TimeInterval`, the end of the last settled word (0 at the start), all in absolute take time;
    - `previous: [TimedWord]`, the last pass's unsettled words;
    - the audio from `keepFrom = max(0, settledEnd - finalContext)` to now. Everything before `keepFrom` is dropped.
  - **A pass** runs when at least `step` seconds of new audio have arrived since the last pass.
    1. Its audio runs from `passStart = max(keepFrom, now - window)` to now.
    2. Recognise it, shift the times by `passStart`, and drop the words with `end <= settledEnd + 0.05`.
    3. The candidates' longest common prefix with `previous` settles. Words are compared lowercased, with leading and trailing punctuation stripped.
    4. Also settle every candidate up to and including the last one with `end < now - settleAge`.
    5. The settled words leave the candidates. `previous` becomes the rest, and the provisional text is the rest.
    6. Yield a `LiveText`: the words joined with single spaces.
  - **`finish()`:**
    - If no pass ever ran, recognise the whole kept audio once and return it joined.
    - Otherwise recognise from `keepFrom` to the end, drop the words with `end <= settledEnd + 0.05`, and return `settled + those`, joined and trimmed.
    - Finish the `updates` stream.

- [ ] **Step 1: Write the failing tests** with `FakeRecognizer`. It is built from a script of "what the true words are", each with absolute times. It returns the words that fall inside the given audio span, shifted to be relative, and can be told to mangle the last word, as a model's unstable tail does.
  - `shortTakeIsOneFullPass`: append 0.6 s, then `finish()` → exactly one recognizer call, over 0.6 s of audio, returning all of its words.
  - `agreedPrefixSettles`: two passes agree on the first 3 words → `settled` holds those 3 words and `provisional` holds the rest.
  - `oldWordsSettleWithoutAgreement`: the fake mangles every word on every other pass; a word ending more than 3 s before now is still settled.
  - `finalTextEqualsScript`: 45 s of scripted speech fed in 0.1 s chunks → `finish()` equals the full script joined, with no duplicated or missing word at the boundaries.
  - `finishOnlyTranscribesTail`: after 60 s, the audio passed to the final call is ≤ `settleAge + step + finalContext + 1` seconds long.
  - `longTakeKeepsBoundedAudio`: after 600 s, `keptSampleCount <= 16_000 * (10 + 1)` at every append.
  - `passesNeverOverlap`: a fake with a 0.3 s delay and concurrent appends → never more than one recognize call in flight.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement the algorithm above in `Streaming.swift`.**
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): streaming transcription with local agreement`

---

### Task 8: Parakeet recognizer and real-model tests

**Files:**
- Create: `native/Sources/SabbelEngine/ParakeetRecognizer.swift`, `native/Tests/SabbelEngineTests/ModelTests.swift`, `native/Tests/SabbelEngineTests/Fixtures/mixed_de_en.txt`
- Modify: `Makefile` (`native-test-model`), `.github/workflows/ci.yml` (job `native`: model step and cache)

**Interfaces:**
- Consumes: `Recognizer`, `TimedWord`, `StreamingTranscriber` (Task 7).
- Produces:
  ```swift
  public actor ParakeetRecognizer: Recognizer {
      public static func load(version: AsrModelVersion = .v3,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> ParakeetRecognizer
      public func recognize(_ samples: [Float]) async throws -> [TimedWord]
  }
  public enum EngineInfo { public static let description = "Parakeet TDT 0.6b v3 (CoreML, FluidAudio 0.18.2)" }
  ```

- [ ] **Step 1: Write the failing model tests.** They are gated by `.enabled(if: ProcessInfo.processInfo.environment["SABBEL_MODEL_TESTS"] == "1")`.
  - **Audio for the tests:** synthesised at test time with `say -o <tmp>.wav --data-format=LEI16@16000`.
  - `englishPhrase`: "Hello world, this is a dictation test." → the words contain `hello`, `world` and `test`.
  - `mixedGermanEnglish`:
    - spoken by the German voice `Anna`; the test is skipped with a message if `say -v '?'` doesn't list it;
    - each line of the fixture is `German sentence | term1, term2`, about 10 lines written for this test, e.g. `Wir müssen das Deployment bis Freitag fertig haben | Deployment`;
    - at least 80 % of the terms come back (fuzzy, as in `scripts/eval_score.py`, Task 9).
  - `timingsAreMonotonic`: the word times are non-decreasing and fall within the audio's duration.
  - `memoryStaysFlat`: after a warm-up, 10 recognitions of the English phrase grow `phys_footprint` (from `task_info(TASK_VM_INFO)`) by less than 64 MB.
  - `finishLatency`:
    - a 60 s take, the English and German clips concatenated, goes through `StreamingTranscriber` in 0.1 s chunks, paced against the wall clock with `Task.sleep` so passes happen as in real use;
    - `finish()` completes in ≤ 0.5 s;
    - the elapsed time is printed.
- [ ] **Step 2: Run `make native-test-model`** (`SABBEL_MODEL_TESTS=1` plus the test filter `SabbelEngineTests`). Expected: compile failure.
- [ ] **Step 3: Implement `ParakeetRecognizer`.**
  - Use `AsrModels.downloadAndLoad(version:progressHandler:)`, `AsrManager(config: .default)` and `loadModels`.
  - Make a fresh `TdtDecoderState.make(decoderLayers:)` per call, as the spike did.
  - Group `tokenTimings` into words: a token starting with `▁` begins a new word. Strip `▁`.
- [ ] **Step 4: Run `make native-test-model`.** Expected: pass, with the latency printed. Record the latency and memory figures in the commit message.
- [ ] **Step 5: Add the model step to the CI job.**
  - Cache FluidAudio's model directory with `actions/cache@v6`, keyed on `hashFiles('native/Package.resolved')`.
  - Before writing the path into the workflow, find it by listing `~/Library/Application Support/` after the local run.
- [ ] **Step 6: Commit.** `feat(native): Parakeet recognizer, real-model tests`

---

### Task 9: Evaluation harness and the local accuracy gate (goals 2 and 3)

**Files:**
- Create: `native/Sources/sabbel-eval/main.swift` (replacing the stub), `scripts/eval_score.py` (stdlib only)
- Modify: `Makefile` (`eval`)

**Interfaces:**
- Consumes: `ParakeetRecognizer`, `StreamingTranscriber`.
- Produces:
  - **The CLI:** `sabbel-eval --clips DIR --out FILE.jsonl --mode stream|full [--model v3|ultra] [--long 60,300 --refs REFS.json --long-out DIR]`.
    - JSONL lines are `{"clip", "text", "finish_ms", "audio_s"}`.
    - `--long` writes concatenated takes, consecutive clips joined with 0.3 s of silence, together with their joined refs into `--long-out`, then evaluates those as well.
  - **Scoring:** `scripts/eval_score.py REFS.json RUN.jsonl [RUN.jsonl …]` prints one row per run: WER, English terms kept, p50/p95/max `finish_ms`.
    - WER: the same normalisation as the spike, the regex `[^\W_][\w'-]*`, lowercased, then Levenshtein over words.
    - English terms: the terms are the `en_terms` field of `refs.json`. A term counts as kept if `difflib.SequenceMatcher` ratio ≥ 0.85 against any output word.
  - **`make eval`:**
    - requires `SABBEL_EVAL_DIR` and fails with a message if it is unset;
    - writes to `$SABBEL_EVAL_DIR/runs/<UTC timestamp>/`;
    - runs `full` and `stream` on the clips plus `--long 60,300`, then scores them all.

- [ ] **Step 1: Write a fixture-based check for `eval_score.py`.** Use a tiny made-up `refs.json` and run file in a temporary directory, with synthetic sentences and no private data. Assert WER 0.25 for 1 substitution in 4 words, and term recall 1/2. Run it with `python3 -I scripts/eval_score.py …` from `make native-test`.
- [ ] **Step 2: Implement `sabbel-eval` and `eval_score.py`.**
  - Stream mode feeds 0.1 s chunks without wall-clock pacing, awaiting each pass. The results equal real use whenever passes are faster than real time, which the spike's 153× gives.
  - `finish_ms` is the wall time of `finish()`.
- [ ] **Step 3: Run `SABBEL_EVAL_DIR=~/dev/temp/sabbel-eval make eval`.** Expected:
  - stream WER ≤ 7.7 % (goal 3);
  - English terms kept ≥ 81.4 %;
  - p95 `finish_ms` ≤ 500 for the clips and for the long takes (goal 2).
- [ ] **Step 4: If English-term recall is below 81.4 %, stop and report to the session lead with numbers only.** The spike's full pass with v3 already measured 77.6 %, so this gate may fail on the model alone, not on streaming. Keno decides: accept, try `--model ultra`, or move vocabulary boosting forward from Phase 2. If WER or latency fail, tune `window`, `settleAge` and `finalContext` within the Task 7 tests, and re-run.
- [ ] **Step 5: Commit** the harness only. Paste the numbers into the commit message, and no transcript text. `feat(native): evaluation harness`

---

### Task 10: Take coordinator

The app's behaviour lives here, as a port of `SabbelApp`, testable with fakes.

**Files:**
- Create: `native/Sources/SabbelCore/TakeCoordinator.swift`, `native/Sources/SabbelCore/Notices.swift`, `native/Tests/SabbelCoreTests/TakeCoordinatorTests.swift`, `native/Tests/SabbelCoreTests/Fakes.swift`

**Interfaces:**
- Consumes: Tasks 2–7.
- Produces:
  ```swift
  public enum IconState: Equatable, Sendable { case idle, recording, working, error(String), failed }
  public enum ModelState: Equatable, Sendable { case loading(progress: Double?), ready, failed(String) }
  public enum Notice: Equatable, Sendable {
      case modelLoading, modelFailed(String), cancelled, deadStream, noAudio, micFallback(String),
           textCopiedNoField, textCopiedFocusChanged, discardedSecure, diagnosticsCopied(Bool),
           historyCleared, updateAvailable(String)
      public var subtitle: String { get }; public var message: String { get }
  }
  public protocol AudioSource: AnyObject, Sendable {
      /// Starts capture; returns the name of a chosen mic that was missing (fell back to default), if any.
      func start(device: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws -> String?
      func stop()
  }
  public protocol FocusProbe: Sendable { func capture() -> (target: FocusTarget?, secure: Bool) ; var ownPID: Int32 { get } }
  @MainActor public protocol SabbelUI: AnyObject {
      func show(_ icon: IconState, status: String)
      func notify(_ notice: Notice)
      func live(_ text: LiveText, masked: Bool)
  }
  @MainActor public final class TakeCoordinator {
      public init(settings: SabbelSettings, paths: SabbelPaths, audio: any AudioSource, focus: any FocusProbe,
                  injector: Injector, makeTranscriber: @escaping @Sendable () -> StreamingTranscriber, ui: any SabbelUI)
      public var modelState: ModelState { get set }      // the app sets it as loading progresses
      public var permissionsReady: Bool { get set }
      public var historyEnabled: Bool { get set }        // the menu toggle; persisted by the caller via Preferences.save
      public func handle(_ action: HotkeyAction)
      public func waitUntilIdle() async                  // for tests and e2e: all queued takes pasted
  }
  ```
- **The copy is fixed by today's app.** Use exactly these strings, from `app.py`:

  | Notice | Subtitle | Message |
  |---|---|---|
  | `modelLoading` | "Model still loading" | "Please wait. The icon will change to 🎙 when Sabbel is ready." |
  | `modelFailed(m)` | "Model could not be loaded" | `"\(m.prefix(160)) — details in /tmp/sabbel-runtime.log"` |
  | `cancelled` | "Recording cancelled" | "Escape pressed — the dictation was discarded." |
  | `deadStream` | "Microphone delivered no signal" | "Check that the mic isn't muted and input volume isn't zero." |
  | `noAudio` | "No audio detected" | "No speech was detected in the last recording." |
  | `micFallback(n)` | `"Mic '\(n)' not found"` | "Using system default. Pick another mic from the Sabbel menu." |
  | `textCopiedNoField` | "Text copied to clipboard" | "No text field detected. Paste manually with Cmd+V." |
  | `textCopiedFocusChanged` | "Text copied to clipboard" | "You switched apps while it was transcribing. Paste with Cmd+V." |
  | `discardedSecure` | "Dictation discarded" | "Sabbel does not type into password fields." |
  | `diagnosticsCopied(ok)` | "Diagnostics copied" / "Could not copy" | "Paste them into your bug report." / "Send /tmp/sabbel-runtime.log instead." |
  | `historyCleared` | "History cleared" | "" |
  | `updateAvailable(v)` | `"Update v\(v) available"` | "Click 'Update' in the Sabbel menu for details." |

- **Status lines and icons:**
  - status lines: "Starting", "Accessibility missing", "Microphone missing", "Downloading model… NN%", "Loading model...", "Ready", "Model failed — restart Sabbel";
  - error texts: "Too short", "No signal", "No audio", "Not recognized", "Error", "Paste failed", "Mic error";
  - an `.error` icon state clears to idle after 2 s.

- [ ] **Step 1: Write the failing tests** with fakes for the audio source, focus, paste environment, recognizer and UI, each ported from `tests/test_app.py`:
  - `failedModelBlocksRecording`: `modelState = .failed("x")`, then `.start` → `notify(.modelFailed("x"))`, and the audio never starts.
  - `loadingModelBlocksRecording` → `.modelLoading`.
  - `readyOnlyWhenModelReady`: permissions ready while the model is loading → status "Loading model...", never "Ready".
  - `comboCancelIsSilent` and `escapeCancelNotifies`.
  - Rejections: one test per verdict, each with its error text and notice (`deadStream` → "No signal" plus `.deadStream`; `noSpeech` → "No audio" plus `.noAudio`; too short → "Too short", no notice). An empty final text → "Not recognized".
  - Outcomes, with the history file on:
    - `.pasted` → saved, no notice;
    - `.leftInClipboard` → saved plus `.textCopiedNoField`;
    - `.focusChanged` → saved plus `.textCopiedFocusChanged`;
    - `.refusedSecure` → **not saved** plus `.discardedSecure`.
  - History off → nothing written.
  - `secureAtStartMasksLiveText`: the focus probe reports a secure field → every `live(_:masked:)` call has `masked == true`.
  - `ownPidTargetIsNeverPastedInto`: the target pid equals `ownPID` → the inject call gets a `nil` target, so the injector judges the frontmost field.
  - `micStartFailureShowsMicError`: the audio source throws → "Mic error", back to idle.
  - `micFallbackNotifiesOncePerDevice`: two takes with the same missing device → one notice.
  - `captureEndingEarlyStillFinishesTake`: the audio source stops sending samples mid-take; then `.stop` → the take is judged and pasted normally.
  - `overlappingTakesPasteInOrderToOwnTargets`: take A released, take B started and released while A's `finish()` is still slow → the injector sees A then B, each with its own target.
  - `pasteRunsOffMainActor`: the fake injector environment records `Thread.isMainThread == false`.
- [ ] **Step 2: Run `make native-test`.** Expected: compile failure.
- [ ] **Step 3: Implement it.**
  - The transcriber for each take comes from `makeTranscriber()`.
  - Takes go to a serial paste actor, so each takes its own `finish()` → `judge` → `inject` → `history` → `notify` path, in order.
  - `TakeStats` is fed alongside the transcriber.
  - The verdict is checked before `finish()` is awaited for its text; a rejected take still calls `finish()` and discards the result, so the stream closes.
  - `injector.inject` runs inside a non-main task.
- [ ] **Step 4: Run `make native-test`.** Expected: pass.
- [ ] **Step 5: Commit.** `feat(native): take coordinator`

---

### Task 11: The app — system adapters, menu bar, live panel

**Files:**
- Create in `native/Sources/Sabbel/`:
  - `main.swift`: `NSApplication` with `.accessory` activation policy;
  - `AppDelegate.swift`;
  - `MenuBar.swift`: an `NSStatusItem` and its menu, implementing `SabbelUI`;
  - `LivePanel.swift`: a non-activating `NSPanel` hosting a SwiftUI view;
  - `HotkeyTap.swift`;
  - `MicCapture.swift`: `AudioSource` via AVAudioEngine and CoreAudio;
  - `SystemPasteEnvironment.swift`;
  - `SystemFocusProbe.swift`;
  - `Permissions.swift`;
  - `Notifier.swift`: UNUserNotificationCenter;
  - `RuntimeLog.swift`;
  - `SingleInstance.swift`.

**Interfaces:**
- Consumes: everything in `SabbelCore`, and `ParakeetRecognizer`.
- Produces: the `Sabbel` executable. `Sabbel --e2e` is reserved for Task 13.

**What each adapter does.** Task 10 already owns the behaviour, so these are only the system bindings:
- **`HotkeyTap`:**
  - a listen-only `CGEventTap` on `keyDown`, `keyUp` and `flagsChanged`;
  - it maps to `KeyInput` for the configured `HotkeySpec`: a modifier hotkey reads its down/up from `flagsChanged` on its keycode, Escape is keycode 53, and every other keyDown counts as `.otherKeyDown`;
  - it ignores synthetic events, meaning any event whose `eventSourceStateID` is not the HID system state (pynput's `injected`);
  - it re-enables the tap after `tapDisabledByTimeout`.
- **`MicCapture`:**
  - the device is chosen by name through CoreAudio; a missing device falls back to the default and returns its name;
  - audio is converted to 16 kHz mono Float32 with `AVAudioConverter`;
  - an engine configuration change or device loss ends the take's sample flow; it does not crash;
  - `listInputDevices() -> [String]` feeds the menu, rebuilt in `menuWillOpen`.
- **`SystemPasteEnvironment`:**
  - AX (`AXUIElementCopyAttributeValue` and `IsAttributeSettable`) on the frontmost app's `kAXFocusedUIElementAttribute`;
  - for the pasteboard: transient items carry the `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType` markers, and every item and type is captured and restored;
  - `CGEventSourceFlagsState(.combinedSessionState)` against command, control, option, shift and fn;
  - Cmd+V (keycode 9) is posted with `postToPid` when a pid is known, else to `.cgAnnotatedSessionEventTap`.
- **`LivePanel`:**
  - style mask `[.titled, .closable, .resizable, .nonactivatingPanel]`, with `hidesOnDeactivate = false` and `becomesKeyOnlyIfNeeded = true`;
  - opened only from the menu item "Show Live Text", never by a take;
  - it shows the settled text in the primary colour and the provisional text in secondary, and "•••" when masked.
- **Menu**, matching the Python app's order:
  - "Status: …";
  - History ▸ "Save history" (checkable, persisted with `Preferences.save("history_enabled", …)`), "Open log", "Clear log";
  - Microphone ▸ "System Default", then the devices;
  - "Show Live Text";
  - "Check for updates", or "Update vX available" which opens the release page, hidden when the version is `dev`;
  - "Copy diagnostics";
  - a separator, then `vX.Y.Z`, then "Quit".
- **The icon title:**
  - 🎙 idle and 🔴 recording;
  - a spinner cycling ◐◓◑◒ every 0.15 s while working;
  - `⚠️ <text>` for an error and ⚠️ for a failure.
- **Startup:**
  - take the single-instance lock or exit;
  - start the log;
  - load the settings, logging each line;
  - poll Accessibility (prompt once) and Microphone (request once) every 1 s, showing the missing one in the status, and start the tap when both are granted;
  - load the model in parallel with progress, keeping `modelState` updated;
  - check for updates when due (`UpdateThrottle`), with a 5 s timeout and silent failure.

- [ ] **Step 1: Build.** Run `make native-build`. Expected: `Build complete!`.
- [ ] **Step 2: Run the unbundled binary.** Run `native/.build/release/Sabbel` from a terminal that has Accessibility permission, check the log and quit. Expected in `/tmp/sabbel-runtime.log`: settings lines, "Permissions ready", model progress, and "Ready". Note the idle memory once it is ready: `ps -o rss= -p $(pgrep -x Sabbel)`. Goal 5 needs it well under today's ~3 GB; record it for the PR.
- [ ] **Step 3: Commit.** `feat(native): menu bar app, live panel, system adapters`
- [ ] **Step 4: Manual smoke test by Keno,** after Task 12 has made it installable. Dictate:
  - a short take and a 2-minute take;
  - a ⌥-combo (@);
  - an Escape cancel;
  - into a password field;
  - with the live panel open.

  Record the results in the PR description.

---

### Task 12: Bundle, signing, install, release workflow

**Files:**
- Create: `native/Resources/Info.plist`, `scripts/bundle_app.sh` (no entitlements file: the app is not sandboxed and not hardened, because there is no notarization)
- Modify: `Makefile`, `install.sh`, `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `README.md`

**Interfaces:**
- Produces:
  - `make build-app` → `dist/Sabbel.app`, signed with `$SABBEL_SIGN_IDENTITY`. When that is unset, it uses "Sabbel Release" if `security find-identity -v -p codesigning` lists it, and ad hoc otherwise, with a warning;
  - `make install-app` → `~/Applications/Sabbel.app`;
  - `VERSION ?= dev` → `CFBundleShortVersionString` (`0.0.0` for dev) and a custom key `SabbelVersion` (`dev` or the tag without its `v`), which the app reads for its version.

- [ ] **Step 1: Write `scripts/bundle_app.sh`.**
  - It assembles `Contents/MacOS/Sabbel`, `Contents/Info.plist` (from the template, with the version substituted) and `Contents/Resources/Sabbel.icns` (the existing `icons/Sabbel.icns` target).
  - It copies every dynamic framework that `swift build` produced into `Contents/Frameworks`, where `@rpath` finds it. SwiftPM `*.bundle` resource bundles are not shipped: an executable's `Bundle.module` never looks inside `Contents/Resources`, and the only one (FluidAudio's LuxTTS G2P resources) is unused on the ASR path.
  - Then `codesign --force --deep --sign "$IDENTITY"`, then `codesign --verify --deep --strict`.
  - Info.plist: `LSUIElement` true, `LSMinimumSystemVersion` `14.0`, and the `NSMicrophoneUsageDescription` copied from `setup.py`.
- [ ] **Step 2: Repoint the Makefile targets to the native build:** `build-app`, `install-app`, `test`, `test-model` and `download-model`. `test` runs `native-test` plus the Python suite until Task 14.
  - `install-app` and `install.sh` reset the TCC grants only when the installed app's designated requirement is missing, a `cdhash` (ad hoc) or different from the new app's (ruling R31, see the spec); `reset-permissions` still resets by hand.
  - `install.sh`'s closing message says whether the permissions were kept or reset.
  - `stop`, `restart`, `status`, `autostart` and `autostart-remove` are unchanged.
- [ ] **Step 3: Verify that the bundle is standalone.** Run:
  ```bash
  make build-app && mv native/.build native/.build.off \
    && (open -W -a dist/Sabbel.app & sleep 20; grep -E "Ready|error" /tmp/sabbel-runtime.log | tail -3; pkill -x Sabbel) \
    ; mv native/.build.off native/.build
  ```
  Expected:
  - "Ready" in the log;
  - `otool -L dist/Sabbel.app/Contents/MacOS/Sabbel` lists only `/System`, `/usr/lib` and `@rpath` paths that resolve inside the bundle.
- [ ] **Step 4: Update `release.yml`.**
  - Runner `macos-15`, Xcode 16.4.
  - A step "Import signing certificate", only on `refs/tags/v*`:
    - decode `SABBEL_SIGN_P12` into a temporary keychain using `SABBEL_SIGN_P12_PASSWORD`;
    - `security set-key-partition-list` for codesign;
    - export `SABBEL_SIGN_IDENTITY="Sabbel Release"`.
  - Build `make build-app VERSION=${GITHUB_REF_NAME#v}`.
  - A step "Refuse ad-hoc signature": `codesign -dvv dist/Sabbel.app 2>&1 | grep -q "Authority=Sabbel Release"` (`-dvv`: plain `-dv` prints no `Authority=` lines), on tags only.
  - Zip and publish with `prerelease: ${{ contains(github.ref_name, '-') }}`.
  - A step that always runs and deletes the keychain.
  - A `workflow_dispatch` run builds ad hoc and never publishes.
- [ ] **Step 5: Write the README section "Signing releases",** adapted from Palaver's: creating "Sabbel Release" with `openssl` and `security import`, the `.p12` backup, and setting the two secrets with `gh secret set`. Keno creates the certificate and secrets himself. The implementer only writes the instructions and **never** handles key material.
- [ ] **Step 6: Run a dry run.** `gh workflow run Release --ref feat/native-swift`. Expected: green, with no release created.
- [ ] **Step 7: Commit.** `build(native): bundle, sign, install and release the Swift app`

---

### Task 13: End-to-end test

This ports `scripts/e2e.py` (merged before Task 1) as a mode of the app binary, so the test exercises the real coordinator, adapters and model.

**Files:**
- Create: `native/Sources/Sabbel/E2E.swift`
- Modify: `native/Sources/Sabbel/main.swift` (`--e2e` dispatch), `Makefile` (`test-e2e` → `make build-app` then `dist/Sabbel.app/Contents/MacOS/Sabbel --e2e`)

**Interfaces:**
- Consumes: `TakeCoordinator`, `SystemPasteEnvironment`, `MicCapture` replaced by a file-fed `AudioSource`, and `SabbelPaths` with `SABBEL_CONFIG_DIR` pointed at a temporary directory.

- [ ] **Step 1: Implement `--e2e`.** It performs every check from `scripts/e2e.py` with the same constants: `RUNS=3`, `MAX_MAIN_THREAD_GAP_MS=250`, `MAX_INTERRUPTIONS=3`, the sentinel clipboard string, the scratch TextEdit document closed with `saving no`, and the clipboard restored only over its own writes. Three checks are new:
  - **"live panel open":** the second take runs with the live panel shown. The text must land in TextEdit, and the frontmost app at paste time must not be Sabbel.
  - **"focus lost right before Cmd+V":** the third take wraps the paste environment so that its first `modifiersHeld()` call activates Finder. Expected: `.focusChanged`, the text in the clipboard, and the notice `textCopiedFocusChanged`. The take is not retried.
  - **"finish latency":** each take logs its release → Cmd+V time, and one above 500 ms fails.

  It also fails fast, with the same messages, on a locked screen (`loginwindow` frontmost) or missing Accessibility.
- [ ] **Step 2: Run `make test-e2e`** on Keno's Mac, with no one touching it for about 30 s. Expected: `PASSED: 0 failed check(s)`.
- [ ] **Step 3: Commit.** `test(native): end-to-end test of the Swift app`

---

### Task 14: Prerelease, promotion, Python removal

These are manual gates (spec, "Distribution and signing"), and each is a checkpoint with Keno.

- [ ] **Step 1: Cut the prerelease.** This needs Keno to have created the "Sabbel Release" certificate and the two secrets (Task 12, Step 5).
  - Open a PR `feat/native-swift` → `main`, marked draft, with the Task 11 smoke results and the Task 9 numbers.
  - Tag `v1.0.0-rc.1` on the branch head and push the tag.
  - Expected: a GitHub **prerelease** with `Sabbel.zip` signed by "Sabbel Release". `install.sh` still installs v0.5.2.
- [ ] **Step 2: Keno installs the prerelease and uses it for a few days.**
  - Install it by downloading the zip into `~/Applications`, then `make autostart`.
  - Problems become fixes on the branch and `-rc.N` tags.
  - After a second rc, Accessibility and Microphone must **not** be asked for again. That is the signing check.
- [ ] **Step 3: Remove the Python app.** Only on Keno's go and with all checks green: `make test`, `make test-model`, `make test-e2e`, and `make eval` meeting goals 2 and 3.
  - Delete `sabbel/`, `tests/`, `pyproject.toml`, `uv.lock`, `setup.py` and `scripts/e2e.py`, and the Python parts of the Makefile and `ci.yml`.
  - Rename `native-test` and `native-test-model` into `test` and `test-model`.
  - Update the README: install, configuration, and permissions, including a one-time re-prompt after the update from 0.5.x.
  - Release notes: users grant permissions once more, and the old ~2.3 GB model can be deleted from `~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3`.
- [ ] **Step 4: Merge after CI is green,** then tag `v1.0.0` on main. Expected: `v1.0.0` is "latest", and `curl … install.sh | sh` on a Mac running 0.5.2 updates to it.

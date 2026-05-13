# Whisper Hallucination Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch and drop Whisper hallucinations (repetition patterns + canned phantom phrases) after transcription, so the user gets a brief "Likely noise" badge instead of garbage being pasted.

**Architecture:** New `sabbel/hallucinations.py` module with pure detection functions. Default phantom set baked in; user can extend via a new `[hallucinations]` section in `dictionary.toml`. App calls `looks_like_hallucination()` in `_transcription_worker` *before* `apply_replacements` and discards the transcription on match.

**Tech Stack:** Plain Python (no new deps), `tomllib`, `pytest`.

**Spec:** `docs/superpowers/specs/2026-05-13-hallucination-filtering-design.md`

---

## File Structure

- **Create** `sabbel/hallucinations.py` — `_normalize`, `_DEFAULT_PHANTOMS`, `is_repetition_hallucination`, `is_known_phantom`, `looks_like_hallucination`.
- **Modify** `sabbel/dictionary.py` — `load_dictionary` passes the `hallucinations` section through; add `get_phantom_phrases()` helper.
- **Modify** `sabbel/app.py` — import + 4-line block in `_transcription_worker`.
- **Create** `tests/test_hallucinations.py`.
- **Create** `tests/test_dictionary.py` — first test file for the dictionary module (does not exist yet).
- **Modify** `README.md` — small note under Custom Dictionary about the `[hallucinations]` section.

No changes to `recorder.py`, `transcriber.py`, `config.py`, packaging, or installer.

---

### Task 1: Create `_normalize` + `is_known_phantom` + defaults

**Files:**
- Create: `sabbel/hallucinations.py`
- Create: `tests/test_hallucinations.py`

- [ ] **Step 1: Create the test file with failing tests**

Create `tests/test_hallucinations.py`:

```python
from sabbel.hallucinations import _normalize, is_known_phantom


def test_normalize_strips_whitespace():
    assert _normalize("  hello  ") == "hello"


def test_normalize_collapses_internal_whitespace():
    assert _normalize("hello   world\tfoo") == "hello world foo"


def test_normalize_strips_trailing_punctuation():
    assert _normalize("Thank you.") == "thank you"
    assert _normalize("Thanks for watching!") == "thanks for watching"
    assert _normalize("oh,") == "oh"
    assert _normalize("hmm;") == "hmm"


def test_normalize_casefolds():
    assert _normalize("THANK YOU") == "thank you"
    # German ß casefolds to ss (Unicode-aware) — important for "Straße" etc.
    assert _normalize("Straße") == "strasse"


def test_normalize_empty_string():
    assert _normalize("") == ""
    assert _normalize("   ") == ""


def test_is_known_phantom_default_english():
    assert is_known_phantom("Thank you.") is True
    assert is_known_phantom("Thanks for watching.") is True
    assert is_known_phantom("Please subscribe.") is True


def test_is_known_phantom_default_german():
    assert is_known_phantom("Untertitel im Auftrag des ZDF") is True
    assert is_known_phantom("Vielen Dank.") is True
    assert is_known_phantom("Danke fürs Zuschauen.") is True


def test_is_known_phantom_normalized_match():
    # Different case, trailing whitespace, and punctuation variants all match.
    assert is_known_phantom("  thank you  ") is True
    assert is_known_phantom("THANK YOU") is True
    assert is_known_phantom("  Untertitel im Auftrag des ZDF  ") is True


def test_is_known_phantom_substring_does_not_match():
    # Full-text equality only; "Thank you very much" is real speech.
    assert is_known_phantom("Thank you very much") is False
    # Likewise embedding the German phantom in real speech.
    assert is_known_phantom("Im Abspann stand Untertitel im Auftrag des ZDF") is False


def test_is_known_phantom_empty():
    assert is_known_phantom("") is False
    assert is_known_phantom("   ") is False


def test_is_known_phantom_extra_phrases_extend_defaults():
    # Custom phrase passed in matches.
    assert is_known_phantom("Hello there", extra_phrases=["Hello there"]) is True
    # Defaults still apply when extra list is present.
    assert is_known_phantom("Thank you.", extra_phrases=["Foo"]) is True
    # Extras are also normalized.
    assert is_known_phantom("HELLO", extra_phrases=["hello"]) is True


def test_is_known_phantom_extra_phrases_none_or_empty():
    assert is_known_phantom("Thank you.", extra_phrases=None) is True
    assert is_known_phantom("Thank you.", extra_phrases=[]) is True
    assert is_known_phantom("nope", extra_phrases=[]) is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_hallucinations.py -v`

Expected: FAIL — `ModuleNotFoundError: No module named 'sabbel.hallucinations'`.

- [ ] **Step 3: Implement the module**

Create `sabbel/hallucinations.py`:

```python
"""Post-Whisper filtering of hallucinated output.

Whisper produces canned phrases or repetition patterns on noise, silence,
or short audio. We catch the two common shapes after transcription:

- Phantom phrases — canned outputs from Whisper's training data, like
  "Thank you." (YouTube English subtitles) or "Untertitel im Auftrag
  des ZDF" (German broadcast subtitles).
- Repetition — same token or n-gram repeated consecutively (handled
  in is_repetition_hallucination, added in a later task).

Matching is exact-full-text after normalization, never substring —
substring matches would reject legitimate speech that happens to
mention a phantom phrase.
"""


def _normalize(text: str) -> str:
    """Normalize a string for phantom-phrase matching.

    - Strip leading/trailing whitespace.
    - Collapse internal runs of whitespace to a single space.
    - Strip trailing punctuation (.!?,;:).
    - Casefold (Unicode-aware lowering — e.g., German ß → ss).
    """
    stripped = " ".join(text.split())
    while stripped and stripped[-1] in ".!?,;:":
        stripped = stripped[:-1]
    return stripped.casefold()


_DEFAULT_PHANTOMS: frozenset[str] = frozenset(
    _normalize(p) for p in [
        # English (Whisper bias from YouTube subtitle training data)
        "Thank you.",
        "Thanks for watching.",
        "Thanks for watching!",
        "Please subscribe.",
        "Bye.",
        "you",
        # German (broadcast subtitle training data)
        "Untertitel im Auftrag des ZDF",
        "Untertitel im Auftrag des ZDF 2017",
        "Untertitel im Auftrag des ZDF 2020",
        "Untertitel von Stephanie Geiges",
        "Untertitel der Amara.org-Community",
        "Untertitelung aufgrund der Amara.org-Community",
        "Vielen Dank.",
        "Danke fürs Zuschauen.",
        # Music / punctuation-only markers
        "♪",
        "♪♪",
        "...",
    ]
)


def is_known_phantom(text: str, extra_phrases: list[str] | None = None) -> bool:
    """Return True iff `text` matches a known Whisper phantom phrase
    after normalization. `extra_phrases` extends the built-in set
    without replacing it.
    """
    norm = _normalize(text)
    if not norm:
        return False
    if norm in _DEFAULT_PHANTOMS:
        return True
    if extra_phrases:
        extras = {_normalize(p) for p in extra_phrases}
        return norm in extras
    return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_hallucinations.py -v`

Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add sabbel/hallucinations.py tests/test_hallucinations.py
git commit -m "hallucinations: known-phantom-phrase matcher with normalized matching"
```

---

### Task 2: Add `is_repetition_hallucination`

**Files:**
- Modify: `sabbel/hallucinations.py`
- Modify: `tests/test_hallucinations.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_hallucinations.py`:

```python
from sabbel.hallucinations import is_repetition_hallucination


def test_repetition_empty():
    assert is_repetition_hallucination("") is False


def test_repetition_too_short_to_judge():
    assert is_repetition_hallucination("hello") is False
    assert is_repetition_hallucination("ja ja ja") is False  # 3 tokens, threshold is 4


def test_repetition_no_repeat():
    assert is_repetition_hallucination("the cat sat on the mat") is False


def test_repetition_three_in_a_row_not_flagged():
    assert is_repetition_hallucination("CR CR CR") is False


def test_repetition_four_in_a_row_flagged():
    assert is_repetition_hallucination("CR CR CR CR") is True
    assert is_repetition_hallucination("CR CR CR CR CR") is True


def test_repetition_emphatic_speech_flagged_known_false_positive():
    # Documented in the spec as an accepted false positive: emphatic speech
    # like "nein nein nein nein" looks identical to a 4-token hallucination.
    assert is_repetition_hallucination("nein nein nein nein") is True


def test_repetition_two_gram_three_times():
    assert is_repetition_hallucination("Hallo Welt Hallo Welt Hallo Welt") is True


def test_repetition_three_gram_three_times():
    assert is_repetition_hallucination(
        "ein zwei drei ein zwei drei ein zwei drei"
    ) is True


def test_repetition_four_gram_three_times():
    assert is_repetition_hallucination(
        "a b c d a b c d a b c d"
    ) is True


def test_repetition_two_gram_only_twice_not_flagged():
    # 2-gram repeats only twice; not a hallucination signature.
    assert is_repetition_hallucination("hello world hello world goodbye") is False


def test_repetition_embedded_repeat_in_real_text_not_flagged():
    # A short repeated phrase inside a longer text doesn't trigger if the
    # run is below the n×3 consecutive-rep threshold.
    assert is_repetition_hallucination(
        "ich habe gesagt hallo welt hallo welt und dann ging ich"
    ) is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_hallucinations.py -v -k "repetition"`

Expected: FAIL — `ImportError: cannot import name 'is_repetition_hallucination' from 'sabbel.hallucinations'`.

- [ ] **Step 3: Implement `is_repetition_hallucination`**

Append to `sabbel/hallucinations.py` after `is_known_phantom`:

```python
def is_repetition_hallucination(text: str) -> bool:
    """Return True iff `text` shows Whisper's repetition-hallucination
    signature.

    Two patterns flag as positive:
    - 4+ identical tokens in a row (e.g., "CR CR CR CR").
    - The same 2-, 3-, or 4-gram repeated 3+ times consecutively
      (e.g., "Hallo Welt Hallo Welt Hallo Welt").

    Texts with fewer than 4 whitespace-tokens never flag, so short
    emphatic outputs like "ja ja ja" pass through unchanged.
    """
    tokens = text.split()
    if len(tokens) < 4:
        return False

    # 4+ consecutive identical tokens.
    run = 1
    for i in range(1, len(tokens)):
        if tokens[i] == tokens[i - 1]:
            run += 1
            if run >= 4:
                return True
        else:
            run = 1

    # 2-, 3-, or 4-gram repeated 3+ times consecutively.
    for n in (2, 3, 4):
        if len(tokens) < n * 3:
            continue
        for start in range(len(tokens) - n * 3 + 1):
            ngram = tokens[start:start + n]
            reps = 1
            i = start + n
            while i + n <= len(tokens) and tokens[i:i + n] == ngram:
                reps += 1
                i += n
                if reps >= 3:
                    return True
    return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_hallucinations.py -v`

Expected: PASS (all tests, including the 11 new repetition cases).

- [ ] **Step 5: Commit**

```bash
git add sabbel/hallucinations.py tests/test_hallucinations.py
git commit -m "hallucinations: consecutive-token and n-gram repetition detector"
```

---

### Task 3: Add `looks_like_hallucination` wrapper

**Files:**
- Modify: `sabbel/hallucinations.py`
- Modify: `tests/test_hallucinations.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_hallucinations.py`:

```python
from sabbel.hallucinations import looks_like_hallucination


def test_looks_like_hallucination_repetition_path():
    assert looks_like_hallucination("CR CR CR CR") is True


def test_looks_like_hallucination_phantom_path():
    assert looks_like_hallucination("Thank you.") is True


def test_looks_like_hallucination_real_speech_passes():
    assert looks_like_hallucination("the cat sat on the mat") is False


def test_looks_like_hallucination_extra_phrases_threaded_through():
    assert looks_like_hallucination(
        "hello", extra_phrases=["Hello"]
    ) is True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_hallucinations.py -v -k "looks_like"`

Expected: FAIL — `ImportError: cannot import name 'looks_like_hallucination'`.

- [ ] **Step 3: Implement the wrapper**

Append to `sabbel/hallucinations.py`:

```python
def looks_like_hallucination(
    text: str, extra_phrases: list[str] | None = None
) -> bool:
    """Convenience: True iff either detector flags `text`."""
    return is_repetition_hallucination(text) or is_known_phantom(
        text, extra_phrases
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_hallucinations.py -v`

Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add sabbel/hallucinations.py tests/test_hallucinations.py
git commit -m "hallucinations: looks_like_hallucination wrapper"
```

---

### Task 4: Extend the dictionary loader with `[hallucinations]` support

**Files:**
- Modify: `sabbel/dictionary.py`
- Create: `tests/test_dictionary.py` (no existing file for this module)

- [ ] **Step 1: Create failing tests**

Create `tests/test_dictionary.py`:

```python
from sabbel.dictionary import load_dictionary, get_phantom_phrases


def test_load_dictionary_missing_file_returns_defaults(tmp_path):
    d = load_dictionary(tmp_path / "missing.toml")
    assert d["replacements"] == {}
    assert d["initial_prompt"] == {"text": ""}
    assert d["hallucinations"] == {"phrases": []}


def test_load_dictionary_reads_hallucinations_section(tmp_path):
    path = tmp_path / "dict.toml"
    path.write_text(
        '[hallucinations]\nphrases = ["foo", "bar"]\n',
        encoding="utf-8",
    )
    d = load_dictionary(path)
    assert d["hallucinations"] == {"phrases": ["foo", "bar"]}


def test_load_dictionary_no_hallucinations_section(tmp_path):
    path = tmp_path / "dict.toml"
    path.write_text('[replacements]\n"foo" = "bar"\n', encoding="utf-8")
    d = load_dictionary(path)
    assert d["hallucinations"] == {"phrases": []}


def test_get_phantom_phrases_valid_list():
    d = {"hallucinations": {"phrases": ["foo", "bar"]}}
    assert get_phantom_phrases(d) == ["foo", "bar"]


def test_get_phantom_phrases_missing_section():
    assert get_phantom_phrases({}) == []


def test_get_phantom_phrases_section_not_a_dict():
    # Defensive: malformed TOML where someone writes
    # `hallucinations = "x"` instead of `[hallucinations]`.
    assert get_phantom_phrases({"hallucinations": "not a dict"}) == []


def test_get_phantom_phrases_phrases_not_a_list():
    assert get_phantom_phrases({"hallucinations": {"phrases": "not a list"}}) == []


def test_get_phantom_phrases_non_string_entries_filtered():
    d = {"hallucinations": {"phrases": ["foo", 123, "bar", None]}}
    assert get_phantom_phrases(d) == ["foo", "bar"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_dictionary.py -v`

Expected: FAIL — `ImportError: cannot import name 'get_phantom_phrases'` and assertions on missing `"hallucinations"` key.

- [ ] **Step 3: Modify `load_dictionary` and add `get_phantom_phrases`**

Current `load_dictionary` (lines 13-25 of `sabbel/dictionary.py`):

```python
def load_dictionary(path: Path | None = None) -> dict:
    """Load dictionary.toml. Returns full dict with 'replacements' and 'initial_prompt' sections."""
    path = path or _DICT_PATH
    if not path.exists():
        return {"replacements": {}, "initial_prompt": {"text": ""}}

    with open(path, "rb") as f:
        data = tomllib.load(f)

    return {
        "replacements": data.get("replacements", {}),
        "initial_prompt": data.get("initial_prompt", {"text": ""}),
    }
```

Replace with:

```python
def load_dictionary(path: Path | None = None) -> dict:
    """Load dictionary.toml. Returns the dict with 'replacements',
    'initial_prompt', and 'hallucinations' sections (missing sections
    fall back to safe empty defaults).
    """
    path = path or _DICT_PATH
    if not path.exists():
        return {
            "replacements": {},
            "initial_prompt": {"text": ""},
            "hallucinations": {"phrases": []},
        }

    with open(path, "rb") as f:
        data = tomllib.load(f)

    return {
        "replacements": data.get("replacements", {}),
        "initial_prompt": data.get("initial_prompt", {"text": ""}),
        "hallucinations": data.get("hallucinations", {"phrases": []}),
    }
```

Then append a new function after `get_initial_prompt` (around line 39):

```python
def get_phantom_phrases(dictionary: dict) -> list[str]:
    """Read user-defined phantom phrases from the loaded dictionary.

    Defensive against malformed config: a missing section, a wrong-type
    section, or wrong-type entries all yield an empty list. The
    built-in defaults in sabbel/hallucinations.py still apply
    regardless.
    """
    section = dictionary.get("hallucinations", {})
    if not isinstance(section, dict):
        return []
    phrases = section.get("phrases", [])
    if not isinstance(phrases, list):
        return []
    return [p for p in phrases if isinstance(p, str)]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_dictionary.py -v`

Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add sabbel/dictionary.py tests/test_dictionary.py
git commit -m "dictionary: pass through [hallucinations] section, add get_phantom_phrases"
```

---

### Task 5: Wire into `_transcription_worker`

**Files:**
- Modify: `sabbel/app.py`

- [ ] **Step 1: Update imports**

In `sabbel/app.py`, find the existing imports near the top of the file:

```python
from sabbel.dictionary import load_dictionary, apply_replacements, get_initial_prompt
```

Replace with:

```python
from sabbel.dictionary import (
    load_dictionary,
    apply_replacements,
    get_initial_prompt,
    get_phantom_phrases,
)
```

Add a new import on a separate line nearby (alongside other `sabbel.*` imports):

```python
from sabbel.hallucinations import looks_like_hallucination
```

- [ ] **Step 2: Add the filter block in `_transcription_worker`**

Locate `_transcription_worker` in `sabbel/app.py`. Find the block immediately after `transcribe(...)` returns and the empty-text check:

```python
            try:
                text = self._transcriber.transcribe(
                    audio,
                    language=self._language,
                    initial_prompt=initial_prompt,
                )
            except Exception:
                logging.exception("Transcription error")
                callAfter(lambda: self._show_error("Error"))
                continue

            if not text:
                logging.info("Recording rejected: empty transcription")
                callAfter(lambda: self._show_error("Not recognized"))
                continue
```

Immediately after that block, **before** `apply_replacements` is called (the spec places this before replacements so phantom matching isn't broken by dictionary substitutions), insert:

```python
            extra_phantoms = get_phantom_phrases(self._dictionary)
            if looks_like_hallucination(text, extra_phantoms):
                logging.info("Filtered hallucination: %r", text[:120])
                callAfter(lambda: self._show_error("Likely noise"))
                continue
```

For reference, the surrounding context after the change should look like:

```python
            if not text:
                logging.info("Recording rejected: empty transcription")
                callAfter(lambda: self._show_error("Not recognized"))
                continue

            extra_phantoms = get_phantom_phrases(self._dictionary)
            if looks_like_hallucination(text, extra_phantoms):
                logging.info("Filtered hallucination: %r", text[:120])
                callAfter(lambda: self._show_error("Likely noise"))
                continue

            # Apply dictionary replacements
            replacements = self._dictionary.get("replacements", {})
            if replacements:
                text = apply_replacements(text, replacements)
```

- [ ] **Step 3: Run the full test suite**

Run: `uv run pytest tests/ -v`

Expected: PASS — all previously passing tests still pass, hallucinations + dictionary tests pass. Nothing exercises the `_transcription_worker` integration directly (rumps coupling), but the imports must resolve and no static error must be introduced.

- [ ] **Step 4: Manual smoke test (skip locally; Keno runs on hardware)**

Build and install:

```bash
make install-app
```

Then in the menu bar:
- Hold the hotkey in a silent room for ~1 s, release → expect ⚠️ "Likely noise" badge for 2 s, no text pasted.
- Add a known phantom phrase like `"Thank you."` to `~/.config/sabbel/dictionary.toml` is unnecessary — the default set already catches it.
- Speak a real sentence → confirm normal dictation path is unaffected.

- [ ] **Step 5: Commit**

```bash
git add sabbel/app.py
git commit -m "app: filter Whisper hallucinations before applying dictionary replacements"
```

---

### Task 6: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a note under Custom Dictionary**

In `README.md`, locate the `## Custom Dictionary` section. At the end of that section, append:

```markdown
### Hallucination filter

Whisper sometimes produces canned phrases on silence or background noise — most commonly `"Thank you."` (English subtitle training data) or `"Untertitel im Auftrag des ZDF"` (German broadcast subtitles). Sabbel drops those automatically and shows a brief ⚠️ "Likely noise" badge instead of pasting.

If you keep seeing a specific phantom phrase that Sabbel doesn't catch, add it to `~/.config/sabbel/dictionary.toml`:

```toml
[hallucinations]
phrases = [
    "Hallo zusammen.",
    "Music playing",
]
```

Entries are matched as exact full-text (case- and whitespace-insensitive, trailing punctuation ignored). The built-in defaults are always applied; entries here extend the set.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README section for the hallucination filter"
```

---

## Final Verification

- [ ] Run the full test suite: `uv run pytest tests/ -v` — all green.
- [ ] Manual: trigger an empty recording (hold hotkey, don't speak) → confirm "Likely noise" badge.
- [ ] Manual: speak normal speech → confirm transcription pastes as before.

---

## Self-Review Notes

**Spec coverage check:**
- Module shape (`_normalize`, `_DEFAULT_PHANTOMS`, `is_repetition_hallucination`, `is_known_phantom`, `looks_like_hallucination`) — Tasks 1-3.
- Repetition detector (4 consecutive tokens, 2-/3-/4-gram × 3, min 4 tokens) — Task 2.
- Phantom matcher (full-text equality, normalization, default set, extra phrases extend) — Task 1.
- Dictionary loader extension (`[hallucinations]` passthrough + `get_phantom_phrases` + defensive parse) — Task 4.
- `dictionary.toml` schema documented — Task 6.
- App wiring (import, filter block before `apply_replacements`, log + show_error) — Task 5.
- UX feedback (`_show_error("Likely noise")`, no notification, INFO log of truncated text) — Task 5.
- Testing (separate per-function tests, dictionary tests, manual checklist) — Tasks 1-4 unit tests + Task 5 manual checklist.

**Placeholder scan:** None found.

**Type consistency:** `extra_phrases: list[str] | None = None` consistent across `is_known_phantom` and `looks_like_hallucination`. `get_phantom_phrases(dictionary: dict) -> list[str]` matches what Task 5 passes. The `hallucinations` section in the loader output is `{"phrases": list[str]}`, consistent with `get_phantom_phrases` reading `section.get("phrases", [])`.

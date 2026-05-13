# Whisper Hallucination Filtering — Design

**Date:** 2026-05-13
**Issue:** [#5](https://github.com/kenodressel/sabbel/issues/5)
**Status:** Approved (pending user review of spec)

## Problem

Whisper produces hallucinated text on short audio, background noise, or microphone artifacts. Two patterns dominate:

1. **Token / n-gram repetition** — "CR CR CR CR CR" or "Untertitel im Auftrag des ZDF Untertitel im Auftrag des ZDF Untertitel im Auftrag des ZDF".
2. **Phantom phrases** — Whisper outputs canned phrases learned from its (heavily subtitled) training data when given noise or silence. The classics: `"Thank you."`, `"Untertitel im Auftrag des ZDF"`, `"Thanks for watching."`, music-note glyphs.

Sabbel's existing safeguards — minimum recording duration (0.5s) and RMS-based silence rejection — don't catch either case. Above-noise-floor audio (fans, traffic, distant speech) flows through to Whisper, which dutifully invents output.

The issue's research already noted that tightening Whisper's built-in `compression_ratio_threshold` and `no_speech_threshold` rejects valid speech too aggressively, so those levers are off the table.

## Goals

- Catch and discard Whisper outputs that match either of the two patterns.
- Surface a clear, brief user signal ("Likely noise") so the user knows why nothing was pasted.
- No new dependencies, no measurable latency.
- User-extensible phantom-phrase list — new Whisper-bias outputs surface over time, and the user should be able to add them without a code change.

## Non-Goals

- No Silero VAD or other pre-Whisper speech-gating. The post-filter approach catches the failure mode where it manifests; pre-filtering would add a ~30 MB model and a dependency for marginal gain.
- No confidence-based filtering (`no_speech_prob`, `avg_logprob`). Too risky — rejects valid quiet speech.
- No replacement / cleanup of partially-hallucinated text. We only flag full-output hallucinations and drop the entire transcription. Partial cleanup belongs to issue #4 (local LLM post-processing).

## Design

### Module: `sabbel/hallucinations.py`

A new module with three module-level functions and a frozen default set. Pure Python, no Whisper/mlx/NumPy dependencies.

```python
def _normalize(text: str) -> str:
    """Normalize for phrase matching: strip, collapse whitespace,
    drop trailing .!?,;: and apply case-fold."""

_DEFAULT_PHANTOMS: frozenset[str]  # pre-normalized

def is_repetition_hallucination(text: str) -> bool: ...
def is_known_phantom(text: str, extra_phrases: list[str] | None = None) -> bool: ...
def looks_like_hallucination(text: str, extra_phrases: list[str] | None = None) -> bool:
    return is_repetition_hallucination(text) or is_known_phantom(text, extra_phrases)
```

### Repetition detector

Whisper hallucinations are characterized by **consecutive** repetition — either the same token or the same n-gram. Algorithm:

1. **Token-level**: tokenize via `text.split()` (whitespace). If 4 or more *identical consecutive* tokens occur anywhere → flag.
2. **N-gram level**: for `n ∈ {2, 3, 4}`, look for the same n-gram repeating `≥ 3` times consecutively → flag.

Minimum text length is 4 tokens; shorter outputs never flag (to keep "ja ja ja" usable).

```python
def is_repetition_hallucination(text: str) -> bool:
    tokens = text.split()
    if len(tokens) < 4:
        return False
    run = 1
    for i in range(1, len(tokens)):
        if tokens[i] == tokens[i - 1]:
            run += 1
            if run >= 4:
                return True
        else:
            run = 1
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

**Known false-positive risk**: emphatic speech like `"nein nein nein nein"` will flag. Accepted — dictation rarely contains 4+ identical adjacent tokens, and the alternative (4-token minimum-run threshold raised to 5+) would weaken the detector against genuine 4-repeat hallucinations.

### Phantom-phrase matcher

**Full-text equality after normalization**, never substring. A substring match on `"Untertitel im Auftrag des ZDF"` would reject any legitimate dictation that happens to mention the phrase.

Normalization:
- `text.strip()`
- collapse whitespace via `" ".join(text.split())`
- strip trailing `.!?,;:`
- `casefold()` (Unicode-aware; right for German ß/ẞ)

```python
def is_known_phantom(text: str, extra_phrases: list[str] | None = None) -> bool:
    norm = _normalize(text)
    if not norm:
        return False
    if norm in _DEFAULT_PHANTOMS:
        return True
    if extra_phrases:
        return norm in {_normalize(p) for p in extra_phrases}
    return False
```

Default phantom set (pre-normalized, stored as `frozenset`):

```python
_DEFAULT_PHANTOMS: frozenset[str] = frozenset(
    _normalize(p) for p in [
        # English (Whisper bias from YouTube subtitle training data)
        "Thank you.",
        "Thanks for watching.",
        "Thanks for watching!",
        "Please subscribe.",
        "Bye.",
        "you",
        # German
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
```

### Dictionary loader extension

New helper in `sabbel/dictionary.py`:

```python
def get_phantom_phrases(dictionary: dict) -> list[str]:
    """Read user-defined phantom phrases from the loaded dictionary.

    Returns [] when the section is missing or malformed; built-in
    defaults still apply.
    """
    section = dictionary.get("hallucinations", {})
    if not isinstance(section, dict):
        return []
    phrases = section.get("phrases", [])
    if not isinstance(phrases, list):
        return []
    return [p for p in phrases if isinstance(p, str)]
```

Defensive: malformed config (`phrases = "foo"` instead of `phrases = ["foo"]`) fails open. The hot-reload already in place (`load_dictionary()` per recording in the worker thread) means edits to `dictionary.toml` take effect at the next dictation — no restart.

### `dictionary.toml` schema

```toml
[initial_prompt]
text = "..."

[replacements]
"kay pee eye" = "KPI"

[hallucinations]
# Additional phantom phrases to filter out as Whisper hallucinations.
# Matched as exact full-text equality after normalization (whitespace,
# trailing punctuation, case). Built-in defaults like "Thank you." and
# "Untertitel im Auftrag des ZDF" are always applied; entries here
# extend the set without replacing it.
phrases = [
    "Hallo zusammen.",
    "Music playing",
]
```

### App wiring

In `sabbel/app.py` `_transcription_worker`, **before** `apply_replacements` (so phantom-phrase exact match isn't broken by replacements):

```python
text = self._transcriber.transcribe(audio, language=self._language, initial_prompt=initial_prompt)

# ... existing empty-check stays ...

extra_phantoms = get_phantom_phrases(self._dictionary)
if looks_like_hallucination(text, extra_phantoms):
    logging.info("Filtered hallucination: %r", text[:120])
    callAfter(lambda: self._show_error("Likely noise"))
    continue
```

Imports:
```python
from sabbel.hallucinations import looks_like_hallucination
from sabbel.dictionary import load_dictionary, apply_replacements, get_initial_prompt, get_phantom_phrases
```

### UX feedback

Reuse `_show_error("Likely noise")`. Matches existing patterns (`"Too short"`, `"No audio"`, `"Not recognized"`, `"Mic error"`): badge in the menu bar, auto-clears after 2 s. **No notification** — would be intrusive on false positives.

The text-truncated `logging.info("Filtered hallucination: %r", text[:120])` writes to `/tmp/sabbel-runtime.log` for after-the-fact diagnosis when a user reports valid speech being dropped.

## Testing

### `tests/test_hallucinations.py` (new)

- **`is_repetition_hallucination`**:
  - `""` → False
  - `"hello"` → False (too short)
  - `"the cat sat on the mat"` → False (no repetition)
  - `"CR CR CR"` → False (only 3 in a row)
  - `"CR CR CR CR"` → True (4 in a row)
  - `"CR CR CR CR CR"` → True
  - `"nein nein nein"` → False (under 4 threshold)
  - `"nein nein nein nein"` → True (accepted false positive on emphatic speech)
  - `"Hallo Welt Hallo Welt Hallo Welt"` → True (2-gram × 3)
  - `"ein zwei drei ein zwei drei ein zwei drei"` → True (3-gram × 3)
  - `"hello world goodbye"` → False

- **`is_known_phantom`**:
  - `"Thank you."` → True
  - `"thank you"` → True (casefold + trailing-dot strip)
  - `"  Untertitel im Auftrag des ZDF  "` → True (whitespace strip)
  - `"Untertitel im Auftrag des ZDF 2017"` → True (exact default with year)
  - `"Thank you very much"` → False (full-text, not substring)
  - `""` → False
  - extra phrases: `is_known_phantom("hello", ["Hello"])` → True
  - extra phrases ignored when match is in default: `is_known_phantom("Thank you.", [])` → True

- **`looks_like_hallucination`**: thin OR; one positive (repetition) and one positive (phantom) and one negative ("the cat sat on the mat").

### `tests/test_dictionary.py` (extend)

- `get_phantom_phrases({"hallucinations": {"phrases": ["foo", "bar"]}})` → `["foo", "bar"]`
- `get_phantom_phrases({})` → `[]`
- `get_phantom_phrases({"hallucinations": "not a dict"})` → `[]`
- `get_phantom_phrases({"hallucinations": {"phrases": "not a list"}})` → `[]`
- `get_phantom_phrases({"hallucinations": {"phrases": ["foo", 123, "bar"]}})` → `["foo", "bar"]`

### Out of scope for tests

The `_transcription_worker` integration path runs through rumps `callAfter` plus the Whisper engine. The pure functions cover the hallucination logic; wire-up correctness is verified manually (next section).

### Manual verification

- Hold the hotkey in a quiet room without speaking → expect `"Likely noise"` badge instead of `"Thank you."` being pasted.
- Speak a genuine emphatic sentence ending in repetition (e.g., "ich sage nein nein nein nein") → confirm the false-positive risk noted in the design — the dictation will be dropped, the user can re-record or adjust.
- Edit `~/.config/sabbel/dictionary.toml`, add a custom phantom phrase, trigger Whisper to produce exactly that phrase (or simulate by writing a unit test) → confirm the extension works without restart.

## Files Touched

- **Create** `sabbel/hallucinations.py` — `_normalize`, `_DEFAULT_PHANTOMS`, `is_repetition_hallucination`, `is_known_phantom`, `looks_like_hallucination`.
- **Modify** `sabbel/dictionary.py` — `get_phantom_phrases()`.
- **Modify** `sabbel/app.py` — import + 4-line block in `_transcription_worker`.
- **Create** `tests/test_hallucinations.py`.
- **Modify** `tests/test_dictionary.py` — add `get_phantom_phrases` tests.
- **Modify** `README.md` — small note under Custom Dictionary about the `[hallucinations]` section.

No changes to `recorder.py`, `transcriber.py`, `config.py`, or packaging.

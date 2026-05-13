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

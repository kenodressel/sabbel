"""Post-Whisper filtering of hallucinated output.

Whisper produces canned phrases or repetition patterns on noise, silence,
or short audio. We catch the two common shapes after transcription:

- Phantom phrases — canned outputs from Whisper's training data, like
  "Thank you." (YouTube English subtitles) or "Untertitel im Auftrag
  des ZDF" (German broadcast subtitles).
- Repetition — same token or n-gram repeated consecutively (handled
  in is_repetition_hallucination).

Matching is exact-full-text after normalization, never substring —
substring matches would reject legitimate speech that happens to
mention a phantom phrase.
"""


def _normalize(text: str) -> str:
    """Normalize a string for phantom-phrase matching.

    - Strip leading/trailing whitespace.
    - Collapse internal runs of whitespace to a single space.
    - Strip trailing punctuation (.!?,;:), but only if non-punctuation
      characters remain — otherwise Whisper's "..." phantom would
      normalize to "" and never match.
    - Casefold (Unicode-aware lowering — e.g., German ß → ss).
    """
    stripped = " ".join(text.split())
    # Count trailing-punctuation run.
    suffix = 0
    while suffix < len(stripped) and stripped[-1 - suffix] in ".!?,;:":
        suffix += 1
    # Only strip if non-punct content remains underneath.
    if suffix < len(stripped):
        stripped = stripped[: len(stripped) - suffix]
    return stripped.casefold()


_DEFAULT_PHANTOMS: frozenset[str] = frozenset(
    _normalize(p) for p in [
        # English (Whisper bias from YouTube subtitle training data)
        "Thank you.",
        "Thanks for watching.",
        "Thanks for watching!",
        "Please subscribe.",
        "Bye.",
        "Bye bye.",
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
        # Bracketed annotations Whisper emits over music/applause
        "[Music]",
        "[Applause]",
        # Music / punctuation-only markers
        "♪",
        "♪♪",
        "♪♪♪",
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
            count = 1
            i = start + n
            while i + n <= len(tokens) and tokens[i:i + n] == ngram:
                count += 1
                i += n
                if count >= 3:
                    return True
    return False


def looks_like_hallucination(
    text: str, extra_phrases: list[str] | None = None
) -> bool:
    """Convenience: True iff either detector flags `text`."""
    return is_repetition_hallucination(text) or is_known_phantom(
        text, extra_phrases
    )

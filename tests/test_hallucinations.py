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

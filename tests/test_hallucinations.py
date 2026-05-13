from sabbel.hallucinations import _normalize, is_known_phantom, is_repetition_hallucination, looks_like_hallucination


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


def test_normalize_keeps_all_punctuation_strings():
    # Whisper's "..." phantom must survive normalization; stripping
    # all three dots would leave nothing for is_known_phantom to match.
    assert _normalize("...") == "..."
    assert _normalize(".") == "."
    assert _normalize("!?") == "!?"


def test_is_known_phantom_dots():
    assert is_known_phantom("...") is True
    # And after whitespace normalization
    assert is_known_phantom("  ...  ") is True


def test_is_known_phantom_you_variants():
    # Whisper "you" phantom (single word on noise) — surface variants all match
    assert is_known_phantom("you") is True
    assert is_known_phantom("You.") is True
    assert is_known_phantom("YOU") is True


def test_is_known_phantom_you_not_in_longer_phrase():
    # Single-word "you" phantom must NOT block longer speech
    assert is_known_phantom("Thank you very much") is False
    assert is_known_phantom("I heard you") is False
    assert is_known_phantom("you are welcome") is False



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


def test_is_known_phantom_extended_defaults():
    """Extended default set: bracketed annotations, longer music runs,
    Bye bye, etc."""
    assert is_known_phantom("Bye bye.") is True
    assert is_known_phantom("[Music]") is True
    assert is_known_phantom("[Applause]") is True
    assert is_known_phantom("♪♪♪") is True
    # Casefolded variants
    assert is_known_phantom("[MUSIC]") is True
    assert is_known_phantom("[music]") is True

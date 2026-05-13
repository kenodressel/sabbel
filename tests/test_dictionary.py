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

from sabbel.preferences import load_preferences, save_preference


def test_load_preferences_missing_file(tmp_path):
    assert load_preferences(tmp_path / "prefs.json") == {}


def test_save_preference_creates_file_with_value(tmp_path):
    path = tmp_path / "prefs.json"

    save_preference("history_enabled", True, path=path)

    assert load_preferences(path) == {"history_enabled": True}


def test_save_preference_preserves_other_keys(tmp_path):
    path = tmp_path / "prefs.json"
    save_preference("foo", 1, path=path)
    save_preference("bar", "two", path=path)

    assert load_preferences(path) == {"foo": 1, "bar": "two"}


def test_save_preference_overwrites_same_key(tmp_path):
    path = tmp_path / "prefs.json"
    save_preference("flag", False, path=path)
    save_preference("flag", True, path=path)

    assert load_preferences(path) == {"flag": True}


def test_load_preferences_handles_corrupt_file(tmp_path):
    path = tmp_path / "prefs.json"
    path.write_text("{ not valid json")

    assert load_preferences(path) == {}


def test_load_preferences_handles_non_dict_root(tmp_path):
    path = tmp_path / "prefs.json"
    path.write_text('["not", "a", "dict"]')

    assert load_preferences(path) == {}


def test_save_preference_creates_parent_dir(tmp_path):
    path = tmp_path / "nested" / "prefs.json"

    save_preference("x", 1, path=path)

    assert path.exists()

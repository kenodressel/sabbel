"""Upgrades rewrite config.toml rather than carrying a landmine forever.

Ignoring a bad value keeps the app alive (see test_config.py), but the line
stays in the user's file and warns on every launch. Migration comments it
out — aggressively, since a stale key can never come back into use, but never
at the cost of a working setting.
"""

import pytest

from sabbel.config import SabbelConfig, load_config, migrate_config
from sabbel.transcriber import DEFAULT_MODEL_REPO


def _write(tmp_path, text):
    config_file = tmp_path / "config.toml"
    config_file.write_text(text, encoding="utf-8")
    return config_file


def test_obsolete_key_is_commented_out(tmp_path):
    """[general] language went away with the Whisper engine."""
    config_file = _write(
        tmp_path,
        '[general]\nlanguage = "de"\nhotkey = "f5"\n',
    )

    notes = migrate_config(config_file)

    text = config_file.read_text(encoding="utf-8")
    assert '# language = "de"' in text
    assert 'hotkey = "f5"' in text
    assert load_config(config_file).hotkey == "f5"
    assert any("language" in note for note in notes)


def test_obsolete_section_is_commented_out_with_its_keys(tmp_path):
    config_file = _write(
        tmp_path,
        '[dictionary]\npath = "~/words.toml"\nenabled = true\n\n'
        '[general]\nhotkey = "f5"\n',
    )

    migrate_config(config_file)

    text = config_file.read_text(encoding="utf-8")
    assert "# [dictionary]" in text
    assert '# path = "~/words.toml"' in text
    assert "# enabled = true" in text
    assert load_config(config_file).hotkey == "f5"


def test_invalid_value_is_commented_out(tmp_path):
    config_file = _write(tmp_path, '[general]\nhotkey = "nope_key"\n')

    migrate_config(config_file)

    text = config_file.read_text(encoding="utf-8")
    assert '# hotkey = "nope_key"' in text
    assert load_config(config_file).hotkey == "alt_r"


def test_explicitly_dropped_key_is_removed(tmp_path):
    """A repo that only proves unusable when the model fails to load."""
    config_file = _write(
        tmp_path,
        '[model]\nrepo = "mlx-community/whisper-large-v3-turbo"\n',
    )

    notes = migrate_config(config_file, drop=[("model", "repo")])

    text = config_file.read_text(encoding="utf-8")
    assert '# repo = "mlx-community/whisper-large-v3-turbo"' in text
    assert load_config(config_file).model_repo == DEFAULT_MODEL_REPO
    assert notes


def test_a_clean_file_is_left_byte_for_byte_alone(tmp_path):
    original = (
        "[general]\n"
        'hotkey = "f5"   # right Option is taken\n\n'
        "[audio]\n"
        "min_duration_seconds = 0.75\n"
    )
    config_file = _write(tmp_path, original)

    notes = migrate_config(config_file)

    assert config_file.read_text(encoding="utf-8") == original
    assert notes == []
    assert not (tmp_path / "config.toml.bak").exists()


def test_comments_and_valid_settings_survive(tmp_path):
    config_file = _write(
        tmp_path,
        "# my Sabbel setup\n"
        "[general]\n"
        'language = "de"\n'
        'hotkey = "ctrl_r"   # trailing comment\n'
        "\n"
        "[audio]\n"
        "min_duration_seconds = 0.75\n",
    )

    migrate_config(config_file)

    text = config_file.read_text(encoding="utf-8")
    assert "# my Sabbel setup" in text
    assert 'hotkey = "ctrl_r"   # trailing comment' in text
    cfg = load_config(config_file)
    assert cfg.hotkey == "ctrl_r"
    assert cfg.min_duration_seconds == 0.75


def test_the_original_is_backed_up_before_rewriting(tmp_path):
    original = '[general]\nlanguage = "de"\nhotkey = "f5"\n'
    config_file = _write(tmp_path, original)

    migrate_config(config_file)

    assert (tmp_path / "config.toml.bak").read_text(encoding="utf-8") == original


def test_migration_is_idempotent(tmp_path):
    config_file = _write(tmp_path, '[general]\nlanguage = "de"\nhotkey = "f5"\n')

    migrate_config(config_file)
    once = config_file.read_text(encoding="utf-8")
    second_notes = migrate_config(config_file)

    assert config_file.read_text(encoding="utf-8") == once
    assert second_notes == []


def test_missing_file_is_a_no_op(tmp_path):
    assert migrate_config(tmp_path / "nonexistent.toml") == []


def test_malformed_file_is_left_alone(tmp_path):
    """Line surgery on a file we cannot parse would be guesswork."""
    original = '[general\nhotkey = "f5"\n'
    config_file = _write(tmp_path, original)

    assert migrate_config(config_file) == []
    assert config_file.read_text(encoding="utf-8") == original


def test_a_rewrite_that_would_change_a_setting_is_abandoned(tmp_path):
    """A multi-line value cannot be commented out one line at a time: the
    continuation lines would be left dangling and break the whole file."""
    original = '[dictionary]\nwords = [\n  "eins",\n  "zwei",\n]\n\n[general]\nhotkey = "f5"\n'
    config_file = _write(tmp_path, original)

    migrate_config(config_file)

    # Untouched beats corrupted — the section is ignored at load time anyway.
    assert config_file.read_text(encoding="utf-8") == original
    assert load_config(config_file).hotkey == "f5"


def test_unwritable_target_does_not_raise(tmp_path):
    config_file = _write(tmp_path, '[general]\nlanguage = "de"\n')
    tmp_path.chmod(0o500)
    try:
        assert migrate_config(config_file) == []
    finally:
        tmp_path.chmod(0o700)


def test_effective_config_is_unchanged_by_migration(tmp_path):
    """The whole point: cleaning the file must not change what Sabbel does."""
    config_file = _write(
        tmp_path,
        '[general]\nlanguage = "de"\nhotkey = "ctrl_r"\n\n'
        "[audio]\nmin_duration_seconds = 0.75\n\n"
        "[history]\nenabled = true\nmax_bytes = 0\n",
    )
    before = load_config(config_file)

    migrate_config(config_file)

    assert load_config(config_file) == before
    assert before.history_max_bytes == SabbelConfig().history_max_bytes


def test_default_path_is_the_users_config_toml(tmp_path, monkeypatch):
    """The startup call passes no path, so the default has to be right."""
    monkeypatch.setattr("sabbel.config.Path.home", lambda: tmp_path)
    config_file = tmp_path / ".config" / "sabbel" / "config.toml"
    config_file.parent.mkdir(parents=True)
    config_file.write_text('[general]\nlanguage = "de"\nhotkey = "f5"\n', encoding="utf-8")

    notes = migrate_config()

    assert notes
    assert '# language = "de"' in config_file.read_text(encoding="utf-8")
    assert load_config().hotkey == "f5"


def test_the_backup_keeps_the_users_own_file_not_an_earlier_migration(tmp_path):
    """A second migration must not overwrite the pristine original: the whole
    value of the backup is recovering what the user wrote by hand."""
    original = (
        '[general]\nlanguage = "de"\nhotkey = "f5"\n\n'
        '[model]\nrepo = "mlx-community/whisper-large-v3-turbo"\n'
    )
    config_file = _write(tmp_path, original)

    migrate_config(config_file)  # obsolete language key
    migrate_config(config_file, drop=[("model", "repo")])  # unusable repo

    assert (tmp_path / "config.toml.bak").read_text(encoding="utf-8") == original
    text = config_file.read_text(encoding="utf-8")
    assert '# language = "de"' in text
    assert '# repo = "mlx-community/whisper-large-v3-turbo"' in text

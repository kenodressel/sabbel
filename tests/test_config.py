import pytest
from sabbel.config import SabbelConfig, load_config
from sabbel.transcriber import DEFAULT_MODEL_REPO


def test_default_config():
    cfg = SabbelConfig()
    assert cfg.model_repo == DEFAULT_MODEL_REPO
    assert cfg.min_duration_seconds == 0.5
    assert cfg.pre_paste_delay == 0.05
    assert cfg.post_paste_delay == 0.15


def test_load_config_missing_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.toml")
    assert cfg.model_repo == DEFAULT_MODEL_REPO


def test_load_config_from_file(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[general]\nhotkey = "f5"\n\n'
        '[audio]\nmin_duration_seconds = 1.0\n'
    )
    cfg = load_config(config_file)
    assert cfg.hotkey == "f5"
    assert cfg.min_duration_seconds == 1.0
    assert cfg.model_repo == DEFAULT_MODEL_REPO


def test_load_config_partial_override(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('[model]\nrepo = "mlx-community/parakeet-tdt-0.6b-v2"\n')
    cfg = load_config(config_file)
    assert cfg.model_repo == "mlx-community/parakeet-tdt-0.6b-v2"
    assert cfg.hotkey == "alt_r"


def test_history_disabled_by_default():
    cfg = SabbelConfig()
    assert cfg.history_enabled is False
    assert cfg.history_max_bytes == 1_000_000


def test_load_config_enables_history(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[history]\nenabled = true\nmax_bytes = 250000\n'
    )
    cfg = load_config(config_file)
    assert cfg.history_enabled is True
    assert cfg.history_max_bytes == 250000


# ---------------------------------------------------------------------------
# Invalid config must never brick the app.
#
# config.toml lives in ~/.config/sabbel and survives every reinstall, so a
# value the current build cannot use would otherwise refuse to transcribe
# forever — and "restart Sabbel" can never clear it. Every bad value is
# dropped in favour of its default instead.
# ---------------------------------------------------------------------------


def test_malformed_toml_falls_back_to_defaults(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('[model\nrepo = "unclosed section header"\n')

    cfg = load_config(config_file)

    assert cfg == SabbelConfig()


def test_unreadable_file_falls_back_to_defaults(tmp_path):
    # A directory where a file is expected: open() raises OSError, not a
    # TOML error, and must be just as survivable.
    config_dir = tmp_path / "config.toml"
    config_dir.mkdir()

    assert load_config(config_dir) == SabbelConfig()


@pytest.mark.parametrize("value", ['""', '"   "', "42", "true", '["a"]'])
def test_invalid_model_repo_falls_back_to_default(tmp_path, value):
    config_file = tmp_path / "config.toml"
    config_file.write_text(f"[model]\nrepo = {value}\n")

    assert load_config(config_file).model_repo == DEFAULT_MODEL_REPO


def test_model_repo_is_stripped(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('[model]\nrepo = "  mlx-community/parakeet-tdt-0.6b-v2  "\n')

    assert load_config(config_file).model_repo == "mlx-community/parakeet-tdt-0.6b-v2"


@pytest.mark.parametrize("value", ['"soon"', "0", "-1", "true", "nan"])
def test_invalid_min_duration_falls_back_to_default(tmp_path, value):
    config_file = tmp_path / "config.toml"
    config_file.write_text(f"[audio]\nmin_duration_seconds = {value}\n")

    assert load_config(config_file).min_duration_seconds == 0.5


@pytest.mark.parametrize("value", ['"fast"', "-0.5", "true", "inf"])
def test_invalid_paste_delays_fall_back_to_defaults(tmp_path, value):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        f"[injection]\npre_paste_delay = {value}\npost_paste_delay = {value}\n"
    )

    cfg = load_config(config_file)
    assert cfg.pre_paste_delay == 0.05
    assert cfg.post_paste_delay == 0.15


def test_zero_paste_delay_is_allowed(tmp_path):
    """Unlike a duration, "no delay at all" is a legitimate choice."""
    config_file = tmp_path / "config.toml"
    config_file.write_text("[injection]\npre_paste_delay = 0\n")

    assert load_config(config_file).pre_paste_delay == 0.0


@pytest.mark.parametrize("value", ['"nope_key"', '""', "5", '"alt_rr"'])
def test_invalid_hotkey_falls_back_to_default(tmp_path, value):
    """An unparseable hotkey used to raise out of SabbelApp.__init__, so the
    app never appeared in the menu bar at all."""
    config_file = tmp_path / "config.toml"
    config_file.write_text(f"[general]\nhotkey = {value}\n")

    assert load_config(config_file).hotkey == "alt_r"


@pytest.mark.parametrize("value", ['"yes"', "1", "0"])
def test_invalid_history_enabled_falls_back_to_default(tmp_path, value):
    config_file = tmp_path / "config.toml"
    config_file.write_text(f"[history]\nenabled = {value}\n")

    assert load_config(config_file).history_enabled is False


@pytest.mark.parametrize("value", ["0", "-1", '"big"', "true", "1.5"])
def test_invalid_history_max_bytes_falls_back_to_default(tmp_path, value):
    config_file = tmp_path / "config.toml"
    config_file.write_text(f"[history]\nmax_bytes = {value}\n")

    assert load_config(config_file).history_max_bytes == 1_000_000


def test_one_bad_value_does_not_discard_the_good_ones(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[general]\nhotkey = "nope_key"\n\n'
        "[audio]\nmin_duration_seconds = 1.5\n"
    )

    cfg = load_config(config_file)
    assert cfg.hotkey == "alt_r"
    assert cfg.min_duration_seconds == 1.5


def test_leftover_keys_from_an_older_version_are_ignored(tmp_path):
    """v0.4.0 dropped language selection and the custom dictionary; a config
    written for the Whisper build must still load."""
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[general]\nlanguage = "de"\nhotkey = "f5"\n\n'
        '[dictionary]\npath = "~/words.toml"\n'
    )

    cfg = load_config(config_file)
    assert cfg.hotkey == "f5"
    assert not hasattr(cfg, "language")


def test_non_table_section_is_ignored(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('model = "not-a-section"\n')

    assert load_config(config_file).model_repo == DEFAULT_MODEL_REPO


def test_invalid_values_are_logged(tmp_path, caplog):
    """A silently ignored setting is as confusing as a broken one."""
    config_file = tmp_path / "config.toml"
    config_file.write_text('[general]\nhotkey = "nope_key"\n')

    with caplog.at_level("WARNING"):
        load_config(config_file)

    assert "hotkey" in caplog.text
    assert "nope_key" in caplog.text

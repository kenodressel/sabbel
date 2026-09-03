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

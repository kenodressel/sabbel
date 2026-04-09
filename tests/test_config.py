import pytest
from sabbel.config import SabbelConfig, load_config


def test_default_config():
    cfg = SabbelConfig()
    assert cfg.language == "de"
    assert cfg.model_repo == "mlx-community/whisper-large-v3-turbo"
    assert cfg.min_duration_seconds == 0.5
    assert cfg.pre_paste_delay == 0.05
    assert cfg.post_paste_delay == 0.15


def test_load_config_missing_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.toml")
    assert cfg.language == "de"


def test_load_config_from_file(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text(
        '[general]\nlanguage = "en"\n\n'
        '[audio]\nmin_duration_seconds = 1.0\n'
    )
    cfg = load_config(config_file)
    assert cfg.language == "en"
    assert cfg.min_duration_seconds == 1.0
    assert cfg.model_repo == "mlx-community/whisper-large-v3-turbo"


def test_load_config_partial_override(tmp_path):
    config_file = tmp_path / "config.toml"
    config_file.write_text('[model]\nrepo = "mlx-community/whisper-tiny"\n')
    cfg = load_config(config_file)
    assert cfg.model_repo == "mlx-community/whisper-tiny"
    assert cfg.language == "de"

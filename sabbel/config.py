from dataclasses import dataclass, fields
from pathlib import Path
import tomllib


@dataclass
class SabbelConfig:
    language: str = "de"
    model_repo: str = "mlx-community/whisper-large-v3-turbo"
    min_duration_seconds: float = 0.5
    pre_paste_delay: float = 0.05
    post_paste_delay: float = 0.15


_TOML_MAP = {
    ("general", "language"): "language",
    ("model", "repo"): "model_repo",
    ("audio", "min_duration_seconds"): "min_duration_seconds",
    ("injection", "pre_paste_delay"): "pre_paste_delay",
    ("injection", "post_paste_delay"): "post_paste_delay",
}

_VALID_FIELDS = {f.name for f in fields(SabbelConfig)}


def load_config(path: Path | None = None) -> SabbelConfig:
    if path is None:
        path = Path.home() / ".config" / "sabbel" / "config.toml"
    if not path.exists():
        return SabbelConfig()

    with open(path, "rb") as f:
        data = tomllib.load(f)

    overrides = {}
    for (section, key), field_name in _TOML_MAP.items():
        if section in data and key in data[section]:
            overrides[field_name] = data[section][key]

    return SabbelConfig(**overrides)

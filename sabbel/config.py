from dataclasses import dataclass, fields
from pathlib import Path
import tomllib

from sabbel.transcriber import DEFAULT_MODEL_REPO


@dataclass
class SabbelConfig:
    model_repo: str = DEFAULT_MODEL_REPO
    min_duration_seconds: float = 0.5
    pre_paste_delay: float = 0.05
    post_paste_delay: float = 0.15
    hotkey: str = "alt_r"
    history_enabled: bool = False
    history_max_bytes: int = 1_000_000


_TOML_MAP = {
    ("model", "repo"): "model_repo",
    ("audio", "min_duration_seconds"): "min_duration_seconds",
    ("injection", "pre_paste_delay"): "pre_paste_delay",
    ("injection", "post_paste_delay"): "post_paste_delay",
    ("general", "hotkey"): "hotkey",
    ("history", "enabled"): "history_enabled",
    ("history", "max_bytes"): "history_max_bytes",
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

"""Runtime-toggled user preferences.

Stored separately from `config.toml`: that file is user-authored config,
while preferences are set by clicking menu items and need to persist
across restarts without touching the user's hand-edited TOML.
"""
import json
import logging
from pathlib import Path


_PREFS_PATH = Path.home() / ".config" / "sabbel" / "preferences.json"


def load_preferences(path: Path | None = None) -> dict:
    target = path or _PREFS_PATH
    if not target.exists():
        return {}
    try:
        data = json.loads(target.read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        logging.debug("Failed to read preferences", exc_info=True)
        return {}


def save_preference(key: str, value, path: Path | None = None) -> None:
    target = path or _PREFS_PATH
    prefs = load_preferences(target)
    prefs[key] = value
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(prefs, indent=2))
    except Exception:
        logging.debug("Failed to save preferences", exc_info=True)

"""Dictionary-based post-transcription replacements and auto-learning."""

import re
import tomllib
import threading
from pathlib import Path


_DICT_PATH = Path.home() / ".config" / "flowspeak" / "dictionary.toml"
_lock = threading.Lock()


def load_dictionary(path: Path | None = None) -> dict:
    """Load dictionary.toml. Returns full dict with 'replacements' and 'initial_prompt' sections."""
    path = path or _DICT_PATH
    if not path.exists():
        return {"replacements": {}, "initial_prompt": {"text": ""}}

    with open(path, "rb") as f:
        data = tomllib.load(f)

    return {
        "replacements": data.get("replacements", {}),
        "initial_prompt": data.get("initial_prompt", {"text": ""}),
    }


def apply_replacements(text: str, replacements: dict[str, str]) -> str:
    """Apply dictionary replacements to transcribed text. Case-insensitive."""
    for spoken, desired in replacements.items():
        pattern = re.compile(re.escape(spoken), re.IGNORECASE)
        text = pattern.sub(desired, text)
    return text


def get_initial_prompt(dictionary: dict) -> str | None:
    """Get the initial_prompt text for Whisper, or None if empty."""
    text = dictionary.get("initial_prompt", {}).get("text", "")
    return text if text.strip() else None


def save_learned_replacement(spoken: str, corrected: str, path: Path | None = None):
    """Append a learned replacement to dictionary.toml. Thread-safe."""
    path = path or _DICT_PATH
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)

        # Read existing content
        existing = ""
        if path.exists():
            existing = path.read_text()

        # Ensure [replacements] section exists
        if "[replacements]" not in existing:
            if existing and not existing.endswith("\n"):
                existing += "\n"
            existing += "\n[replacements]\n"

        # Append new entry
        # Escape quotes in keys/values
        key = spoken.replace('"', '\\"')
        val = corrected.replace('"', '\\"')
        entry = f'"{key}" = "{val}"\n'

        # Check if this replacement already exists
        if f'"{key}"' in existing:
            return  # Already learned

        path.write_text(existing + entry)

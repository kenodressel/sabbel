"""User-authored configuration from ``~/.config/sabbel/config.toml``.

That file is user data: it lives outside the app bundle and survives every
reinstall, upgrade and restart. A value the running build cannot use must
therefore never be fatal — the pre-0.4.0 README told users to pin
``[model] repo = "mlx-community/whisper-large-v3-turbo"``, and once Parakeet
replaced Whisper that same line refused every transcription for good, with
"restart Sabbel" as the only (useless) advice.

So every value is validated here and a bad one is dropped in favour of its
default, loudly in the log but without taking the rest of the file — or the
app — down with it.
"""

from dataclasses import dataclass, fields
from typing import Iterable
import logging
import math
import os
import re
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


# ---------------------------------------------------------------------------
# Validators. Each returns the coerced value or raises ValueError with a
# reason short enough to sit in a log line.
#
# bool is a subclass of int in Python, so every numeric validator has to
# reject it explicitly: `min_duration_seconds = true` is a mistake, not 1.
# ---------------------------------------------------------------------------


def _text(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("expected a non-empty string")
    return value.strip()


def _number(value, *, minimum, inclusive):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("expected a number")
    if not math.isfinite(value):
        raise ValueError("expected a finite number")
    if inclusive and value < minimum:
        raise ValueError(f"expected a number >= {minimum}")
    if not inclusive and value <= minimum:
        raise ValueError(f"expected a number > {minimum}")
    return float(value)


def _duration(value):
    return _number(value, minimum=0, inclusive=False)


def _delay(value):
    # Zero is legitimate here: "paste with no delay at all" is a real choice,
    # unlike a zero-length minimum recording.
    return _number(value, minimum=0, inclusive=True)


def _flag(value):
    if not isinstance(value, bool):
        raise ValueError("expected true or false")
    return value


def _byte_count(value):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("expected a whole number")
    if value <= 0:
        raise ValueError("expected a whole number > 0")
    return value


def _hotkey(value):
    name = _text(value)
    # Imported here so config stays importable without pynput, and so the
    # frozen app doesn't pull the keyboard backend in before Quartz.
    from sabbel.hotkey import _parse_hotkey

    _parse_hotkey(name)  # raises ValueError on an unknown key name
    return name


_TOML_MAP = {
    ("model", "repo"): ("model_repo", _text),
    ("audio", "min_duration_seconds"): ("min_duration_seconds", _duration),
    ("injection", "pre_paste_delay"): ("pre_paste_delay", _delay),
    ("injection", "post_paste_delay"): ("post_paste_delay", _delay),
    ("general", "hotkey"): ("hotkey", _hotkey),
    ("history", "enabled"): ("history_enabled", _flag),
    ("history", "max_bytes"): ("history_max_bytes", _byte_count),
}

_VALID_FIELDS = {f.name for f in fields(SabbelConfig)}

_DEFAULTS = SabbelConfig()


def default_config_path() -> Path:
    return Path.home() / ".config" / "sabbel" / "config.toml"


def _known_keys() -> dict[str, set[str]]:
    known: dict[str, set[str]] = {}
    for section, key in _TOML_MAP:
        known.setdefault(section, set()).add(key)
    return known


def _obsolete_entries(data: dict) -> list[tuple[str, str | None]]:
    """Sections and keys this build has no use for any more.

    A key of ``None`` means the whole section is obsolete. v0.4.0 dropped
    ``[general] language`` and the entire custom dictionary this way.
    """
    known = _known_keys()
    found: list[tuple[str, str | None]] = []
    for section, values in data.items():
        if not isinstance(values, dict):
            continue  # a top-level scalar, not a section we manage
        if section not in known:
            found.append((section, None))
            continue
        found.extend(
            (section, key) for key in values if key not in known[section]
        )
    return found


def _validated_overrides(data: dict) -> tuple[dict, list[tuple[str, str, object, str]]]:
    """Split *data* into usable overrides and rejected (section, key, raw, why)."""
    overrides = {}
    rejected = []
    for (section, key), (field_name, validate) in _TOML_MAP.items():
        values = data.get(section)
        if not isinstance(values, dict) or key not in values:
            continue
        raw = values[key]
        try:
            overrides[field_name] = validate(raw)
        except ValueError as exc:
            rejected.append((section, key, raw, str(exc)))
    return overrides, rejected


def _read(path: Path) -> dict | None:
    """Parse *path*, or return None if it cannot be read as TOML."""
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        logging.warning("Ignoring %s — using defaults (%s)", path, exc)
        return None


def load_config(path: Path | None = None) -> SabbelConfig:
    if path is None:
        path = default_config_path()
    if not path.exists():
        return SabbelConfig()

    data = _read(path)
    if data is None:
        return SabbelConfig()

    for section, key in _obsolete_entries(data):
        if key is None:
            logging.info("Ignoring unknown section [%s] in %s", section, path)
        else:
            logging.info("Ignoring unknown key [%s] %s in %s", section, key, path)

    overrides, rejected = _validated_overrides(data)
    for section, key, raw, why in rejected:
        logging.warning(
            "Ignoring [%s] %s = %r in %s (%s) — using the default %r",
            section,
            key,
            raw,
            path,
            why,
            getattr(_DEFAULTS, _TOML_MAP[(section, key)][0]),
        )

    return SabbelConfig(**overrides)


# ---------------------------------------------------------------------------
# Migration
#
# Ignoring a bad entry keeps Sabbel running, but the line stays in the user's
# file and warns on every launch. On an upgrade we comment it out instead —
# aggressively, because an obsolete key can never come back into use.
#
# Two things make that safe on a hand-written file: the original is copied to
# config.toml.bak first, and the rewritten text has to yield exactly the same
# effective config before it is allowed to replace anything. Only whole lines
# we can locate unambiguously are touched, so comments and formatting around
# them survive untouched.
# ---------------------------------------------------------------------------

_SECTION_RE = re.compile(r"^\s*\[\s*(?P<name>[^\[\]]+?)\s*\]\s*(?:#.*)?$")
_KEY_RE = re.compile(r"""^\s*(?P<key>[A-Za-z0-9_-]+|"[^"]*"|'[^']*')\s*=""")


def _commented(line: str, reason: str) -> str:
    body = line.rstrip("\r\n")
    newline = line[len(body) :] or "\n"
    return f"# sabbel: {reason}{newline}# {body}{newline}"


def _comment_out(
    text: str, targets: dict[tuple[str, str | None], str]
) -> tuple[str, list[str]]:
    obsolete_sections = {s for (s, k) in targets if k is None}
    obsolete_keys = {(s, k) for (s, k) in targets if k is not None}

    out: list[str] = []
    notes: list[str] = []
    section: str | None = None

    for line in text.splitlines(keepends=True):
        stripped = line.rstrip("\r\n")

        header = _SECTION_RE.match(stripped)
        if header:
            section = header.group("name")
            if section in obsolete_sections:
                reason = targets[(section, None)]
                out.append(_commented(line, reason))
                notes.append(f"[{section}] — {reason}")
                continue
            out.append(line)
            continue

        entry = _KEY_RE.match(stripped)
        if entry is not None and section is not None:
            key = entry.group("key").strip("\"'")
            if section in obsolete_sections or (section, key) in obsolete_keys:
                reason = targets.get((section, key)) or targets[(section, None)]
                out.append(_commented(line, reason))
                notes.append(f"[{section}] {key} — {reason}")
                continue

        out.append(line)

    return "".join(out), notes


def migrate_config(
    path: Path | None = None,
    *,
    drop: Iterable[tuple[str, str]] = (),
) -> list[str]:
    """Comment out obsolete, invalid and *drop*-listed entries in config.toml.

    Returns a note per change, empty when nothing was (or could safely be)
    rewritten. Never raises: a config file is not worth failing a launch over.
    """
    if path is None:
        path = default_config_path()

    try:
        if not path.exists():
            return []
        original = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        logging.info("Not migrating %s (%s)", path, exc)
        return []

    try:
        data = tomllib.loads(original)
    except tomllib.TOMLDecodeError as exc:
        # Line surgery on a file we cannot parse would be guesswork, and
        # load_config already falls back to defaults for it.
        logging.info("Not migrating %s — it is not valid TOML (%s)", path, exc)
        return []

    targets: dict[tuple[str, str | None], str] = {}
    for section, key in _obsolete_entries(data):
        targets[(section, key)] = "no longer used by this version of Sabbel"
    for section, key, _raw, why in _validated_overrides(data)[1]:
        targets[(section, key)] = f"ignored — {why}"
    for section, key in drop:
        values = data.get(section)
        if isinstance(values, dict) and key in values:
            targets[(section, key)] = "not usable by this version of Sabbel"

    if not targets:
        return []

    new_text, notes = _comment_out(original, targets)
    if not notes:
        return []

    dropped_fields = {
        _TOML_MAP[(s, k)][0] for (s, k) in drop if (s, k) in _TOML_MAP
    }
    overrides, _ = _validated_overrides(data)
    expected = SabbelConfig(
        **{f: v for f, v in overrides.items() if f not in dropped_fields}
    )

    try:
        new_data = tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as exc:
        logging.warning(
            "Not migrating %s — the result would not parse (%s). "
            "Left untouched; the entries are ignored at load time anyway.",
            path,
            exc,
        )
        return []

    if SabbelConfig(**_validated_overrides(new_data)[0]) != expected:
        logging.warning(
            "Not migrating %s — the rewrite would change a setting.", path
        )
        return []

    backup = path.with_suffix(path.suffix + ".bak")
    scratch = path.with_suffix(path.suffix + ".tmp")
    try:
        # Only ever the first time: the backup is there to recover the file the
        # user wrote by hand, and a later migration would overwrite it with a
        # copy Sabbel had already edited.
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")
        scratch.write_text(new_text, encoding="utf-8")
        os.replace(scratch, path)
    except OSError as exc:
        logging.warning("Could not migrate %s (%s)", path, exc)
        scratch.unlink(missing_ok=True)
        return []

    for note in notes:
        logging.info("Migrated %s: commented out %s", path, note)
    logging.info("Original %s saved as %s", path, backup)
    return notes

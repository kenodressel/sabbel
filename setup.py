"""
py2app build configuration for Sabbel.

Usage:
    uv run --extra build python setup.py py2app
"""

import os
import glob
import re
import sys

# modulegraph's AST visitor can hit Python's default recursion limit on
# deeply nested expressions found in packages like numpy/mlx.
sys.setrecursionlimit(10_000)

APP = ["sabbel/__main__.py"]


def _read_version():
    """Read __version__ from sabbel/__init__.py without importing it.

    The plist requires a numeric "X.Y.Z" string; "dev" is not valid, so
    fall back to "0.0.0" for unreleased builds.
    """
    init = os.path.join(os.path.dirname(__file__), "sabbel", "__init__.py")
    with open(init) as f:
        match = re.search(r'^__version__\s*=\s*"([^"]+)"', f.read(), re.M)
    version = match.group(1) if match else "0.0.0"
    return "0.0.0" if version == "dev" else version


_BUNDLE_VERSION = _read_version()

# ---------------------------------------------------------------------------
# Locate native libraries that py2app won't discover automatically
# ---------------------------------------------------------------------------

def _find_in_venv(pattern):
    """Find a file matching *pattern* inside the active venv's site-packages."""
    import site
    for sp in site.getsitepackages():
        matches = glob.glob(os.path.join(sp, pattern))
        if matches:
            return matches[0]
    # Fallback: walk from the venv root
    venv = os.environ.get("VIRTUAL_ENV", os.path.join(os.path.dirname(__file__), ".venv"))
    for root, _dirs, files in os.walk(venv):
        for f in files:
            if glob.fnmatch.fnmatch(f, os.path.basename(pattern)):
                candidate = os.path.join(root, f)
                if glob.fnmatch.fnmatch(candidate, f"*{pattern}"):
                    return candidate
    return None


libmlx = _find_in_venv("mlx/lib/libmlx.dylib")
metallib = _find_in_venv("mlx/lib/mlx.metallib")
libportaudio = _find_in_venv("_sounddevice_data/portaudio-binaries/libportaudio.dylib")


def _relpath(p):
    """Convert an absolute path to a path relative to setup.py's directory."""
    if p is None:
        return None
    return os.path.relpath(p, os.path.dirname(os.path.abspath(__file__)))


# frameworks are copied into Contents/Frameworks/ — only include actual
# Mach-O dylibs.  mlx.metallib is a Metal shader archive (not Mach-O),
# so it must be copied separately (see Makefile post-build step).
frameworks = [_relpath(p) for p in (libmlx, libportaudio) if p]

# ---------------------------------------------------------------------------
# py2app options
# ---------------------------------------------------------------------------

OPTIONS = {
    "iconfile": "icons/Sabbel.icns",
    "packages": [
        "sabbel",
        "rumps",
        "pynput",
        "sounddevice",
        "_sounddevice_data",
        "numpy",
        # mlx is a namespace package (no __init__.py) with a native .so
        # core — py2app's modulegraph/imp.find_module cannot locate it.
        # We omit it from packages and rely on the module graph to
        # discover individual mlx modules through import analysis.
        # Native libs (libmlx.dylib, mlx.metallib) are in frameworks.
        "mlx_whisper",
    ],
    "includes": [
        "pynput.keyboard._darwin",
        "pynput.mouse._darwin",
        "pynput._util.darwin",
        "AppKit",
        "Foundation",
        "Cocoa",
        "Quartz",
        "AVFoundation",
        "HIServices",
        "CoreFoundation",
        "objc",
    ],
    "frameworks": frameworks,
    "plist": {
        "CFBundleDisplayName": "Sabbel",
        "CFBundleIdentifier": "com.sabbel.app",
        "CFBundleName": "Sabbel",
        "CFBundleShortVersionString": _BUNDLE_VERSION,
        "CFBundleVersion": _BUNDLE_VERSION,
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription": (
            "Sabbel needs microphone access to transcribe your speech locally."
        ),
    },
}

# ---------------------------------------------------------------------------
# Monkey-patch: setuptools reads pyproject.toml and populates install_requires
# on the Distribution *after* setup() merges our attrs. py2app explicitly
# rejects a non-empty install_requires. We clear it right before py2app's
# finalize_options runs.
#
# Only apply the patch when py2app is available (i.e., when we're actually
# building the .app, not when setuptools is inspecting setup.py for metadata).
# ---------------------------------------------------------------------------
try:
    from py2app.build_app import py2app as _py2app_cmd

    _orig_finalize = _py2app_cmd.finalize_options

    def _patched_finalize(self):
        self.distribution.install_requires = []
        _orig_finalize(self)

    _py2app_cmd.finalize_options = _patched_finalize
except ImportError:
    pass  # py2app not installed — setuptools is just reading metadata

# ---------------------------------------------------------------------------

from setuptools import setup

setup(
    name="Sabbel",
    app=APP,
    options={"py2app": OPTIONS},
)

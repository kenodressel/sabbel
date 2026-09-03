import locale
import logging
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Force a UTF-8 locale before anything reads a file.
#
# py2app's stub restores the launch-time LC_CTYPE *after* Py_Initialize(), and
# LaunchServices supplies none, so open() defaults to ASCII and any non-ASCII
# byte raises UnicodeDecodeError — PYTHONUTF8 in the plist cannot win against
# that ordering. Our own code passes
# encoding="utf-8" explicitly; third-party code does not — parakeet-mlx reads
# the model's config.json with a bare open() and dies on the em-dash in it.
#
# open() resolves its default per call via the current LC_CTYPE, so setting it
# here fixes every later read, ours and third-party alike.
# ---------------------------------------------------------------------------
for _loc in ("en_US.UTF-8", "C.UTF-8", "UTF-8"):
    try:
        locale.setlocale(locale.LC_CTYPE, _loc)
        break
    except locale.Error:
        continue

# ---------------------------------------------------------------------------
# Frozen-app detection: when running inside a py2app .app bundle, tell MLX
# where to find its Metal shader library before anything imports mlx.
# ---------------------------------------------------------------------------
if getattr(sys, "frozen", False):
    _bundle_dir = os.path.normpath(
        os.path.join(os.path.dirname(sys.executable), "..", "Frameworks")
    )
    _metallib = os.path.join(_bundle_dir, "mlx.metallib")
    if os.path.isfile(_metallib):
        os.environ.setdefault("MLX_METAL_LIB_PATH", _metallib)

import Quartz  # Eager import to prevent pyobjc race condition

from sabbel.app import SabbelApp
from sabbel.config import load_config
from sabbel.single_instance import SingleInstanceLock


LOG_PATH = Path("/tmp/sabbel-runtime.log")


def setup_logging() -> None:
    logging.basicConfig(
        filename=LOG_PATH,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        force=True,
    )

def main():
    setup_logging()
    lock = SingleInstanceLock(Path("/tmp/sabbel.lock"))
    if not lock.acquire():
        logging.info("Sabbel is already running. Exiting.")
        return 0

    logging.info("Sabbel starting")
    config = load_config()
    try:
        app = SabbelApp(config)
    except Exception as exc:
        logging.exception("Failed to initialize Sabbel")
        lock.release()
        return 1

    try:
        app.run()
    finally:
        logging.info("Sabbel shutting down")
        lock.release()


if __name__ == "__main__":
    main()

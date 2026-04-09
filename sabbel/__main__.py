import logging
import os
import sys
from pathlib import Path

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

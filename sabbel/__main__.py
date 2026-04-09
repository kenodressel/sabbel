import logging
from pathlib import Path
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

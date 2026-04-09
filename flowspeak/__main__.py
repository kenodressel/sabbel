import logging
from pathlib import Path
import Quartz  # Eager import to prevent pyobjc race condition

from flowspeak.app import FlowSpeakApp
from flowspeak.config import load_config
from flowspeak.single_instance import SingleInstanceLock


LOG_PATH = Path("/tmp/flowspeak-runtime.log")


def setup_logging() -> None:
    logging.basicConfig(
        filename=LOG_PATH,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        force=True,
    )

def main():
    setup_logging()
    lock = SingleInstanceLock(Path("/tmp/flowspeak.lock"))
    if not lock.acquire():
        logging.info("FlowSpeak is already running. Exiting.")
        return 0

    logging.info("FlowSpeak starting")
    config = load_config()
    try:
        app = FlowSpeakApp(config)
    except Exception as exc:
        logging.exception("Failed to initialize FlowSpeak")
        lock.release()
        return 1

    try:
        app.run()
    finally:
        logging.info("FlowSpeak shutting down")
        lock.release()


if __name__ == "__main__":
    main()

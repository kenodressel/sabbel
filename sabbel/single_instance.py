import fcntl
import os
from pathlib import Path


class SingleInstanceLock:
    def __init__(self, path: Path):
        self._path = path
        self._fd = None

    def acquire(self) -> bool:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = self._path.open("w", encoding="utf-8")
        try:
            fcntl.flock(self._fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._fd.close()
            self._fd = None
            return False

        self._fd.write(f"{os.getpid()}\n")
        self._fd.flush()
        return True

    def release(self) -> None:
        if self._fd is None:
            return
        fcntl.flock(self._fd.fileno(), fcntl.LOCK_UN)
        self._fd.close()
        self._fd = None

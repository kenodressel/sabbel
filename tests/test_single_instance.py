from pathlib import Path

from flowspeak.single_instance import SingleInstanceLock


def test_single_instance_lock_blocks_second_acquire(tmp_path: Path):
    lock_path = tmp_path / "flowspeak.lock"
    first = SingleInstanceLock(lock_path)
    second = SingleInstanceLock(lock_path)

    assert first.acquire() is True
    assert second.acquire() is False

    first.release()
    assert second.acquire() is True
    second.release()

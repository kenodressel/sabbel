import numpy as np
import pytest
from unittest.mock import patch, MagicMock
from flowspeak.recorder import AudioRecorder


def test_get_audio_empty():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    audio = recorder.get_audio()
    assert isinstance(audio, np.ndarray)
    assert audio.dtype == np.float32
    assert len(audio) == 0


def test_get_audio_assembles_chunks():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()

    for _ in range(3):
        chunk = np.random.randn(1600, 1).astype(np.float32)
        recorder._queue.put(chunk)

    audio = recorder.get_audio()
    assert audio.dtype == np.float32
    assert audio.ndim == 1
    assert len(audio) == 4800


def test_is_valid_duration():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._min_samples = 8000

    short_audio = np.zeros(4000, dtype=np.float32)
    assert recorder.is_valid_duration(short_audio) is False

    valid_audio = np.zeros(8000, dtype=np.float32)
    assert recorder.is_valid_duration(valid_audio) is True

    long_audio = np.zeros(16000, dtype=np.float32)
    assert recorder.is_valid_duration(long_audio) is True


def test_get_audio_clears_queue():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._queue.put(np.zeros((1600, 1), dtype=np.float32))

    _ = recorder.get_audio()
    assert recorder._queue.empty()

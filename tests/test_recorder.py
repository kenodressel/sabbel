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


@patch("flowspeak.recorder.sd.InputStream")
def test_start_initializes_stream_lazily(mock_input_stream):
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None

    stream = MagicMock()
    mock_input_stream.return_value = stream

    recorder.start()

    mock_input_stream.assert_called_once()
    stream.start.assert_called_once()
    assert recorder._stream is stream


def test_stop_without_stream_is_noop():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._stream = None
    recorder.stop()


def test_close_without_stream_is_noop():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._stream = None
    recorder.close()


def test_has_speech_accepts_quiet_voice_level_audio():
    recorder = AudioRecorder.__new__(AudioRecorder)
    audio = np.full(16000, 0.005, dtype=np.float32)
    assert recorder.has_speech(audio) is True


def test_has_speech_rejects_near_silence():
    recorder = AudioRecorder.__new__(AudioRecorder)
    audio = np.full(16000, 0.001, dtype=np.float32)
    assert recorder.has_speech(audio) is False

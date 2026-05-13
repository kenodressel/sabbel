import numpy as np
import pytest
from unittest.mock import patch, MagicMock
from sabbel.recorder import AudioRecorder


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


@patch("sabbel.recorder.sd.InputStream")
def test_start_initializes_stream_lazily(mock_input_stream):
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = None
    recorder.last_missing_device = None

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


def test_list_input_devices_filters_output_only():
    fake_devices = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
        {"name": "MacBook Pro Speakers", "index": 1, "max_input_channels": 0},
        {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
    ]
    with patch("sabbel.recorder.sd.query_devices", return_value=fake_devices):
        from sabbel.recorder import list_input_devices
        result = list_input_devices()

    assert result == [
        {"name": "MacBook Pro Microphone", "index": 0},
        {"name": "Dell WD22 Mic", "index": 2},
    ]


def test_list_input_devices_handles_query_error():
    import sounddevice as sd
    with patch("sabbel.recorder.sd.query_devices", side_effect=sd.PortAudioError("PortAudio error")):
        from sabbel.recorder import list_input_devices
        assert list_input_devices() == []


def test_set_device_closes_existing_stream():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._device = None
    stream = MagicMock()
    stream.active = True
    recorder._stream = stream
    recorder._stream_device_index = 2  # add this

    recorder.set_device("Dell WD22 Mic")

    assert recorder._device == "Dell WD22 Mic"
    stream.stop.assert_called_once()
    stream.close.assert_called_once()
    assert recorder._stream is None
    assert recorder._stream_device_index is None  # add this


def test_set_device_with_no_active_stream_just_updates():
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._device = "Old Mic"
    recorder._stream = None

    recorder.set_device(None)

    assert recorder._device is None
    assert recorder._stream is None


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_resolves_known_device_to_index(mock_input_stream, mock_query):
    mock_query.return_value = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
        {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
    ]
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_missing_device = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] == 2
    assert recorder.last_missing_device is None


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_unknown_device_falls_back_to_default(mock_input_stream, mock_query):
    mock_query.return_value = [
        {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
    ]
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_missing_device = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] is None
    assert recorder.last_missing_device == "Dell WD22 Mic"


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_with_no_device_pref_uses_system_default(mock_input_stream, mock_query):
    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = None
    recorder.last_missing_device = None

    recorder.start()

    call_kwargs = mock_input_stream.call_args.kwargs
    assert call_kwargs["device"] is None
    assert recorder.last_missing_device is None
    mock_query.assert_not_called()


def test_constructor_accepts_device_param():
    recorder = AudioRecorder(min_duration_seconds=0.5, device="Dell WD22 Mic")
    assert recorder._device == "Dell WD22 Mic"
    assert recorder.last_missing_device is None


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_invalidates_cached_stream_when_device_reappears(mock_input_stream, mock_query):
    """Scenario: dock unplugged → recorded with default → dock replugged → next
    recording must re-open against dock, not reuse the system-default stream.
    """
    # First resolve: only internal mic available (Dell missing)
    # Second resolve: Dell back at index 2
    mock_query.side_effect = [
        [{"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1}],
        [
            {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
            {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
        ],
    ]
    streams = [MagicMock(), MagicMock()]
    mock_input_stream.side_effect = streams

    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_missing_device = None

    # First call: Dell missing → opens with device=None
    recorder.start()
    assert mock_input_stream.call_args_list[0].kwargs["device"] is None
    assert recorder.last_missing_device == "Dell WD22 Mic"
    assert recorder._stream is streams[0]
    assert recorder._stream_device_index is None

    # Second call: Dell back → must close stream-0 and open stream-1 on index 2
    recorder.start()
    streams[0].close.assert_called_once()
    assert mock_input_stream.call_args_list[1].kwargs["device"] == 2
    assert recorder.last_missing_device is None
    assert recorder._stream is streams[1]
    assert recorder._stream_device_index == 2


@patch("sabbel.recorder.sd.query_devices")
@patch("sabbel.recorder.sd.InputStream")
def test_start_invalidates_cached_stream_when_device_disappears(mock_input_stream, mock_query):
    """Scenario: dock was present and used → next recording must close the
    dock-bound stream and re-open against the system default when dock unplugged.
    """
    mock_query.side_effect = [
        [
            {"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1},
            {"name": "Dell WD22 Mic", "index": 2, "max_input_channels": 2},
        ],
        [{"name": "MacBook Pro Microphone", "index": 0, "max_input_channels": 1}],
    ]
    streams = [MagicMock(), MagicMock()]
    mock_input_stream.side_effect = streams

    recorder = AudioRecorder.__new__(AudioRecorder)
    recorder._queue = __import__("queue").Queue()
    recorder._min_samples = 8000
    recorder._stream = None
    recorder._stream_device_index = None
    recorder._device = "Dell WD22 Mic"
    recorder.last_missing_device = None

    recorder.start()
    assert recorder._stream_device_index == 2

    recorder.start()
    streams[0].close.assert_called_once()
    assert mock_input_stream.call_args_list[1].kwargs["device"] is None
    assert recorder.last_missing_device == "Dell WD22 Mic"
    assert recorder._stream_device_index is None

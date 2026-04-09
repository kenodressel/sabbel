import numpy as np
from unittest.mock import patch
from sabbel.transcriber import TranscriptionEngine


@patch("sabbel.transcriber._load_mlx_whisper")
def test_transcribe_returns_text(mock_whisper):
    mock_whisper.return_value.transcribe.return_value = {
        "text": "  Hallo Welt  ",
        "segments": [],
        "language": "de",
    }
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    audio = np.random.randn(16000).astype(np.float32)
    result = engine.transcribe(audio, language="de")
    assert result == "Hallo Welt"
    mock_whisper.return_value.transcribe.assert_called_once()
    call_kwargs = mock_whisper.return_value.transcribe.call_args[1]
    assert call_kwargs["path_or_hf_repo"] == "mlx-community/whisper-tiny"
    assert call_kwargs["language"] == "de"


@patch("sabbel.transcriber._load_mlx_whisper")
def test_transcribe_short_audio_returns_empty(mock_whisper):
    engine = TranscriptionEngine(
        model_repo="mlx-community/whisper-tiny",
        min_samples=8000,
    )
    short_audio = np.zeros(4000, dtype=np.float32)
    result = engine.transcribe(short_audio, language="de")
    assert result == ""
    mock_whisper.assert_not_called()


@patch("sabbel.transcriber._load_mlx_whisper")
def test_transcribe_empty_audio_returns_empty(mock_whisper):
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    empty_audio = np.array([], dtype=np.float32)
    result = engine.transcribe(empty_audio, language="de")
    assert result == ""
    mock_whisper.assert_not_called()


@patch("sabbel.transcriber._load_mlx_whisper")
def test_transcribe_whitespace_result_returns_empty(mock_whisper):
    mock_whisper.return_value.transcribe.return_value = {
        "text": "   ",
        "segments": [],
        "language": "de",
    }
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    audio = np.random.randn(16000).astype(np.float32)
    result = engine.transcribe(audio, language="de")
    assert result == ""


@patch("sabbel.transcriber._load_mlx_whisper")
def test_warmup_transcribes_silence(mock_whisper):
    mock_whisper.return_value.transcribe.return_value = {"text": "", "segments": [], "language": "de"}
    engine = TranscriptionEngine(model_repo="mlx-community/whisper-tiny")
    engine.warmup()
    call_args = mock_whisper.return_value.transcribe.call_args
    audio_arg = call_args[0][0]
    assert isinstance(audio_arg, np.ndarray)
    assert len(audio_arg) == 16000

import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from sabbel.transcriber import DEFAULT_MODEL_REPO, TranscriptionEngine


def _fake_parakeet(text="Hallo Welt", sample_rate=16000):
    """Stand-in for (mx, from_pretrained, get_logmel)."""
    mx = MagicMock()
    mx.array.side_effect = lambda a: ("mel-input", a)
    model = MagicMock()
    model.preprocessor_config.sample_rate = sample_rate
    model.generate.return_value = [MagicMock(text=text)]
    from_pretrained = MagicMock(return_value=model)
    get_logmel = MagicMock(return_value="mel")
    return mx, from_pretrained, get_logmel, model


@patch("sabbel.transcriber._load_parakeet")
def test_transcribe_returns_text(mock_load):
    mx, from_pretrained, get_logmel, model = _fake_parakeet("  Hallo Welt  ")
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    engine = TranscriptionEngine()
    result = engine.transcribe(np.random.randn(16000).astype(np.float32))

    assert result == "Hallo Welt"
    from_pretrained.assert_called_once_with(DEFAULT_MODEL_REPO)
    model.generate.assert_called_once_with("mel")


@patch("sabbel.transcriber._load_parakeet")
def test_transcribe_goes_through_logmel_not_ffmpeg(mock_load):
    """BaseParakeet.transcribe() shells out to ffmpeg, which Sabbel doesn't ship."""
    mx, from_pretrained, get_logmel, model = _fake_parakeet()
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    TranscriptionEngine().transcribe(np.random.randn(16000).astype(np.float32))

    get_logmel.assert_called_once()
    model.transcribe.assert_not_called()


@patch("sabbel.transcriber._load_parakeet")
def test_audio_is_passed_as_float32(mock_load):
    """get_logmel reinterprets the STFT via mx.view; bfloat16 breaks the shape."""
    mx, from_pretrained, get_logmel, _ = _fake_parakeet()
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    audio = np.random.randn(16000).astype(np.float64)
    TranscriptionEngine().transcribe(audio)

    passed = mx.array.call_args[0][0]
    assert passed.dtype == np.float32


@patch("sabbel.transcriber._load_parakeet")
def test_model_is_loaded_once(mock_load):
    mx, from_pretrained, get_logmel, _ = _fake_parakeet()
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    engine = TranscriptionEngine()
    audio = np.random.randn(16000).astype(np.float32)
    engine.transcribe(audio)
    engine.transcribe(audio)

    from_pretrained.assert_called_once()


@patch("sabbel.transcriber._load_parakeet")
def test_rejects_wrong_sample_rate(mock_load):
    """Sabbel records at 16 kHz; a mismatched model would silently mis-transcribe."""
    mx, from_pretrained, get_logmel, _ = _fake_parakeet(sample_rate=22050)
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    with pytest.raises(RuntimeError, match="22050 Hz"):
        TranscriptionEngine().transcribe(np.random.randn(16000).astype(np.float32))


@patch("sabbel.transcriber._load_parakeet")
def test_short_audio_returns_empty(mock_load):
    engine = TranscriptionEngine(min_samples=8000)
    assert engine.transcribe(np.zeros(4000, dtype=np.float32)) == ""
    mock_load.assert_not_called()


@patch("sabbel.transcriber._load_parakeet")
def test_empty_audio_returns_empty(mock_load):
    engine = TranscriptionEngine()
    assert engine.transcribe(np.array([], dtype=np.float32)) == ""
    mock_load.assert_not_called()


@patch("sabbel.transcriber._load_parakeet")
def test_whitespace_result_returns_empty(mock_load):
    mx, from_pretrained, get_logmel, _ = _fake_parakeet("   ")
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    engine = TranscriptionEngine()
    assert engine.transcribe(np.random.randn(16000).astype(np.float32)) == ""


@patch("sabbel.transcriber._load_parakeet")
def test_warmup_transcribes_silence(mock_load):
    mx, from_pretrained, get_logmel, _ = _fake_parakeet("")
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    TranscriptionEngine().warmup()

    audio = mx.array.call_args[0][0]
    assert isinstance(audio, np.ndarray)
    assert len(audio) == 16000


@patch("sabbel.transcriber._load_parakeet")
def test_custom_repo_is_used(mock_load):
    mx, from_pretrained, get_logmel, _ = _fake_parakeet()
    mock_load.return_value = (mx, from_pretrained, get_logmel)

    TranscriptionEngine(model_repo="mlx-community/parakeet-tdt-0.6b-v2").transcribe(
        np.random.randn(16000).astype(np.float32)
    )

    from_pretrained.assert_called_once_with("mlx-community/parakeet-tdt-0.6b-v2")

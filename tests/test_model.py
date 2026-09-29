"""Real-model tests — opt-in with `make test-model` (or `pytest -m model`).

Everything else in this suite mocks MLX, and that is how two regressions
shipped: mlx 0.32 made streams thread-owned, so v0.4.x transcribed nothing,
and MLX's buffer cache grew ~0.5 GB per dictation until v0.5.0 sat on tens of
GB. Neither is visible without the real model on real Metal.

The first run downloads the model (~2.3 GB) into the Hugging Face cache.
Speech comes from macOS `say`, so no audio fixture lives in the repo.
"""

import shutil
import subprocess
import threading
import wave

import numpy as np
import pytest

# Resolved now, at collection: the autouse _isolate_home fixture points HOME at
# a temp dir before each test, which would send the 2.3 GB download there.
import huggingface_hub.constants as _hf

_REAL_HF_CACHE = _hf.HF_HUB_CACHE

from sabbel.transcriber import SAMPLE_RATE, TranscriptionEngine

pytestmark = pytest.mark.model

_PHRASE = "Hello world, this is a dictation test."


@pytest.fixture(autouse=True)
def _real_model_cache(monkeypatch):
    monkeypatch.setattr(_hf, "HF_HUB_CACHE", _REAL_HF_CACHE)


@pytest.fixture(scope="module")
def speech(tmp_path_factory) -> np.ndarray:
    if shutil.which("say") is None:
        pytest.skip("macOS `say` is needed to synthesise test speech")
    path = tmp_path_factory.mktemp("speech") / "phrase.wav"
    subprocess.run(
        ["say", "-o", str(path), f"--data-format=LEI16@{SAMPLE_RATE}", _PHRASE],
        check=True,
    )
    with wave.open(str(path)) as f:
        assert f.getframerate() == SAMPLE_RATE and f.getnchannels() == 1
        pcm = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


def _words(text: str) -> set[str]:
    return {w.strip(".,!?").lower() for w in text.split()}


def test_transcribes_on_the_thread_that_loaded_the_model(speech):
    """The app's shape: one worker thread loads the model and transcribes
    forever after. mlx 0.32 broke exactly this while silence kept returning
    empty — so assert on words, not on "no exception"."""
    result: dict = {}

    def worker():
        try:
            engine = TranscriptionEngine()
            engine.warmup()
            result["text"] = engine.transcribe(speech)
        except Exception as exc:  # surfaced below, not lost with the thread
            result["error"] = exc

    t = threading.Thread(target=worker)
    t.start()
    t.join(timeout=600)

    assert not t.is_alive(), "transcription hung"
    assert "error" not in result, result.get("error")
    assert {"hello", "world", "test"} <= _words(result["text"]), result["text"]


def test_memory_stays_flat_across_dictations(speech):
    """Each take has a new length, so MLX's buffer cache never reused its
    buffers and kept every one: ~0.5 GB per dictation, ~5 GB after ten."""
    import mlx.core as mx

    engine = TranscriptionEngine()
    engine.warmup()
    baseline = mx.get_active_memory()

    rng = np.random.default_rng(0)
    for seconds in (3, 17, 8, 29, 12, 24, 5, 21, 14, 27):
        take = np.resize(speech, seconds * SAMPLE_RATE)
        take = take + rng.normal(0, 0.002, take.shape).astype(np.float32)
        engine.transcribe(take)

    mb = 1024**2
    cached = mx.get_cache_memory() / mb
    grown = (mx.get_active_memory() - baseline) / mb
    assert cached < 64, f"MLX buffer cache holds {cached:.0f} MB after 10 takes"
    assert grown < 64, f"active memory grew {grown:.0f} MB over 10 takes"

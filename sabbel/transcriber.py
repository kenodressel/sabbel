"""Speech-to-text via NVIDIA Parakeet TDT (parakeet-mlx).

Parakeet is a TDT/CTC model rather than an autoregressive one, so it returns
nothing on silence instead of inventing subtitle boilerplate the way Whisper
does. Language is auto-detected across 25 languages; there is no forced-language
or prompt-biasing knob, and Sabbel does not pretend otherwise.
"""

import logging
from typing import NamedTuple

import numpy as np


DEFAULT_MODEL_REPO = "mlx-community/parakeet-tdt-0.6b-v3"

SAMPLE_RATE = 16_000


class ModelFallback(NamedTuple):
    """A configured model repo that could not be used, and why."""

    repo: str
    reason: str


def _load_parakeet():
    """Import parakeet-mlx lazily and return the pieces we need.

    We deliberately avoid ``BaseParakeet.transcribe()``: it decodes via an
    ``ffmpeg`` subprocess, which Sabbel neither ships nor requires. Sabbel
    already holds 16 kHz float32 mono, so we go straight to the mel front-end.
    """
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel

    return mx, from_pretrained, get_logmel


class TranscriptionEngine:
    def __init__(
        self,
        model_repo: str = DEFAULT_MODEL_REPO,
        min_samples: int = 8000,
    ):
        self._model_repo = model_repo
        self._min_samples = min_samples
        self._loaded = None
        self.fallback: ModelFallback | None = None

    def _load(self):
        if self._loaded is None:
            mx, from_pretrained, get_logmel = _load_parakeet()
            try:
                model = self._load_model(from_pretrained, self._model_repo)
            except Exception as exc:
                # A repo pinned in config.toml outlives the build that could
                # load it — the pre-0.4.0 Whisper repo is the case that
                # shipped. Refusing forever is worse than dictating with the
                # default model, so fall back and let the app say so.
                if self._model_repo == DEFAULT_MODEL_REPO:
                    raise
                logging.warning(
                    "Model %r could not be loaded; falling back to %s",
                    self._model_repo,
                    DEFAULT_MODEL_REPO,
                    exc_info=True,
                )
                self.fallback = ModelFallback(self._model_repo, str(exc))
                model = self._load_model(from_pretrained, DEFAULT_MODEL_REPO)
            self._loaded = (mx, get_logmel, model)
        return self._loaded

    def _load_model(self, from_pretrained, repo: str):
        model = from_pretrained(repo)
        rate = model.preprocessor_config.sample_rate
        if rate != SAMPLE_RATE:
            raise RuntimeError(
                f"{repo} expects {rate} Hz audio, but Sabbel "
                f"records at {SAMPLE_RATE} Hz. Pick a 16 kHz Parakeet model."
            )
        return model

    def transcribe(self, audio: np.ndarray) -> str:
        if len(audio) < self._min_samples:
            return ""

        mx, get_logmel, model = self._load()
        # float32, not bfloat16: get_logmel reinterprets the STFT output via
        # mx.view(x, original_dtype), and only a 4-byte dtype halves back to
        # n_fft//2+1 bins. bfloat16 audio produces a filterbank shape mismatch.
        samples = mx.array(np.ascontiguousarray(audio, dtype=np.float32))
        mel = get_logmel(samples, model.preprocessor_config)
        return model.generate(mel)[0].text.strip()

    def warmup(self):
        silence = np.zeros(SAMPLE_RATE, dtype=np.float32)
        self.transcribe(silence)

import numpy as np


def _load_mlx_whisper():
    import mlx_whisper

    return mlx_whisper


class TranscriptionEngine:
    def __init__(
        self,
        model_repo: str = "mlx-community/whisper-large-v3-turbo",
        min_samples: int = 8000,
    ):
        self._model_repo = model_repo
        self._min_samples = min_samples
        self._mlx_whisper = None

    def _whisper(self):
        if self._mlx_whisper is None:
            self._mlx_whisper = _load_mlx_whisper()
        return self._mlx_whisper

    def transcribe(self, audio: np.ndarray, language: str | None = "de", initial_prompt: str | None = None) -> str:
        if len(audio) < self._min_samples:
            return ""

        kwargs = {"path_or_hf_repo": self._model_repo}
        if language is not None:
            kwargs["language"] = language
        if initial_prompt:
            kwargs["initial_prompt"] = initial_prompt

        result = self._whisper().transcribe(audio, **kwargs)
        text = result["text"].strip()
        return text if text else ""

    def warmup(self):
        silence = np.zeros(16000, dtype=np.float32)
        self.transcribe(silence)

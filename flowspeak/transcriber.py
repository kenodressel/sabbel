import numpy as np
import mlx_whisper


class TranscriptionEngine:
    def __init__(
        self,
        model_repo: str = "mlx-community/whisper-large-v3-turbo",
        min_samples: int = 8000,
    ):
        self._model_repo = model_repo
        self._min_samples = min_samples

    def transcribe(self, audio: np.ndarray, language: str = "de") -> str:
        if len(audio) < self._min_samples:
            return ""

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._model_repo,
            language=language,
        )
        text = result["text"].strip()
        return text if text else ""

    def warmup(self):
        silence = np.zeros(16000, dtype=np.float32)
        self.transcribe(silence)

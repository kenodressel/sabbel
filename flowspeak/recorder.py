import queue
import numpy as np
import sounddevice as sd


SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "float32"
BLOCK_SIZE = 1600  # 100ms chunks


class AudioRecorder:
    def __init__(self, min_duration_seconds: float = 0.5):
        self._queue: queue.Queue[np.ndarray] = queue.Queue()
        self._min_samples = int(min_duration_seconds * SAMPLE_RATE)
        self._stream: sd.InputStream | None = None

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if status:
            print(f"sounddevice status: {status}")
        self._queue.put(indata.copy())

    def start(self):
        while not self._queue.empty():
            self._queue.get()
        if self._stream is None:
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=BLOCK_SIZE,
                callback=self._audio_callback,
            )
        self._stream.start()

    def stop(self):
        if self._stream is not None and self._stream.active:
            self._stream.stop()

    def get_audio(self) -> np.ndarray:
        chunks = []
        while not self._queue.empty():
            chunks.append(self._queue.get())
        if not chunks:
            return np.array([], dtype=np.float32)
        return np.concatenate(chunks, axis=0).flatten()

    def is_valid_duration(self, audio: np.ndarray) -> bool:
        return len(audio) >= self._min_samples

    def has_speech(self, audio: np.ndarray, rms_threshold: float = 0.01) -> bool:
        """Check if audio contains likely speech based on RMS energy.

        Fast check (~microseconds) — just compares volume level against threshold.
        Default threshold 0.01 filters silence/quiet background noise.
        """
        if len(audio) == 0:
            return False
        rms = float(np.sqrt(np.mean(audio ** 2)))
        return rms > rms_threshold

    def close(self):
        if self._stream is not None:
            if self._stream.active:
                self._stream.stop()
            self._stream.close()
            self._stream = None

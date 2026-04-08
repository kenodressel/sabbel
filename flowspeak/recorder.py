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
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCK_SIZE,
            callback=self._audio_callback,
        )

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if status:
            print(f"sounddevice status: {status}")
        self._queue.put(indata.copy())

    def start(self):
        while not self._queue.empty():
            self._queue.get()
        self._stream.start()

    def stop(self):
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

    def close(self):
        self._stream.close()

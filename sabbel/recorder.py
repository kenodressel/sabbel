import logging
import queue
import numpy as np
import sounddevice as sd


SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "float32"
BLOCK_SIZE = 1600  # 100ms chunks


def list_input_devices() -> list[dict]:
    """Return input-capable devices as `[{"name": str, "index": int}, ...]`.

    Filters `sd.query_devices()` to entries with `max_input_channels > 0`.
    Returns `[]` if PortAudio enumeration fails — Sabbel should still work
    via the system default in that case.
    """
    try:
        devices = sd.query_devices()
    except Exception:
        logging.debug("query_devices failed", exc_info=True)
        return []
    result = []
    for i, d in enumerate(devices):
        if d.get("max_input_channels", 0) > 0:
            result.append({"name": d["name"], "index": d.get("index", i)})
    return result


class AudioRecorder:
    def __init__(self, min_duration_seconds: float = 0.5, device: str | None = None):
        self._queue: queue.Queue[np.ndarray] = queue.Queue()
        self._min_samples = int(min_duration_seconds * SAMPLE_RATE)
        self._stream: sd.InputStream | None = None
        self._stream_device_index: int | None = None
        self._device: str | None = device
        self.last_missing_device: str | None = None

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if status:
            print(f"sounddevice status: {status}")
        self._queue.put(indata.copy())

    def _open_stream(self, device_index: int | None) -> None:
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCK_SIZE,
            device=device_index,
            callback=self._audio_callback,
        )
        self._stream_device_index = device_index

    def _resolve_device(self) -> tuple[int | None, str | None]:
        """Resolve `self._device` to a PortAudio index.

        Returns `(index_or_None, missing_name_or_None)`.
        - If `self._device is None` → `(None, None)` (system default).
        - If exact name match found → `(index, None)`.
        - If not found → `(None, self._device)` (missing, caller should notify).
        """
        if self._device is None:
            return (None, None)
        try:
            devices = sd.query_devices()
        except Exception:
            logging.debug("query_devices failed during resolve", exc_info=True)
            return (None, self._device)
        for i, d in enumerate(devices):
            if d.get("max_input_channels", 0) > 0 and d.get("name") == self._device:
                return (d.get("index", i), None)
        return (None, self._device)

    def set_device(self, name: str | None) -> None:
        """Change the input device.

        PortAudio binds a device at stream-open time, so the cached stream
        (if any) must be closed and re-opened on the next `start()` call
        to pick up the new selection.
        """
        self._device = name
        if self._stream is not None:
            if self._stream.active:
                self._stream.stop()
            self._stream.close()
            self._stream = None
            self._stream_device_index = None

    def start(self):
        while not self._queue.empty():
            self._queue.get()

        device_index, missing = self._resolve_device()
        self.last_missing_device = missing

        # If the cached stream is bound to a different device than what we
        # just resolved (device was un/replugged, or index changed via hotplug),
        # close it so we re-open against the right device.
        if self._stream is not None and self._stream_device_index != device_index:
            self._stream.close()
            self._stream = None
            self._stream_device_index = None

        try:
            if self._stream is None:
                self._open_stream(device_index)
            self._stream.start()
        except sd.PortAudioError:
            # The device disappeared between our resolve and the actual start
            # (race) — drop the stream, surface the missing-device name, and
            # retry against the system default. Re-raises if the default also
            # fails, so the app's existing PortAudioError handler still kicks in.
            if self._stream is not None:
                self._stream.close()
            self._stream = None
            self._stream_device_index = None

            if self._device is None or device_index is None:
                raise

            logging.exception("Configured stream failed; falling back to default")
            self.last_missing_device = self._device
            self._open_stream(None)
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

    def has_speech(self, audio: np.ndarray, rms_threshold: float = 0.003) -> bool:
        """Check if audio contains likely speech based on RMS energy.

        Fast check (~microseconds) — just compares volume level against threshold.
        Default threshold 0.003 keeps quiet speech while still filtering silence.
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

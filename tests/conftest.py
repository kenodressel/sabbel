"""Shared pytest fixtures.

Disables the PortAudio terminate/initialize cycle in tests so the recorder
suite doesn't actually re-enumerate audio devices on each call (slow, and
would require a working PortAudio install in CI).
"""
import pytest


@pytest.fixture(autouse=True)
def _no_real_portaudio_cycle(monkeypatch):
    try:
        monkeypatch.setattr("sabbel.recorder.sd._terminate", lambda: None)
        monkeypatch.setattr("sabbel.recorder.sd._initialize", lambda: None)
    except AttributeError:
        # sd was not imported by the test under question.
        pass

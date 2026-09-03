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


@pytest.fixture(autouse=True)
def _isolate_home(tmp_path, monkeypatch):
    """No test may touch the developer's real home directory.

    Sabbel writes config.toml, preferences.json and history.log under ~, and
    migrate_config() rewrites config.toml in place. A test that mocks the
    transcriber reaches that code path, so without this a test run would edit
    the config of whoever ran it.
    """
    from pathlib import Path

    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr(Path, "home", lambda: home)

"""End-to-end check on this Mac: the real app, the real model, a real paste.

The unit tests mock MLX and PyObjC, and `make test-model` covers the model on
its own. This drives the whole take path the way the menu bar app runs it:
the rumps run loop, the transcription worker, the paste into a real text
field, the history write and the hand-back to the main thread, with speech
from `say`. Only the key press and the microphone are left out, because Sabbel
ignores synthetic keystrokes on purpose.

Run it with `make test-e2e` from a logged-in desktop session; the terminal
needs Accessibility (System Settings → Privacy & Security). It opens a scratch
file in TextEdit and closes only that file. Your clipboard and ~/.config/sabbel
are left as they were.
"""

import os
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

# Before anything imports sabbel: its preference and history paths are read
# from HOME at import time. The model cache has to stay the real one, or every
# run would download 2.3 GB into the scratch home.
import huggingface_hub.constants as _hf

os.environ["HF_HUB_CACHE"] = _hf.HF_HUB_CACHE
SCRATCH = Path(tempfile.mkdtemp(prefix="sabbel-e2e-")).resolve()
os.environ["HOME"] = str(SCRATCH / "home")
(SCRATCH / "home").mkdir()

import numpy as np  # noqa: E402
import rumps  # noqa: E402

import sabbel.app as sabbel_app  # noqa: E402
from sabbel import injector  # noqa: E402
from sabbel.config import SabbelConfig  # noqa: E402
from sabbel.permissions import check_accessibility  # noqa: E402

PHRASE = "Hello world, this is a dictation test."
EXPECTED_WORDS = {"hello", "world", "test"}
RUNS = int(os.environ.get("RUNS", "3"))
MODEL_TIMEOUT = 600  # a first run downloads the model
TAKE_TIMEOUT = 30
# One take stalls the worker for seconds; the main thread must not notice.
MAX_MAIN_THREAD_GAP_MS = 250
# Takes interrupted by another app taking focus are retried, up to this many.
MAX_INTERRUPTIONS = 3
SENTINEL = "sabbel-e2e clipboard sentinel"
DOC = SCRATCH / "e2e-target.txt"


def osa(script: str) -> str:
    return subprocess.run(
        ["osascript", "-e", script], capture_output=True, text=True
    ).stdout.strip()


def doc_ref() -> str:
    return f'(first document whose path is "{DOC}")'


def synthesise_speech() -> np.ndarray:
    wav = SCRATCH / "phrase.wav"
    subprocess.run(
        ["say", "-o", str(wav), "--data-format=LEI16@16000", PHRASE], check=True
    )
    with wave.open(str(wav)) as f:
        pcm = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


def app_name(pid) -> str:
    from AppKit import NSRunningApplication

    app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid or 0)
    return app.localizedName() if app is not None else f"pid {pid}"


def words(text: str) -> set[str]:
    return {w.strip(".,!?").lower() for w in text.split()}


class Checks:
    def __init__(self):
        self.failures: list[str] = []

    def check(self, ok: bool, label: str, detail: str = "") -> None:
        print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f" — {detail}" if detail else ""), flush=True)
        if not ok:
            self.failures.append(label)


def main() -> None:
    if not check_accessibility(prompt=False):
        sys.exit(
            "This terminal has no Accessibility permission, so nothing can be "
            "pasted. Grant it in System Settings → Privacy & Security."
        )

    if (injector.capture_focus_target() or {}).get("name") == "loginwindow":
        sys.exit("The screen is locked. Unlock it: nothing can be pasted to a lock screen.")

    print("Hands off the Mac for ~30s: the takes paste into TextEdit, and typing,\n"
          "copying or switching apps meanwhile would land in the test.", flush=True)
    speech = synthesise_speech()
    DOC.write_text("", encoding="utf-8")

    # Record instead of posting: outside an .app bundle macOS has no
    # notification center, and a notice is itself a result worth checking.
    notices: list[dict] = []
    rumps.notification = lambda **kw: notices.append(kw)

    outcomes: list[dict] = []
    real_inject = sabbel_app.inject_text

    def recording_inject(*args, **kwargs):
        focused = injector._focused_element()
        role = injector._ax_value(focused, "AXRole")[1] if focused is not None else None
        outcome = real_inject(*args, **kwargs)
        outcomes.append({
            "text": args[0] if args else kwargs.get("text"),
            "outcome": outcome,
            "thread": threading.current_thread().name,
            "frontmost_pid": injector._frontmost_pid(),
            "focused_role": role,
        })
        return outcome

    sabbel_app.inject_text = recording_inject

    app = sabbel_app.SabbelApp(SabbelConfig(history_enabled=True))
    history = Path(os.environ["HOME"]) / ".config" / "sabbel" / "history.log"

    ticks: list[float] = []
    statuses: list[tuple[str, bool]] = []

    def tick(_timer):
        ticks.append(time.monotonic())
        entry = (app._status_item.title, app._model_ready)
        if not statuses or statuses[-1] != entry:
            statuses.append(entry)

    rumps.Timer(tick, 0.05).start()

    pb = injector._general_pasteboard()
    saved_clipboard = injector._capture_pasteboard(pb)
    checks = Checks()

    def drive():
        opened = False
        try:
            deadline = time.monotonic() + MODEL_TIMEOUT
            while not (app._model_ready or app._model_failed):
                if time.monotonic() > deadline:
                    checks.check(False, "model loaded", f"not ready after {MODEL_TIMEOUT}s")
                    return
                time.sleep(0.1)
            if app._model_failed:
                checks.check(False, "model loaded", app._model_error)
                return
            time.sleep(1.0)  # let the permission monitor and _set_idle land

            print("status", flush=True)
            early_ready = [s for s, ready in statuses if s == "Status: Ready" and not ready]
            checks.check(not early_ready, "no \"Ready\" before the model loaded",
                         " → ".join(s for s, _ in statuses))
            checks.check(app._status_item.title == "Status: Ready", "\"Ready\" once loaded",
                         app._status_item.title)

            subprocess.run(["open", "-a", "TextEdit", str(DOC)], check=True)
            opened = True

            passed = interruptions = 0
            while passed < RUNS:
                print(f"take {passed + 1}/{RUNS}", flush=True)
                osa(f'tell application "TextEdit" to set text of {doc_ref()} to ""')
                target = None
                for _ in range(100):
                    osa('tell application "TextEdit" to activate')
                    target = injector.capture_focus_target()
                    front = osa('tell application "TextEdit" to get name of front window')
                    if (target or {}).get("name") == "TextEdit" and front == DOC.name:
                        break
                    time.sleep(0.1)
                else:
                    # Every later take would fail the same way, slowly.
                    checks.check(False, "TextEdit in front with the scratch file", str(target))
                    break
                time.sleep(0.5)

                injector._write_transient(pb, SENTINEL)
                notices.clear()
                seen = len(outcomes)
                start = time.monotonic()
                app._takes.put((speech, target))

                while len(outcomes) == seen or app.title != "🎙":
                    if time.monotonic() - start > TAKE_TIMEOUT:
                        break
                    time.sleep(0.05)
                done = time.monotonic()
                time.sleep(0.3)  # the paste lands a moment after it is posted

                result = outcomes[-1] if len(outcomes) > seen else None
                if result is None:
                    checks.check(False, "take finished", f"no paste within {TAKE_TIMEOUT}s")
                    break
                spoken = result["text"] or ""
                clipboard = pb.stringForType_(injector.NSPasteboardTypeString)
                logged = history.read_text(encoding="utf-8") if history.exists() else ""
                window = [t for t in ticks if start <= t <= done]
                gap = 1000 * max(np.diff(window)) if len(window) > 1 else float("inf")

                checks.check(EXPECTED_WORDS <= words(spoken), "transcribed the speech", repr(spoken))
                checks.check(bool(spoken) and spoken in logged, "saved to history")
                checks.check(result["thread"] != "MainThread", "pasted off the main thread",
                             result["thread"])
                checks.check(gap < MAX_MAIN_THREAD_GAP_MS, "main thread stayed responsive",
                             f"longest pause {gap:.0f} ms")
                checks.check(app.title == "🎙", "back to idle", app.title)

                if (result["outcome"] == injector.FOCUS_CHANGED
                        and result["frontmost_pid"] != target["pid"]
                        and interruptions < MAX_INTERRUPTIONS):
                    # Not Sabbel's doing: something else took the front while
                    # the take ran (you, or an app grabbing focus). Sabbel must
                    # then hold the text back — check that, and go again.
                    interruptions += 1
                    print(f"  ----  {app_name(result['frontmost_pid'])} came to the front "
                          f"mid-take; checking the fallback, then retrying", flush=True)
                    checks.check(clipboard == spoken, "fallback: text left in the clipboard",
                                 repr(clipboard))
                    subtitles = [n.get("subtitle") for n in notices]
                    checks.check(subtitles == ["Text copied to clipboard"],
                                 "fallback: told the user where the text went", str(subtitles))
                    continue

                text = osa(f'tell application "TextEdit" to get text of {doc_ref()}')
                checks.check(result["outcome"] == injector.PASTED, "pasted", str(result))
                checks.check(text == spoken, "text landed in the document", repr(text))
                checks.check(clipboard == SENTINEL, "clipboard restored", repr(clipboard))
                checks.check(not notices, "no notification", str(notices))
                passed += 1
        except Exception as exc:
            checks.check(False, "driver crashed", repr(exc))
        finally:
            if opened:
                osa(f'tell application "TextEdit" to close {doc_ref()} saving no')
            # Only put the old clipboard back over our own writes. Anything
            # else is a copy made during the run, and clobbering it loses it.
            ours = {None, SENTINEL} | {o["text"] for o in outcomes}
            if pb.stringForType_(injector.NSPasteboardTypeString) in ours:
                injector._restore_pasteboard(pb, saved_clipboard)
            else:
                print("Clipboard changed during the run — left as it is.", flush=True)
            failed = len(checks.failures)
            print(f"\n{'FAILED' if failed else 'PASSED'}: "
                  f"{failed} failed check(s)" + (f" — {checks.failures}" if failed else ""),
                  flush=True)
            os._exit(1 if failed else 0)

    threading.Thread(target=drive, name="e2e-driver", daemon=True).start()
    app.run()


if __name__ == "__main__":
    main()

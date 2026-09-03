"""Tests for text injection.

The AppKit/Quartz/HIServices calls are patched out — these cover the decision
logic and the pasteboard save/restore contract, which is where the bugs were.
"""
import time
from unittest.mock import MagicMock, patch

import pytest

from sabbel import injector


@pytest.fixture
def pb():
    """A fake NSPasteboard whose changeCount advances on clearContents()."""
    board = MagicMock()
    board._count = 1

    def clear():
        board._count += 1
        return board._count

    board.clearContents.side_effect = clear
    board.changeCount.side_effect = lambda: board._count
    board.pasteboardItems.return_value = []
    board.stringForType_.return_value = None
    return board


# --- focus target -----------------------------------------------------------


def test_focus_target_active_when_pid_matches():
    with patch.object(injector, "_frontmost_pid", return_value=42):
        assert injector.focus_target_is_active({"pid": 42, "name": "Notes"})


def test_focus_target_inactive_when_pid_differs():
    with patch.object(injector, "_frontmost_pid", return_value=99):
        assert not injector.focus_target_is_active({"pid": 42, "name": "Notes"})


def test_focus_target_optimistic_without_target():
    """No captured target must not block pasting."""
    with patch.object(injector, "_frontmost_pid", return_value=99):
        assert injector.focus_target_is_active(None)


def test_focus_target_optimistic_when_pid_unreadable():
    with patch.object(injector, "_frontmost_pid", return_value=None):
        assert injector.focus_target_is_active({"pid": 42, "name": "Notes"})


def test_inject_skips_when_focus_changed(pb):
    with patch.object(injector, "_general_pasteboard", return_value=pb), \
         patch.object(injector, "focus_target_is_active", return_value=False), \
         patch.object(injector, "_write_transient") as write:
        result = injector.inject_text("hallo", target={"pid": 1, "name": "Notes"})

    assert result == injector.FOCUS_CHANGED  # text left in clipboard
    write.assert_called_once()


# --- secure fields ----------------------------------------------------------


def test_inject_refuses_secure_field(pb):
    with patch.object(injector, "_general_pasteboard", return_value=pb), \
         patch.object(injector, "focus_target_is_active", return_value=True), \
         patch.object(injector, "_focused_element", return_value=object()), \
         patch.object(injector, "is_secure_field", return_value=True), \
         patch.object(injector, "_write_transient") as write:
        result = injector.inject_text("hunter2")

    assert result == injector.REFUSED_SECURE
    # Crucially, nothing is written to the clipboard either.
    write.assert_not_called()


@pytest.mark.parametrize(
    "subrole,expected",
    [("AXSecureTextField", True), ("AXTextField", False), (None, False)],
)
def test_is_secure_field_reads_subrole(subrole, expected):
    with patch.object(injector, "_ax_value", return_value=(0, subrole)):
        assert injector.is_secure_field(object()) is expected


# --- modifier release -------------------------------------------------------


def test_wait_for_modifiers_returns_immediately_when_clear():
    with patch.object(injector, "_modifier_flags", return_value=0):
        started = time.monotonic()
        assert injector.wait_for_modifiers_released(timeout=1.0)
        assert time.monotonic() - started < 0.1


def test_wait_for_modifiers_times_out_when_held():
    """Right Option still down must not turn Cmd+V into Cmd+Opt+V."""
    with patch.object(injector, "_modifier_flags", return_value=injector._MODIFIER_MASK):
        assert not injector.wait_for_modifiers_released(timeout=0.05, poll=0.01)


def test_wait_for_modifiers_clears_mid_wait():
    values = iter([injector._MODIFIER_MASK, 0, 0])
    with patch.object(injector, "_modifier_flags", side_effect=lambda: next(values)):
        assert injector.wait_for_modifiers_released(timeout=1.0, poll=0.001)


# --- pasteboard snapshot ----------------------------------------------------


def test_capture_pasteboard_keeps_every_type(pb):
    item = MagicMock()
    item.types.return_value = ["public.png", "public.utf8-plain-text"]
    item.dataForType_.side_effect = lambda t: f"data:{t}".encode()
    pb.pasteboardItems.return_value = [item]

    snapshot = injector._capture_pasteboard(pb)

    assert snapshot == [
        {
            "public.png": b"data:public.png",
            "public.utf8-plain-text": b"data:public.utf8-plain-text",
        }
    ]


def test_capture_pasteboard_handles_empty(pb):
    pb.pasteboardItems.return_value = None
    assert injector._capture_pasteboard(pb) == []


def test_restore_pasteboard_rewrites_all_items(pb):
    created = []

    def make_item():
        item = MagicMock()
        item._data = {}
        item.setData_forType_.side_effect = lambda d, t: item._data.__setitem__(t, d)
        created.append(item)
        return item

    snapshot = [{"public.png": b"img"}, {"public.utf8-plain-text": b"txt"}]
    with patch.object(injector, "_new_pasteboard_item", side_effect=make_item):
        injector._restore_pasteboard(pb, snapshot)

    pb.clearContents.assert_called_once()
    assert created[0]._data == {"public.png": b"img"}
    assert created[1]._data == {"public.utf8-plain-text": b"txt"}
    pb.writeObjects_.assert_called_once()


def test_restore_pasteboard_empty_snapshot_just_clears(pb):
    injector._restore_pasteboard(pb, [])
    pb.clearContents.assert_called_once()
    pb.writeObjects_.assert_not_called()


# --- end-to-end paste path --------------------------------------------------


def _patch_paste_env(pb, landed=True, can_paste=True):
    """Patch everything inject_text touches except the logic under test."""
    return [
        patch.object(injector, "_general_pasteboard", return_value=pb),
        patch.object(injector, "focus_target_is_active", return_value=True),
        patch.object(injector, "_focused_element", return_value=object()),
        patch.object(injector, "is_secure_field", return_value=False),
        patch.object(injector, "_can_accept_paste", return_value=can_paste),
        patch.object(injector, "wait_for_modifiers_released", return_value=True),
        patch.object(injector, "_focused_value", return_value=""),
        patch.object(injector, "_paste_landed", return_value=landed),
        patch.object(injector, "_write_transient", side_effect=lambda p, t: p.clearContents()),
        patch.object(injector, "_post_paste_keystroke"),
    ]


def test_inject_restores_snapshot_after_paste(pb):
    patches = _patch_paste_env(pb)
    for p in patches:
        p.start()
    try:
        with patch.object(injector, "_capture_pasteboard", return_value=[{"t": b"old"}]), \
             patch.object(injector, "_restore_pasteboard") as restore:
            result = injector.inject_text("hallo", pre_paste_delay=0, post_paste_delay=0)
    finally:
        for p in patches:
            p.stop()

    assert result == injector.PASTED
    restore.assert_called_once()
    assert restore.call_args[0][1] == [{"t": b"old"}]


def test_inject_posts_to_captured_pid(pb):
    """Cmd+V goes to the app that was focused when recording started."""
    patches = _patch_paste_env(pb)
    for p in patches:
        p.start()
    try:
        with patch.object(injector, "_capture_pasteboard", return_value=[]), \
             patch.object(injector, "_restore_pasteboard"):
            injector.inject_text(
                "hallo",
                pre_paste_delay=0,
                post_paste_delay=0,
                target={"pid": 4242, "name": "Notes"},
            )
        injector._post_paste_keystroke.assert_called_once_with(4242)
    finally:
        for p in patches:
            p.stop()


def test_inject_leaves_text_when_no_text_field(pb):
    patches = _patch_paste_env(pb, can_paste=False)
    for p in patches:
        p.start()
    try:
        with patch.object(injector, "_capture_pasteboard", return_value=[]), \
             patch.object(injector, "_restore_pasteboard") as restore:
            result = injector.inject_text("hallo", pre_paste_delay=0, post_paste_delay=0)
    finally:
        for p in patches:
            p.stop()

    assert result == injector.LEFT_IN_CLIPBOARD
    restore.assert_not_called()


def test_inject_skips_restore_when_user_copied_during_paste(pb):
    patches = _patch_paste_env(pb)
    for p in patches:
        p.start()
    try:
        # Someone else bumps the clipboard after we wrote ours.
        with patch.object(injector, "_capture_pasteboard", return_value=[]), \
             patch.object(injector, "_restore_pasteboard") as restore:
            pb.stringForType_.return_value = "something the user copied"
            original_landed = injector._paste_landed

            def bump(*args, **kwargs):
                pb._count += 5
                return True

            with patch.object(injector, "_paste_landed", side_effect=bump):
                result = injector.inject_text(
                    "hallo", pre_paste_delay=0, post_paste_delay=0
                )
            del original_landed
    finally:
        for p in patches:
            p.stop()

    assert result == injector.PASTED
    restore.assert_not_called()


def test_unreadable_field_uses_fixed_delay_not_verify_timeout(pb):
    """Electron/terminals expose no AXValue — polling them would stall every paste.

    Regression guard: an earlier version polled for the full verify_timeout on
    every dictation into Slack or VS Code, turning a 150ms paste into 2s.
    """
    patches = _patch_paste_env(pb)
    for p in patches:
        p.start()
    try:
        with patch.object(injector, "_capture_pasteboard", return_value=[]), \
             patch.object(injector, "_restore_pasteboard"), \
             patch.object(injector, "_focused_value", return_value=None), \
             patch.object(injector, "_paste_landed", return_value=False) as landed:
            started = time.monotonic()
            injector.inject_text(
                "hallo",
                pre_paste_delay=0,
                post_paste_delay=0.01,
                verify_timeout=5.0,
            )
            elapsed = time.monotonic() - started
    finally:
        for p in patches:
            p.stop()

    assert elapsed < 1.0, f"unreadable field stalled for {elapsed:.2f}s"
    landed.assert_not_called()


def test_readable_field_polls_until_paste_lands(pb):
    """A readable field must be waited on rather than restored after 150ms."""
    patches = _patch_paste_env(pb)
    for p in patches:
        p.start()
    try:
        answers = iter([False, False, True])
        with patch.object(injector, "_capture_pasteboard", return_value=[]), \
             patch.object(injector, "_restore_pasteboard") as restore, \
             patch.object(injector, "_focused_value", return_value="vorher"), \
             patch.object(injector, "_paste_landed", side_effect=lambda *a: next(answers)):
            result = injector.inject_text(
                "hallo", pre_paste_delay=0, post_paste_delay=0, verify_timeout=5.0
            )
    finally:
        for p in patches:
            p.stop()

    assert result == injector.PASTED
    restore.assert_called_once()

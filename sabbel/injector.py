import logging
import time
from AppKit import NSPasteboard, NSPasteboardTypeString, NSWorkspace
import HIServices
import Quartz


_TEXT_ROLES = {"AXTextField", "AXTextArea", "AXWebArea", "AXComboBox", "AXSearchField"}


def _has_focused_text_input() -> bool:
    """Check if the frontmost app has a focused text input element."""
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if app is None:
            return False
        pid = app.processIdentifier()
        app_elem = HIServices.AXUIElementCreateApplication(pid)
        err, focused = HIServices.AXUIElementCopyAttributeValue(app_elem, "AXFocusedUIElement", None)
        if err != 0 or focused is None:
            return False
        err, role = HIServices.AXUIElementCopyAttributeValue(focused, "AXRole", None)
        if err != 0 or role is None:
            return False
        return role in _TEXT_ROLES
    except Exception:
        logging.debug("Could not check focused element", exc_info=True)
        return False


def inject_text(text: str, pre_paste_delay: float = 0.05, post_paste_delay: float = 0.15) -> bool:
    """Paste text into the focused app by writing to clipboard and simulating Cmd+V.

    If a text input is focused, pastes the text and restores the previous
    clipboard contents. If no text input is detected, leaves the transcribed
    text in the clipboard so the user can paste it manually.

    Returns True if text was pasted, False if left in clipboard.
    """
    pb = NSPasteboard.generalPasteboard()
    can_paste = _has_focused_text_input()

    # Save current clipboard (only needed if we'll restore it)
    old_contents = pb.stringForType_(NSPasteboardTypeString) if can_paste else None

    # Set transcribed text on clipboard
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)

    if not can_paste:
        logging.info("No text input focused — text left in clipboard")
        return False

    # Wait for pasteboard sync
    time.sleep(pre_paste_delay)

    # Simulate Cmd+V via CGEvent
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    v_down = Quartz.CGEventCreateKeyboardEvent(src, 9, True)   # keycode 9 = 'v'
    v_up = Quartz.CGEventCreateKeyboardEvent(src, 9, False)
    Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_down)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_up)

    # Restore clipboard after paste is consumed by target app
    time.sleep(post_paste_delay)
    pb.clearContents()
    if old_contents is not None:
        pb.setString_forType_(old_contents, NSPasteboardTypeString)
    return True

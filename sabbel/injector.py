import logging
import time
from AppKit import NSPasteboard, NSPasteboardTypeString, NSWorkspace
import HIServices
import Quartz


# Roles where we KNOW paste won't work (no text input)
_NON_TEXT_ROLES = {"AXWebArea", "AXImage", "AXGroup", "AXToolbar", "AXMenuBar",
                   "AXScrollArea", "AXSplitGroup", "AXTable", "AXOutline"}

# Mark clipboard entries as transient so clipboard managers (Maccy, Paste,
# etc.) ignore them.  See http://nspasteboard.org/
_TRANSIENT_TYPE = "org.nspasteboard.TransientType"


def _can_accept_paste() -> bool:
    """Check if the focused element likely accepts text input.

    Returns True (optimistic) when:
    - AX query fails entirely (Electron apps, etc.) — assume paste works
    - Focused element has AXSelectedTextRange (has a cursor)
    - AXValue or AXSelectedText is settable
    - Role is not in the known non-text-input list

    Returns False only when we're confident there's no text input.
    """
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if app is None:
            return True  # optimistic

        pid = app.processIdentifier()
        app_elem = HIServices.AXUIElementCreateApplication(pid)

        err, focused = HIServices.AXUIElementCopyAttributeValue(
            app_elem, "AXFocusedUIElement", None
        )
        if err != 0 or focused is None:
            # Can't read focused element (Electron apps, etc.)
            # Be optimistic — Cmd+V usually works in these apps
            return True

        # Check 1: does it have a text selection range? (most reliable positive signal)
        err2, _ = HIServices.AXUIElementCopyAttributeValue(
            focused, "AXSelectedTextRange", None
        )
        if err2 == 0:
            return True

        # Check 2: is AXValue or AXSelectedText settable?
        err3, settable = HIServices.AXUIElementIsAttributeSettable(
            focused, "AXValue", None
        )
        if err3 == 0 and settable:
            return True

        err4, settable2 = HIServices.AXUIElementIsAttributeSettable(
            focused, "AXSelectedText", None
        )
        if err4 == 0 and settable2:
            return True

        # Check 3: is the role a known non-text role?
        err5, role = HIServices.AXUIElementCopyAttributeValue(focused, "AXRole", None)
        if err5 == 0 and role in _NON_TEXT_ROLES:
            logging.info("Paste detection: non-text role %s — text left in clipboard", role)
            return False

        # Unknown situation — be optimistic
        return True
    except Exception:
        logging.debug("Paste detection failed", exc_info=True)
        return True  # optimistic on error


def inject_text(text: str, pre_paste_delay: float = 0.05, post_paste_delay: float = 0.15) -> bool:
    """Paste text into the focused app by writing to clipboard and simulating Cmd+V.

    If a text input is detected (or detection is inconclusive), pastes and
    restores the previous clipboard. If we're confident there's no text input,
    pastes and leaves the transcribed text in the clipboard as fallback.

    Clipboard entries are marked as transient (org.nspasteboard.TransientType)
    so clipboard managers ignore them.

    Returns True if clipboard was restored, False if text was left in clipboard.
    """
    pb = NSPasteboard.generalPasteboard()
    paste_likely = _can_accept_paste()

    # Save current clipboard and change count
    old_contents = pb.stringForType_(NSPasteboardTypeString)
    old_change_count = pb.changeCount()

    # Set transcribed text on clipboard, marked as transient
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)
    pb.setData_forType_(b"", _TRANSIENT_TYPE)
    our_change_count = pb.changeCount()

    # Wait for pasteboard sync
    time.sleep(pre_paste_delay)

    # Always simulate Cmd+V
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    v_down = Quartz.CGEventCreateKeyboardEvent(src, 9, True)   # keycode 9 = 'v'
    v_up = Quartz.CGEventCreateKeyboardEvent(src, 9, False)
    Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_down)
    Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, v_up)

    time.sleep(post_paste_delay)

    # Check if someone else touched the clipboard during our paste
    # (e.g. the user copied something, or another app wrote to it)
    if pb.changeCount() != our_change_count:
        # Clipboard was modified by someone else — don't restore, don't overwrite
        logging.info("Clipboard changed during paste — skipping restore")
        return True

    if not paste_likely:
        # Leave text in clipboard as fallback
        return False

    # Restore old clipboard
    pb.clearContents()
    if old_contents is not None:
        pb.setString_forType_(old_contents, NSPasteboardTypeString)
    return True

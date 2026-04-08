import time
from AppKit import NSPasteboard, NSPasteboardTypeString
import Quartz


def inject_text(text: str, pre_paste_delay: float = 0.05, post_paste_delay: float = 0.15):
    """Paste text into the focused app by writing to clipboard and simulating Cmd+V.

    Preserves the user's clipboard contents by saving and restoring.
    """
    pb = NSPasteboard.generalPasteboard()

    # Save current clipboard
    old_contents = pb.stringForType_(NSPasteboardTypeString)

    # Set transcribed text on clipboard
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)

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

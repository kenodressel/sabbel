import time

import AVFoundation
import HIServices


def check_accessibility(prompt: bool = False) -> bool:
    options = {HIServices.kAXTrustedCheckOptionPrompt: prompt}
    return bool(HIServices.AXIsProcessTrustedWithOptions(options))


def check_microphone(request_if_needed: bool = True) -> bool:
    status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
        AVFoundation.AVMediaTypeAudio
    )
    if status == AVFoundation.AVAuthorizationStatusAuthorized:
        return True
    if status == AVFoundation.AVAuthorizationStatusNotDetermined and request_if_needed:
        granted = [None]

        def handler(granted_value):
            granted[0] = granted_value

        AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVFoundation.AVMediaTypeAudio, handler
        )
        for _ in range(300):
            if granted[0] is not None:
                return bool(granted[0])
            time.sleep(0.1)
    return False

from sabbel.app import _build_mic_menu_spec


def test_no_devices_only_default():
    spec = _build_mic_menu_spec(devices=[], selected=None)
    assert spec == [
        {"kind": "device", "name": None, "label": "System Default", "checked": True},
    ]


def test_devices_sorted_alphabetically_with_separator():
    devices = [
        {"name": "USB Headset", "index": 3},
        {"name": "MacBook Pro Microphone", "index": 0},
        {"name": "Dell WD22 Mic", "index": 2},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected=None)
    assert spec == [
        {"kind": "device", "name": None, "label": "System Default", "checked": True},
        {"kind": "separator"},
        {"kind": "device", "name": "Dell WD22 Mic", "label": "Dell WD22 Mic", "checked": False},
        {"kind": "device", "name": "MacBook Pro Microphone", "label": "MacBook Pro Microphone", "checked": False},
        {"kind": "device", "name": "USB Headset", "label": "USB Headset", "checked": False},
    ]


def test_selected_device_present_gets_checkmark():
    devices = [
        {"name": "Dell WD22 Mic", "index": 2},
        {"name": "MacBook Pro Microphone", "index": 0},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected="Dell WD22 Mic")
    labels_checked = [(item.get("label"), item.get("checked")) for item in spec if item["kind"] == "device"]
    assert labels_checked == [
        ("System Default", False),
        ("Dell WD22 Mic", True),
        ("MacBook Pro Microphone", False),
    ]


def test_selected_device_offline_shows_header_and_defaults_checked():
    devices = [
        {"name": "MacBook Pro Microphone", "index": 0},
    ]
    spec = _build_mic_menu_spec(devices=devices, selected="Dell WD22 Mic")
    assert spec[0] == {"kind": "offline", "label": "Saved: Dell WD22 Mic (offline)"}
    assert spec[1] == {"kind": "separator"}
    device_items = [item for item in spec if item["kind"] == "device"]
    assert device_items[0] == {
        "kind": "device", "name": None, "label": "System Default", "checked": True,
    }
    assert {"name": "MacBook Pro Microphone", "label": "MacBook Pro Microphone", "checked": False, "kind": "device"} in device_items

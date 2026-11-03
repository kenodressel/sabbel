import Testing
@testable import SabbelSystem

@Suite struct MicCaptureTests {
    let devices: [(name: String, id: UInt32)] = [("MacBook Pro Microphone", 42), ("AirPods", 77)]

    @Test func micDeviceFallback() {
        #expect(MicCapture.resolve(device: nil, among: devices) == MicResolution(choice: .systemDefault, missing: nil))
        #expect(MicCapture.resolve(device: "AirPods", among: devices) == MicResolution(choice: .device(77), missing: nil))
        #expect(MicCapture.resolve(device: "Yeti", among: devices) == MicResolution(choice: .systemDefault, missing: "Yeti"))
        // Exact, case-sensitive match, like recorder.py.
        #expect(MicCapture.resolve(device: "airpods", among: devices) == MicResolution(choice: .systemDefault, missing: "airpods"))
        #expect(MicCapture.resolve(device: "Yeti", among: []) == MicResolution(choice: .systemDefault, missing: "Yeti"))
    }

    // MARK: menu (port of tests/test_mic_selection.py)

    @Test func noDevicesOnlyDefault() {
        #expect(MicMenu.entries(devices: [], selected: nil) == [.device(name: nil, label: "System Default", checked: true)])
    }

    @Test func devicesSortedAlphabeticallyWithSeparator() {
        let entries = MicMenu.entries(devices: ["USB Headset", "MacBook Pro Microphone", "Dell WD22 Mic"], selected: nil)
        #expect(entries == [
            .device(name: nil, label: "System Default", checked: true),
            .separator,
            .device(name: "Dell WD22 Mic", label: "Dell WD22 Mic", checked: false),
            .device(name: "MacBook Pro Microphone", label: "MacBook Pro Microphone", checked: false),
            .device(name: "USB Headset", label: "USB Headset", checked: false),
        ])
    }

    @Test func selectedDevicePresentGetsCheckmark() {
        let entries = MicMenu.entries(devices: ["Dell WD22 Mic", "MacBook Pro Microphone"], selected: "Dell WD22 Mic")
        #expect(entries == [
            .device(name: nil, label: "System Default", checked: false),
            .separator,
            .device(name: "Dell WD22 Mic", label: "Dell WD22 Mic", checked: true),
            .device(name: "MacBook Pro Microphone", label: "MacBook Pro Microphone", checked: false),
        ])
    }

    @Test func selectedDeviceOfflineShowsHeaderAndDefaultChecked() {
        let entries = MicMenu.entries(devices: ["MacBook Pro Microphone"], selected: "Dell WD22 Mic")
        #expect(entries == [
            .offline("Saved: Dell WD22 Mic (offline)"),
            .separator,
            .device(name: nil, label: "System Default", checked: true),
            .separator,
            .device(name: "MacBook Pro Microphone", label: "MacBook Pro Microphone", checked: false),
        ])
    }

    @Test func caseMismatchTreatsSavedDeviceAsOffline() {
        let entries = MicMenu.entries(devices: ["Dell WD22 Mic"], selected: "dell wd22 mic")
        #expect(entries.first == .offline("Saved: dell wd22 mic (offline)"))
        #expect(entries.contains(.device(name: "Dell WD22 Mic", label: "Dell WD22 Mic", checked: false)))
    }
}

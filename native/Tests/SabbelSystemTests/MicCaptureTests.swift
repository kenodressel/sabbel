import AVFoundation
import Foundation
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

    // MARK: tap session

    /// A 440 Hz tone, so the resampler has real signal to work on.
    private func tone(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![ch][i] = 0.1 * sin(2 * .pi * 440 * Float(i) / Float(format.sampleRate))
            }
        }
        return buffer
    }

    @Test func convertsToSixteenKilohertzMono() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let collected = Collected()
        let session = try TapSession(inputFormat: input) { collected.add($0) }
        for _ in 0..<10 { session.deliver(tone(input, frames: 4_800)) }  // 1 s of audio
        // The resampler holds back its filter latency (~14 ms), never more.
        #expect(abs(collected.count - 16_000) <= 400)
        #expect(collected.peak > 0.01)
    }

    @Test func configurationChangeBeforeTheFirstBufferRestarts() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let collected = Collected()
        let session = try TapSession(inputFormat: input) { collected.add($0) }
        #expect(session.configurationChanged() == .restart)
        #expect(session.isActive)

        // The headset profile switch: the input comes back in another format.
        let switched = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        try session.adopt(inputFormat: switched)
        for _ in 0..<10 { session.deliver(tone(switched, frames: 2_400)) }  // 1 s at 24 kHz
        #expect(abs(collected.count - 16_000) <= 400)
    }

    /// A device that keeps reconfiguring before it delivers anything must not
    /// restart capture forever: three restarts per take, then the take ends.
    @Test func restartsBeforeTheFirstBufferAreCappedAtThree() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let session = try TapSession(inputFormat: input) { _ in }
        for _ in 0..<3 { #expect(session.configurationChanged() == .restart) }
        #expect(session.isActive)
        #expect(session.configurationChanged() == .gaveUp)
        #expect(!session.isActive)
    }

    @Test func configurationChangeAfterTheFirstBufferEndsTheTake() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let collected = Collected()
        let session = try TapSession(inputFormat: input) { collected.add($0) }
        session.deliver(tone(input, frames: 4_800))
        let before = collected.count
        #expect(before > 0)

        #expect(session.configurationChanged() == .endTake)
        #expect(!session.isActive)
        session.deliver(tone(input, frames: 4_800))
        #expect(collected.count == before)
    }
}

/// Thread-safe sink for `onSamples`.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func add(_ s: [Float]) { lock.withLock { samples += s } }
    var count: Int { lock.withLock { samples.count } }
    var peak: Float { lock.withLock { samples.map(abs).max() ?? 0 } }
}

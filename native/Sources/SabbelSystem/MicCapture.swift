@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import SabbelCore

/// Which input device a take records from.
public enum MicChoice: Equatable, Sendable {
    case systemDefault
    case device(AudioDeviceID)
}

/// The device a saved mic name resolves to, and the name when it is missing.
public struct MicResolution: Equatable, Sendable {
    public let choice: MicChoice
    /// The chosen mic was not found; the take falls back to the system default.
    public let missing: String?
}

/// `AudioSource` on AVAudioEngine: 16 kHz mono Float32, the device chosen by
/// name through CoreAudio (behaviour of `sabbel/recorder.py`).
///
/// A fresh engine per take. AVAudioEngine binds its input to a device when the
/// input node is first used, so a long-lived engine would keep recording from
/// whatever was the default at launch; recorder.py re-enumerates PortAudio
/// before every take for the same reason (AirPods, dock mics, USB cameras).
public final class MicCapture: AudioSource, @unchecked Sendable {
    /// The format every buffer is converted to before it reaches the coordinator.
    public static let sampleRate: Double = 16_000

    public enum MicError: Error, CustomStringConvertible {
        case noInputDevice
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .noInputDevice: "no input device"
            case .unsupportedFormat(let f): "cannot convert input format \(f)"
            }
        }
    }

    private let log: @Sendable (String) -> Void
    /// Guards `running`. Never held while calling into the engine's tap
    /// machinery from the tap thread, so stop() and the tap cannot deadlock.
    private let lock = NSLock()
    private var running: Running?

    private struct Running {
        let engine: AVAudioEngine
        let session: TapSession
        let observer: NSObjectProtocol
    }

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    deinit { stop() }

    // MARK: AudioSource

    public func start(device: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws -> String? {
        stop()
        let resolution = Self.resolve(device: device, among: Self.inputDevices())
        if let missing = resolution.missing {
            log("Mic '\(missing)' not found — using the system default")
        }
        do {
            try open(resolution.choice, onSamples: onSamples)
            return resolution.missing
        } catch where resolution.choice != .systemDefault {
            // The device can vanish between enumeration and start (recorder.py's
            // race): retry on the default and report the chosen mic as missing.
            log("Configured mic failed (\(error)); falling back to the system default")
            try open(.systemDefault, onSamples: onSamples)
            return device
        }
    }

    public func stop() {
        lock.lock()
        let current = running
        running = nil
        lock.unlock()
        guard let current else { return }
        current.session.end()
        NotificationCenter.default.removeObserver(current.observer)
        current.engine.inputNode.removeTap(onBus: 0)
        current.engine.stop()
    }

    private func open(_ choice: MicChoice, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if case .device(let id) = choice {
            try Self.setDevice(id, on: input)
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw MicError.noInputDevice }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw MicError.unsupportedFormat("\(inFormat)")
        }
        // Mix every channel into the mono stream instead of keeping only the first.
        converter.downmix = true

        let session = TapSession(converter: converter, outFormat: outFormat, onSamples: onSamples)
        // The tap only converts and hands over: no locks shared with stop(), no
        // Task per buffer. The coordinator owns the serial consumer.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            session.deliver(buffer)
        }

        // A configuration change (device unplugged, default switched, sample
        // rate changed) stops the engine underneath us. The take's sample flow
        // ends there; it never crashes or resumes on another device mid-take.
        let log = self.log
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            log("Audio engine configuration changed (device lost or switched) — capture stopped")
            session.end()
            self?.stopIfCurrent(session)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            session.end()
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw error
        }
        lock.lock()
        running = Running(engine: engine, session: session, observer: observer)
        lock.unlock()
    }

    private func stopIfCurrent(_ session: TapSession) {
        lock.lock()
        let isCurrent = running?.session === session
        lock.unlock()
        if isCurrent { stop() }
    }

    // MARK: devices

    /// Resolves a saved mic name: exact, case-sensitive match like recorder.py;
    /// a missing name falls back to the system default and is reported.
    static func resolve(device: String?, among devices: [(name: String, id: AudioDeviceID)]) -> MicResolution {
        guard let device else { return MicResolution(choice: .systemDefault, missing: nil) }
        if let match = devices.first(where: { $0.name == device }) {
            return MicResolution(choice: .device(match.id), missing: nil)
        }
        return MicResolution(choice: .systemDefault, missing: device)
    }

    /// Names of the current input devices, for the Microphone menu.
    public static func inputDeviceNames() -> [String] {
        inputDevices().map(\.name)
    }

    /// Every CoreAudio device with at least one input channel. Empty when the
    /// enumeration fails: Sabbel still works on the system default then.
    static func inputDevices() -> [(name: String, id: AudioDeviceID)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let name = deviceName(id) else { return nil }
            return (name, id)
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func setDevice(_ id: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw MicError.noInputDevice }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// One take's tap: converts each buffer to 16 kHz mono and hands it over until ended.
private final class TapSession: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let onSamples: @Sendable ([Float]) -> Void
    private let active = OSAllocatedUnfairLock(initialState: true)

    init(converter: AVAudioConverter, outFormat: AVAudioFormat, onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.converter = converter
        self.outFormat = outFormat
        self.onSamples = onSamples
    }

    func end() { active.withLock { $0 = false } }

    /// Runs on the tap's thread only, so the converter (which keeps resampler
    /// state between buffers) is never used concurrently.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        guard active.withLock({ $0 }), buffer.frameLength > 0 else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
    }
}

/// One row of the Microphone submenu.
public enum MicMenuEntry: Equatable, Sendable {
    /// `name` nil is "System Default".
    case device(name: String?, label: String, checked: Bool)
    case separator
    /// A greyed-out header naming a saved mic that is not connected.
    case offline(String)
}

/// Port of `_build_mic_menu_spec` in `sabbel/app.py`.
public enum MicMenu {
    public static func entries(devices: [String], selected: String?) -> [MicMenuEntry] {
        var entries: [MicMenuEntry] = []
        let savedOffline = selected.map { !devices.contains($0) } ?? false
        if savedOffline, let selected {
            entries.append(.offline("Saved: \(selected) (offline)"))
            entries.append(.separator)
        }
        // Default is active when chosen explicitly, or when the saved device is
        // offline (the take fell back to it at runtime).
        entries.append(.device(name: nil, label: "System Default", checked: selected == nil || savedOffline))
        if !devices.isEmpty {
            entries.append(.separator)
            for name in devices.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                entries.append(.device(name: name, label: name, checked: name == selected))
            }
        }
        return entries
    }
}

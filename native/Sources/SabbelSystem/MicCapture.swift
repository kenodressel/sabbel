@preconcurrency import AVFoundation
import CoreAudio
import Foundation
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
        /// The device this take records from, for a restart on a fresh engine.
        let choice: MicChoice

        /// Stops the engine without ending the session. Main queue only.
        func tearDown() {
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
        guard let current = lock.withLock({ () -> Running? in
            defer { running = nil }
            return running
        }) else { return }
        current.session.end()
        current.tearDown()
    }

    private func open(_ choice: MicChoice, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let take = try launch(choice) { try TapSession(inputFormat: $0, onSamples: onSamples) }
        lock.withLock { running = take }
    }

    /// A fresh engine on `choice`, tapped and started. `session` gets the input
    /// format and returns the session that receives the buffers.
    private func launch(_ choice: MicChoice, session makeSession: (AVAudioFormat) throws -> TapSession) throws -> Running {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if case .device(let id) = choice {
            try Self.setDevice(id, on: input)
        }
        let format = try Self.usableFormat(input)
        let session = try makeSession(format)
        let observer = observeConfigurationChanges(of: engine, session: session)
        do {
            try Self.tapAndStart(engine, format: format, session: session)
        } catch {
            NotificationCenter.default.removeObserver(observer)
            throw error
        }
        return Running(engine: engine, session: session, observer: observer, choice: choice)
    }

    /// Taps the input in `format` and starts the engine; the tap is removed again
    /// when this throws.
    ///
    /// Every engine call that can raise an Objective-C exception runs through
    /// `catchingObjCException`: AVAudioEngine raises (rather than returning an
    /// error) when a tap format does not match the device, and an uncaught
    /// exception aborts the app.
    private static func tapAndStart(_ engine: AVAudioEngine, format: AVAudioFormat, session: TapSession) throws {
        let input = engine.inputNode
        do {
            try catchingObjCException {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                    session.deliver(buffer)
                }
            }
            try catchingObjCException { engine.prepare() }
            var startError: Error?
            try catchingObjCException {
                do { try engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// A configuration change (device unplugged, default switched, a headset
    /// switching profile, a USB camera reconfiguring its mic) stops the engine
    /// underneath us.
    ///
    /// The handler runs on the engine's internal dispatch queue, where the
    /// engine must not be torn down or released (AVAudioEngine.h: it can
    /// deadlock). So it only decides and ends the sample flow; teardown and
    /// restart hop to the main queue, where the coordinator calls start/stop,
    /// and the engine's last reference is never dropped on that queue.
    private func observeConfigurationChanges(of engine: AVAudioEngine, session: TapSession) -> NSObjectProtocol {
        let log = self.log
        return NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            switch session.configurationChanged() {
            case .restart:
                log("Audio configuration changed before the first buffer — restarting capture")
                DispatchQueue.main.async { [weak self] in self?.restartIfCurrent(session) }
            case .endTake:
                log("Audio engine configuration changed (device lost or switched) — capture stopped")
                DispatchQueue.main.async { [weak self] in self?.stopIfCurrent(session) }
            case .gaveUp:
                log("Audio configuration changed again before the first buffer after \(TapSession.maxRestarts) restarts — capture stopped")
                DispatchQueue.main.async { [weak self] in self?.stopIfCurrent(session) }
            }
        }
    }

    private func current(_ session: TapSession) -> Running? {
        lock.withLock { running?.session === session ? running : nil }
    }

    /// Main queue only (see `observeConfigurationChanges`).
    private func stopIfCurrent(_ session: TapSession) {
        if current(session) != nil { stop() }
    }

    /// A change before any audio arrived (AirPods switching to their headset
    /// profile, a USB camera reconfiguring its mic right after start) must not
    /// cost the take: re-tap the input in its new format and start the engine
    /// again. Main queue only.
    ///
    /// The reconfigured engine can reject the new tap (seen with an Insta360
    /// Link 2C, whose engine raised in installTap). Then capture moves to a
    /// fresh engine on the same device. Only the fallback: on a mic that
    /// reconfigures whenever an engine starts on it, every fresh engine would
    /// change again before its first buffer, while the reused one settles.
    private func restartIfCurrent(_ session: TapSession) {
        guard let take = current(session) else { return }
        let input = take.engine.inputNode
        input.removeTap(onBus: 0)
        let reported = input.outputFormat(forBus: 0)
        do {
            let format = try Self.restartFormat(reported: reported, hardware: input.inputFormat(forBus: 0))
            try session.adopt(inputFormat: format)
            try Self.tapAndStart(take.engine, format: format, session: session)
            log("Capture restarted (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch; engine reported \(Int(reported.sampleRate)) Hz)")
            return
        } catch {
            log("Could not restart capture on the reconfigured engine (\(error); engine reported \(Int(reported.sampleRate)) Hz, "
                + "hardware \(Int(input.inputFormat(forBus: 0).sampleRate)) Hz) — trying a fresh one")
        }
        take.tearDown()
        do {
            let fresh = try launch(take.choice) { format in
                try session.adopt(inputFormat: format)
                return session
            }
            lock.withLock { running = fresh }
            let format = fresh.engine.inputNode.outputFormat(forBus: 0)
            log("Capture restarted on a fresh engine (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
        } catch {
            log("Could not restart capture after the configuration change (\(error)) — capture stopped")
            stop()
        }
    }

    /// The tap format after a configuration change. The engine keeps
    /// reporting the input's old sample rate (`outputFormat`) after the device
    /// switched, and AVAudioEngine rejects a tap whose rate differs from the
    /// hardware's (`format.sampleRate == inputHWFormat.sampleRate`; an Insta360
    /// Link 2C going 48 → 44.1 kHz on start). So the rate comes from the
    /// hardware format (`inputFormat`), the rest from the reported format.
    static func restartFormat(reported: AVAudioFormat, hardware: AVAudioFormat) throws -> AVAudioFormat {
        let rate = hardware.sampleRate > 0 ? hardware.sampleRate : reported.sampleRate
        guard rate > 0, reported.channelCount > 0,
              let format = AVAudioFormat(commonFormat: reported.commonFormat, sampleRate: rate,
                                         channels: reported.channelCount, interleaved: reported.isInterleaved)
        else { throw MicError.noInputDevice }
        return format
    }

    private static func usableFormat(_ input: AVAudioInputNode) throws -> AVAudioFormat {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInputDevice }
        return format
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
final class TapSession: @unchecked Sendable {
    /// `gaveUp`: the change came before the first buffer, but capture already
    /// restarted `maxRestarts` times this take, so it ends instead.
    enum ConfigurationChange: Equatable { case restart, endTake, gaveUp }

    /// Restarts before the first buffer, per take. A device that keeps
    /// reconfiguring without ever delivering audio must not loop forever.
    static let maxRestarts = 3

    static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicCapture.sampleRate,
                                         channels: 1, interleaved: false)!

    private let onSamples: @Sendable ([Float]) -> Void
    /// Guards the fields below. Held only briefly, never across engine calls.
    private let lock = NSLock()
    private var active = true
    private var sawBuffer = false
    private var restarts = 0
    private var inputFormat: AVAudioFormat
    /// Keeps resampler state between buffers; used only from the tap's thread.
    private var converter: AVAudioConverter

    init(inputFormat: AVAudioFormat, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        self.inputFormat = inputFormat
        self.converter = try Self.makeConverter(from: inputFormat)
        self.onSamples = onSamples
    }

    private static func makeConverter(from format: AVAudioFormat) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: format, to: outFormat) else {
            throw MicCapture.MicError.unsupportedFormat("\(format)")
        }
        // Mix every channel into the mono stream instead of keeping only the first.
        converter.downmix = true
        return converter
    }

    var isActive: Bool { lock.withLock { active } }

    func end() { lock.withLock { active = false } }

    /// Decides what a configuration change means for this take. Before the
    /// first buffer nothing was lost, so capture restarts, up to `maxRestarts`
    /// times; after it, the take's sample flow ends here and is never resumed
    /// on another device mid-take.
    func configurationChanged() -> ConfigurationChange {
        lock.withLock {
            if !sawBuffer && restarts < Self.maxRestarts {
                restarts += 1
                return .restart
            }
            active = false
            return sawBuffer ? .endTake : .gaveUp
        }
    }

    /// Converts from a new input format from now on. Call only while the tap is removed.
    func adopt(inputFormat format: AVAudioFormat) throws {
        guard lock.withLock({ format != inputFormat }) else { return }
        let replacement = try Self.makeConverter(from: format)
        lock.withLock {
            inputFormat = format
            converter = replacement
        }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let converter: AVAudioConverter? = lock.withLock {
            guard active else { return nil }
            sawBuffer = true
            return self.converter
        }
        guard let converter else { return }
        let outFormat = Self.outFormat
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

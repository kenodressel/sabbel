import Foundation
@testable import SabbelCore

/// A scripted microphone. `send` plays the role of the capture callback.
/// Thread-safe: every stored property is read and written under one lock.
final class FakeAudioSource: AudioSource, @unchecked Sendable {
    struct StartFailure: Error {}

    private let lock = NSLock()
    private var _startError: (any Error)?
    private var _missingDevice: String?
    private var _devices: [String?] = []
    private var _stopCount = 0
    private var _onSamples: (@Sendable ([Float]) -> Void)?

    /// Thrown by the next `start` calls while set.
    var startError: (any Error)? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    /// Returned by `start`: the chosen mic that was missing.
    var missingDevice: String? {
        get { lock.withLock { _missingDevice } }
        set { lock.withLock { _missingDevice = newValue } }
    }
    /// The device of every `start` call, including ones that threw.
    var devices: [String?] { lock.withLock { _devices } }
    var startCount: Int { devices.count }
    var stopCount: Int { lock.withLock { _stopCount } }

    func start(device: String?, onSamples: @escaping @Sendable ([Float]) -> Void) throws -> String? {
        try lock.withLock {
            _devices.append(device)
            if let error = _startError { throw error }
            _onSamples = onSamples
            return _missingDevice
        }
    }

    func stop() {
        lock.withLock {
            _stopCount += 1
            _onSamples = nil
        }
    }

    /// Delivers `samples` as the capture callback would, in `chunk`-sized buffers.
    /// Does nothing when capture is not running.
    func send(_ samples: [Float], chunk: Int = 4_000) {
        guard let onSamples = lock.withLock({ _onSamples }) else { return }
        var i = 0
        while i < samples.count {
            onSamples(Array(samples[i..<min(i + chunk, samples.count)]))
            i += chunk
        }
    }
}

/// Answers `capture()` per call from a script; the last answer repeats.
final class FakeFocusProbe: FocusProbe, @unchecked Sendable {
    let ownPID: Int32
    private let answers: [(target: FocusTarget?, secure: Bool)]
    private let lock = NSLock()
    private var calls = 0

    init(_ answers: [(target: FocusTarget?, secure: Bool)] = [(FocusTarget(pid: 101, name: "Editor"), false)],
         ownPID: Int32 = 4_242) {
        self.answers = answers
        self.ownPID = ownPID
    }

    func capture() -> (target: FocusTarget?, secure: Bool) {
        lock.withLock {
            let answer = answers[min(calls, answers.count - 1)]
            calls += 1
            return answer
        }
    }
}

/// Records everything the coordinator shows.
@MainActor
final class FakeUI: SabbelUI {
    private(set) var shows: [(icon: IconState, status: String)] = []
    private(set) var notices: [Notice] = []
    private(set) var lives: [(text: LiveText, masked: Bool)] = []

    var icon: IconState? { shows.last?.icon }
    var status: String? { shows.last?.status }
    var statuses: [String] { shows.map(\.status) }

    func show(_ icon: IconState, status: String) { shows.append((icon, status)) }
    func notify(_ notice: Notice) { notices.append(notice) }
    func live(_ text: LiveText, masked: Bool) { lives.append((text, masked)) }
}

/// Hands out one recognizer per take, in order; the last one repeats.
final class RecognizerQueue: @unchecked Sendable {
    private let recognizers: [FakeRecognizer]
    private let lock = NSLock()
    private var next = 0

    init(_ recognizers: [FakeRecognizer]) { self.recognizers = recognizers }

    func take() -> FakeRecognizer {
        lock.withLock {
            let r = recognizers[min(next, recognizers.count - 1)]
            next += 1
            return r
        }
    }
}

/// A value written on one thread and read on another.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

import Testing
@testable import SabbelSystem

@Suite struct PermissionGateTests {
    @Test func promptsForAccessibilityOnceAndSkipsTheMicUntilGranted() {
        var gate = PermissionGate()
        var prompts: [Bool] = []
        var micReads = 0
        for _ in 0..<3 {
            let step = gate.step(accessibility: { prompts.append($0); return false },
                                 microphone: { micReads += 1; return .granted })
            #expect(step == .waiting("Accessibility missing", requestMicrophone: false))
        }
        #expect(prompts == [true, false, false])
        #expect(micReads == 0)
    }

    @Test func requestsTheMicrophoneOnce() {
        var gate = PermissionGate()
        #expect(gate.step(accessibility: { _ in true }, microphone: { .undetermined })
                == .waiting("Microphone missing", requestMicrophone: true))
        #expect(gate.step(accessibility: { _ in true }, microphone: { .undetermined })
                == .waiting("Microphone missing", requestMicrophone: false))
    }

    @Test func deniedMicrophoneIsNeverRequested() {
        var gate = PermissionGate()
        #expect(gate.step(accessibility: { _ in true }, microphone: { .denied })
                == .waiting("Microphone missing", requestMicrophone: false))
    }

    @Test func readyOnceBothAreGranted() {
        var gate = PermissionGate()
        _ = gate.step(accessibility: { _ in false }, microphone: { .granted })
        _ = gate.step(accessibility: { _ in true }, microphone: { .undetermined })
        #expect(gate.step(accessibility: { _ in true }, microphone: { .granted }) == .ready)
    }
}

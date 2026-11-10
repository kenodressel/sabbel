import AVFoundation
import Foundation
import Testing
@testable import SabbelSystem

@Suite struct ObjCExceptionTests {
    @Test func anObjectiveCExceptionBecomesASwiftError() {
        #expect(throws: (any Error).self) {
            try catchingObjCException { NSException(name: .genericException, reason: "boom").raise() }
        }
        do {
            try catchingObjCException { NSException(name: .genericException, reason: "boom").raise() }
        } catch {
            #expect("\(error)".contains("boom"))
        }
    }

    @Test func aBlockThatDoesNotRaiseRunsOnce() throws {
        var runs = 0
        try catchingObjCException { runs += 1 }
        #expect(runs == 1)
    }

    /// The crash from the field: AVAudioEngine rejects a tap by raising, which
    /// Swift cannot catch. A second tap on the same bus raises the same way
    /// without needing audio hardware.
    @Test func aRejectedTapDoesNotTakeTheProcessDown() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try catchingObjCException { player.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in } }
        #expect(throws: (any Error).self) {
            try catchingObjCException { player.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in } }
        }
        player.removeTap(onBus: 0)
    }
}

import Foundation
import Testing
@testable import SabbelCore

@Suite struct AudioLevelTests {
    private func tone(_ amplitude: Float, count: Int = 1_600) -> [Float] {
        (0..<count).map { amplitude * sin(Float($0) * 0.3) }
    }

    @Test func silenceIsZero() {
        #expect(AudioLevel.level(of: [Float](repeating: 0, count: 1_600)) == 0)
        #expect(AudioLevel.level(of: []) == 0)
        // -60 dBFS is under the floor.
        #expect(AudioLevel.level(of: [Float](repeating: 0.001, count: 1_600)) == 0)
    }

    @Test func loudIsOne() {
        #expect(AudioLevel.level(of: [Float](repeating: 0.5, count: 1_600)) == 1)
        #expect(AudioLevel.level(of: tone(1)) == 1)
    }

    @Test func mapsTheDecibelRangeLinearly() {
        #expect(AudioLevel.level(dB: -50) == 0)
        #expect(AudioLevel.level(dB: -10) == 1)
        #expect(abs(AudioLevel.level(dB: -30) - 0.5) < 1e-9)
        // A constant 0.01 is exactly -40 dBFS.
        #expect(abs(AudioLevel.level(of: [Float](repeating: 0.01, count: 100)) - 0.25) < 1e-6)
    }

    @Test func isMonotonic() {
        let amplitudes: [Float] = [0, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1]
        let levels = amplitudes.map { AudioLevel.level(of: tone($0)) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(levels.first == 0 && levels.last == 1)
        #expect(Set(levels).count > 4)
    }

    @Test func garbageIsSafe() {
        #expect(AudioLevel.level(of: [.nan, 0.5]) == 0)
        #expect(AudioLevel.level(of: [.infinity]) == 0)
        #expect(AudioLevel.level(dB: .nan) == 0)
        #expect(AudioLevel.level(dB: .infinity) == 1)
        #expect(AudioLevel.level(dB: -.infinity) == 0)
    }
}

@Suite struct LevelThrottleTests {
    @Test func atMostTwentyPerSecond() {
        var throttle = LevelThrottle()
        var delivered = 0
        // One buffer a millisecond for two seconds.
        for ms in 0..<2_000 where throttle.offer(0.5, at: Double(ms) / 1_000) != nil {
            delivered += 1
        }
        #expect(delivered <= 40 && delivered >= 39)
    }

    @Test func firstLevelPassesAtOnce() {
        var throttle = LevelThrottle()
        #expect(throttle.offer(0.3, at: 10) == 0.3)
        #expect(throttle.offer(0.4, at: 10.01) == nil)
    }

    @Test func aHeldBackPeakIsDeliveredNext() {
        var throttle = LevelThrottle()
        _ = throttle.offer(0.1, at: 0)
        #expect(throttle.offer(0.9, at: 0.01) == nil)
        #expect(throttle.offer(0.2, at: 0.02) == nil)
        #expect(throttle.offer(0.2, at: 0.05) == 0.9)
        // The peak is spent once delivered.
        #expect(throttle.offer(0.3, at: 0.1) == 0.3)
    }

    @Test func meterUsesItsClock() {
        let clock = LockedBox<TimeInterval>(0)
        let meter = LevelMeter(now: { clock.value })
        #expect(meter.measure([Float](repeating: 0.5, count: 160)) == 1)
        #expect(meter.measure([Float](repeating: 0.5, count: 160)) == nil)
        clock.value = 0.05
        #expect(meter.measure([Float](repeating: 0, count: 160)) == 1)
        clock.value = 0.1
        #expect(meter.measure([Float](repeating: 0, count: 160)) == 0)
    }
}

@Suite struct LevelBarsTests {
    @Test func startsFlat() {
        let bars = LevelBars()
        #expect(bars.values.count == LevelBars.count)
        #expect(bars.values.allSatisfy { $0 == LevelBars.rest })
    }

    @Test func newestEntersOnTheRightAndStaysInRange() {
        var bars = LevelBars()
        bars.push(1)
        #expect(bars.values.last! > LevelBars.rest)
        #expect(bars.values.dropLast().allSatisfy { $0 == LevelBars.rest })
        for _ in 0..<40 { bars.push(1) }
        #expect(bars.values.allSatisfy { $0 <= 1 && $0 > 0.9 })
        bars.push(.nan)
        bars.push(-3)
        #expect(bars.values.allSatisfy { $0 >= LevelBars.rest && $0 <= 1 })
        #expect(bars.values.count == LevelBars.count)
    }

    @Test func risesFasterThanItFalls() {
        var up = LevelBars()
        up.push(1)
        var down = LevelBars()
        for _ in 0..<40 { down.push(1) }
        down.push(0)
        let rise = up.values.last! - LevelBars.rest
        let fall = 1 - down.values.last!
        #expect(rise > fall)
    }

    @Test func resetFlattens() {
        var bars = LevelBars()
        bars.push(0.8)
        bars.reset()
        #expect(bars == LevelBars())
    }
}

@Suite struct OverlayMachineTests {
    @Test func pressShowsRecording() {
        var m = OverlayMachine(style: .minimal)
        #expect(m.phase == .hidden)
        m.handle(.started(take: 1), at: 5)
        #expect(m.phase == .recording(since: 5))
        #expect(m.hideAt == nil)
    }

    @Test func switchingToTextKeepsTheTakeOnScreen() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.style = .text
        #expect(m.phase == .recording(since: 0))
        m.handle(.released(take: 1), at: 2)
        #expect(m.phase == .finishing(elapsed: 2))
    }

    @Test func switchingOffHidesAndIgnoresTheRestOfTheTake() {
        var m = OverlayMachine(style: .text)
        m.handle(.started(take: 1), at: 0)
        m.style = .off
        #expect(m.phase == .hidden)
        #expect(m.hideAt == nil)
        m.handle(.released(take: 1), at: 2)
        #expect(m.phase == .hidden)
        m.style = .minimal
        m.handle(.finished(take: 1, .pasted), at: 3)
        #expect(m.phase == .hidden)
    }

    @Test func releaseShowsFinishing() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 2)
        #expect(m.phase == .finishing(elapsed: 2))
    }

    @Test func pastedShowsResultThenHidesAfterItsDuration() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 2)
        m.handle(.finished(take: 1, .pasted), at: 3)
        #expect(m.phase == .result(OverlayResult(.pasted)))
        #expect(m.hideAt == 3 + OverlayMachine.resultDuration)
        m.tick(at: 3.5)
        #expect(m.phase.isVisible)
        m.tick(at: 3.8)
        #expect(m.phase == .hidden)
        #expect(m.hideAt == nil)
    }

    @Test func copiedShowsLikePasted() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 1)
        m.handle(.finished(take: 1, .copied), at: 1)
        #expect(m.phase == .result(OverlayResult(.copied)))
        #expect(m.hideAt == 1 + OverlayMachine.resultDuration)
    }

    @Test func errorStaysLonger() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 1)
        m.handle(.finished(take: 1, .failed("Too short")), at: 1)
        #expect(m.hideAt == 1 + OverlayMachine.errorDuration)
        #expect(OverlayMachine.errorDuration > OverlayMachine.resultDuration)
        m.tick(at: 1 + OverlayMachine.resultDuration)
        #expect(m.phase == .result(OverlayResult(.failed("Too short"))))
        m.tick(at: 1 + OverlayMachine.errorDuration)
        #expect(m.phase == .hidden)
    }

    @Test func cancelHidesAtOnce() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.cancelled(take: 1), at: 1)
        #expect(m.phase == .hidden)
    }

    @Test func newPressDuringResultRecordsAgain() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 1)
        m.handle(.finished(take: 1, .failed("Not recognized")), at: 2)
        m.handle(.started(take: 2), at: 2.5)
        #expect(m.phase == .recording(since: 2.5))
        #expect(m.hideAt == nil)
        // The old result's timer firing late changes nothing.
        m.tick(at: 10)
        #expect(m.phase == .recording(since: 2.5))
    }

    @Test func anEarlierTakesResultNeverInterruptsTheNewTake() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.started(take: 1), at: 0)
        m.handle(.released(take: 1), at: 1)
        m.handle(.started(take: 2), at: 1.5)
        m.handle(.finished(take: 1, .pasted), at: 2)
        #expect(m.phase == .recording(since: 1.5))
        m.handle(.released(take: 1), at: 2)
        m.handle(.cancelled(take: 1), at: 2)
        #expect(m.phase == .recording(since: 1.5))
        m.handle(.released(take: 2), at: 3)
        m.handle(.finished(take: 2, .pasted), at: 4)
        #expect(m.phase == .result(OverlayResult(.pasted)))
    }

    @Test func resultWithoutReleaseIsIgnored() {
        var m = OverlayMachine(style: .minimal)
        m.handle(.finished(take: 1, .pasted), at: 0)
        #expect(m.phase == .hidden)
        m.handle(.released(take: 1), at: 0)
        #expect(m.phase == .hidden)
    }

    @Test func styleOffNeverShows() {
        var m = OverlayMachine(style: .off)
        let events: [TakeEvent] = [.started(take: 1), .released(take: 1), .finished(take: 1, .pasted),
                                   .started(take: 2), .cancelled(take: 2), .started(take: 3)]
        for (i, event) in events.enumerated() {
            m.handle(event, at: Double(i))
            #expect(m.phase == .hidden)
            m.tick(at: Double(i) + 0.5)
            #expect(m.phase == .hidden)
        }
    }

    @Test func textStyleFollowsTheSameStates() {
        var m = OverlayMachine(style: .text)
        m.handle(.started(take: 1), at: 0)
        #expect(m.phase == .recording(since: 0))
    }

    @Test func resultWords() {
        #expect(OverlayResult(.pasted).text == "Pasted" && OverlayResult(.pasted).symbol == "checkmark")
        #expect(OverlayResult(.copied).text == "Copied" && OverlayResult(.copied).symbol == "doc.on.clipboard")
        let error = OverlayResult(.failed("Not recognized"))
        #expect(error.kind == .error && error.text == "Not recognized" && error.symbol == "xmark")
    }

    @Test func elapsedIsMinutesAndSeconds() {
        #expect(OverlayMachine.elapsed(0) == "0:00")
        #expect(OverlayMachine.elapsed(9.99) == "0:09")
        #expect(OverlayMachine.elapsed(61) == "1:01")
        #expect(OverlayMachine.elapsed(600) == "10:00")
        #expect(OverlayMachine.elapsed(-1) == "0:00")
        #expect(OverlayMachine.elapsed(.nan) == "0:00")
    }
}

/// The coordinator's side: which events and levels reach the UI.
@MainActor
@Suite struct TakeCoordinatorOverlayTests {
    @Test func pastedTakeStartsReleasesAndFinishes() async {
        let h = Harness()
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes == [.started(take: 1), .released(take: 1), .finished(take: 1, .pasted)])
    }

    @Test func rejectionsCarryTheMenuBarText() async {
        let h = Harness()
        h.take(Harness.speech(0.2))
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes.last == .finished(take: 1, .failed("Too short")))
        #expect(h.ui.shows.contains { $0.icon == .error("Too short") })
    }

    @Test func notRecognizedIsAnError() async {
        let h = Harness(recognizers: [FakeRecognizer(script: [], mangle: .none)])
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes.last == .finished(take: 1, .failed("Not recognized")))
    }

    @Test func leftInClipboardIsCopied() async {
        let h = Harness()
        h.env.frontmostPIDAnswer = { _, _ in 999 }
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes.last == .finished(take: 1, .copied))
    }

    @Test func secureTakeIsDiscarded() async {
        let h = Harness(focus: FakeFocusProbe([(Harness.target, true)]))
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes.last == .finished(take: 1, .failed("Discarded")))
    }

    @Test func cancelIsReported() async {
        let h = Harness()
        h.coordinator.handle(.start)
        h.coordinator.handle(.cancel(.escape))
        #expect(h.ui.takes == [.started(take: 1), .cancelled(take: 1)])
    }

    @Test func failedMicStartsNoTake() {
        let h = Harness()
        h.audio.startError = FakeAudioSource.StartFailure()
        h.coordinator.handle(.start)
        #expect(h.ui.takes.isEmpty)
    }

    @Test func overlappingTakesFinishInOrder() async {
        let h = Harness(recognizers: [Harness.hello(delay: 0.1), Harness.hello()])
        h.take()
        h.take()
        await h.coordinator.waitUntilIdle()
        #expect(h.ui.takes == [.started(take: 1), .released(take: 1), .started(take: 2), .released(take: 2),
                               .finished(take: 1, .pasted), .finished(take: 2, .pasted)])
    }

    @Test func levelsAreThrottledAndOnlyWhileRecording() async {
        let h = Harness()
        h.coordinator.handle(.start)
        // Ten buffers at the same instant: one level.
        h.audio.send(Harness.speech(0.5), chunk: 800)
        #expect(await eventually { h.ui.levels.count == 1 })
        h.clock.value += 0.05
        h.audio.send(Harness.speech(0.1), chunk: 800)
        #expect(await eventually { h.ui.levels.count == 2 })
        #expect(h.ui.levels.allSatisfy { $0 > 0.9 })
        h.clock.value += 0.05
        h.audio.send(Harness.speech(0.1), chunk: 800)
        h.coordinator.handle(.stop)
        await h.coordinator.waitUntilIdle()
        // The hop to the main actor landed after the release: dropped.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.ui.levels.count == 2)
    }
}

import Testing
@testable import SabbelEngine

/// Records how many operations run at once and the order they finish in.
private actor Probe {
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var finished: [Int] = []

    func enter() {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func leave(_ id: Int) {
        inFlight -= 1
        finished.append(id)
    }
}

private struct Boom: Error {}

@Suite struct SerialLockTests {
    /// Waits (bounded) until `count` callers are queued behind the holder.
    private func waitForWaiters(_ lock: AsyncSerialLock, _ count: Int) async {
        for _ in 0..<10_000 {
            if await lock.waiterCount >= count { return }
            await Task.yield()
        }
        Issue.record("lock never had \(count) waiters")
    }

    @Test func recognizeIsSerialised() async throws {
        let lock = AsyncSerialLock()
        let probe = Probe()
        let (started, startedSink) = AsyncStream.makeStream(of: Void.self)

        @Sendable func slow(_ id: Int) async throws -> Int {
            await probe.enter()
            if id == 1 { startedSink.yield() }
            // Long enough for the other callers to pile up while it is suspended.
            try await Task.sleep(for: .milliseconds(40))
            await probe.leave(id)
            return id
        }

        let first = Task { try await lock.run { try await slow(1) } }
        var it = started.makeAsyncIterator()
        _ = await it.next()
        let second = Task { try await lock.run { try await slow(2) } }
        await waitForWaiters(lock, 1)
        let third = Task { try await lock.run { try await slow(3) } }
        await waitForWaiters(lock, 2)

        let results = try await [first.value, second.value, third.value]
        #expect(results == [1, 2, 3])
        #expect(await probe.maxInFlight == 1)
        #expect(await probe.finished == [1, 2, 3])
    }

    @Test func throwingOperationReleasesTheLock() async throws {
        let lock = AsyncSerialLock()
        await #expect(throws: Boom.self) { try await lock.run { () async throws -> Int in throw Boom() } }
        let value = try await lock.run { 7 }
        #expect(value == 7)
        #expect(await lock.waiterCount == 0)
    }
}

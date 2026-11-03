/// A FIFO async mutex: `run` executes one operation at a time, in call order.
///
/// An actor alone does not serialise async work: across an `await` it is
/// reentrant, so a second call starts while the first is suspended.
actor AsyncSerialLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callers queued behind the current holder (for tests).
    var waiterCount: Int { waiters.count }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock straight to the next waiter, so no late caller can jump the queue.
    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

import Foundation

/// Port of `sabbel/single_instance.py`: an exclusive, non-blocking `flock` on a
/// lock file, held for the life of the process. The kernel drops it on exit or
/// crash, so a stale file never blocks a restart.
public final class SingleInstanceLock {
    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL = URL(fileURLWithPath: "/tmp/sabbel.lock")) {
        self.url = url
    }

    public func acquire() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // No O_TRUNC: truncating before the lock is won would wipe the holder's pid.
        let newFD = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard newFD >= 0 else { return false }
        guard flock(newFD, LOCK_EX | LOCK_NB) == 0 else {
            close(newFD)
            return false
        }
        _ = ftruncate(newFD, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(newFD, $0.baseAddress, $0.count) }
        fd = newFD
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

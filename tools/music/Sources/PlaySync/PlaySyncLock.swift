import Darwin
import Foundation

/// The exclusive lock one play-sync pass holds from start to finish, across
/// processes: the TUI's worker, `music sync-plays`, and a second copy of either.
///
/// It is a `flock` on its own open of the lock file. `flock` belongs to the open
/// file description, so two `PlaySyncLock`s in one process exclude each other
/// exactly as two processes do.
final class PlaySyncLock {

    enum Failure: Error, Equatable {
        /// Another pass holds the lock.
        case busy
        /// The lock file could not be opened (the errno).
        case unavailable(Int32)
    }

    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Takes the lock at `url`, creating the file mode 0600 if needed. With a
    /// zero `wait` it tries once; otherwise it polls until `wait` has passed.
    static func acquire(_ url: URL, waitingUpTo wait: TimeInterval,
                        pollInterval: TimeInterval = 0.05) -> Result<PlaySyncLock, Failure> {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(.unavailable(errno)) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return .failure(.unavailable(EINVAL))
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, wait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return .success(PlaySyncLock(fd: fd))
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else {
                close(fd)
                return .failure(.unavailable(code))
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                close(fd)
                return .failure(.busy)
            }
            usleep(useconds_t(min(pollInterval, remaining) * 1_000_000))
        }
    }

    /// Releases the lock. Safe to call more than once.
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

// The cross-process output lock (slice 3, Part 1, decision D6).
//
// A TUI Output switch and a CLI playback change must not interleave: a CLI
// `queue` landing between the switch's pause and its commit would leave the
// outgoing player playing under the incoming selection. The in-process `order`
// lock in `RoutingCoordinator` cannot see another process, so both sides also
// take this: an exclusive `flock(2)` on a stable file beside `mode.json`.
//
// - **Never replaced, never deleted.** A lock file that is swapped or removed
//   lets two processes lock two different inodes and both "hold" it.
// - **A fresh descriptor per acquisition**, closed on release, so the release
//   is the close. `flock` is released when the descriptor closes, including on
//   crash or SIGKILL, so no stale lock survives a dead process.
// - **`O_CLOEXEC`**, so a child (`open`, `osascript`, a detached
//   `__watch-container`) cannot inherit the descriptor and prolong the lock.
// - **Bounded waiting, never forced release.** `timeout` bounds a WAITER's
//   attempt; a holder is never made to let go while it may still be changing
//   playback. 30 s is CHOSEN, NOT MEASURED.
// - **Fail closed.** A lock file that cannot be opened refuses, naming the path
//   and the error, rather than proceeding unordered.
// - **Ordering.** In every process: the in-process `order` lock first, then
//   this; never the reverse, and never re-entered on one thread. A second
//   acquisition on the same path from the same thread would wait on its own
//   process for the whole bound, so it throws the coordinator's internal-error
//   sentence instead.
//
// The lock orders a switch against a playback change; it does not create
// evidence. The switch's pause confirmation must still be positive for both
// players.
import Foundation

/// Why the lock could not be taken. Each surface words the refusal for what it
/// was about to do, so the sentence is chosen by the caller's surface.
enum OutputLockError: Error, Equatable {
    /// The bound passed while another process held the lock.
    case busy
    /// The lock file could not be opened or locked for a reason other than
    /// another holder.
    case unavailable(path: String, reason: String)

    func message(for surface: InvocationSurface) -> String {
        switch (self, surface) {
        case (.busy, .cli):
            return "Output is being switched; nothing was changed. Try again."
        case (.busy, .tui):
            return "A music command is changing playback; nothing was switched."
        case (.unavailable(let path, let reason), .cli):
            return "Couldn't open the output lock at \(path) (\(reason)); nothing was changed."
        case (.unavailable(let path, let reason), .tui):
            return "Couldn't open the output lock at \(path) (\(reason)); nothing was switched."
        }
    }
}

final class OutputLock {

    /// How long a waiter tries before refusing. CHOSEN, NOT MEASURED.
    static let defaultTimeout: TimeInterval = 30

    /// The CLI's refusal when, after acquiring, the persisted mode no longer
    /// matches the mode the command routed on. A mismatch refuses; it never
    /// re-routes.
    static func cliModeChangedMessage(now mode: PlaybackMode) -> String {
        "Output changed to \(mode == .musicApp ? "Music.app" : "Bridge") while this command ran; nothing was changed."
    }

    /// The TUI's refusal when another process moved the persisted selection
    /// away from the mode this TUI holds in memory.
    static let tuiModeChangedMessage = "Output was changed by another MusicTUI process; nothing was switched."

    /// The coordinator's existing re-entry sentence, reused so a nested
    /// acquisition reads the same as a nested action.
    static let reentryMessage = "Internal error: a playback action started another inside itself"

    let path: String

    private let pollInterval: TimeInterval
    private let clock: () -> Date
    private let pause: (TimeInterval) -> Void
    private let reentryKey: String

    private let state = NSLock()
    private var waitingHook: (() -> Void)?
    private var descriptor: Int32?

    init(path: String,
         pollInterval: TimeInterval = 0.05,
         clock: @escaping () -> Date = Date.init,
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         onWaiting: (() -> Void)? = nil) {
        self.path = path
        self.pollInterval = pollInterval
        self.clock = clock
        self.pause = pause
        self.waitingHook = onWaiting
        // Keyed by PATH, not instance: two instances on one path conflict just
        // as one instance does, so either would wedge a thread on itself.
        self.reentryKey = "OutputLock." + (path as NSString).standardizingPath
    }

    /// TEST SEAM. Called once per acquisition, on the waiting thread, when the
    /// first attempt finds the lock held and the wait begins.
    func onWaiting(_ hook: (() -> Void)?) {
        state.lock(); waitingHook = hook; state.unlock()
    }

    /// TEST SEAM. The descriptor currently holding the lock, if this instance
    /// holds it, so a test can check its flags.
    var heldDescriptor: Int32? {
        state.lock(); defer { state.unlock() }
        return descriptor
    }

    /// Runs `body` holding the lock, releasing it on return and on throw.
    /// Errors from `body` pass through untouched.
    func withLock<T>(timeout: TimeInterval = OutputLock.defaultTimeout,
                     _ body: () throws -> T) throws -> T {
        let marker = Thread.current.threadDictionary
        guard marker[reentryKey] == nil else {
            throw ActionError(message: Self.reentryMessage)
        }

        let fd = try acquire(timeout: timeout)
        state.lock(); descriptor = fd; state.unlock()
        marker[reentryKey] = true
        defer {
            marker.removeObject(forKey: reentryKey)
            state.lock(); descriptor = nil; state.unlock()
            close(fd)   // the release: flock belongs to this open file description
        }
        return try body()
    }

    // MARK: - private

    private func acquire(timeout: TimeInterval) throws -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw OutputLockError.unavailable(path: path, reason: String(cString: strerror(errno)))
        }

        let start = clock()
        var announced = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let err = errno
            if err == EINTR { continue }
            guard err == EWOULDBLOCK else {
                close(fd)
                throw OutputLockError.unavailable(path: path, reason: String(cString: strerror(err)))
            }
            if !announced {
                announced = true
                state.lock(); let hook = waitingHook; state.unlock()
                hook?()
            }
            guard clock().timeIntervalSince(start) < timeout else {
                close(fd)
                throw OutputLockError.busy
            }
            pause(pollInterval)
        }
    }
}

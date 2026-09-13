// tools/music/Sources/TUI/Shell/ShellActions.swift
import Foundation

// MARK: - Status toast

/// A transient one-line message shown in the footer band, replacing the key
/// hints until it expires. The shell's only error/feedback channel: every
/// user-initiated AppleScript action used to be `_ = try?`, making a failed
/// play/toggle/seek visually identical to success.
struct StatusToast: Equatable {
    let text: String
    let isError: Bool
    let expiresAt: Date
}

/// Thread-safe holder for the current toast (same shape as NowPlayingStore:
/// one lock, one value). Posted from the action queue or scenes; read by the
/// render loop once per iteration.
final class StatusStore {
    private let lock = NSLock()
    private var toast: StatusToast?

    func post(_ text: String, error: Bool = false, ttl: TimeInterval = 3, now: Date = Date()) {
        lock.lock()
        toast = StatusToast(text: text, isError: error, expiresAt: now.addingTimeInterval(ttl))
        lock.unlock()
    }

    /// The active toast, or nil once expired (expiry clears it).
    func current(now: Date = Date()) -> StatusToast? {
        lock.lock(); defer { lock.unlock() }
        guard let t = toast else { return nil }
        if now >= t.expiresAt { toast = nil; return nil }
        return t
    }
}

// MARK: - Action queue

/// A failure with a user-facing message; ActionRunner shows it as an error toast.
///
/// `LocalizedError` so a CLI command that lets it escape prints `message`:
/// ArgumentParser renders any other error with `String(describing:)`, which
/// would print `ActionError(message: "...")`.
struct ActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Throw an ActionError when a Bool-reporting helper failed.
func require(_ ok: Bool, _ message: String) throws {
    if !ok { throw ActionError(message: message) }
}

/// Runs user-initiated AppleScript off the input loop, serially (one queue for
/// the whole shell, so actions apply in press order), posting an error toast on
/// failure. The input loop never blocks on an osascript round-trip; the poller
/// reflects the effect on its next tick.
final class ActionRunner {
    private let queue = DispatchQueue(label: "music.shell.actions")
    private let status: StatusStore

    init(status: StatusStore) { self.status = status }

    func run(_ label: String, _ body: @escaping () throws -> Void) {
        queue.async {
            do { try body() } catch let e as ActionError {
                self.status.post(e.message, error: true)
            } catch {
                self.status.post("\(label) failed.", error: true)
            }
        }
    }
}

// MARK: - Keypress coalescing

/// Accumulates relative deltas (master volume ±5 per press). Each keypress
/// enqueues one action, but the first action to run applies the whole
/// accumulated delta and the rest no-op — holding a key never builds an
/// osascript backlog.
final class DeltaAccumulator {
    private let lock = NSLock()
    private var delta = 0

    func add(_ d: Int) { lock.lock(); delta += d; lock.unlock() }

    /// The accumulated delta, zeroing it. 0 means an earlier action already applied it.
    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let d = delta; delta = 0; return d
    }
}

/// Latest absolute target per key (per-speaker volume). Same skip-if-taken
/// pattern as DeltaAccumulator: queued actions for superseded targets no-op.
final class TargetAccumulator {
    private let lock = NSLock()
    private var targets: [String: Int] = [:]

    func set(_ key: String, _ value: Int) { lock.lock(); targets[key] = value; lock.unlock() }

    /// The pending target for `key`, removing it. nil means already applied.
    func take(_ key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return targets.removeValue(forKey: key)
    }
}

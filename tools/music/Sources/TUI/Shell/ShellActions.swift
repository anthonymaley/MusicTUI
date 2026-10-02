// tools/music/Sources/TUI/Shell/ShellActions.swift
import Foundation

// MARK: - Status toast

/// A one-line message shown in the footer band, replacing the key hints.
/// The shell's only error/feedback channel: every user-initiated AppleScript
/// action used to be `_ = try?`, making a failed play/toggle/seek visually
/// identical to success.
///
/// Two lifetimes. A TRANSIENT status ("Playing X", "Paired with Y") expires
/// on its own after a few seconds. A message that means something will NOT
/// play (a refused play, queue or switch; songs skipped as unavailable)
/// carries no expiry: it stays until the next state change, because a
/// person who looked away must still be able to read why nothing, or not
/// everything, is playing.
struct StatusToast: Equatable {
    let text: String
    let isError: Bool
    /// nil: stays until the next state change.
    let expiresAt: Date?

    var staysUntilStateChange: Bool { expiresAt == nil }
}

/// The routing coordinator's two switch counters, read when a lasting
/// message is posted: a committed output or data-source switch moves one of
/// them, and that clears the message.
struct StatusSwitchStamp: Equatable {
    let epoch: Int
    let dataEpoch: Int
}

/// Thread-safe holder for the current toast (same shape as NowPlayingStore:
/// one lock, one value). Posted from the action queue or scenes; read by the
/// render loop once per iteration.
final class StatusStore {
    /// How long after a lasting message is posted a new track still counts as
    /// the start of the play that posted it, not as the next track change. A
    /// play posts its notice as soon as the output accepts the queue, and
    /// playback reports the first song a poll or two later; without this, a
    /// notice about skipped songs would vanish the moment its own play began.
    static let trackSettle: TimeInterval = 10

    private struct Lasting {
        let postedAt: Date
        let stamp: StatusSwitchStamp
        var track: String?
    }

    private let lock = NSLock()
    private var toast: StatusToast?
    private var lasting: Lasting?
    private var lastTrack: String?
    private let switchStamp: () -> StatusSwitchStamp

    /// `switchStamp` reads the routing coordinator's switch counters; the
    /// default never moves (tests, and any store with no coordinator).
    init(switchStamp: @escaping () -> StatusSwitchStamp = { StatusSwitchStamp(epoch: 0, dataEpoch: 0) }) {
        self.switchStamp = switchStamp
    }

    /// `untilStateChange`: a won't-play message, which ignores `ttl` and stays
    /// until `stateChanged()`, the next track change, a committed output or
    /// data-source switch, or the next post (which replaces it).
    func post(_ text: String, error: Bool = false, ttl: TimeInterval = 3,
              untilStateChange: Bool = false, now: Date = Date()) {
        // Read before taking the lock: the coordinator has a lock of its own.
        let stamp = untilStateChange ? switchStamp() : nil
        lock.lock(); defer { lock.unlock() }
        if let stamp {
            toast = StatusToast(text: text, isError: error, expiresAt: nil)
            lasting = Lasting(postedAt: now, stamp: stamp, track: lastTrack)
        } else {
            toast = StatusToast(text: text, isError: error, expiresAt: now.addingTimeInterval(ttl))
            lasting = nil
        }
    }

    /// Something the person did changed the state (a play started, a tab
    /// changed): a lasting message goes. A transient one keeps its own clock.
    func stateChanged() {
        lock.lock(); defer { lock.unlock() }
        clearLasting()
    }

    /// Once per render-loop iteration, with the track playback reports now
    /// (`statusTrackKey`). nil is not a change: a poll that failed or a queue
    /// still loading says nothing about which song is playing.
    func observe(track: String?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let track else { return }
        lastTrack = track
        guard var l = lasting else { return }
        if now < l.postedAt.addingTimeInterval(Self.trackSettle) || l.track == nil {
            // Still the play's own start (or the first song seen at all).
            l.track = track
            lasting = l
        } else if track != l.track {
            clearLasting()
        }
    }

    /// The active toast, or nil once expired (expiry clears it). A lasting
    /// message is gone once a switch has committed since it was posted.
    func current(now: Date = Date()) -> StatusToast? {
        let stampNow = switchStamp()
        lock.lock(); defer { lock.unlock() }
        if let l = lasting, l.stamp != stampNow { clearLasting() }
        guard let t = toast else { return nil }
        if let expiry = t.expiresAt, now >= expiry { toast = nil; return nil }
        return t
    }

    /// Caller holds `lock`.
    private func clearLasting() {
        guard lasting != nil else { return }
        lasting = nil
        toast = nil
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

    /// Blocks until every action queued so far has run. Tests only.
    func waitUntilIdle() { queue.sync {} }

    /// Actions that start something. Queuing one is a state change: a lasting
    /// message from before it goes at the keypress, so whatever this action
    /// then posts (its own refusal, its own skip notice) is what shows.
    static let startingLabels: Set<String> = ["Play", "Play/pause", "Shuffle", "Genius", "Skip", "Back"]

    /// Actions whose failure means something did not play or did not switch:
    /// their error stays until the next state change. Any other action's
    /// error (volume, seek, favorite, EQ...) is a transient status.
    static let wontPlayLabels: Set<String> = startingLabels.union(["Output", "SpanDAC"])

    func run(_ label: String, _ body: @escaping () throws -> Void) {
        if Self.startingLabels.contains(label) { status.stateChanged() }
        let lasting = Self.wontPlayLabels.contains(label)
        queue.async {
            do { try body() } catch let e as ActionError {
                self.status.post(e.message, error: true, untilStateChange: lasting)
            } catch {
                self.status.post("\(label) failed.", error: true, untilStateChange: lasting)
            }
        }
    }

    /// The same serial queue, with no status post and no state change: for
    /// work nobody pressed a key for (ending a Discover copy he has stopped
    /// listening to), which must still never interleave with a play.
    func enqueueQuiet(_ body: @escaping () -> Void) {
        queue.async(execute: body)
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

/// The track the footer's lasting message watches, or nil when playback
/// reports none (stopped, loading, or a poll that failed).
func statusTrackKey(_ snap: NowPlayingSnapshot) -> String? {
    if let bridge = snap.bridge {
        return bridge.title.isEmpty ? nil : trackKey(title: bridge.title, artist: bridge.artist)
    }
    if case .active(let np) = snap.outcome, !np.track.isEmpty {
        return trackKey(title: np.track, artist: np.artist)
    }
    return nil
}

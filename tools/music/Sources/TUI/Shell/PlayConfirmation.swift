// tools/music/Sources/TUI/Shell/PlayConfirmation.swift
//
// Honest "Playing" (2026-11-01). A play script that exits cleanly says only
// that Apple's Music app accepted it. That day the laptop's Music accepted
// the play and stayed paused on the previous track while MusicTUI said
// "Playing". So a play the PERSON starts on an app-owned queue (Playlists
// Enter, Now's jumps, Library song/album/artist plays, the global next and
// previous, and the SpanDAC library hand-off's first track) is confirmed
// after its script returns: Music's player state and the current track's
// persistent ID are read a few times over a short window, off the action
// queue and outside the routing boundary.
//
// - Confirmed: `playing`, and the current track's persistent ID is the
//   requested one. Nothing changes; whatever the play posted stands.
// - Not confirmed in the window (paused, stopped, another track, or a read
//   that failed): `playNotStartedWarning` replaces the footer line, followed
//   by any notice the play carried. The queue is kept. A confirmation that
//   arrives later for the same, still-current request withdraws exactly that
//   warning. A script that ERRORED is not this case at all: it keeps today's
//   behaviour (rollback, "Couldn't play").
// - While a request is unconfirmed the poller does not auto-advance the new
//   queue off the previous track's natural end, until the requested track has
//   been seen playing (or, with no identity to compare, a safe new baseline)
//   or a later request replaces it. The hold is taken in the same locked step
//   that installs or moves the queue (`AppQueueStore.setRequested`).
// - Only the latest request may speak: every request, pause, skip, play and
//   committed output or data-source switch since makes a late result drop
//   silently.
//
// Message timing (CHOSEN): the play's own message posts at once, as before,
// and the warning replaces it only when the window closes unconfirmed. The
// normal case gains no delay, and the extra read never sits on the key path.
// Titles are never compared: identity is the persistent ID only.
import Foundation

/// One read of Apple's Music app for a confirmation: the player state, and
/// the current track's persistent ID (nil when there is none, or it could not
/// be read).
struct PlayerIdentityReading: Equatable {
    let state: String
    let persistentID: String?
}

/// The confirmation read: state and identity in one script. The identity read
/// is wrapped, so a player with no current track (or the macOS 26 `-1728` on a
/// streamed track) still answers with its state.
let playerIdentityReadScript = """
    set fs to (ASCII character 31)
    set st to player state as text
    set pid to ""
    try
        set pid to persistent ID of current track
    end try
    return st & fs & pid
    """

/// `playerIdentityReadScript`'s answer, or nil when it is not one. Pure.
func parsePlayerIdentityReading(_ raw: String) -> PlayerIdentityReading? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: asFieldSep, maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    let pid = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    return PlayerIdentityReading(state: parts[0], persistentID: pid.isEmpty ? nil : pid)
}

/// One live confirmation read. Nil when the script failed or timed out: an
/// unreadable player is not a confirmed one, and never an error.
func readPlayerIdentity(backend: AppleScriptBackend, timeout: TimeInterval = 2) -> PlayerIdentityReading? {
    guard let raw = try? backend.runMusicBlocking(playerIdentityReadScript, timeout: timeout) else { return nil }
    return parsePlayerIdentityReading(raw)
}

/// The footer line for a play Music accepted but did not confirm. The
/// evidence is a failed confirmation, not a proven stop, so it says so
/// (Codex r1 wording, 2026-11-01).
func playNotStartedWarning(_ title: String) -> String {
    "Play was requested, but Music didn't confirm '\(title)' started. If nothing plays, quitting and reopening Music fixed this before."
}

/// What must not have moved between a request and its late result: both
/// routing epochs (a committed output or data-source switch) and the routing
/// play serial (any chosen-music play admitted since).
struct PlayConfirmFence: Equatable {
    let epoch: Int
    let dataEpoch: Int
    let playSerial: Int

    static let still = PlayConfirmFence(epoch: 0, dataEpoch: 0, playSerial: 0)
}

/// Confirms person-started queue plays, and holds the poller's auto-advance
/// while one is unconfirmed. Thread-safe: requests come from the action
/// queue, observation and the hold from the poller thread, and the
/// confirmation itself runs on whatever `schedule` gives it.
///
/// There is at most ONE current request. Every read is bound to the request
/// (ticket and fence) it was begun for, and is applied only if that request is
/// still current: a read begun before a newer request, even one for the same
/// track, changes nothing (Codex r1, finding 2). Only a `playing` reading of
/// the requested identity confirms; a `paused` one confirms nothing.
///
/// A play whose own identity could not be read (finding 3) can never confirm,
/// so its hold is released on a SAFE NEW BASELINE instead: the first
/// `playing` reading whose identity is readable and differs from the track
/// that was current just before the play (read in the same play script). The
/// previous track, still playing or ending, is never that baseline, so its
/// natural end still cannot advance the new queue. With no current track
/// before the play, any readable `playing` track is new.
final class PlayConfirmer {
    struct Ticket: Equatable { let serial: Int }

    /// How often, and for how long, a request is read. CHOSEN: four reads a
    /// second for up to 1.5 s, the first at once.
    struct Timing: Equatable {
        var interval: TimeInterval = 0.25
        var window: TimeInterval = 1.5
    }

    private struct Request {
        let serial: Int
        let fence: PlayConfirmFence
        /// The play script has returned (confirm was called).
        var scriptDone = false
        var expected: String?
        /// The current track's identity just before the play; nil: none or unreadable.
        var prior: String?
        var held = true
        var confirmed = false
        /// The status post of this request's warning, while it shows.
        var warningID: Int?
    }

    private let read: () -> PlayerIdentityReading?
    private let post: (String) -> Int?
    private let withdraw: (Int) -> Void
    private let fence: () -> PlayConfirmFence
    private let timing: Timing
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let schedule: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var serial = 0
    private var current: Request?

    /// `read` is one confirmation read; `post` shows the warning and returns
    /// its status id, which `withdraw` takes back when the same request is
    /// confirmed late. The clock, the sleep and the scheduler are injected so
    /// a test runs the window without waiting it out; production sleeps on a
    /// global queue.
    init(read: @escaping () -> PlayerIdentityReading?,
         post: @escaping (String) -> Int?,
         withdraw: @escaping (Int) -> Void = { _ in },
         fence: @escaping () -> PlayConfirmFence = { .still },
         timing: Timing = Timing(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         schedule: @escaping (@escaping () -> Void) -> Void = {
             DispatchQueue.global(qos: .userInitiated).async(execute: $0)
         }) {
        self.read = read
        self.post = post
        self.withdraw = withdraw
        self.fence = fence
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.schedule = schedule
    }

    /// The fence as it stands now, for a caller that must take it before
    /// entering its own lock (`AppQueueStore.setRequested`).
    func fenceNow() -> PlayConfirmFence { fence() }

    /// A person-started play is about to run its script: it replaces every
    /// earlier request, and holds auto-advance from now. `AppQueueStore`
    /// calls this under its own lock, in the same step that installs or
    /// moves the queue, so the poller never sees the queue without its hold.
    func request(fence stamp: PlayConfirmFence? = nil) -> Ticket {
        let stamp = stamp ?? fence()
        lock.lock(); defer { lock.unlock() }
        serial += 1
        current = Request(serial: serial, fence: stamp)
        return Ticket(serial: serial)
    }

    /// The play's script errored: nothing was accepted, so nothing is held for
    /// it. Today's error handling follows, unchanged.
    func abandon(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        if current?.serial == ticket.serial { current = nil }
    }

    /// The play's script exited cleanly, for the track `expected` (its
    /// persistent ID; nil when it could not be read, which can never confirm),
    /// with `prior` current just before it. `notice` follows the warning
    /// (what else the play already said, such as tracks left out). Returns at
    /// once; the reads run on `schedule`.
    func confirm(_ ticket: Ticket, expected: String?, prior: String? = nil, title: String,
                 notice: String? = nil) {
        let expectedID = Self.identity(expected)
        lock.lock()
        guard ticket.serial == serial, var r = current, r.serial == ticket.serial else { lock.unlock(); return }
        r.scriptDone = true
        r.expected = expectedID
        r.prior = Self.identity(prior)
        current = r
        let stamp = r.fence
        lock.unlock()
        let text = [playNotStartedWarning(title), notice].compactMap { $0 }.joined(separator: " ")
        schedule { [self] in self.runWindow(ticket, fence: stamp, text: text) }
    }

    /// A pause, skip, play or switch the person made: every earlier request is
    /// superseded. Its late result drops silently and its hold goes.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        serial += 1
        current = nil
    }

    /// True while the current request holds and nothing has replaced it: the
    /// poller must not auto-advance its queue.
    var holdsAutoAdvance: Bool { heldRequest() != nil }

    /// The poller's look while the hold is on: one read, applied only to the
    /// request it was begun for. Reads nothing when not holding.
    func observeCurrentTrack() {
        guard let (ticket, stamp) = heldRequest() else { return }
        _ = apply(read(), ticket: ticket, fence: stamp)
    }

    private static func identity(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !t.isEmpty else { return nil }
        return t
    }

    /// The current request's ticket and fence while it holds; a fence that
    /// moved retires it.
    private func heldRequest() -> (Ticket, PlayConfirmFence)? {
        let stamp = fence()
        lock.lock(); defer { lock.unlock() }
        guard let r = current else { return nil }
        guard r.fence == stamp else { current = nil; return nil }
        return r.held ? (Ticket(serial: r.serial), r.fence) : nil
    }

    /// Applies one reading begun for `ticket` under `stamp`. True once that
    /// request is confirmed.
    private func apply(_ reading: PlayerIdentityReading?, ticket: Ticket, fence stamp: PlayConfirmFence) -> Bool {
        let fenceNow = fence()
        lock.lock(); defer { lock.unlock() }
        guard var r = current, r.serial == ticket.serial, r.fence == stamp, fenceNow == stamp else { return false }
        if r.confirmed { return true }
        guard r.scriptDone, let reading, reading.state == "playing",
              let pid = Self.identity(reading.persistentID) else { return false }
        if let expected = r.expected {
            guard pid == expected else { return false }
            r.confirmed = true
            r.held = false
            if let id = r.warningID { withdraw(id); r.warningID = nil }
            current = r
            return true
        }
        // No identity to confirm against: release only on a safe new baseline.
        if pid != r.prior { r.held = false; current = r }
        return false
    }

    private func runWindow(_ ticket: Ticket, fence stamp: PlayConfirmFence, text: String) {
        let start = now()
        while true {
            lock.lock(); let latest = ticket.serial == serial; lock.unlock()
            guard latest else { return }
            if apply(read(), ticket: ticket, fence: stamp) { return }
            if now().timeIntervalSince(start) + timing.interval > timing.window + 1e-9 { break }
            sleep(timing.interval)
        }
        let fenceNow = fence()
        // Decided and posted under the lock, bound to the request still being
        // current and unconfirmed: a confirmation, pause or play that lands
        // now either comes first (and this drops) or after (and withdraws or
        // replaces this).
        lock.lock(); defer { lock.unlock() }
        guard var r = current, r.serial == ticket.serial, r.fence == stamp, fenceNow == stamp,
              !r.confirmed else { return }
        r.warningID = post(text)
        current = r
    }
}

/// What a Library album or artist play says beside the warning when only
/// some of its tracks could be queued, so the warning never erases it (Codex
/// r1, UX), or nil when every matched track was queued. CHOSEN wording: the
/// shipped "Playing N of M" would contradict the warning.
func partialAvailabilityNotice(queued: Int, matched: Int) -> String? {
    matched > queued ? "\(queued) of \(matched) are queued \u{2014} the rest aren't available yet." : nil
}

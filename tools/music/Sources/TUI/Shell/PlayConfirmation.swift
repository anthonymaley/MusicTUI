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
//   that failed): `playNotStartedWarning` replaces the footer line. The
//   queue is kept. A script that ERRORED is not this case at all: it keeps
//   today's behaviour (rollback, "Couldn't play").
// - While a request is unconfirmed the poller does not auto-advance the new
//   queue off the previous track's natural end, until the requested track has
//   been seen or a later request replaces it.
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

/// The footer line for a play Music accepted but has not started. CHOSEN
/// wording (Anthony, 2026-11-01).
func playNotStartedWarning(_ title: String) -> String {
    "Play was requested, but Music hasn't started '\(title)' yet. If nothing plays, quitting and reopening Music fixed this before."
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
final class PlayConfirmer {
    struct Ticket: Equatable { let serial: Int }

    /// How often, and for how long, a request is read. CHOSEN: four reads a
    /// second for up to 1.5 s, the first at once.
    struct Timing: Equatable {
        var interval: TimeInterval = 0.25
        var window: TimeInterval = 1.5
    }

    private struct Pending {
        let serial: Int
        let fence: PlayConfirmFence
        var expected: String?
    }

    private let read: () -> PlayerIdentityReading?
    private let post: (String) -> Void
    private let fence: () -> PlayConfirmFence
    private let timing: Timing
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let schedule: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var serial = 0
    /// The latest request until its track has been seen (or it is replaced).
    private var pending: Pending?

    /// `read` is one confirmation read; `post` shows the warning. The clock,
    /// the sleep and the scheduler are injected so a test runs the window
    /// without waiting it out; production sleeps on a global queue.
    init(read: @escaping () -> PlayerIdentityReading?,
         post: @escaping (String) -> Void,
         fence: @escaping () -> PlayConfirmFence = { .still },
         timing: Timing = Timing(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         schedule: @escaping (@escaping () -> Void) -> Void = {
             DispatchQueue.global(qos: .userInitiated).async(execute: $0)
         }) {
        self.read = read
        self.post = post
        self.fence = fence
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.schedule = schedule
    }

    /// A person-started play is about to run its script: it replaces every
    /// earlier request, and holds auto-advance from now (its queue is already
    /// set). Called inside the play, after the routing admission.
    func request() -> Ticket {
        let stamp = fence()
        lock.lock(); defer { lock.unlock() }
        serial += 1
        pending = Pending(serial: serial, fence: stamp, expected: nil)
        return Ticket(serial: serial)
    }

    /// The play's script errored: nothing was accepted, so nothing is held for
    /// it. Today's error handling follows, unchanged.
    func abandon(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        if pending?.serial == ticket.serial { pending = nil }
    }

    /// The play's script exited cleanly, for the track `expected` (its
    /// persistent ID; nil when it could not be read, which can never confirm).
    /// Returns at once; the reads run on `schedule`.
    func confirm(_ ticket: Ticket, expected: String?, title: String) {
        let expectedID = expected.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        lock.lock()
        guard ticket.serial == serial, var p = pending, p.serial == ticket.serial else { lock.unlock(); return }
        p.expected = expectedID
        pending = p
        lock.unlock()
        schedule { [self] in self.runWindow(ticket, expected: expectedID, title: title, fence: p.fence) }
    }

    /// A pause, skip, play or switch the person made: every earlier request is
    /// superseded. Its late result drops silently and its hold goes.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        serial += 1
        pending = nil
    }

    /// True while the latest request's track has not been seen and nothing
    /// has replaced it: the poller must not auto-advance its queue.
    var holdsAutoAdvance: Bool {
        let stamp = fence()
        lock.lock(); defer { lock.unlock() }
        guard let p = pending else { return false }
        guard p.fence == stamp else { pending = nil; return false }
        return true
    }

    /// The poller's look while the hold is on: one read, and the hold goes once
    /// the current track is the requested one. Reads nothing when not holding.
    func observeCurrentTrack() {
        guard holdsAutoAdvance else { return }
        observe(currentPersistentID: read()?.persistentID)
    }

    /// The requested track has been seen as Music's current track: the hold
    /// goes. Any other identity, or none, keeps it.
    func observe(currentPersistentID: String?) {
        guard let pid = currentPersistentID?.uppercased(), !pid.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let p = pending, p.expected == pid { pending = nil }
    }

    private func isLatest(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket.serial == serial
    }

    private func runWindow(_ ticket: Ticket, expected: String?, title: String, fence stamp: PlayConfirmFence) {
        let start = now()
        while true {
            guard isLatest(ticket) else { return }
            let reading = read()
            if let expected, let pid = reading?.persistentID?.uppercased(), pid == expected {
                observe(currentPersistentID: pid)
                if reading?.state == "playing" { return }
            }
            if now().timeIntervalSince(start) + timing.interval > timing.window + 1e-9 { break }
            sleep(timing.interval)
        }
        let fenceNow = fence()
        // Decided and posted under the lock, so a pause or play that lands now
        // either comes first (and this drops) or after (and replaces this).
        lock.lock(); defer { lock.unlock() }
        guard ticket.serial == serial, fenceNow == stamp else { return }
        post(playNotStartedWarning(title))
    }
}

// tools/music/Sources/TUI/Shell/QueueResume.swift
//
// Queue resume-across-restart. SAVE is wired into PlaybackPoller.syncQueuePersistence
// (the one choke point that sees every queue mutation); RESTORE is wired into
// Shell.runShell() via restoreQueueOnLaunch, called once before poller.start().
//
// Restore is v2-lite since 2026-08-31: it adopts when the playing track is the
// saved current track OR within `queueResumeForwardScan` positions after it, so
// a track ending during the quit-relaunch gap no longer discards the queue. The
// forward half matches on name+artist alone and discards on ambiguity; see
// `resumePosition` for why that asymmetry exists and why it is the safe side.
import Foundation

/// The on-disk shape of a saved queue: the whole in-memory `AppQueue`, verbatim,
/// plus an **anchor** — the identity of the track that was current when saved.
/// The anchor is what `queueMatches` uses on restore to decide adopt-vs-discard;
/// it's kept separate from `AppQueue` itself because a persistent ID (and the
/// save-time name/artist fallback) has no meaning to the in-memory queue, only to
/// the restore guard.
struct PersistedQueue: Codable, Equatable {
    let queue: AppQueue
    /// Apple's stable id (`persistent id of current track`) for the track that
    /// was current at save time. Can be nil when unreadable (the macOS 26 -1728
    /// bug on streamed tracks; album/playlist tracks are library tracks so this
    /// normally reads fine) — name+artist below is always stored as a fallback.
    let anchorPersistentID: String?
    let anchorName: String
    let anchorArtist: String

    /// The saved queue, ready to hand to `AppQueueStore.set`.
    func toAppQueue() -> AppQueue { queue }
}

/// Case/whitespace-insensitive identity compare for the name+artist fallback.
/// Trims outer whitespace and collapses internal runs so "A  Tribe  Called Quest"
/// matches "a tribe called quest".
private func namesMatch(_ a: String, _ b: String) -> Bool {
    func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    return normalize(a) == normalize(b)
}

/// Does the currently-playing track match the saved queue's current entry?
///
/// Two identity sources are reconciled here: `saved.anchorPersistentID` (captured
/// at save time, lives only on `PersistedQueue`) is authoritative for the
/// persistent-ID check; `saved.queue.tracks[currentIndex - 1]` — the saved
/// queue's own record of its current track — supplies the name+artist fallback,
/// since `TrackListEntry` carries no persistent ID of its own. Persistent ID wins
/// whenever BOTH sides have one, even if names happen to match (two different
/// occurrences of the same title must not be treated as the same track — the mpv
/// index-keyed-resume lesson). Otherwise falls back to name+artist. Pure — no I/O.
func queueMatches(playingPersistentID: String?, playingName: String, playingArtist: String,
                   saved: PersistedQueue) -> Bool {
    let q = saved.queue
    guard q.currentIndex >= 1, q.currentIndex <= q.tracks.count else { return false }
    let savedCurrent = q.tracks[q.currentIndex - 1]

    if let playingID = playingPersistentID, let savedID = saved.anchorPersistentID {
        return playingID == savedID
    }

    return namesMatch(playingName, savedCurrent.name) && namesMatch(playingArtist, savedCurrent.artist)
}

/// Persists the app-owned queue to `~/.config/music/queue.json`, mirroring
/// `StationStore`'s pattern: injectable path for tests, atomic write,
/// create-dir-if-needed, corrupt/missing file reads as absent rather than error.
///
/// No in-memory cache (unlike `StationStore`, which serves many reads/writes per
/// session for a UI list). `QueueStore` is read once at TUI startup and written
/// only at the queue's own mutation points (a handful of times a session) — a
/// disk read each time is cheap here and avoids a cache that could go stale
/// relative to a file another process/instance wrote.
final class QueueStore {
    private let path: String

    init(path: String = NSString(string: "~/.config/music/queue.json").expandingTildeInPath) {
        self.path = path
    }

    func save(_ q: PersistedQueue) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(q)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Absent or corrupt file reads as nil — resume is a convenience, never a
    /// reason to error at the user.
    func load() -> PersistedQueue? {
        guard let data = FileManager.default.contents(atPath: path),
              let q = try? JSONDecoder().decode(PersistedQueue.self, from: data)
        else { return nil }
        return q
    }

    /// No-op if the file doesn't exist.
    func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - SAVE: pure write-cadence decisions

/// Pure decision: does the poller need to persist `active` to disk given what
/// it last wrote? Full-struct equality (not just currentIndex) catches every
/// kind of mutation — advance, jump, reshuffle, or a wholesale queue
/// replacement — without bespoke per-field tracking. No active queue never
/// triggers a save (see `queueShouldClear` for that side). Pure — no I/O.
func queueShouldSave(active: AppQueue?, lastWritten: AppQueue?) -> Bool {
    guard let active else { return false }
    return active != lastWritten
}

/// Pure decision: does the poller need to clear the on-disk queue? True only
/// once the queue has gone inactive AND `lastWritten` shows this poller
/// actually wrote something this session — avoids a `removeItem` call every
/// idle tick once the file is already gone (or was never written). Pure — no I/O.
func queueShouldClear(active: AppQueue?, lastWritten: AppQueue?) -> Bool {
    active == nil && lastWritten != nil
}

/// Read `persistent id of current track`, failure-tolerant: any AppleScript
/// throw — including the macOS 26 `-1728` bug on streamed/non-library tracks
/// (Apple FB19908171) — returns nil rather than surfacing an error. Called
/// once at save time and once at startup restore; never per poll tick.
func currentTrackPersistentID(backend: AppleScriptBackend) -> String? {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            try
                return persistent id of current track
            end try
            return ""
        """)
    }) else { return nil }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - RESTORE: pure adopt/discard decision + startup wiring

/// The three outcomes of a startup restore attempt, kept separate from the
/// I/O that produces its inputs (`queueStore.load()`, one live poll) so the
/// adopt-vs-discard-vs-do-nothing decision itself is pure and testable.
enum QueueRestoreDecision: Equatable {
    case adopt(AppQueue)
    case discard
    case doNothing
}

/// How far past the saved current position a restore will look.
///
/// Three is a SAFETY bound, not a cost one. Identity at forward positions is
/// name+artist only, because `TrackListEntry` carries no persistent ID, so a
/// wider window raises the chance of a duplicate collision the scan cannot
/// resolve and must therefore discard on. Widening this without giving entries
/// a persistent ID trades a rare recovered queue for a rarer wrong one.
let queueResumeForwardScan = 3

/// Where the playing track actually sits in the saved queue, if that can be
/// said unambiguously. Returns a 1-based position in `saved.queue.tracks` — an
/// index into the PLAY ORDER, not a source-playlist position. The source
/// position for `play track N of playlist X` is that entry's own `.index`, and
/// the two differ once a queue is shuffled.
///
/// v1 adopted only when the playing track was still the saved current track, so
/// a single track ending during the quit-relaunch gap discarded the queue. This
/// keeps that check first and unchanged — the persistent ID is authoritative at
/// `currentIndex` — and only then looks ahead.
///
/// The forward scan is deliberately weaker than the check it extends, and this
/// is the crux of v2-lite: forward entries have no persistent ID to compare, so
/// they match on name+artist alone. **Ambiguity therefore discards.** If more
/// than one position in the window matches, returning any of them risks putting
/// `currentSourcePosition` on the wrong entry, and the next auto-advance would
/// play the wrong song. Losing the queue is the cheaper failure. Ambiguity is
/// the name+artist PAIR, never the title alone — a compilation repeating a title
/// under different artists stays resolvable.
///
/// Backward movement is out of scope: a queue that went back discards, as it
/// did in v1. Pure — no I/O.
func resumePosition(playingPersistentID: String?, playingName: String, playingArtist: String,
                    saved: PersistedQueue) -> Int? {
    let q = saved.queue
    guard q.currentIndex >= 1, q.currentIndex <= q.tracks.count else { return nil }

    // v1 semantics, untouched: ID wins here when both sides have one.
    if queueMatches(playingPersistentID: playingPersistentID, playingName: playingName,
                    playingArtist: playingArtist, saved: saved) {
        return q.currentIndex
    }

    var candidates: [Int] = []
    for offset in 1...queueResumeForwardScan {
        let pos = q.currentIndex + offset
        guard pos <= q.tracks.count else { break }
        let e = q.tracks[pos - 1]
        if namesMatch(playingName, e.name) && namesMatch(playingArtist, e.artist) {
            candidates.append(pos)
        }
    }
    return candidates.count == 1 ? candidates[0] : nil
}

/// Pure: given what was saved and one live read of the playing track, decide
/// whether to adopt the saved queue, discard it, or do nothing (nothing was
/// saved to begin with). A stopped player always discards — there's nothing
/// to resume onto — before any matching is consulted. Otherwise `resumePosition`
/// decides where in the saved queue the playing track is, and the adopted queue
/// carries that as its `currentIndex`; everything else is the saved queue
/// verbatim. Pure — no I/O.
func decideQueueRestore(saved: PersistedQueue?, playerStopped: Bool,
                         playingPersistentID: String?, playingName: String,
                         playingArtist: String) -> QueueRestoreDecision {
    guard let saved else { return .doNothing }
    if playerStopped { return .discard }
    guard let pos = resumePosition(playingPersistentID: playingPersistentID,
                                   playingName: playingName, playingArtist: playingArtist,
                                   saved: saved) else { return .discard }
    // Only the index moves; the play order and its source positions are the
    // saved queue's, verbatim.
    var q = saved.queue
    q.currentIndex = pos
    return .adopt(q)
}

/// Startup restore, called once from `runShell()` before `poller.start()`.
/// After this call returns, only the poller ever touches `queueStore` (see
/// `PlaybackPoller.syncQueuePersistence`) — no concurrent access, no lock
/// needed. Never re-issues `play`: the audio is already sounding at its real
/// position, adopting the queue only re-attaches the driver.
func restoreQueueOnLaunch(queueStore: QueueStore, appQueue: AppQueueStore, backend: AppleScriptBackend) {
    guard let saved = queueStore.load() else { return }
    switch pollNowPlaying(backend: backend) {
    case .stopped:
        if decideQueueRestore(saved: saved, playerStopped: true, playingPersistentID: nil,
                               playingName: "", playingArtist: "") == .discard {
            queueStore.clear()
        }
    case .active(let np):
        let anchorID = currentTrackPersistentID(backend: backend)
        switch decideQueueRestore(saved: saved, playerStopped: false, playingPersistentID: anchorID,
                                   playingName: np.track, playingArtist: np.artist) {
        case .adopt(let q): appQueue.set(q)
        case .discard: queueStore.clear()
        case .doNothing: break
        }
    case .unavailable:
        // Can't determine reality (e.g. Music not yet responding at a cold
        // launch) — never guess. Leave the file for the next launch to try.
        break
    }
}

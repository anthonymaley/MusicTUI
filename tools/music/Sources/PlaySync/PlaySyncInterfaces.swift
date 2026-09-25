// tools/music/Sources/PlaySync/PlaySyncInterfaces.swift
import Foundation

// The shared vocabulary of play-count write-back: recording library songs that
// Bridge played to the end in Music.app's `played count` and `played date`.
//
// These shapes are FROZEN. The feed client, the journal and engine, the
// Music.app writer, `music sync-plays` and the TUI worker are built against
// them in parallel; a change here is a change to all five.

// MARK: - The feed: finished plays as Bridge reports them

/// One library song Bridge played to the end.
struct CompletedPlayRecord: Equatable {
    /// Position in the play record `CompletedPlaysPage.ledgerID` names.
    let seq: Int
    /// The play's own identity, stable however many times it is delivered.
    let playID: String
    /// Music.app's persistent ID as a signed decimal, when Bridge has one.
    let alias: String?
    let libraryID: String?
    let title: String
    let artist: String
    /// When the end of the song was observed.
    let completedAt: Date
    let end: String?
}

/// One page of finished plays, oldest first.
struct CompletedPlaysPage: Equatable {
    let ledgerID: String
    let latestSeq: Int
    /// The cursor to ask from next: the last play returned, or the request's
    /// `after` when the page is empty.
    let nextAfter: Int
    let more: Bool
    let plays: [CompletedPlayRecord]
}

protocol CompletedPlaysReading {
    /// Plays after `after` in the record `ledgerID` names (nil: no cursor yet).
    /// Throws `SourceAppError`; `.ledgerChanged` means the cursor belongs to a
    /// record that no longer exists and the caller starts again from nil and 0.
    func completedPlays(ledgerID: String?, after: Int, limit: Int) throws -> CompletedPlaysPage
}

// MARK: - The writer: Music.app, never launched

/// A track's play count and last-played date. `date` is whole epoch seconds;
/// nil means never played.
struct TrackPlayState: Equatable, Codable {
    let count: Int
    let date: Int?
}

/// One running Music.app process. The start time makes the identity immune to
/// pid reuse: when the process that received a write has gone, nothing that
/// write sent can still take effect.
struct MusicProcess: Codable, Equatable {
    let pid: Int32
    let startedAt: Double

    enum CodingKeys: String, CodingKey {
        case pid
        case startedAt = "started_at"
    }
}

enum TrackLookup: Equatable {
    case found(TrackPlayState)
    case notFound(libraryTrackCount: Int)
    case ambiguous(matches: Int)
}

enum MusicAccessError: Error, Equatable {
    case notRunning
    case timedOut
    case failed(String)
}

/// What a write did. Only `notSent` means nothing was submitted: once a set
/// call has been made, any result that was not read back is `unknown` or
/// `countAppliedDateUnknown`, whatever the error said.
enum WriteOutcome: Equatable {
    /// Every set call returned; the readback is this state.
    case applied(TrackPlayState)
    /// No set call was made. `current` is what was seen instead, if anything.
    case notSent(current: TrackPlayState?, reason: String)
    /// The count set returned; the date set is unconfirmed.
    case countAppliedDateUnknown(String)
    /// A set call was made and is unconfirmed.
    case unknown(String)
}

protocol PlayCountWriting {
    /// A fresh lookup on every call. Never launches Music.app.
    func musicProcess() -> MusicProcess?
    /// Throws `MusicAccessError`.
    func read(_ process: MusicProcess, persistentID: String) throws -> TrackLookup
    func write(_ process: MusicProcess, persistentID: String,
               expect: TrackPlayState, target: TrackPlayState) -> WriteOutcome
    func writeDate(_ process: MusicProcess, persistentID: String,
                   expect: TrackPlayState, date: Int) -> WriteOutcome
}

// MARK: - The journal's values

enum EntryState: String, Codable {
    case pending, writing, unresolved, done, unmatched, conflict
}

enum WritePhase: String, Codable {
    case countAndDate = "count_and_date"
    case dateOnly = "date_only"
}

/// A write that was begun: which phase, which Music.app process received it,
/// and when (epoch seconds).
struct WriteAttempt: Codable, Equatable {
    let phase: WritePhase
    let process: MusicProcess
    let startedAt: Int

    enum CodingKeys: String, CodingKey {
        case phase, process
        case startedAt = "started_at"
    }
}

/// One finished play, from capture until it is recorded or set aside.
struct PlaySyncEntry: Codable, Equatable {
    let ledgerID: String
    let seq: Int
    let playID: String
    let alias: String?
    /// Music.app's persistent ID, sixteen uppercase hex digits.
    let persistentID: String?
    let title: String
    let artist: String
    /// Epoch seconds, floored.
    let completedAt: Int
    var state: EntryState
    /// `countAndDate` until the count is confirmed applied; then `dateOnly`.
    var phase: WritePhase
    /// The absolute values the plan was made from.
    var before: TrackPlayState?
    /// The absolute target. Never recomputed while an attempt may be outstanding.
    var target: TrackPlayState?
    /// Present while `writing` or `unresolved`.
    var attempt: WriteAttempt?
    /// The last observation, for reports.
    var observed: TrackPlayState?
    /// Re-plans allowed because the Music.app process that received a write
    /// has exited (at most 3).
    var barrierReplans: Int
    /// no_alias | bad_alias | not_found | ambiguous | changed | superseded | …
    var reason: String?
    /// Done because the target was observed, not because our write was confirmed.
    var reconciled: Bool
    /// Set by the engine, under the lock, when first returned as a new problem.
    var reported: Bool

    enum CodingKeys: String, CodingKey {
        case ledgerID = "ledger_id"
        case seq
        case playID = "play_id"
        case alias
        case persistentID = "pid_hex"
        case title, artist
        case completedAt = "completed_at"
        case state, phase, before, target, attempt, observed
        case barrierReplans = "barrier_replans"
        case reason, reconciled, reported
    }
}

// MARK: - The run

enum PlaySyncTrigger {
    /// The TUI's worker: skips when another sync holds the lock.
    case background
    /// `music sync-plays`: waits a bounded time for the lock.
    case explicit
}

enum PlaySyncBlock: Equatable {
    case lockBusy
    case journalUnreadable(path: String)
    case journalTooNew
    case directoryUnsafe(path: String)
}

enum PlaySyncFetchStatus: Equatable {
    case ok(newPlays: Int)
    case bridgeNotRunning
    case bridgeTooOld
    case ledgerReplaced
    case failed(String)
    case skipped
}

struct PlaySyncResult: Equatable {
    var blocked: PlaySyncBlock?
    var fetch: PlaySyncFetchStatus
    var musicRunning: Bool
    /// Recorded this pass, including those done by observation.
    var recorded: [PlaySyncEntry]
    /// Problems not reported before; each is returned here once.
    var newProblems: [PlaySyncEntry]
    /// Every entry left unmatched or in conflict.
    var outstanding: [PlaySyncEntry]
    /// Every write Music.app has not confirmed yet.
    var unconfirmed: [PlaySyncEntry]
    /// Plays still waiting, including those held behind an unconfirmed write.
    var waiting: Int
}

/// The only way anything outside the engine touches play sync. Every journal
/// read and write, reporting included, happens inside `pass`, under the lock.
protocol PlaySyncRunning {
    func pass(_ trigger: PlaySyncTrigger) -> PlaySyncResult
}

// MARK: - The files

/// Where play sync keeps its journal and lock. Tests always pass a temporary
/// directory; only the command and the TUI use `.live`.
struct PlaySyncPaths: Equatable {
    let directory: URL
    var journal: URL { directory.appendingPathComponent("journal.json") }
    var lock: URL { directory.appendingPathComponent("lock") }
    static var live: PlaySyncPaths {
        PlaySyncPaths(directory: URL(fileURLWithPath: NSHomeDirectory() + "/.config/music/playsync"))
    }
}

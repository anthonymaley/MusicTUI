// tools/music/Sources/Commands/SyncPlaysCommand.swift
import ArgumentParser
import Foundation

/// `music sync-plays`: record library songs Bridge played to the end in
/// Music.app's play counts, now, and say what happened.
///
/// It runs whichever output is selected, and it never launches Music.app: when
/// Music.app is not running the plays stay waiting and the command says so.
struct SyncPlays: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-plays",
        abstract: "Record library songs Bridge played to the end in Music.app's play counts.")

    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let engine = PlaySyncEngine(
            paths: .live,
            // The same control connection `SourceAppClient().control` holds,
            // typed as the feed so it can never silently be missing.
            feed: SourceAppControl(),
            writer: MusicPlayCountWriter(),
            inspector: ProcMusicInstanceInspector())
        let out = Self.perform(engine, json: json)
        print(out.text)
        if out.exit != 0 { throw ExitCode(out.exit) }
    }

    /// One explicit pass, rendered. Separate from `run` so the pass can be a
    /// stand-in.
    static func perform(_ runner: PlaySyncRunning, json: Bool) -> (text: String, exit: Int32) {
        renderSyncPlays(runner.pass(.explicit), json: json)
    }
}

// MARK: - Sentences, defined once

enum SyncPlaysSentence {
    static func recorded(_ n: Int) -> String {
        n == 1 ? "Recorded 1 library play in Music.app."
               : "Recorded \(n) library plays in Music.app."
    }
    static let nothingNew = "Nothing new to record."
    static func musicNotRunning(waiting n: Int) -> String {
        (n == 1 ? "1 play waiting" : "\(n) plays waiting")
            + ": Music.app is not running. Open Music.app and run music sync-plays again."
    }
    /// Why Music.app, found running, could not be read or written. Shared
    /// with the TUI's status line.
    static func musicAccessCause(_ error: MusicAccessError) -> String {
        switch error {
        case .notRunning: return "Music.app quit while plays were being recorded"
        case .timedOut: return "Music.app did not answer in time"
        case .failed(let detail):
            if detail == MusicAccessSentence.libraryNotLoaded {
                return "Music.app's library hasn't finished loading"
            }
            if detail == MusicAccessSentence.noMatch {
                return "the track could not be found in Music.app when it came time to write"
            }
            var trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return "Music.app could not be accessed (\(trimmed))"
        }
    }
    /// `1 play waiting: <cause>. <next step>`; with nothing waiting (only
    /// unconfirmed writes), the cause alone.
    static func musicAccessFailed(_ error: MusicAccessError, waiting n: Int) -> String {
        let prefix = n == 0 ? "" : (n == 1 ? "1 play waiting: " : "\(n) plays waiting: ")
        let next = error == .notRunning ? "Open Music.app and run music sync-plays again."
                                        : "Run music sync-plays again."
        return prefix + musicAccessCause(error) + ". " + next
    }
    static func unconfirmedHeader(_ n: Int) -> String { "Waiting for Music.app to confirm (\(n)):" }
    static let unconfirmedFooter = "  These, and later plays of the same songs, are checked again on every sync."
    static let bridgeNotRunning = "Bridge is not running, so no new plays could be read."
    static let bridgeTooOld = "Bridge is older than this MusicTUI and does not record plays — update Bridge."
    static let ledgerReplaced = "Bridge's play record was replaced; plays it held before could not all be read."
    static func fetchFailed(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = trimmed.hasSuffix(".") ? trimmed : trimmed + "."
        return "No new plays could be read: \(ended)"
    }
    static let lockBusy = "Another sync is running; try again in a moment."
    static func journalUnreadable(_ path: String) -> String {
        "The play-sync journal at \(path) could not be read; nothing was changed. "
            + "Keep this file: it is what stops plays being counted twice."
    }
    /// The journal could not be saved part-way through a pass. Music.app may
    /// already have been written to, so this never says nothing was changed.
    static func journalNotSaved(_ path: String) -> String {
        "The play-sync journal at \(path) could not be saved, so the sync stopped; "
            + "nothing more was changed. Keep this file: it is what stops plays being counted twice."
    }
    static let journalTooNew = "The play-sync journal was written by a newer MusicTUI; nothing was changed. "
        + "Update MusicTUI to sync plays."
    static func directoryUnsafe(_ path: String) -> String {
        "The play-sync folder \(path) is not private (owner and mode 700 required); nothing was changed."
    }
    static func notRecordedHeader(_ n: Int) -> String { "Not recorded (\(n)):" }

    /// Why a play was set aside, by its state and reason.
    static func why(_ entry: PlaySyncEntry) -> String {
        if entry.state == .conflict { return "Music.app's play count changed during the write; left as it was" }
        switch entry.reason {
        case "no_alias", "bad_alias": return "Bridge could not identify it in Music.app"
        case "not_found": return "not in your Music.app library"
        case "ambiguous": return "matches more than one Music.app track"
        case "conflict": return "Music.app's play count changed during the write; left as it was"
        default: return "could not be recorded"
        }
    }
}

// MARK: - Rendering

/// The whole output of `music sync-plays` for one pass, and its exit status.
///
/// Exit 1 when the pass was blocked, when Music.app was not running while
/// plays wait, when Music.app was running but could not be read or written,
/// or when new plays could not be read from Bridge. Unconfirmed and set-aside
/// plays never change the exit status on their own.
func renderSyncPlays(_ result: PlaySyncResult, json: Bool) -> (text: String, exit: Int32) {
    typealias S = SyncPlaysSentence
    var lines: [String] = []
    var failure: String?

    func track(_ entry: PlaySyncEntry) -> String { "  \(entry.title) — \(entry.artist)" }

    if !result.recorded.isEmpty {
        lines.append(S.recorded(result.recorded.count))
        lines += result.recorded.map(track)
    }

    if let block = result.blocked {
        let sentence: String
        switch block {
        case .lockBusy:
            sentence = S.lockBusy
        case .journalUnreadable(let path):
            // The same block is returned when the journal could not be read at
            // the start and when it could not be saved later in the pass. Only
            // a pass that got past the start has a fetch status or reached
            // Music.app; before any set call Music.app has been found running.
            let passHadStarted = result.fetch != .skipped || result.musicRunning || !result.recorded.isEmpty
            sentence = passHadStarted ? S.journalNotSaved(path) : S.journalUnreadable(path)
        case .journalTooNew:
            sentence = S.journalTooNew
        case .directoryUnsafe(let path):
            sentence = S.directoryUnsafe(path)
        }
        lines.append(sentence)
        failure = sentence
    } else {
        var notices: [String] = []
        switch result.fetch {
        case .ok, .skipped:
            break
        case .bridgeNotRunning:
            notices.append(S.bridgeNotRunning); failure = failure ?? S.bridgeNotRunning
        case .bridgeTooOld:
            notices.append(S.bridgeTooOld); failure = failure ?? S.bridgeTooOld
        case .ledgerReplaced:
            notices.append(S.ledgerReplaced)
        case .failed(let detail):
            let sentence = S.fetchFailed(detail)
            notices.append(sentence); failure = failure ?? sentence
        }
        if !result.musicRunning && result.waiting > 0 {
            let sentence = S.musicNotRunning(waiting: result.waiting)
            notices.append(sentence); failure = failure ?? sentence
        }
        if result.musicRunning, let access = result.musicAccess {
            let sentence = S.musicAccessFailed(access, waiting: result.waiting)
            notices.append(sentence); failure = failure ?? sentence
        }
        if result.recorded.isEmpty && notices.isEmpty { lines.append(S.nothingNew) }
        lines += notices

        if !result.unconfirmed.isEmpty {
            lines.append(S.unconfirmedHeader(result.unconfirmed.count))
            lines += result.unconfirmed.map(track)
            lines.append(S.unconfirmedFooter)
        }
        if !result.outstanding.isEmpty {
            lines.append(S.notRecordedHeader(result.outstanding.count))
            lines += result.outstanding.map { "  \($0.title) — \($0.artist): \(S.why($0))" }
        }
    }

    let exit: Int32 = failure == nil ? 0 : 1
    guard json else { return (lines.joined(separator: "\n"), exit) }

    let bridge: Any
    switch result.fetch {
    case .ok: bridge = "ok"
    case .bridgeNotRunning: bridge = "not_running"
    case .bridgeTooOld: bridge = "too_old"
    case .ledgerReplaced: bridge = "replaced"
    case .failed: bridge = "failed"
    case .skipped: bridge = NSNull()   // the pass never asked Bridge
    }
    let body: [String: Any] = [
        "ok": exit == 0,
        "recorded": result.recorded.map {
            ["title": $0.title, "artist": $0.artist, "completed_at": $0.completedAt] as [String: Any]
        },
        "waiting": result.waiting,
        "unconfirmed": result.unconfirmed.map { ["title": $0.title, "artist": $0.artist] },
        "music_running": result.musicRunning,
        "bridge": bridge,
        "problems": result.outstanding.map {
            ["title": $0.title, "artist": $0.artist, "state": $0.state.rawValue,
             "reason": $0.reason ?? ($0.state == .conflict ? "conflict" : "")] as [String: Any]
        },
        "error": failure.map { $0 as Any } ?? NSNull(),
    ]
    return (OutputFormat(mode: .json).render(body), exit)
}

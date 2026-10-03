// tools/music/Sources/TUI/DiscoverCopyWatcher.swift
//
// Discover "play from here" on Apple's own copy: when listening has ended, and
// the one place a copy is deleted from his library (score step C5).
//
// Deleting a playlist that is playing stops his music, and deleting one he
// added himself destroys something of his. So:
//   - an end needs two readable observations of the same kind at least
//     `DiscoverCopyTiming.endEvidenceGap` apart; one bad read never counts;
//   - the watcher never deletes, it only says "ended" once;
//   - the delete is by persistent ID only, only for a journal entry that is
//     `owned` or `listening`, and the script re-checks, at the moment it runs,
//     that the copy is not the current playlist of a player that is not stopped.
import Foundation

// MARK: Observation

/// One read of the player: its state as text, and the persistent IDs of the
/// current playlist and the current track (nil when that read failed).
struct DiscoverCopyPlayerRead: Equatable {
    let state: String
    let playlistID: String?
    let trackID: String?
}

enum DiscoverCopyObservation: Equatable { case inOurCopy, stopped, foreign, unreadable }

/// The player states in which something is loaded: with a readable current
/// playlist these say whether it is ours. Anything else that is not `stopped`
/// is an unreadable state.
private let discoverCopyLoadedStates: Set<String> = ["playing", "paused", "fast forwarding", "rewinding"]

/// nil read, or an unreadable state -> `.unreadable`. State `stopped` ->
/// `.stopped`. Playlist readable and = hex (any track) -> `.inOurCopy`.
/// Playlist readable and != hex -> `.foreign`. Playlist unreadable while
/// something is loaded (a station or stream) -> `.unreadable`.
func discoverCopyObservation(_ read: DiscoverCopyPlayerRead?, hex: String) -> DiscoverCopyObservation {
    guard let read else { return .unreadable }
    let state = read.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if state == "stopped" { return .stopped }
    guard discoverCopyLoadedStates.contains(state) else { return .unreadable }
    guard let raw = read.playlistID else { return .unreadable }
    let playlist = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !playlist.isEmpty else { return .unreadable }
    return playlist == hex.uppercased() ? .inOurCopy : .foreign
}

struct DiscoverCopyEndEvidence: Equatable {
    let kind: DiscoverCopyObservation
    let at: Date
}

/// `.inOurCopy` clears the evidence. `.unreadable` changes nothing. `.stopped`
/// or `.foreign`: with no evidence, or evidence of the other kind, record it
/// now; with evidence of the SAME kind at least `endEvidenceGap` old, ended.
func discoverCopyEndStep(evidence: DiscoverCopyEndEvidence?, observation: DiscoverCopyObservation,
                         now: Date) -> (evidence: DiscoverCopyEndEvidence?, ended: Bool) {
    switch observation {
    case .inOurCopy:
        return (nil, false)
    case .unreadable:
        return (evidence, false)
    case .stopped, .foreign:
        guard let evidence, evidence.kind == observation else {
            return (DiscoverCopyEndEvidence(kind: observation, at: now), false)
        }
        let ended = now.timeIntervalSince(evidence.at) >= DiscoverCopyTiming.endEvidenceGap
        return (evidence, ended)
    }
}

// MARK: The watcher's one script per tick

/// AppleScript body (no `tell` wrapper): the player state, the current
/// playlist's persistent ID and the current track's persistent ID, each in its
/// own `try`, joined by `|`. A read that failed leaves its field empty.
let discoverCopyObservationScript = """
set stateText to ""
try
    set stateText to (player state as text)
end try
set playlistText to ""
try
    set playlistText to (persistent ID of current playlist) as text
end try
set trackText to ""
try
    set trackText to (persistent ID of current track) as text
end try
return stateText & "|" & playlistText & "|" & trackText
"""

/// Parses `discoverCopyObservationScript`'s output. nil when the call failed
/// or the output is not three `|`-separated fields; an empty playlist or track
/// field reads as nil.
func discoverCopyPlayerRead(fromScriptOutput output: String?) -> DiscoverCopyPlayerRead? {
    guard let output else { return nil }
    let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard fields.count == 3 else { return nil }
    return DiscoverCopyPlayerRead(state: fields[0],
                                  playlistID: fields[1].isEmpty ? nil : fields[1],
                                  trackID: fields[2].isEmpty ? nil : fields[2])
}

// MARK: The watcher

/// Decides, conservatively, when listening to a copy has ended. It never
/// deletes: on an end it forgets the copy and calls `enqueueEnd` once.
final class DiscoverCopyWatcher {
    struct Seams {
        var read: () -> DiscoverCopyPlayerRead?
        var now: () -> Date
        var enqueueEnd: (_ txn: String) -> Void     // production: onto the shell's action queue
    }

    private struct Watched {
        var hex: String
        var evidence: DiscoverCopyEndEvidence?
    }

    private let seams: Seams
    private let lock = NSLock()
    private var watched: [String: Watched] = [:]

    init(seams: Seams) { self.seams = seams }

    /// Thread-safe. Adopting a watched txn again resets its evidence.
    func adopt(txn: String, hex: String) {
        lock.lock()
        watched[txn] = Watched(hex: hex, evidence: nil)
        lock.unlock()
    }

    /// The poller's 1 s tick. No script when nothing is watched.
    func tick() {
        lock.lock()
        let anything = !watched.isEmpty
        lock.unlock()
        guard anything else { return }

        // The read runs with the lock free: it is an osascript call in production.
        let read = seams.read()
        let now = seams.now()

        var ended: [String] = []
        lock.lock()
        for txn in watched.keys.sorted() {
            guard var entry = watched[txn] else { continue }
            let observation = discoverCopyObservation(read, hex: entry.hex)
            let step = discoverCopyEndStep(evidence: entry.evidence, observation: observation, now: now)
            if step.ended {
                watched[txn] = nil
                ended.append(txn)
            } else {
                entry.evidence = step.evidence
                watched[txn] = entry
            }
        }
        lock.unlock()

        for txn in ended { seams.enqueueEnd(txn) }
    }
}

// MARK: Deletion

/// True for `persistentIDHex`'s shape: sixteen characters of `0-9A-F`.
private func discoverCopyIsPersistentIDHex(_ hex: String) -> Bool {
    hex.utf8.count == 16 && hex.utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
    }
}

/// AppleScript body (no `tell` wrapper) that ends one copy, addressed by
/// persistent ID only: no playlist name appears in it. It answers one word:
///   `gone`    the copy was not in the library before anything was done;
///   `spared`  the player is not stopped and the current playlist is the copy,
///             or could not be read (it could be the copy);
///   `deleted` it was deleted and then read absent      (only when `delete`);
///   `still`   it was deleted and still read present    (only when `delete`);
///   `kept`    nothing was deleted                      (only when not `delete`).
/// An unreadable player state counts as active (`unreadablePlayerStateFallback`).
/// With `delete` false the script holds no `delete` command at all.
func discoverCopyEndScript(hex: String, delete: Bool) -> String {
    let lookup = discoverCopyLookupPreamble(hex: hex)
    let guardLines = """
    \(lookup)
    if pl is missing value then return "gone"
    set stateText to "\(unreadablePlayerStateFallback)"
    try
        set stateText to (player state as text)
    end try
    set currentID to ""
    set currentReadable to false
    try
        set currentID to (persistent ID of current playlist) as text
        set currentReadable to true
    end try
    if currentID is "" then set currentReadable to false
    if currentID is "missing value" then set currentReadable to false
    set playerActive to true
    if stateText is "stopped" then set playerActive to false
    if playerActive and not currentReadable then return "spared"
    if playerActive and currentID is "\(hex)" then return "spared"
    """
    guard delete else {
        return guardLines + "\nreturn \"kept\""
    }
    return """
    \(guardLines)
    delete pl
    \(lookup)
    if pl is missing value then return "deleted"
    return "still"
    """
}

/// The deletion guard of design section 5, for one journal entry.
struct DiscoverCopyDeleter {
    private let journal: DiscoverCopyJournalStore
    private let run: ScriptRunner

    init(journal: DiscoverCopyJournalStore, run: @escaping ScriptRunner) {
        self.journal = journal
        self.run = run
    }

    /// `intent`, `uncertain`, `closed`, an unknown txn, or no usable hex ->
    /// `.kept`, and NO script runs. An `owned` or `listening` entry runs the
    /// deleting script; a `preexisting` one runs the same checks with no
    /// `delete`. The entry becomes `closed` only after the copy read absent.
    func end(txn: String) -> DiscoverCopyDeleteResult {
        let entry: DiscoverCopyEntry
        do {
            guard let found = try journal.entries().first(where: { $0.txn == txn }) else { return .kept }
            entry = found
        } catch {
            return .failed      // the journal could not be read: nothing is touched
        }
        guard let hex = entry.hex, discoverCopyIsPersistentIDHex(hex) else { return .kept }

        let delete: Bool
        switch entry.state {
        case .owned, .listening: delete = entry.isDeletable
        case .preexisting: delete = false
        case .intent, .uncertain, .closed: return .kept
        }

        let answer = run(discoverCopyEndScript(hex: hex, delete: delete))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer {
        case "gone":
            close(txn)
            return .alreadyGone
        case "spared":
            return .spared
        case "deleted" where delete:
            close(txn)
            return .deleted
        case "kept" where !delete:
            return .kept
        default:                // nil, "still", or anything unexpected: the entry is unchanged
            return .failed
        }
    }

    /// The copy read absent. A failed write leaves the entry for reconcile.
    private func close(_ txn: String) {
        _ = try? journal.update(txn: txn) { entry in
            entry.state = .closed
            entry.watching = false
        }
    }
}

/// What the watcher's `enqueueEnd` runs, on the action queue so it can never
/// interleave with a play transaction. The delete runs first, then
/// `restoreModes` for EVERY result: it is the one guarded restore, which holds
/// while a copy of ours may be playing (a spared copy included) and keeps the
/// record for later when it cannot finish. Then the bookkeeping per result:
/// `.spared` -> watch the copy again. `.deleted` / `.alreadyGone` / `.kept` ->
/// the entry stops being watched, and a `preexisting` entry closes. `.failed`
/// -> nothing more (the journal keeps it for reconcile).
func discoverCopyHandleEnd(txn: String, deleter: DiscoverCopyDeleter, journal: DiscoverCopyJournalStore,
                           restoreModes: (String) -> Void, readopt: (String, String) -> Void) {
    let result = deleter.end(txn: txn)
    restoreModes(txn)
    switch result {
    case .spared:
        guard let entry = (try? journal.entries())?.first(where: { $0.txn == txn }),
              let hex = entry.hex else { return }
        readopt(txn, hex)
    case .deleted, .alreadyGone, .kept:
        guard let entry = (try? journal.entries())?.first(where: { $0.txn == txn }),
              entry.watching || entry.state == .preexisting else { return }
        _ = try? journal.update(txn: txn) { entry in
            entry.watching = false
            if entry.state == .preexisting { entry.state = .closed }
        }
    case .failed:
        return
    }
}

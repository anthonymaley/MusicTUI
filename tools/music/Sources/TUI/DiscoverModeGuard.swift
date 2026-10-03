import Foundation

// S10 and the restore of Discover play-from-here: shuffle and song repeat are
// switched off for our play and put back afterwards to what he had, unless he
// changed them himself in the meantime. His prior values live in the journal
// entry (`priorShuffle`, `priorRepeat`), written BEFORE anything is set, so a
// crash leaves them recorded for reconcile. If the modes cannot be read or
// set, nothing plays (`switchOff` answers false).
//
// The record is durable evidence: it is cleared only when he changed the modes
// himself, or after a fresh read shows both recorded values back. A set's own
// answer proves nothing either way. While our sets are in flight, and after
// any restore or rollback that could not be verified, the entry is marked
// `restorePending`: the recorded values then go back whatever the modes read,
// because a half-set pair is ours, not a change of his.
//
// THE ONE WAY HIS MODES GO BACK is `restore(txn:)`, and it runs ONE Music.app
// script (`discoverModeRestoreScript`). That script reads the two modes, then
// looks at the player: if the player is not stopped and the current playlist
// is any copy the journal names (every well-formed hex, in every state), or
// cannot be read, it answers `held` and sets nothing. Only after that look, in
// the same script, does it check for his own change (an ordinary record), set
// the recorded values and read them back. One malformed hex anywhere in the
// journal makes the script hold whenever the player is not stopped. No caller
// has a guard of its own: every caller goes through `discoverCopySettleModes`,
// which hands a held copy to the end watcher so its end brings the restore back.
//
// The rollback inside `switchOff` is not a restore. It writes back the values
// it read at the top of the same call, never the record, so it bypasses the
// player guard; it keeps the verified, pending discipline. Inside one process
// a restore and a switch-off never overlap: one lock is held for the whole of
// each. The look-then-write gap shrinks to the few Apple events inside one
// script; it cannot be zero.

// MARK: - What the restore script is asked and what it answers

/// Every copy the journal names, in every state, as the restore script compares them.
enum DiscoverOurCopies: Equatable {
    case known([String])   // sorted, de-duplicated; every one passes discoverCopyHexIsWellFormed
    case unknowable        // some entry's hex is non-nil and malformed: any playlist could be ours
}

/// All entries, every state. A nil hex is skipped; one malformed non-nil hex -> `.unknowable`.
func discoverOurCopies(_ entries: [DiscoverCopyEntry]) -> DiscoverOurCopies {
    var hexes = Set<String>()
    for entry in entries {
        guard let hex = entry.hex else { continue }
        guard discoverCopyHexIsWellFormed(hex) else { return .unknowable }
        hexes.insert(hex)
    }
    return .known(hexes.sorted())
}

struct DiscoverModeRestoreRequest: Equatable {
    let shuffle: Bool?            // the recorded value to put back; nil = none recorded
    let songRepeat: RepeatMode?   // nil = none recorded (or prior_repeat is not a raw value)
    let ours: DiscoverOurCopies
    let unlessHeChanged: Bool     // true for an ordinary record, false for a pending one
}

/// What the one script answered. Every case but `.set` and `.unknown` means NOTHING was set.
enum DiscoverModeRestoreAnswer: Equatable {
    case held(current: String?)   // `held|<ID>`, `held|`: a copy of ours may be playing
    case modesUnreadable          // `unreadable`
    case changed                  // `changed` (believed only when unlessHeChanged)
    case back                     // `back`: already as recorded
    case set(shuffle: Bool?, songRepeat: RepeatMode?)   // `set|<s>,<r>`: sets sent; this is the read-back
    case unknown                  // nil, a timeout, or anything else: sets may have happened
}

let discoverModeHeldToken = "held"
let discoverModeUnreadableToken = "unreadable"
let discoverModeChangedToken = "changed"
let discoverModeBackToken = "back"
let discoverModeSetToken = "set"

/// The hexes the script may compare the current playlist with, or nil when
/// the request must be emitted in the unknowable form. A `.known` list holding
/// anything that is not sixteen `0-9A-F` is treated as unknowable (defence in
/// depth: `discoverOurCopies` never builds one), so no other text can reach
/// the script.
private func discoverModeComparableHexes(_ ours: DiscoverOurCopies) -> [String]? {
    guard case .known(let hexes) = ours, hexes.allSatisfy(discoverCopyHexIsWellFormed) else { return nil }
    return hexes
}

/// AppleScript body (no `tell` wrapper) for one restore attempt: read the
/// modes, look at the player, decide, set only the recorded halves, read back.
/// Every `return` that sets nothing comes before the first set. Each copy of
/// ours is an explicit `currentID is "<HEX>"` comparison (no list membership
/// test); the hexes are uppercase by validation. Never run by the tests.
func discoverModeRestoreScript(_ request: DiscoverModeRestoreRequest) -> String {
    var lines = [
        "set shuffleNow to \"\"",
        "try",
        "    set shuffleNow to (shuffle enabled as text)",
        "end try",
        "set repeatNow to \"\"",
        "try",
        "    set repeatNow to (song repeat as text)",
        "end try",
        "if shuffleNow is \"\" then return \"\(discoverModeUnreadableToken)\"",
        "if repeatNow is \"\" then return \"\(discoverModeUnreadableToken)\"",
        "set stateText to \"\(unreadablePlayerStateFallback)\"",
        "try",
        "    set stateText to (player state as text)",
        "end try",
    ]
    if let hexes = discoverModeComparableHexes(request.ours) {
        lines += [
            "set currentID to \"\"",
            "try",
            "    set currentID to (persistent ID of current playlist) as text",
            "end try",
            "if currentID is \"missing value\" then set currentID to \"\"",
            "if stateText is not \"stopped\" and currentID is \"\" then return \"\(discoverModeHeldToken)|\"",
        ]
        if !hexes.isEmpty {
            let terms = hexes.map { "currentID is \"\($0)\"" }.joined(separator: " or ")
            lines.append("if stateText is not \"stopped\" and (\(terms)) then return \"\(discoverModeHeldToken)|\" & currentID")
        }
    } else {
        lines.append("if stateText is not \"stopped\" then return \"\(discoverModeHeldToken)|\"")
    }
    if request.unlessHeChanged {
        lines += [
            "if shuffleNow is not \"false\" then return \"\(discoverModeChangedToken)\"",
            "if repeatNow is not \"off\" then return \"\(discoverModeChangedToken)\"",
        ]
    }
    var backTerms: [String] = []
    if let shuffle = request.shuffle { backTerms.append("shuffleNow is \"\(shuffle)\"") }
    if let mode = request.songRepeat { backTerms.append("repeatNow is \"\(mode.rawValue)\"") }
    if !backTerms.isEmpty {
        lines.append("if \(backTerms.joined(separator: " and ")) then return \"\(discoverModeBackToken)\"")
    }
    if let shuffle = request.shuffle {
        lines += ["try", "    set shuffle enabled to \(shuffle)", "end try"]
    }
    if let mode = request.songRepeat {
        lines += ["try", "    set song repeat to \(mode.rawValue)", "end try"]
    }
    lines += [
        "set shuffleAfter to \"\"",
        "try",
        "    set shuffleAfter to (shuffle enabled as text)",
        "end try",
        "set repeatAfter to \"\"",
        "try",
        "    set repeatAfter to (song repeat as text)",
        "end try",
        "return \"\(discoverModeSetToken)|\" & shuffleAfter & \",\" & repeatAfter",
    ]
    return lines.joined(separator: "\n")
}

/// The restore script's output, trimmed. `held|` + an ID that is well-formed
/// after uppercasing and one of `ours` -> `.held(current: ID)`; any other
/// `held|` -> `.held(current: nil)`. `changed` is believed only when it was
/// asked for. `set|<s>,<r>` needs exactly two fields. Anything else -> `.unknown`.
func parseDiscoverModeRestoreAnswer(_ output: String?,
                                    request: DiscoverModeRestoreRequest) -> DiscoverModeRestoreAnswer {
    guard let output else { return .unknown }
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let heldPrefix = discoverModeHeldToken + "|"
    if text.hasPrefix(heldPrefix) {
        let id = String(text.dropFirst(heldPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if discoverCopyHexIsWellFormed(id), case .known(let hexes) = request.ours, hexes.contains(id) {
            return .held(current: id)
        }
        return .held(current: nil)
    }
    switch text {
    case discoverModeUnreadableToken: return .modesUnreadable
    case discoverModeChangedToken: return request.unlessHeChanged ? .changed : .unknown
    case discoverModeBackToken: return .back
    default: break
    }
    let setPrefix = discoverModeSetToken + "|"
    guard text.hasPrefix(setPrefix) else { return .unknown }
    let fields = text.dropFirst(setPrefix.count)
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard fields.count == 2 else { return .unknown }
    let shuffle: Bool?
    switch fields[0] {
    case "true": shuffle = true
    case "false": shuffle = false
    default: shuffle = nil
    }
    return .set(shuffle: shuffle, songRepeat: RepeatMode(rawValue: fields[1]))
}

/// The live form of `Seams.restore`: builds the script, runs it once, parses the answer.
func discoverModeRestore(run: ScriptRunner, _ request: DiscoverModeRestoreRequest) -> DiscoverModeRestoreAnswer {
    parseDiscoverModeRestoreAnswer(run(discoverModeRestoreScript(request)), request: request)
}

/// What one restore attempt did.
enum DiscoverModeRestore: Equatable {
    case nothingRecorded      // unknown txn, or no value to put back: no script, no write
    case journalUnreadable    // no script, no write
    case notMarked            // the pending mark could not be written: no script
    case held(watch: String?) // nothing set; record and mark as before the call
    case modesUnreadable      // nothing set; record and mark as before the call
    case hisChange            // ordinary record, modes not (off, off): nothing set, record cleared
    case restored             // read back as recorded (already, or after the sets): record cleared
    case unverified           // sets may have happened, not read back as recorded: record kept, pending
}

// MARK: - The guard

struct DiscoverModeGuard {
    struct Seams {
        var read: () -> (shuffle: Bool, songRepeat: RepeatMode)?   // switchOff ONLY; nil = unreadable
        var setShuffle: (Bool) -> Bool                              // switchOff ONLY; false = the set failed
        var setRepeat: (RepeatMode) -> Bool                         // switchOff ONLY
        /// restore ONLY: one Music.app operation that looks, decides, sets and reads back.
        var restore: (DiscoverModeRestoreRequest) -> DiscoverModeRestoreAnswer

        /// `read`/`setShuffle`/`setRepeat` wrap `fetchPlaybackModes`,
        /// `setShuffleEnabled` and `setSongRepeat`; `restore` runs one script on `run`.
        static func live(backend: AppleScriptBackend, run: @escaping ScriptRunner) -> Seams {
            Seams(
                read: {
                    guard let modes = try? fetchPlaybackModes(backend) else { return nil }
                    return (modes.shuffleEnabled, modes.songRepeat)
                },
                setShuffle: { on in
                    do { try setShuffleEnabled(backend, on); return true } catch { return false }
                },
                setRepeat: { mode in
                    do { try setSongRepeat(backend, mode); return true } catch { return false }
                },
                restore: { discoverModeRestore(run: run, $0) })
        }
    }

    let journal: DiscoverCopyJournalStore
    let seams: Seams
    /// A reference, so every copy of this struct that a closure captures shares it.
    private let lock = NSLock()

    init(journal: DiscoverCopyJournalStore, seams: Seams) {
        self.journal = journal
        self.seams = seams
    }

    private func holdsPrior(_ entry: DiscoverCopyEntry) -> Bool {
        entry.priorShuffle != nil || entry.priorRepeat != nil
    }

    private func isOff(_ modes: (shuffle: Bool, songRepeat: RepeatMode)?) -> Bool {
        guard let modes else { return false }
        return !modes.shuffle && modes.songRepeat == .off
    }

    /// Best effort: a failed clear leaves the record, which restore reads again.
    private func clearRecord(_ txn: String) {
        _ = try? journal.update(txn: txn) {
            $0.priorShuffle = nil; $0.priorRepeat = nil; $0.restorePending = nil
        }
    }

    /// Best effort: the mark is normally already there, written before the sets.
    private func markPending(_ txn: String) {
        _ = try? journal.update(txn: txn) { $0.restorePending = true }
    }

    /// True when shuffle and song repeat are now (off, off) and his prior
    /// values are recorded on `txn`. False changes nothing that stays changed.
    /// Holds the guard's lock throughout.
    func switchOff(txn: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = seams.read() else { return false }
        guard let all = try? journal.entries(),
              let mine = all.first(where: { $0.txn == txn }) else { return false }

        // What this entry will hold, and where it came from.
        enum Source { case kept, moved(from: [DiscoverCopyEntry]), fresh }
        let source: Source
        let shuffleToRecord: Bool?
        let repeatToRecord: String?
        if holdsPrior(mine) {
            // The same-copy replay: his values are already ours to restore.
            source = .kept
            shuffleToRecord = mine.priorShuffle
            repeatToRecord = mine.priorRepeat
        } else {
            let others = all.filter { $0.txn != txn && holdsPrior($0) }
            if let newest = others.last {
                // An earlier play's modes are still ours: the newest play inherits them.
                source = .moved(from: others)
                shuffleToRecord = newest.priorShuffle
                repeatToRecord = newest.priorRepeat
            } else {
                source = .fresh
                shuffleToRecord = current.shuffle
                repeatToRecord = current.songRepeat.rawValue
            }
        }

        // Record before setting anything, marked pending until the sets are
        // verified: a crash between them leaves a restore to retry. A replay
        // (`.kept`) writes the values it already holds, and the same mark.
        do {
            try journal.update(txn: txn) {
                $0.priorShuffle = shuffleToRecord
                $0.priorRepeat = repeatToRecord
                $0.restorePending = true
            }
        } catch { return false }
        if case .moved(let from) = source {
            // His originals now live on this entry only. If an older holder
            // cannot be cleared, undo and change nothing.
            var cleared: [DiscoverCopyEntry] = []
            for entry in from {
                do {
                    try journal.update(txn: entry.txn) {
                        $0.priorShuffle = nil; $0.priorRepeat = nil; $0.restorePending = nil
                    }
                    cleared.append(entry)
                } catch {
                    // Nothing has been set yet: the modes are as they were read.
                    for undone in cleared {
                        _ = try? journal.update(txn: undone.txn) {
                            $0.priorShuffle = undone.priorShuffle
                            $0.priorRepeat = undone.priorRepeat
                            $0.restorePending = undone.restorePending
                        }
                    }
                    clearRecord(txn)
                    return false
                }
            }
        }

        // Undo of a failed attempt: modes back to the values read at the top
        // of THIS call (never the record, and with no player guard: see the
        // file header), and, ONLY once a fresh read shows them back, the
        // record back to what it was before this call. Unverified, the record
        // stays on this entry, pending, for restore to retry.
        func giveUp(shuffleSet: Bool, repeatSet: Bool) -> Bool {
            if shuffleSet { _ = seams.setShuffle(current.shuffle) }
            if repeatSet { _ = seams.setRepeat(current.songRepeat) }
            guard let after = seams.read(),
                  after.shuffle == current.shuffle, after.songRepeat == current.songRepeat else {
                markPending(txn)
                return false
            }
            switch source {
            case .kept:
                // The record was his before this call and still is; only the
                // mark goes back to what it was. If that write fails it stays
                // pending, which restore then finishes.
                _ = try? journal.update(txn: txn) { $0.restorePending = mine.restorePending }
            case .fresh:
                clearRecord(txn)
            case .moved(let from):
                // Every older holder gets its record back FIRST; this entry
                // lets go of his originals only if all of them did. A
                // duplicate record is harmless (the second restore answers
                // `back` or `changed`); a lost one is not.
                var allRewritten = true
                for entry in from {
                    do {
                        try journal.update(txn: entry.txn) {
                            $0.priorShuffle = entry.priorShuffle
                            $0.priorRepeat = entry.priorRepeat
                            $0.restorePending = entry.restorePending
                        }
                    } catch {
                        allRewritten = false
                    }
                }
                if allRewritten { clearRecord(txn) } else { markPending(txn) }
            }
            return false
        }

        guard seams.setShuffle(false) else { return giveUp(shuffleSet: true, repeatSet: false) }
        guard seams.setRepeat(.off) else { return giveUp(shuffleSet: true, repeatSet: true) }
        guard isOff(seams.read()) else { return giveUp(shuffleSet: true, repeatSet: true) }
        // Verified (off, off): an ordinary record again, so a later change of
        // his is read as his.
        do { try journal.update(txn: txn) { $0.restorePending = nil } }
        catch { return giveUp(shuffleSet: true, repeatSet: true) }
        return true
    }

    /// The one guarded restore. Holds the guard's lock throughout; makes at
    /// most ONE `seams.restore` call and touches Music.app in no other way.
    /// The entry is marked pending before the script (unless it already is)
    /// and cleared only when the read-back matches; when the script set
    /// nothing, the mark this call wrote is taken back.
    @discardableResult
    func restore(txn: String) -> DiscoverModeRestore {
        lock.lock()
        defer { lock.unlock() }
        let all: [DiscoverCopyEntry]
        do { all = try journal.entries() } catch { return .journalUnreadable }
        guard let mine = all.first(where: { $0.txn == txn }) else { return .nothingRecorded }
        let wantShuffle = mine.priorShuffle
        let wantRepeat = mine.priorRepeat.flatMap { RepeatMode(rawValue: $0) }
        guard wantShuffle != nil || wantRepeat != nil else { return .nothingRecorded }

        let wasPending = mine.restorePending == true
        if !wasPending {
            do { try journal.update(txn: txn) { $0.restorePending = true } } catch { return .notMarked }
        }
        /// Best effort: gives back the mark this call wrote, so an ordinary
        /// record stays ordinary when nothing was set.
        func unmark() {
            guard !wasPending else { return }
            _ = try? journal.update(txn: txn) { $0.restorePending = nil }
        }

        let ours = discoverOurCopies(all)
        let answer = seams.restore(DiscoverModeRestoreRequest(
            shuffle: wantShuffle, songRepeat: wantRepeat, ours: ours, unlessHeChanged: !wasPending))
        switch answer {
        case .held(let current):
            unmark()
            guard case .known = ours else { return .held(watch: nil) }
            if let current { return .held(watch: current) }
            if let hex = mine.hex, discoverCopyHexIsWellFormed(hex) { return .held(watch: hex) }
            return .held(watch: nil)
        case .modesUnreadable:
            unmark()
            return .modesUnreadable
        case .changed:
            // Only an ordinary record is asked about his change.
            guard !wasPending else { return .unverified }
            clearRecord(txn)
            return .hisChange
        case .back:
            clearRecord(txn)
            return .restored
        case .set(let shuffle, let mode):
            let shuffleBack = wantShuffle == nil || shuffle == wantShuffle
            let repeatBack = wantRepeat == nil || mode == wantRepeat
            guard shuffleBack, repeatBack else { return .unverified }
            clearRecord(txn)
            return .restored
        case .unknown:
            return .unverified
        }
    }
}

/// Every caller's `restoreModes`: one guarded attempt. On `.held(watch: X)`
/// the copy X goes to the end watcher (`adopt(txn, X)`), so its end brings the
/// restore back; every reconcile retries it too. Logs any result other than
/// `.nothingRecorded` and `.restored`.
@discardableResult
func discoverCopySettleModes(txn: String, modes: DiscoverModeGuard,
                             adopt: (_ txn: String, _ hex: String) -> Void,
                             log: (String) -> Void) -> DiscoverModeRestore {
    let result = modes.restore(txn: txn)
    switch result {
    case .nothingRecorded, .restored:
        break
    default:
        log("discover copy \(txn): mode restore \(result)")
    }
    if case .held(let watch?) = result { adopt(txn, watch) }
    return result
}

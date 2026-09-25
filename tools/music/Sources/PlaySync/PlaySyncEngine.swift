import Foundation

/// Points in a pass where a test can step in. Production code passes no hook.
enum PlaySyncPassStage: Equatable {
    /// The lock is held and the journal has not been read yet.
    case locked
    /// Problems are marked reported and the journal is compacted; it is about
    /// to be saved, still under the lock.
    case beforeFinalSave
}

/// One play-sync pass: read the finished library plays Bridge reports, and
/// record each one in Music.app's `played count` and `played date`.
///
/// The whole pass runs under the play-sync lock, and every journal read and
/// write happens inside it. The journal is saved before every side effect:
/// captured plays before Music.app is touched, and each write as `writing`
/// before its set call. A write whose effect is unknown keeps its song on hold
/// until the target is observed or the Music.app instance that received it is
/// verified to have exited. Time alone never releases it.
final class PlaySyncEngine: PlaySyncRunning {

    /// How long `music sync-plays` waits for another sync to finish.
    static let explicitLockWaitSeconds: TimeInterval = 20
    /// Plays asked for per page.
    static let pageLimit = 200
    /// Fresh re-plans per entry per pass after a write that was not sent.
    static let maxFreshReplansPerPass = 3
    /// Retries of one write released by a Music.app restart before the entry is
    /// set aside as a conflict.
    static let maxBarrierReplans = 3
    /// Recorded entries kept after a pass; nothing else is ever removed.
    static let keptDoneEntries = 500

    let paths: PlaySyncPaths
    fileprivate let feed: CompletedPlaysReading?
    fileprivate let writer: PlayCountWriting
    fileprivate let inspector: MusicInstanceInspecting
    fileprivate let now: () -> Date
    fileprivate let explicitLockWait: TimeInterval
    fileprivate let pageLimit: Int
    fileprivate let stageHook: ((PlaySyncPassStage) -> Void)?

    /// - Parameters:
    ///   - feed: where finished plays come from; nil runs a pass that only
    ///     applies what the journal already holds.
    ///   - inspector: decides whether the Music.app instance that received an
    ///     unconfirmed write has exited.
    init(paths: PlaySyncPaths,
         feed: CompletedPlaysReading?,
         writer: PlayCountWriting,
         inspector: MusicInstanceInspecting,
         now: @escaping () -> Date = Date.init,
         explicitLockWait: TimeInterval = PlaySyncEngine.explicitLockWaitSeconds,
         pageLimit: Int = PlaySyncEngine.pageLimit,
         stageHook: ((PlaySyncPassStage) -> Void)? = nil) {
        self.paths = paths
        self.feed = feed
        self.writer = writer
        self.inspector = inspector
        self.now = now
        self.explicitLockWait = explicitLockWait
        self.pageLimit = pageLimit
        self.stageHook = stageHook
    }

    func pass(_ trigger: PlaySyncTrigger) -> PlaySyncResult {
        guard PrivateDirectory.prepare(paths.directory) else {
            return .passBlocked(.directoryUnsafe(path: paths.directory.path))
        }

        let wait: TimeInterval = trigger == .explicit ? explicitLockWait : 0
        let lock: PlaySyncLock
        switch PlaySyncLock.acquire(paths.lock, waitingUpTo: wait) {
        case .success(let held):
            lock = held
        case .failure(.busy):
            return .passBlocked(.lockBusy)
        case .failure(.unavailable):
            // The lock file inside the folder is not a plain file this user can
            // open: the folder is not in the state play sync keeps it in.
            return .passBlocked(.directoryUnsafe(path: paths.directory.path))
        }
        defer { lock.release() }
        stageHook?(.locked)

        let journal: PlaySyncJournal
        switch PlaySyncJournal.load(from: paths.journal) {
        case .loaded(let loaded): journal = loaded
        case .unreadable: return .passBlocked(.journalUnreadable(path: paths.journal.path))
        case .tooNew: return .passBlocked(.journalTooNew)
        }
        return PassRun(engine: self, journal: journal).perform()
    }
}

// MARK: - One pass, under the lock

private enum Next { case next, stop }

private struct JournalSaveFailed: Error {}

private extension EntryState {
    /// States whose song later plays must wait behind.
    var holdsItsTrack: Bool {
        switch self {
        case .pending, .writing, .unresolved: return true
        case .done, .unmatched, .conflict: return false
        }
    }

    var isProblem: Bool {
        switch self {
        case .unresolved, .unmatched, .conflict: return true
        case .pending, .writing, .done: return false
        }
    }
}

fileprivate extension PlaySyncResult {
    static func passBlocked(_ block: PlaySyncBlock) -> PlaySyncResult {
        PlaySyncResult(blocked: block, fetch: .skipped, musicRunning: false, recorded: [],
                       newProblems: [], outstanding: [], unconfirmed: [], waiting: 0)
    }
}

private final class PassRun {
    private let engine: PlaySyncEngine
    private var journal: PlaySyncJournal
    /// What the journal file holds now, so an unchanged journal is not rewritten.
    private var persisted: PlaySyncJournal
    private var fetchStatus: PlaySyncFetchStatus = .skipped
    private var musicRunning = false
    private var recorded: [PlaySyncEntry] = []
    /// The first Music.app failure that left a play waiting or unconfirmed.
    private var musicAccess: MusicAccessError?

    init(engine: PlaySyncEngine, journal: PlaySyncJournal) {
        self.engine = engine
        self.journal = journal
        self.persisted = journal
    }

    private var nowEpoch: Int { Int(engine.now().timeIntervalSince1970.rounded(.down)) }

    func perform() -> PlaySyncResult {
        journal.recoverInterruptedWrites()
        do {
            try fetchPages()
            try apply()

            var newProblems: [PlaySyncEntry] = []
            for index in journal.entries.indices
            where journal.entries[index].state.isProblem && !journal.entries[index].reported {
                journal.entries[index].reported = true
                newProblems.append(journal.entries[index])
            }
            journal.compact(keepingDone: PlaySyncEngine.keptDoneEntries)
            engine.stageHook?(.beforeFinalSave)
            if journal != persisted { try save() }

            return PlaySyncResult(
                blocked: nil, fetch: fetchStatus, musicRunning: musicRunning,
                recorded: recorded, newProblems: newProblems,
                outstanding: journal.entries.filter { $0.state == .unmatched || $0.state == .conflict },
                unconfirmed: journal.entries.filter { $0.state == .unresolved },
                waiting: journal.entries.filter { $0.state == .pending }.count,
                musicAccess: musicAccess)
        } catch {
            // The journal could not be saved. Nothing further was attempted:
            // no set call is ever made without its `writing` entry on disk.
            var result = PlaySyncResult.passBlocked(.journalNotSaved(path: engine.paths.journal.path))
            result.fetch = fetchStatus
            result.musicRunning = musicRunning
            result.recorded = recorded
            result.musicAccess = musicAccess
            return result
        }
    }

    private func save() throws {
        do {
            try journal.save(to: engine.paths.journal)
        } catch {
            throw JournalSaveFailed()
        }
        persisted = journal
    }

    // MARK: Fetch

    private func fetchPages() throws {
        guard let feed = engine.feed else {
            fetchStatus = .skipped
            return
        }
        var known: [String: String] = [:]   // "ledger#seq" -> play id
        for entry in journal.entries { known[key(entry.ledgerID, entry.seq)] = entry.playID }

        var newPlays = 0
        var replaced = false
        var failure: PlaySyncFetchStatus?
        var replacedTwice = false

        fetching: while true {
            let after = journal.consumedThrough
            let page: CompletedPlaysPage
            do {
                page = try feed.completedPlays(ledgerID: journal.ledgerID, after: after, limit: engine.pageLimit)
            } catch SourceAppError.ledgerChanged {
                try retireLedger()
                if replaced {
                    replacedTwice = true
                    failure = .failed("Bridge's play record was replaced again while it was being read.")
                    break fetching
                }
                replaced = true
                continue fetching
            } catch let error as SourceAppError {
                failure = Self.status(for: error)
                break fetching
            } catch {
                failure = .failed(String(describing: error))
                break fetching
            }

            if let current = journal.ledgerID, current != page.ledgerID {
                failure = .failed("Bridge answered from a different play record than the one asked for.")
                break fetching
            }
            if page.more && page.nextAfter <= after {
                failure = .failed("Bridge's play record page did not move forward.")
                break fetching
            }

            var fresh: [PlaySyncEntry] = []
            for play in page.plays {
                let playKey = key(page.ledgerID, play.seq)
                if let existing = known[playKey] {
                    if existing == play.playID { continue }   // delivered again: already captured
                    failure = .failed("Bridge's play record gave play \(play.seq) two different identities; "
                                      + "nothing more was read.")
                    break fetching
                }
                known[playKey] = play.playID
                fresh.append(Self.entry(from: play, ledgerID: page.ledgerID))
            }

            // One write: the page's plays and the cursor past them, before
            // anything touches Music.app.
            journal.ledgerID = page.ledgerID
            journal.consumedThrough = max(journal.consumedThrough, page.nextAfter)
            journal.entries.append(contentsOf: fresh)
            newPlays += fresh.count
            if journal != persisted { try save() }

            if !page.more { break fetching }
        }

        if replaced && !replacedTwice {
            // Reported whenever it happened: it is the one notice that plays
            // may have been lost, and a later failure recurs on its own.
            fetchStatus = .ledgerReplaced
        } else if let failure {
            fetchStatus = failure
        } else {
            fetchStatus = .ok(newPlays: newPlays)
        }
    }

    /// The cursor belongs to a play record Bridge no longer has: keep a note of
    /// it and start again from the beginning. Entries already captured keep
    /// their own data and rules.
    private func retireLedger() throws {
        if let old = journal.ledgerID {
            journal.retiredLedgers.append(RetiredLedger(ledgerID: old,
                                                        consumedThrough: journal.consumedThrough,
                                                        retiredAt: nowEpoch))
        }
        journal.ledgerID = nil
        journal.consumedThrough = 0
        if journal != persisted { try save() }
    }

    private func key(_ ledgerID: String, _ seq: Int) -> String { "\(ledgerID)#\(seq)" }

    private static func status(for error: SourceAppError) -> PlaySyncFetchStatus {
        switch error {
        case .notRunning: return .bridgeNotRunning
        case .unsupported: return .bridgeTooOld
        default: return .failed(error.message)
        }
    }

    private static func entry(from play: CompletedPlayRecord, ledgerID: String) -> PlaySyncEntry {
        PlaySyncEntry(
            ledgerID: ledgerID, seq: play.seq, playID: play.playID,
            alias: play.alias, persistentID: play.alias.flatMap(persistentIDHex(fromAlias:)),
            title: play.title, artist: play.artist,
            completedAt: Int(play.completedAt.timeIntervalSince1970.rounded(.down)),
            state: .pending, phase: .countAndDate,
            before: nil, target: nil, attempt: nil, observed: nil,
            barrierReplans: 0, reason: nil, reconciled: false, reported: false)
    }

    // MARK: Apply

    private func apply() throws {
        guard let process = engine.writer.musicProcess() else {
            musicRunning = false
            return
        }
        musicRunning = true

        // Songs with an earlier entry still pending, being written or
        // unconfirmed. A later play of the same song waits behind it, so an
        // older target can never land over a newer one.
        var held = Set<String>()
        for index in journal.entries.indices {
            let next = try advance(index, process: process, held: held)
            let entry = journal.entries[index]
            if let pid = entry.persistentID, entry.state.holdsItsTrack { held.insert(pid) }
            if next == .stop { return }
        }
    }

    private func advance(_ index: Int, process: MusicProcess, held: Set<String>) throws -> Next {
        let entry = journal.entries[index]
        switch entry.state {
        case .done, .unmatched, .conflict:
            return .next
        case .writing, .unresolved:
            return try resolve(index, process: process, held: held)
        case .pending:
            guard let pid = entry.persistentID else {
                try conclude(index, .unmatched, reason: entry.alias == nil ? "no_alias" : "bad_alias")
                return .next
            }
            if held.contains(pid) { return .next }
            switch entry.phase {
            case .dateOnly:
                return try writeDateOnly(index, process: process)
            case .countAndDate:
                // A pending entry that already carries a target is never
                // re-planned: that target may be what an earlier write sent.
                if entry.target != nil { return try writeRetained(index, process: process) }
                return try planAndWrite(index, process: process)
            }
        }
    }

    /// A fresh plan: read the track, aim one play higher, and write. A write
    /// that was positively not sent is planned again from a fresh read, a
    /// bounded number of times per pass.
    private func planAndWrite(_ index: Int, process: MusicProcess) throws -> Next {
        guard let pid = journal.entries[index].persistentID else { return .next }
        var replans = 0
        while true {
            let lookup: TrackLookup
            do {
                lookup = try engine.writer.read(process, persistentID: pid)
            } catch {
                noteAccessFailure(error)
                return .stop
            }
            switch lookup {
            case .notFound(libraryTrackCount: 0):
                noteAccessFailure(MusicAccessError.failed(MusicAccessSentence.libraryNotLoaded))
                return .stop   // the library is not loaded yet
            case .notFound:
                try conclude(index, .unmatched, reason: "not_found")
                return .next
            case .ambiguous:
                try conclude(index, .unmatched, reason: "ambiguous")
                return .next
            case .found(let before):
                let completedAt = journal.entries[index].completedAt
                let target = TrackPlayState(count: before.count + 1,
                                            date: max(before.date ?? completedAt, completedAt))
                update(index) {
                    $0.before = before
                    $0.target = target
                    $0.observed = before
                }
                try beginAttempt(index, process: process)
                switch engine.writer.write(process, persistentID: pid, expect: before, target: target) {
                case .applied(let state):
                    try settleApplied(index, state)
                    return .next
                case .notSent(let current, let reason):
                    // No set call was made, so nothing can land: the plan is
                    // dropped and made again from what is there now.
                    update(index) {
                        $0.state = .pending
                        $0.before = nil
                        $0.target = nil
                        $0.attempt = nil
                        if let current { $0.observed = current }
                    }
                    try save()
                    guard replans < PlaySyncEngine.maxFreshReplansPerPass else {
                        // Left waiting for a later pass. With nothing observed,
                        // Music.app could not be used, and the pass says why.
                        if current == nil { noteNotSent(reason) }
                        return .next
                    }
                    replans += 1
                case .countAppliedDateUnknown:
                    try markUnresolved(index, phase: .dateOnly)
                    return .next
                case .unknown:
                    try markUnresolved(index, phase: .countAndDate)
                    return .next
                }
            }
        }
    }

    /// A retained plan, released by a verified Music.app exit: the original
    /// target with the original expected values, never a new increment.
    private func writeRetained(_ index: Int, process: MusicProcess) throws -> Next {
        let entry = journal.entries[index]
        guard let pid = entry.persistentID, let before = entry.before, let target = entry.target else { return .next }
        try beginAttempt(index, process: process)
        switch engine.writer.write(process, persistentID: pid, expect: before, target: target) {
        case .applied(let state):
            try settleApplied(index, state)
        case .notSent(nil, let reason):
            update(index) {
                $0.state = .pending
                $0.attempt = nil
            }
            try save()
            noteNotSent(reason)
        case .notSent(let current?, _):
            // The track changed after it was read. The saved target is kept
            // and no new one is made.
            if current == target {
                try markDone(index, reconciled: true)
            } else {
                try conclude(index, .conflict, observed: current)
            }
        case .countAppliedDateUnknown:
            try markUnresolved(index, phase: .dateOnly)
        case .unknown:
            try markUnresolved(index, phase: .countAndDate)
        }
        return .next
    }

    /// The count is already at its target; only the date is written. Never a
    /// count write.
    private func writeDateOnly(_ index: Int, process: MusicProcess) throws -> Next {
        let entry = journal.entries[index]
        guard let pid = entry.persistentID, let before = entry.before,
              let target = entry.target, let date = target.date else { return .next }
        let expect = TrackPlayState(count: target.count, date: before.date)
        try beginAttempt(index, process: process)
        switch engine.writer.writeDate(process, persistentID: pid, expect: expect, date: date) {
        case .applied(let state):
            try settleApplied(index, state)
        case .notSent(nil, let reason):
            update(index) {
                $0.state = .pending
                $0.attempt = nil
            }
            try save()
            noteNotSent(reason)
        case .notSent(let current?, _):
            if current == target {
                try markDone(index, reconciled: true)
            } else if Self.isAtLeastAsLate(current, target) {
                try markDone(index, reconciled: true, reason: "superseded")
            } else {
                try conclude(index, .conflict, observed: current)
            }
        case .unknown, .countAppliedDateUnknown:
            try markUnresolved(index, phase: .dateOnly)
        }
        return .next
    }

    /// An entry whose last write may still land. Only two things settle it:
    /// seeing its exact target, or a verified exit of the Music.app instance
    /// that received the write, followed by a successful read from the
    /// instance running now.
    private func resolve(_ index: Int, process: MusicProcess, held: Set<String>) throws -> Next {
        let entry = journal.entries[index]
        guard let pid = entry.persistentID, let attempt = entry.attempt,
              let before = entry.before, let target = entry.target else { return .next }
        if held.contains(pid) { return .next }

        // Decided before the read, so a read that releases anything is taken
        // after the old instance is known to be gone.
        let barrier = attempt.process != process
            && engine.inspector.state(of: attempt.process) == .exited

        let lookup: TrackLookup
        do {
            lookup = try engine.writer.read(process, persistentID: pid)
        } catch {
            noteAccessFailure(error)
            return .stop
        }
        guard case .found(let current) = lookup else {
            // No observation of the track: nothing is released.
            if case .notFound(libraryTrackCount: 0) = lookup {
                noteAccessFailure(MusicAccessError.failed(MusicAccessSentence.libraryNotLoaded))
                return .stop
            }
            return .next
        }

        update(index) { $0.observed = current }
        if current == target {
            try markDone(index, reconciled: true)
            return .next
        }
        guard barrier else { return .next }   // still unconfirmed; the song stays on hold

        let countConfirmed = TrackPlayState(count: target.count, date: before.date)
        switch entry.phase {
        case .countAndDate:
            if current == before {
                let replans = entry.barrierReplans + 1
                update(index) { $0.barrierReplans = replans }
                if replans >= PlaySyncEngine.maxBarrierReplans {
                    try conclude(index, .conflict, observed: current)
                    return .next
                }
                update(index) {
                    $0.state = .pending
                    $0.attempt = nil
                }
                try save()
                return try writeRetained(index, process: process)
            }
            if current == countConfirmed {
                update(index) {
                    $0.state = .pending
                    $0.phase = .dateOnly
                    $0.attempt = nil
                }
                try save()
                return try writeDateOnly(index, process: process)
            }
            try conclude(index, .conflict, observed: current)
        case .dateOnly:
            if current == countConfirmed {
                update(index) {
                    $0.state = .pending
                    $0.attempt = nil
                }
                try save()
                return try writeDateOnly(index, process: process)
            }
            if Self.isAtLeastAsLate(current, target) {
                try markDone(index, reconciled: true, reason: "superseded")
            } else {
                try conclude(index, .conflict, observed: current)
            }
        }
        return .next
    }

    // MARK: Music.app failures, carried to the result

    /// A read that threw: the entry keeps its state and the pass says why.
    private func noteAccessFailure(_ error: Error) {
        guard musicAccess == nil else { return }
        musicAccess = (error as? MusicAccessError) ?? .failed(String(describing: error))
    }

    /// A write refused before any set call, with nothing observed.
    private func noteNotSent(_ reason: String) {
        guard musicAccess == nil else { return }
        switch reason {
        case MusicAccessSentence.notRunning: musicAccess = .notRunning
        case MusicAccessSentence.timedOut: musicAccess = .timedOut
        default: musicAccess = .failed(reason)
        }
    }

    // MARK: Transitions (each saved before the next entry is touched)

    /// Applies a change to one entry. Moving into a problem state makes it
    /// news again, to be reported once.
    private func update(_ index: Int, _ change: (inout PlaySyncEntry) -> Void) {
        var entry = journal.entries[index]
        let previous = entry.state
        change(&entry)
        if entry.state != previous && entry.state.isProblem { entry.reported = false }
        journal.entries[index] = entry
    }

    /// Saved before the set call it announces.
    private func beginAttempt(_ index: Int, process: MusicProcess) throws {
        let startedAt = nowEpoch
        update(index) {
            $0.state = .writing
            $0.attempt = WriteAttempt(phase: $0.phase, process: process, startedAt: startedAt)
        }
        try save()
    }

    private func settleApplied(_ index: Int, _ state: TrackPlayState) throws {
        if state == journal.entries[index].target {
            try markDone(index, reconciled: false)
        } else {
            try conclude(index, .conflict, observed: state)
        }
    }

    private func markUnresolved(_ index: Int, phase: WritePhase) throws {
        update(index) {
            $0.state = .unresolved
            $0.phase = phase
        }
        try save()
    }

    private func markDone(_ index: Int, reconciled: Bool, reason: String? = nil) throws {
        update(index) {
            $0.state = .done
            $0.attempt = nil
            $0.reconciled = reconciled
            $0.reason = reason
        }
        try save()
        recorded.append(journal.entries[index])
    }

    /// `unmatched` or `conflict`: terminal, with nothing left that could land.
    private func conclude(_ index: Int, _ state: EntryState, reason: String? = nil,
                          observed: TrackPlayState? = nil) throws {
        update(index) {
            $0.state = state
            $0.attempt = nil
            $0.reason = reason ?? (state == .conflict ? "conflict" : $0.reason)
            if let observed { $0.observed = observed }
        }
        try save()
    }

    private static func isAtLeastAsLate(_ current: TrackPlayState, _ target: TrackPlayState) -> Bool {
        guard let date = current.date, let targetDate = target.date else { return false }
        return date >= targetDate
    }
}

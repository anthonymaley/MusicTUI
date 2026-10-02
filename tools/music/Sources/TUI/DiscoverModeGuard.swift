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

struct DiscoverModeGuard {
    struct Seams {
        var read: () -> (shuffle: Bool, songRepeat: RepeatMode)?   // nil = unreadable
        var setShuffle: (Bool) -> Bool                              // false = the set failed
        var setRepeat: (RepeatMode) -> Bool

        /// Wraps `fetchPlaybackModes`, `setShuffleEnabled` and `setSongRepeat`.
        static func live(backend: AppleScriptBackend) -> Seams {
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
                })
        }
    }

    let journal: DiscoverCopyJournalStore
    let seams: Seams

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
    func switchOff(txn: String) -> Bool {
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

        // Undo of a failed attempt: modes back as they were read, and, ONLY
        // once a fresh read shows them back, the record back to what it was
        // before this call. Unverified, the record stays on this entry,
        // pending, for restore to retry.
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
                clearRecord(txn)
                for entry in from {
                    _ = try? journal.update(txn: entry.txn) {
                        $0.priorShuffle = entry.priorShuffle
                        $0.priorRepeat = entry.priorRepeat
                        $0.restorePending = entry.restorePending
                    }
                }
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

    /// Puts his recorded values back unless he changed them since. Idempotent;
    /// works on an entry in any state. The record is cleared only after a
    /// fresh read shows both values back; until then it stays, pending, and
    /// the next call (reconcile's included) retries instead of reading a
    /// half-restored pair as a change of his.
    func restore(txn: String) {
        guard let all = try? journal.entries(),
              let mine = all.first(where: { $0.txn == txn }),
              holdsPrior(mine) else { return }
        guard let current = seams.read() else { return }   // unreadable: leave it recorded
        let wantRepeat = mine.priorRepeat.flatMap { RepeatMode(rawValue: $0) }
        func isBack(_ modes: (shuffle: Bool, songRepeat: RepeatMode)) -> Bool {
            (mine.priorShuffle == nil || modes.shuffle == mine.priorShuffle)
                && (wantRepeat == nil || modes.songRepeat == wantRepeat)
        }
        if mine.restorePending == true {
            if isBack(current) { clearRecord(txn); return }
        } else {
            guard isOff(current) else {
                clearRecord(txn)   // he changed them: his values stand
                return
            }
            // Marked before the first set, so a crash or a failed set between
            // the two is retried. If the mark cannot be written, set nothing.
            guard (try? journal.update(txn: txn) { $0.restorePending = true }) != nil else { return }
        }
        if let shuffle = mine.priorShuffle { _ = seams.setShuffle(shuffle) }
        if let mode = wantRepeat { _ = seams.setRepeat(mode) }
        if let after = seams.read(), isBack(after) { clearRecord(txn) }
    }
}

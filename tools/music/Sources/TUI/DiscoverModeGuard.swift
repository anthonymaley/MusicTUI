import Foundation

// S10 and the restore of Discover play-from-here: shuffle and song repeat are
// switched off for our play and put back afterwards to what he had, unless he
// changed them himself in the meantime. His prior values live in the journal
// entry (`priorShuffle`, `priorRepeat`), written BEFORE anything is set, so a
// crash leaves them recorded for reconcile. If the modes cannot be read or
// set, nothing plays (`switchOff` answers false).

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
        _ = try? journal.update(txn: txn) { $0.priorShuffle = nil; $0.priorRepeat = nil }
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

        // Record before setting anything.
        if case .kept = source {} else {
            do {
                try journal.update(txn: txn) {
                    $0.priorShuffle = shuffleToRecord
                    $0.priorRepeat = repeatToRecord
                }
            } catch { return false }
        }
        if case .moved(let from) = source {
            // His originals now live on this entry only. If an older holder
            // cannot be cleared, undo and change nothing.
            var cleared: [DiscoverCopyEntry] = []
            for entry in from {
                do {
                    try journal.update(txn: entry.txn) { $0.priorShuffle = nil; $0.priorRepeat = nil }
                    cleared.append(entry)
                } catch {
                    for undone in cleared {
                        _ = try? journal.update(txn: undone.txn) {
                            $0.priorShuffle = undone.priorShuffle
                            $0.priorRepeat = undone.priorRepeat
                        }
                    }
                    clearRecord(txn)
                    return false
                }
            }
        }

        // Undo of a failed attempt: modes back as they were read, and the
        // record back to what it was before this call.
        func giveUp(shuffleSet: Bool, repeatSet: Bool) -> Bool {
            if shuffleSet { _ = seams.setShuffle(current.shuffle) }
            if repeatSet { _ = seams.setRepeat(current.songRepeat) }
            switch source {
            case .kept:
                break   // the record was his before this call and still is
            case .fresh:
                clearRecord(txn)
            case .moved(let from):
                clearRecord(txn)
                for entry in from {
                    _ = try? journal.update(txn: entry.txn) {
                        $0.priorShuffle = entry.priorShuffle
                        $0.priorRepeat = entry.priorRepeat
                    }
                }
            }
            return false
        }

        guard seams.setShuffle(false) else { return giveUp(shuffleSet: true, repeatSet: false) }
        guard seams.setRepeat(.off) else { return giveUp(shuffleSet: true, repeatSet: true) }
        guard isOff(seams.read()) else { return giveUp(shuffleSet: true, repeatSet: true) }
        return true
    }

    /// Puts his recorded values back unless he changed them since. Idempotent;
    /// works on an entry in any state.
    func restore(txn: String) {
        guard let all = try? journal.entries(),
              let mine = all.first(where: { $0.txn == txn }),
              holdsPrior(mine) else { return }
        guard let current = seams.read() else { return }   // unreadable: leave it recorded
        guard isOff(current) else {
            clearRecord(txn)   // he changed them: his values stand
            return
        }
        var ok = true
        if let shuffle = mine.priorShuffle, !seams.setShuffle(shuffle) { ok = false }
        if let raw = mine.priorRepeat, let mode = RepeatMode(rawValue: raw), !seams.setRepeat(mode) { ok = false }
        if ok { clearRecord(txn) }
    }
}

import XCTest
@testable import music

/// A scripted Music.app for the mode guard: it holds the modes, records every
/// set in `calls`, and can fail a named set or the read.
private final class ModeGuardFakeModes {
    var shuffle: Bool
    var songRepeat: RepeatMode
    var readable = true
    var failShuffleSet = false
    var failRepeatSet = false
    /// Replaces what a read returns after the sets (a wrong read-back).
    var readOverride: ((Bool, RepeatMode) -> (shuffle: Bool, songRepeat: RepeatMode)?)?
    private(set) var calls: [String] = []
    var onFirstSet: (() -> Void)?
    /// Scripts one setter fully: whether the value is applied, and what the
    /// set answers. Nil leaves the `fail…Set` flags in charge.
    var shuffleSet: ((Bool) -> (applied: Bool, ok: Bool))?
    var repeatSet: ((RepeatMode) -> (applied: Bool, ok: Bool))?

    init(shuffle: Bool, songRepeat: RepeatMode) {
        self.shuffle = shuffle
        self.songRepeat = songRepeat
    }

    var seams: DiscoverModeGuard.Seams {
        DiscoverModeGuard.Seams(
            read: { [self] in
                guard readable else { return nil }
                if let readOverride, calls.count >= 2 { return readOverride(shuffle, songRepeat) }
                return (shuffle, songRepeat)
            },
            setShuffle: { [self] on in
                if calls.isEmpty { onFirstSet?() }
                calls.append("shuffle:\(on)")
                if let shuffleSet {
                    let answer = shuffleSet(on)
                    if answer.applied { shuffle = on }
                    return answer.ok
                }
                if failShuffleSet { return false }
                shuffle = on
                return true
            },
            setRepeat: { [self] mode in
                if calls.isEmpty { onFirstSet?() }
                calls.append("repeat:\(mode.rawValue)")
                if let repeatSet {
                    let answer = repeatSet(mode)
                    if answer.applied { songRepeat = mode }
                    return answer.ok
                }
                if failRepeatSet { return false }
                songRepeat = mode
                return true
            })
    }
}

private func modeGuardEntry(_ txn: String, shuffle: Bool? = nil, repeat mode: String? = nil,
                            state: DiscoverCopyState = .listening, pending: Bool? = nil) -> DiscoverCopyEntry {
    DiscoverCopyEntry(txn: txn, playlistID: "pl.x", title: "P", state: state, hex: "0123456789ABCDEF",
                      copiesRead: 1, watching: false, copySeen: false, toldAtLaunch: false,
                      priorShuffle: shuffle, priorRepeat: mode, restorePending: pending,
                      createdAt: 1, updatedAt: 1)
}

final class DiscoverModeGuardTests: XCTestCase {
    private func make(_ entries: [DiscoverCopyEntry], _ modes: ModeGuardFakeModes)
        -> (DiscoverModeGuard, InMemoryDiscoverCopyJournalStore) {
        let store = InMemoryDiscoverCopyJournalStore(entries: entries)
        return (DiscoverModeGuard(journal: store, seams: modes.seams), store)
    }

    private func entry(_ store: InMemoryDiscoverCopyJournalStore, _ txn: String) -> DiscoverCopyEntry? {
        store.stored.first { $0.txn == txn }
    }

    func testPriorValuesAreInTheJournalBeforeTheFirstSet() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        var seenAtFirstSet: DiscoverCopyEntry?
        var eventsAtFirstSet: [String] = []
        modes.onFirstSet = {
            seenAtFirstSet = store.stored.first
            eventsAtFirstSet = store.events
        }
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(seenAtFirstSet?.priorShuffle, true)
        XCTAssertEqual(seenAtFirstSet?.priorRepeat, "all")
        XCTAssertTrue(eventsAtFirstSet.contains("update:A"))
    }

    func testSwitchOffSetsBothOffAndReadsBack() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls, ["shuffle:false", "repeat:off"])
        XCTAssertFalse(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .off)
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
    }

    func testUnreadableChangesNothing() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        modes.readable = false
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls, [])
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertEqual(store.events, [])
    }

    func testFailedJournalWriteChangesNothing() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        store.failWrites = { $0.hasPrefix("update:A") }
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls, [])
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
    }

    func testFailedShuffleSetPutsBackAndClearsTheRecord() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        modes.failShuffleSet = true
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertEqual(modes.calls, ["shuffle:false", "shuffle:true"])
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
    }

    func testFailedRepeatSetPutsBothBackAndClearsTheRecord() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        modes.failRepeatSet = true
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertTrue(modes.shuffle)
        // The record is cleared because a fresh read shows both originals
        // back, not because the compensating sets were issued.
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertEqual(modes.calls.first, "shuffle:false")
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testWrongReadBackPutsBackAndClearsTheRecord() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        // Both sets "succeed", but Music.app still reports shuffle on.
        modes.readOverride = { _, rep in (true, rep) }
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
    }

    func testRestorePutsBothBack() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
    }

    func testRestoreDoesNotOverwriteWhatHeChangedSince() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        modes.shuffle = true            // he turned shuffle back on himself
        modes.songRepeat = .one
        let before = modes.calls
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, before)
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
    }

    func testRestoreAfterACrashReadsTheRecordedValues() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        // A fresh guard on a journal that already holds the record.
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "one", state: .closed)], modes)
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
    }

    func testSecondRestoreIsANoOp() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, _) = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        guardian.restore(txn: "A")
        let before = modes.calls
        modes.shuffle = false
        modes.songRepeat = .off
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, before)
        XCTAssertFalse(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .off)
    }

    func testRestoreUnreadableLeavesTheValuesRecorded() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        modes.readable = false
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, [])
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
    }

    func testRestoreKeepsTheRecordWhenASetFails() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        modes.failRepeatSet = true
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
        guardian.restore(txn: "A")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)
    }

    func testRestoreWithNoRecordDoesNothing() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A", state: .closed)], modes)
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, [])
        XCTAssertEqual(store.events, ["entries"])
    }

    func testPlayAThenPlayBMovesHisOriginalsToTheNewestPlay() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A"), modeGuardEntry("B")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        // Play B starts while A's modes are still ours (off/off now).
        XCTAssertTrue(guardian.switchOff(txn: "B"))
        XCTAssertEqual(entry(store, "B")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "B")?.priorRepeat, "all")
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        // A's restore does nothing; B's returns his originals.
        let before = modes.calls
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, before)
        XCTAssertFalse(modes.shuffle)
        guardian.restore(txn: "B")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
    }

    func testFailedMoveRestoresTheOlderHoldersRecord() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        modes.failShuffleSet = true
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all"), modeGuardEntry("B")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "B"))
        // His originals are still recorded, on A, and not lost.
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
        XCTAssertNil(entry(store, "B")?.priorShuffle)
    }

    func testSecondSwitchOffOnTheSameEntryKeepsItsPriorValues() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        // Replay of the same copy: modes are off/off now; the record must not become off/off.
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
    }

    func testUnknownEntryIsRefused() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, _) = make([], modes)
        XCTAssertFalse(guardian.switchOff(txn: "nope"))
        XCTAssertEqual(modes.calls, [])
    }

    // MARK: - The record is cleared only on a verified read

    func testTheRecordIsPendingWhileTheModesAreInTransitAndNotAfter() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        var pendingAtFirstSet: Bool?
        modes.onFirstSet = { pendingAtFirstSet = store.stored.first?.restorePending }
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(pendingAtFirstSet, true, "a crash between the sets must leave a restore to retry")
        XCTAssertNil(entry(store, "A")?.restorePending, "verified off: an ordinary record again")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
    }

    func testASetThatAppliesThenReportsFailureIsClearedOnlyOnceReadBack() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        // Music.app applies every shuffle set and reports each as failed.
        modes.shuffleSet = { _ in (applied: true, ok: false) }
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls, ["shuffle:false", "shuffle:true"])
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testAFailedCompensatingSetKeepsTheRecordPendingAndTheRetryFinishes() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        // Shuffle off is applied but reported failed; putting it back fails outright.
        modes.shuffleSet = { on in on ? (applied: false, ok: false) : (applied: true, ok: false) }
        let (guardian, store) = make([modeGuardEntry("A", state: .closed)], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertFalse(modes.shuffle, "the rollback did not take")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)

        // Still failing: the record survives another attempt.
        guardian.restore(txn: "A")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.restorePending, true)

        // Reconcile's retry. The modes read (off, all), which is not (off, off):
        // without the pending mark that would read as "he changed them".
        modes.shuffleSet = nil
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testAnUnreadableRollbackKeepsTheRecordPending() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        modes.failRepeatSet = true
        // Readable until the rollback's verifying read.
        modes.readOverride = { _, _ in nil }
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)
    }

    func testRestorePartialFailureIsFinishedByARetry() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        modes.failRepeatSet = true
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all", state: .closed)], modes)
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .off)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)

        // (on, off) is not (off, off), yet he changed nothing: the retry sets repeat.
        modes.failRepeatSet = false
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testReconcileRetriesAPendingRestoreFromTheJournalAlone() {
        // A fresh guard after a crash, as reconcile runs it on a closed entry.
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .all)
        let (guardian, store) = make(
            [modeGuardEntry("A", shuffle: true, repeat: "one", state: .closed, pending: true)], modes)
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, ["shuffle:true", "repeat:one"])
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testAPendingRestoreAlreadyBackIsClearedWithoutASet() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = make(
            [modeGuardEntry("A", shuffle: true, repeat: "one", state: .closed, pending: true)], modes)
        guardian.restore(txn: "A")
        XCTAssertEqual(modes.calls, [])
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testANewPlayInheritsAPendingRecordAsAnOrdinaryOne() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .all)
        let (guardian, store) = make(
            [modeGuardEntry("A", shuffle: true, repeat: "all", state: .closed, pending: true), modeGuardEntry("B")],
            modes)
        XCTAssertTrue(guardian.switchOff(txn: "B"))
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.restorePending)
        XCTAssertEqual(entry(store, "B")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "B")?.priorRepeat, "all")
        XCTAssertNil(entry(store, "B")?.restorePending)
        guardian.restore(txn: "B")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
    }

    // MARK: - A same-copy replay rolls back like any other source

    /// A's play is on (his originals recorded, modes off), he then set
    /// (shuffle on, repeat all) himself, and the same copy is played again.
    private func replayed(_ modes: ModeGuardFakeModes)
        -> (DiscoverModeGuard, InMemoryDiscoverCopyJournalStore) {
        let made = make([modeGuardEntry("A")], modes)
        XCTAssertTrue(made.0.switchOff(txn: "A"))
        modes.shuffle = true
        modes.songRepeat = .all
        return made
    }

    func testAReplayIsPendingWhileItsSetsAreInTransit() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = replayed(modes)
        var pendingAtSet: Bool?
        modes.shuffleSet = { on in
            pendingAtSet = store.stored.first?.restorePending
            return (applied: true, ok: true)
        }
        XCTAssertTrue(guardian.switchOff(txn: "A"))
        XCTAssertEqual(pendingAtSet, true)
        XCTAssertNil(entry(store, "A")?.restorePending)
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
    }

    func testAReplayWhoseSetAppliesThenReportsFailureKeepsTheRecordAndIsVerifiedBack() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = replayed(modes)
        modes.shuffleSet = { _ in (applied: true, ok: false) }
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        // Read back as they were at the replay: the record is as it was before it.
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
        XCTAssertNil(entry(store, "A")?.restorePending)

        modes.shuffleSet = nil
        guardian.restore(txn: "A")
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
    }

    func testAReplayWhoseAppliedSetCannotBeReadBackStaysPendingAndALaterRestoreFinishes() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = replayed(modes)
        // Applied and reported failed; the read after the rollback fails.
        modes.shuffleSet = { _ in (applied: true, ok: false) }
        modes.readOverride = { [unowned modes] shuffle, mode in modes.calls.count >= 4 ? nil : (shuffle, mode) }
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls.count, 4, "the first play's two sets, the replay's one, and its rollback")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)

        modes.shuffleSet = nil
        modes.readOverride = nil
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testAReplayWhoseCompensatingSetFailsStaysPendingAndALaterRestoreFinishes() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = replayed(modes)
        // Shuffle off is applied but reported failed; putting it back fails outright.
        modes.shuffleSet = { on in on ? (applied: false, ok: false) : (applied: true, ok: false) }
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertFalse(modes.shuffle, "the rollback did not take")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)

        modes.shuffleSet = nil
        guardian.restore(txn: "A")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .one)
        XCTAssertNil(entry(store, "A")?.priorShuffle)
        XCTAssertNil(entry(store, "A")?.priorRepeat)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }
}

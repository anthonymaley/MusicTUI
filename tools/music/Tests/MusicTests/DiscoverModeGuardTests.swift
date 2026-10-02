import XCTest
@testable import music

/// A scripted Music.app for the mode guard: it holds the modes and the
/// player, records every set in `calls`, and can fail a named set or the read.
/// `switchOff` reaches it through `read`/`setShuffle`/`setRepeat`; `restore`
/// reaches it only through `dfhModeRestoreContract`, the one-script contract.
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
    /// The player as the restore script's look sees it. Stopped by default.
    var player: DiscoverCopyPlayerRead? = DiscoverCopyPlayerRead(state: "stopped", playlistID: nil, trackID: nil)
    /// Replaces the contract's answer (a timeout, junk output).
    var restoreAnswer: DiscoverModeRestoreAnswer?
    private(set) var restoreRequests: [DiscoverModeRestoreRequest] = []

    init(shuffle: Bool, songRepeat: RepeatMode) {
        self.shuffle = shuffle
        self.songRepeat = songRepeat
    }

    private func readNow() -> (shuffle: Bool, songRepeat: RepeatMode)? {
        guard readable else { return nil }
        if let readOverride, calls.count >= 2 { return readOverride(shuffle, songRepeat) }
        return (shuffle, songRepeat)
    }

    private func set(shuffle on: Bool) -> Bool {
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
    }

    private func set(repeat mode: RepeatMode) -> Bool {
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
    }

    var seams: DiscoverModeGuard.Seams {
        DiscoverModeGuard.Seams(
            read: { [self] in readNow() },
            setShuffle: { [self] in set(shuffle: $0) },
            setRepeat: { [self] in set(repeat: $0) },
            restore: { [self] request in
                restoreRequests.append(request)
                let answer = dfhModeRestoreContract(request, modes: readNow(), player: player) { s, r in
                    if let s { _ = set(shuffle: s) }
                    if let r { _ = set(repeat: r) }
                    return readNow()
                }
                return restoreAnswer ?? answer
            })
    }
}

private let ownHex = "0123456789ABCDEF"
private let otherHex = "00000000000000AA"

private func modeGuardEntry(_ txn: String, shuffle: Bool? = nil, repeat mode: String? = nil,
                            state: DiscoverCopyState = .listening, pending: Bool? = nil,
                            hex: String? = ownHex) -> DiscoverCopyEntry {
    DiscoverCopyEntry(txn: txn, playlistID: "pl.x", title: "P", state: state, hex: hex,
                      copiesRead: 1, watching: false, copySeen: false, toldAtLaunch: false,
                      priorShuffle: shuffle, priorRepeat: mode, restorePending: pending,
                      createdAt: 1, updatedAt: 1)
}

private func playing(_ playlist: String?, _ state: String = "playing") -> DiscoverCopyPlayerRead {
    DiscoverCopyPlayerRead(state: state, playlistID: playlist, trackID: "T")
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

    // MARK: - The one guarded restore

    func testAClosedPendingRecordWithOurCopyPlayingIsHeldNotRestoredAndKeepsItsMark() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .all)
        modes.player = playing(ownHex)
        let (guardian, store) = make(
            [modeGuardEntry("A", shuffle: true, repeat: "one", state: .closed, pending: true)], modes)
        XCTAssertEqual(guardian.restore(txn: "A"), .held(watch: ownHex))
        XCTAssertEqual(modes.calls, [])
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
        XCTAssertEqual(entry(store, "A")?.restorePending, true)
    }

    func testAPausedOrPlayingCopyOfAnyJournalEntryHoldsTheRestore() {
        for state in [DiscoverCopyState.intent, .owned, .listening, .preexisting, .uncertain, .closed] {
            for playerState in ["playing", "paused"] {
                let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
                modes.player = playing(otherHex, playerState)
                let other = modeGuardEntry("A", state: state, hex: state == .intent ? nil : otherHex)
                let (guardian, store) = make([other, modeGuardEntry("B", shuffle: true, repeat: "all")], modes)
                let expected: DiscoverModeRestore = state == .intent ? .restored : .held(watch: otherHex)
                XCTAssertEqual(guardian.restore(txn: "B"), expected, "\(state) \(playerState)")
                if state != .intent {
                    XCTAssertEqual(modes.calls, [], "\(state) \(playerState)")
                    XCTAssertEqual(entry(store, "B")?.priorShuffle, true)
                }
            }
        }
    }

    func testAnUnreadableCurrentPlaylistWhileNotStoppedHoldsTheRestore() {
        let reads: [DiscoverCopyPlayerRead?] = [
            playing(nil), playing(nil, "paused"), playing("missing value"),
            DiscoverCopyPlayerRead(state: "", playlistID: nil, trackID: nil),   // the state read failed too
            nil,
        ]
        for read in reads {
            for pending in [nil, true] as [Bool?] {
                let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
                modes.player = read
                let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all", pending: pending)], modes)
                XCTAssertEqual(guardian.restore(txn: "A"), .held(watch: ownHex), "\(String(describing: read))")
                XCTAssertEqual(modes.calls, [])
                XCTAssertEqual(entry(store, "A")?.restorePending, pending)
            }
        }
    }

    func testAStoppedPlayerOrAReadableForeignPlaylistLetsTheRestoreThrough() {
        let reads = [DiscoverCopyPlayerRead(state: "stopped", playlistID: ownHex, trackID: nil),
                     playing("00000000000000EE"), playing("00000000000000EE", "paused")]
        for read in reads {
            for pending in [nil, true] as [Bool?] {
                let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
                modes.player = read
                let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all", pending: pending)], modes)
                XCTAssertEqual(guardian.restore(txn: "A"), .restored, "\(read)")
                XCTAssertEqual(modes.calls, ["shuffle:true", "repeat:all"])
                XCTAssertNil(entry(store, "A")?.priorShuffle)
                XCTAssertNil(entry(store, "A")?.priorRepeat)
                XCTAssertNil(entry(store, "A")?.restorePending)
            }
        }
    }

    func testAMalformedHexAnywhereInTheJournalFailsClosed() {
        for bad in ["0000abcd0000abcd", "XYZ"] {
            for (read, expected) in [(playing("00000000000000EE"), DiscoverModeRestore.held(watch: nil)),
                                     (DiscoverCopyPlayerRead(state: "stopped", playlistID: nil, trackID: nil), .restored)] {
                let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
                modes.player = read
                let (guardian, _) = make([modeGuardEntry("X", state: .closed, hex: bad),
                                          modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
                XCTAssertEqual(guardian.restore(txn: "A"), expected, "\(bad) \(read)")
                XCTAssertEqual(modes.restoreRequests.map(\.ours), [.unknowable])
            }
        }
    }

    func testTheLookAndTheSetsAreOneSeamCall() {
        let answers: [DiscoverModeRestoreAnswer] = [
            .held(current: nil), .held(current: ownHex), .modesUnreadable, .changed, .back,
            .set(shuffle: true, songRepeat: .all), .set(shuffle: false, songRepeat: nil), .unknown,
        ]
        for answer in answers {
            for pending in [nil, true] as [Bool?] {
                var calls = 0
                let store = InMemoryDiscoverCopyJournalStore(
                    entries: [modeGuardEntry("A", shuffle: true, repeat: "all", pending: pending)])
                let guardian = DiscoverModeGuard(journal: store, seams: DiscoverModeGuard.Seams(
                    read: { XCTFail("restore read the modes outside its one script"); return nil },
                    setShuffle: { _ in XCTFail("restore set shuffle outside its one script"); return false },
                    setRepeat: { _ in XCTFail("restore set repeat outside its one script"); return false },
                    restore: { _ in calls += 1; return answer }))
                guardian.restore(txn: "A")
                XCTAssertEqual(calls, 1, "\(answer)")
            }
        }
    }

    func testAHeldOrdinaryRecordGivesBackTheMarkItWrote() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        modes.player = playing(ownHex)
        let (_, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
        var pendingDuringScript: Bool?
        let inner = modes.seams.restore
        let watched = DiscoverModeGuard(journal: store, seams: DiscoverModeGuard.Seams(
            read: modes.seams.read, setShuffle: modes.seams.setShuffle, setRepeat: modes.seams.setRepeat,
            restore: { pendingDuringScript = store.stored.first?.restorePending; return inner($0) }))
        XCTAssertEqual(watched.restore(txn: "A"), .held(watch: ownHex))
        XCTAssertEqual(pendingDuringScript, true, "marked while the script is in flight")
        XCTAssertNil(entry(store, "A")?.restorePending, "an ordinary record stays ordinary")
        XCTAssertEqual(store.events, ["entries", "update:A", "update:A"], "mark, then unmark")
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
    }

    func testAnOrdinaryRecordAsksForHisChangeAndAPendingOneDoesNot() {
        for pending in [nil, true] as [Bool?] {
            let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)   // not (off, off)
            let (guardian, store) = make([modeGuardEntry("A", shuffle: false, repeat: "one", pending: pending)], modes)
            let result = guardian.restore(txn: "A")
            XCTAssertEqual(modes.restoreRequests.map(\.unlessHeChanged), [pending != true])
            if pending == true {
                XCTAssertEqual(result, .restored)
                XCTAssertEqual(modes.calls, ["shuffle:false", "repeat:one"])
            } else {
                XCTAssertEqual(result, .hisChange)
                XCTAssertEqual(modes.calls, [], "his values stand")
                XCTAssertTrue(modes.shuffle)
                XCTAssertEqual(modes.songRepeat, .all)
            }
            XCTAssertNil(entry(store, "A")?.priorShuffle)
        }
    }

    func testNoAnswerOrAWrongReadBackLeavesTheRecordPending() {
        for answer in [DiscoverModeRestoreAnswer.unknown, .set(shuffle: true, songRepeat: .off),
                       .set(shuffle: nil, songRepeat: nil)] {
            let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
            modes.restoreAnswer = answer
            let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
            XCTAssertEqual(guardian.restore(txn: "A"), .unverified, "\(answer)")
            XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
            XCTAssertEqual(entry(store, "A")?.priorRepeat, "all")
            XCTAssertEqual(entry(store, "A")?.restorePending, true)
        }
    }

    func testAMarkThatCannotBeWrittenRunsNoScript() {
        let modes = ModeGuardFakeModes(shuffle: false, songRepeat: .off)
        let (guardian, store) = make([modeGuardEntry("A", shuffle: true, repeat: "all")], modes)
        store.failWrites = { $0.hasPrefix("update:A") }
        XCTAssertEqual(guardian.restore(txn: "A"), .notMarked)
        XCTAssertEqual(modes.restoreRequests, [])
        XCTAssertEqual(modes.calls, [])
        XCTAssertEqual(entry(store, "A")?.priorShuffle, true)
        XCTAssertNil(entry(store, "A")?.restorePending)
    }

    func testASwitchOffWaitsForARestoreInFlight() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        let store = InMemoryDiscoverCopyJournalStore(entries: [
            modeGuardEntry("A", shuffle: true, repeat: "all", state: .closed, hex: nil), modeGuardEntry("B"),
        ])
        let guardian = DiscoverModeGuard(journal: store, seams: DiscoverModeGuard.Seams(
            read: { reached.signal(); return nil },      // switchOff answers false at once
            setShuffle: { _ in false },
            setRepeat: { _ in false },
            restore: { _ in entered.signal(); release.wait(); return .back }))
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) { guardian.restore(txn: "A") }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async(group: done) { _ = guardian.switchOff(txn: "B") }
        XCTAssertEqual(reached.wait(timeout: .now() + 0.2), .timedOut, "switchOff must not read while a restore runs")
        release.signal()
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }

    func testTheRollbackBypassesThePlayerAndWritesOnlyWhatThisCallRead() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .one)
        let (guardian, store) = replayed(modes)       // he set (on, all) during our play
        modes.player = playing(ownHex)                // and our copy is still playing
        modes.shuffleSet = { _ in (applied: true, ok: false) }
        let before = modes.calls.count
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(Array(modes.calls[before...]), ["shuffle:false", "shuffle:true"],
                       "the rollback writes the (on, all) read at the top of this call, not the record (on, one)")
        XCTAssertEqual(modes.restoreRequests, [], "switchOff never goes through the guarded restore")
        XCTAssertTrue(modes.shuffle)
        XCTAssertEqual(modes.songRepeat, .all)
        XCTAssertEqual(entry(store, "A")?.priorRepeat, "one")
    }

    /// Residual (Codex 69.4): the rollback is pinned to the values read at
    /// the start of its own call, so a change he makes DURING a failed
    /// transition is overwritten by it.
    func testTheRollbackWritesTheValuesReadAtTheStartOfItsCallOverAConcurrentChange() {
        let modes = ModeGuardFakeModes(shuffle: true, songRepeat: .all)
        let (guardian, store) = make([modeGuardEntry("A")], modes)
        modes.repeatSet = { [unowned modes] mode in
            if mode == .off { modes.songRepeat = .one }   // his own click lands mid-transition
            return mode == .off ? (applied: false, ok: false) : (applied: true, ok: true)
        }
        XCTAssertFalse(guardian.switchOff(txn: "A"))
        XCTAssertEqual(modes.calls, ["shuffle:false", "repeat:off", "shuffle:true", "repeat:all"])
        XCTAssertEqual(modes.songRepeat, .all, "his concurrent 'one' is overwritten by the start-of-call 'all'")
        XCTAssertNil(entry(store, "A")?.priorShuffle, "verified back to what the call read: the record is cleared")
        XCTAssertEqual(modes.restoreRequests, [])
    }

    // MARK: - discoverCopySettleModes

    private func settled(_ answer: DiscoverModeRestoreAnswer, entries: [DiscoverCopyEntry],
                         txn: String = "A") -> (DiscoverModeRestore, [String], [String]) {
        let store = InMemoryDiscoverCopyJournalStore(entries: entries)
        let guardian = DiscoverModeGuard(journal: store, seams: DiscoverModeGuard.Seams(
            read: { nil }, setShuffle: { _ in false }, setRepeat: { _ in false }, restore: { _ in answer }))
        var adopted: [String] = []
        var logs: [String] = []
        let result = discoverCopySettleModes(txn: txn, modes: guardian, adopt: { adopted.append("\($0):\($1)") },
                                             log: { logs.append($0) })
        return (result, adopted, logs)
    }

    func testSettleWatchesTheCopyThatHeldIt() {
        let holder = modeGuardEntry("A", shuffle: true, repeat: "all")
        let other = modeGuardEntry("X", state: .closed, hex: otherHex)
        XCTAssertEqual(settled(.held(current: otherHex), entries: [holder, other]).1, ["A:\(otherHex)"])
        XCTAssertEqual(settled(.held(current: nil), entries: [holder]).1, ["A:\(ownHex)"], "its own copy")
        for answer in [DiscoverModeRestoreAnswer.back, .unknown, .changed, .set(shuffle: true, songRepeat: .all),
                       .modesUnreadable] {
            let (result, adopted, logs) = settled(answer, entries: [holder])
            XCTAssertEqual(adopted, [], "\(answer)")
            XCTAssertEqual(logs.isEmpty, result == .restored, "\(answer) -> \(result)")
        }
    }

    func testSettleWatchesNothingWhenTheHoldNamesNoUsableID() {
        let unknowable = [modeGuardEntry("A", shuffle: true, repeat: "all"), modeGuardEntry("X", hex: "XYZ")]
        let (first, adoptedA, _) = settled(.held(current: nil), entries: unknowable)
        XCTAssertEqual(first, .held(watch: nil))
        XCTAssertEqual(adoptedA, [])
        let noHex = [modeGuardEntry("A", shuffle: true, repeat: "all", state: .closed, hex: nil)]
        let (second, adoptedB, logs) = settled(.held(current: nil), entries: noHex)
        XCTAssertEqual(second, .held(watch: nil))
        XCTAssertEqual(adoptedB, [])
        XCTAssertEqual(logs.count, 1)
    }
}

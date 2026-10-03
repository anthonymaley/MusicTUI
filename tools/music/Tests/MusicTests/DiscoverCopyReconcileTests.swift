import XCTest
@testable import music

/// Crash replay: a journal seeded in each state, then reconcile (score step
/// C2). Fakes only; the journal is a file at a temporary directory.
final class DiscoverCopyReconcileTests: XCTestCase {
    private typealias F = DFHC2Fixture

    private func reconcile(_ f: DFHC2Fixture, atLaunch: Bool) {
        DiscoverCopyReconciler(copy: f.copySeams, post: f.post).run(atLaunch: atLaunch)
    }

    private func seeded(_ entries: DiscoverCopyEntry...) throws -> DFHC2Fixture {
        let f = F()
        for entry in entries { try f.journal.insert(entry) }
        return f
    }

    /// Everything but `updatedAt`, which reconcile stamps.
    private func stripped(_ entry: DiscoverCopyEntry) -> DiscoverCopyEntry {
        var copy = entry
        copy.updatedAt = 0
        return copy
    }

    // MARK: closed

    func testAClosedEntryStillHoldingPriorModesGetsThemRestored() throws {
        let f = try seeded(F.entry("plain", .closed),
                           F.entry("shuffle", .closed, priorShuffle: true),
                           F.entry("repeat", .closed, priorRepeat: "one"))
        let before = try f.onDisk()
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.restoreCalls, ["shuffle", "repeat"])
        XCTAssertEqual(f.deleteCalls, [])
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(try f.onDisk(), before)
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.restoreCalls, ["shuffle", "repeat", "shuffle", "repeat"])
    }

    // MARK: uncertain

    func testAnUncertainEntryIsNeverTouchedAndToldOnceAtLaunch() throws {
        let f = try seeded(F.entry("seen", .uncertain, hex: F.hexA, copySeen: true, title: "Seen Mix"),
                           F.entry("maybe", .uncertain, copySeen: false, title: "Maybe Mix"))
        let before = try f.onDisk()

        // Before a play: nothing at all.
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(try f.onDisk(), before)

        // The first launch tells him, once each, with the sentence the evidence earns.
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.toasts, [
            .outcome(.refused(discoverCopyLeftText(playlist: "Seen Mix")), title: "Seen Mix"),
            .outcome(.refused(discoverCopyMaybeAddedText(playlist: "Maybe Mix")), title: "Maybe Mix"),
        ])
        let after = try f.onDisk()
        XCTAssertEqual(after.map(\.state), [.uncertain, .uncertain])
        XCTAssertEqual(after.map(\.toldAtLaunch), [true, true])
        XCTAssertEqual(after.map(\.hex), before.map(\.hex))
        XCTAssertEqual(after.map(\.copySeen), [true, false])

        // The second launch says nothing more.
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.toasts.count, 2)
        XCTAssertEqual(try f.onDisk(), after)

        XCTAssertEqual(f.deleteCalls, [])
        XCTAssertEqual(f.restoreCalls, [])
        XCTAssertEqual(f.adoptCalls, [])
        XCTAssertEqual(f.ops.calls, [])
    }

    // MARK: intent

    func testAnIntentWaitsWhileSpanDACDataIsNotSelected() throws {
        let f = try seeded(F.entry("I", .intent))
        f.spandacSelected = false
        f.ops.copiesResults = [.success([F.copyA])]
        let before = try f.onDisk()
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.ops.calls, [])               // asking would start SpanDAC
        XCTAssertEqual(try f.onDisk(), before)
        XCTAssertEqual(f.toasts, [])
    }

    func testAnIntentWhoseCopiesReadFailsIsLeft() throws {
        let f = try seeded(F.entry("I", .intent))
        f.ops.copiesResults = [.failure(SpanDACLibraryOpError.failed("down"))]
        let before = try f.onDisk()
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertEqual(try f.onDisk(), before)
        XCTAssertEqual(f.toasts, [])
    }

    func testAnIntentWithNoCopyIsClosed() throws {
        let f = try seeded(F.entry("I", .intent))
        f.ops.copiesResults = [.success([])]
        reconcile(f, atLaunch: true)
        XCTAssertEqual(try f.onDisk().map(\.state), [.closed])
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(f.deleteCalls, [])
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])   // never an add
    }

    func testAnIntentWithACopyPresentIsUncertainNamedAndNeverDeleted() throws {
        for atLaunch in [true, false] {
            for copies in [[F.copyA], [F.copyA, F.copyB]] {
                let f = try seeded(F.entry("I", .intent, title: "Road Mix"))
                f.ops.copiesResults = [.success(copies)]
                reconcile(f, atLaunch: atLaunch)

                let entry = try XCTUnwrap(try f.onDisk().first)
                XCTAssertEqual(entry.state, .uncertain)
                XCTAssertTrue(entry.copySeen)
                XCTAssertNil(entry.hex)
                XCTAssertFalse(entry.isDeletable)
                XCTAssertEqual(entry.toldAtLaunch, atLaunch)
                XCTAssertEqual(f.toasts, [
                    .outcome(.refused(discoverCopyLeftText(playlist: "Road Mix")), title: "Road Mix"),
                ])
                XCTAssertEqual(f.deleteCalls, [])
                XCTAssertEqual(f.adoptCalls, [])

                // Told before a play: the next launch repeats it once. Told at launch: never again.
                reconcile(f, atLaunch: true)
                XCTAssertEqual(f.toasts.count, atLaunch ? 1 : 2)
                reconcile(f, atLaunch: true)
                XCTAssertEqual(f.toasts.count, atLaunch ? 1 : 2)
                XCTAssertEqual(f.deleteCalls, [])
            }
        }
    }

    // MARK: owned, listening, preexisting

    func testASparedCopyIsWatchedAgainAndAnOwnedOneBecomesListening() throws {
        let f = try seeded(F.entry("O", .owned, hex: F.hexA),
                           F.entry("L", .listening, hex: "00000000000000BB"),
                           F.entry("P", .preexisting, hex: "00000000000000CC"))
        f.deleteResult = { _ in .spared }
        reconcile(f, atLaunch: true)

        let after = try f.onDisk()
        XCTAssertEqual(after.map(\.state), [.listening, .listening, .preexisting])
        XCTAssertEqual(after.map(\.watching), [true, true, true])
        XCTAssertEqual(f.deleteCalls, ["O", "L", "P"])
        XCTAssertEqual(f.adoptCalls, ["O:\(F.hexA)", "L:00000000000000BB", "P:00000000000000CC"])
        XCTAssertEqual(f.restoreCalls, [])
        XCTAssertEqual(f.toasts, [])
    }

    func testAnEndedCopyGetsItsModesRestoredAndAPreexistingEntryCloses() throws {
        for result in [DiscoverCopyDeleteResult.deleted, .alreadyGone, .kept] {
            let f = try seeded(F.entry("O", .owned, hex: F.hexA),
                               F.entry("L", .listening, hex: "00000000000000BB", watching: true),
                               F.entry("P", .preexisting, hex: "00000000000000CC"))
            let before = try f.onDisk()
            f.deleteResult = { _ in result }
            reconcile(f, atLaunch: false)

            let after = try f.onDisk()
            XCTAssertEqual(f.deleteCalls, ["O", "L", "P"], "\(result)")
            XCTAssertEqual(f.restoreCalls, [], "\(result): none of them holds a record")
            XCTAssertEqual(f.adoptCalls, [], "\(result)")
            // Reconcile closes only the preexisting one; the guard owns the rest.
            XCTAssertEqual(after.map(\.state), [.owned, .listening, .closed], "\(result)")
            XCTAssertEqual(Array(after.prefix(2)), Array(before.prefix(2)), "\(result)")
            XCTAssertEqual(f.toasts, [], "\(result)")
        }
    }

    func testAFailedDeleteIsLeftForTheNextReconcile() throws {
        let f = try seeded(F.entry("O", .owned, hex: F.hexA),
                           F.entry("P", .preexisting, hex: "00000000000000CC"))
        let before = try f.onDisk()
        f.deleteResult = { _ in .failed }
        reconcile(f, atLaunch: true)
        XCTAssertEqual(try f.onDisk(), before)
        XCTAssertEqual(f.restoreCalls, [])
        XCTAssertEqual(f.adoptCalls, [])
        XCTAssertEqual(f.deleteCalls, ["O", "P"])
    }

    // MARK: a recorded mode restore, whatever the entry's state

    private func pending(_ entry: DiscoverCopyEntry) -> DiscoverCopyEntry {
        var copy = entry
        copy.restorePending = true
        return copy
    }

    /// A scripted Music.app: his modes, every set that reached them, and the player.
    private final class Music68 {
        var shuffle = false
        var songRepeat = RepeatMode.all
        var state = "stopped"
        var current: String?
        var setsWork = true
        private(set) var sets: [String] = []
        func set(shuffle on: Bool) { sets.append("shuffle:\(on)"); if setsWork { shuffle = on } }
        func set(repeat mode: RepeatMode) { sets.append("repeat:\(mode.rawValue)"); if setsWork { songRepeat = mode } }
    }

    /// The real guard over `music`: restore reaches it only through the
    /// one-script contract; switch-off is not exercised here.
    private func guardOver(_ music: Music68, _ journal: DiscoverCopyJournalStore) -> DiscoverModeGuard {
        DiscoverModeGuard(journal: journal, seams: DiscoverModeGuard.Seams(
            read: { XCTFail("reconcile never switches off"); return nil },
            setShuffle: { _ in XCTFail("reconcile never switches off"); return false },
            setRepeat: { _ in XCTFail("reconcile never switches off"); return false },
            restore: { request in
                dfhModeRestoreContract(request, modes: (music.shuffle, music.songRepeat),
                                       player: DiscoverCopyPlayerRead(state: music.state, playlistID: music.current,
                                                                      trackID: nil)) { s, r in
                    if let s { music.set(shuffle: s) }
                    if let r { music.set(repeat: r) }
                    return (music.shuffle, music.songRepeat)
                }
            }))
    }

    func testAPendingRestoreOnAnOwnedEntryIsRetriedThoughItsDeleteKeepsFailing() throws {
        let f = try seeded(pending(F.entry("O", .owned, hex: F.hexA, priorShuffle: true, priorRepeat: "all")))
        f.deleteResult = { _ in .failed }
        // The real guard over a scripted player, stopped: a half-set pair, (off, all).
        let music = Music68()
        music.setsWork = false
        let guardian = guardOver(music, f.journal)
        f.onRestore = { guardian.restore(txn: $0) }

        // The restore cannot be verified yet: everything stays for the next reconcile.
        reconcile(f, atLaunch: true)
        XCTAssertEqual(f.deleteCalls, ["O"])
        XCTAssertEqual(f.restoreCalls, ["O"])
        var entry = try XCTUnwrap(try f.onDisk().first)
        XCTAssertEqual(entry.priorShuffle, true)
        XCTAssertEqual(entry.restorePending, true)
        XCTAssertFalse(music.shuffle)

        // Verified: the mark and his values are cleared; the entry stays for the delete retry.
        music.setsWork = true
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.deleteCalls, ["O", "O"])
        XCTAssertEqual(f.restoreCalls, ["O", "O"])
        XCTAssertTrue(music.shuffle)
        XCTAssertEqual(music.songRepeat, .all)
        entry = try XCTUnwrap(try f.onDisk().first)
        XCTAssertNil(entry.priorShuffle)
        XCTAssertNil(entry.priorRepeat)
        XCTAssertNil(entry.restorePending)
        XCTAssertEqual(entry.state, .owned)
        XCTAssertEqual(entry.hex, F.hexA)

        // Nothing left to restore: only the delete is retried.
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.deleteCalls, ["O", "O", "O"])
        XCTAssertEqual(f.restoreCalls, ["O", "O"])
    }

    func testAPendingRestoreWaitsWhileTheCopyIsStillPlaying() throws {
        let f = try seeded(pending(F.entry("L", .listening, hex: F.hexA, watching: true,
                                           priorShuffle: true, priorRepeat: "all")))
        f.deleteResult = { _ in .spared }
        let music = Music68()
        music.state = "playing"
        music.current = F.hexA
        let guardian = guardOver(music, f.journal)
        let seams = f.copySeams
        f.onRestore = { discoverCopySettleModes(txn: $0, modes: guardian, adopt: seams.adopt, log: { _ in }) }
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.restoreCalls, ["L"], "offered, and the primitive holds it")
        XCTAssertEqual(music.sets, [], "our play is still on: the modes stay off until it ends")
        XCTAssertEqual(f.adoptCalls, ["L:\(F.hexA)", "L:\(F.hexA)"], "the spared replay, then the held restore")
        XCTAssertEqual(try f.onDisk().first?.restorePending, true)
        XCTAssertEqual(try f.onDisk().first?.priorShuffle, true)
    }

    func testAPendingRestoreOnAnUncertainOrPreexistingEntryIsRetriedAndNothingElseTouched() throws {
        let f = try seeded(
            pending(F.entry("U", .uncertain, hex: F.hexA, copySeen: true, told: true, priorShuffle: true)),
            pending(F.entry("P", .preexisting, hex: "00000000000000CC", priorRepeat: "one")),
            pending(F.entry("I", .intent, priorShuffle: false)))
        f.spandacSelected = false
        f.deleteResult = { _ in .failed }
        let before = try f.onDisk()
        for atLaunch in [true, false] {
            reconcile(f, atLaunch: atLaunch)
        }
        XCTAssertEqual(f.restoreCalls, ["U", "P", "I", "U", "P", "I"])
        XCTAssertEqual(f.deleteCalls, ["P", "P"], "an uncertain copy is never offered for deletion")
        XCTAssertEqual(f.adoptCalls, [])
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(try f.onDisk(), before)
    }

    func testAPendingRestoreIsAttemptedOncePerEntryPerReconcile() throws {
        let f = try seeded(pending(F.entry("C", .closed, priorShuffle: true)),
                           pending(F.entry("P", .preexisting, hex: "00000000000000CC", priorRepeat: "one")))
        f.deleteResult = { _ in .kept }
        reconcile(f, atLaunch: false)
        XCTAssertEqual(f.restoreCalls, ["C", "P"])
    }

    func testReconcileOffersEveryRecordHolderOnceWhateverItsStateOrDeleteResult() throws {
        let states: [DiscoverCopyState] = [.intent, .owned, .listening, .preexisting, .uncertain, .closed]
        func hex(_ state: DiscoverCopyState, _ n: Int) -> String? {
            state == .intent ? nil : String(format: "%016X", 0xC000 + n)
        }
        for result in [DiscoverCopyDeleteResult.spared, .deleted, .alreadyGone, .kept, .failed] {
            for marked in [false, true] {
                var entries: [DiscoverCopyEntry] = []
                for (n, state) in states.enumerated() {
                    var holder = F.entry("R-\(state.rawValue)", state, hex: hex(state, n), told: true,
                                         priorShuffle: true, priorRepeat: "all")
                    holder.restorePending = marked ? true : nil
                    entries.append(holder)
                    entries.append(F.entry("N-\(state.rawValue)", state, hex: hex(state, n + 10), told: true))
                }
                let f = F()
                for entry in entries { try f.journal.insert(entry) }
                f.spandacSelected = false
                f.deleteResult = { _ in result }
                reconcile(f, atLaunch: false)
                XCTAssertEqual(f.restoreCalls, states.map { "R-\($0.rawValue)" }, "\(result), pending \(marked)")
            }
        }
    }

    func testAClosedPendingEntryWhoseCopyPlaysIsHeldAndWatchedThroughReconcile() throws {
        let f = try seeded(pending(F.entry("C", .closed, hex: F.hexA, priorShuffle: true, priorRepeat: "all")))
        let music = Music68()
        music.state = "playing"
        music.current = F.hexA
        let guardian = guardOver(music, f.journal)
        let seams = f.copySeams
        f.onRestore = { discoverCopySettleModes(txn: $0, modes: guardian, adopt: seams.adopt, log: { _ in }) }
        reconcile(f, atLaunch: false)
        XCTAssertEqual(music.sets, [])
        XCTAssertEqual(try f.onDisk().first?.restorePending, true)
        XCTAssertEqual(try f.onDisk().first?.priorShuffle, true)
        XCTAssertEqual(f.adoptCalls, ["C:\(F.hexA)"])
    }

    // MARK: Codex 68 reproductions (failed at f49d19d; only the guard's construction changed)

    func testRepro68_1_AClosedPendingRecordIsNotRestoredWhileItsCopyPlays() throws {
        let f = try seeded(pending(F.entry("C", .closed, hex: F.hexA, priorShuffle: true, priorRepeat: "all")))
        let music = Music68()
        music.state = "playing"
        music.current = F.hexA
        let guardian = guardOver(music, f.journal)
        f.onRestore = { guardian.restore(txn: $0) }
        reconcile(f, atLaunch: false)
        XCTAssertEqual(music.sets, [], "his modes must stay off while our copy plays")
        XCTAssertEqual(try f.onDisk().first?.restorePending, true)
        XCTAssertEqual(try f.onDisk().first?.priorShuffle, true)
    }

    func testRepro68_2_APlayStartedBetweenTheLookAndTheSetsIsNotRestoredOver() throws {
        let f = try seeded(pending(F.entry("O", .owned, hex: F.hexA, priorShuffle: true, priorRepeat: "all")))
        f.deleteResult = { _ in .failed }
        let music = Music68()
        let guardian = guardOver(music, f.journal)
        f.onRestore = {
            // He starts our copy after the look and before the restore writes.
            music.state = "playing"
            music.current = F.hexA
            guardian.restore(txn: $0)
        }
        reconcile(f, atLaunch: false)
        XCTAssertEqual(music.sets, [], "the look and the write must be one operation")
        XCTAssertEqual(try f.onDisk().first?.restorePending, true)
    }

    // MARK: every state at once, in order

    func testCrashReplayAcrossEveryState() throws {
        let f = try seeded(
            F.entry("closed", .closed, priorShuffle: false),
            F.entry("uncertain", .uncertain, copySeen: false, title: "U"),
            F.entry("intent", .intent, title: "I"),
            F.entry("owned", .owned, hex: F.hexA),
            F.entry("listening", .listening, hex: "00000000000000BB", watching: true),
            F.entry("preexisting", .preexisting, hex: "00000000000000CC"))
        f.ops.copiesResults = [.success([F.copyA])]
        f.deleteResult = { $0 == "listening" ? .spared : ($0 == "owned" ? .failed : .kept) }

        reconcile(f, atLaunch: true)

        XCTAssertEqual(try f.onDisk().map(\.state),
                       [.closed, .uncertain, .uncertain, .owned, .listening, .closed])
        XCTAssertEqual(try f.onDisk().map(\.toldAtLaunch), [false, true, true, false, false, false])
        XCTAssertEqual(f.restoreCalls, ["closed"], "the only entry holding a record")
        XCTAssertEqual(f.deleteCalls, ["owned", "listening", "preexisting"])
        XCTAssertEqual(f.adoptCalls, ["listening:00000000000000BB"])
        XCTAssertEqual(f.toasts, [
            .outcome(.refused(discoverCopyMaybeAddedText(playlist: "U")), title: "U"),
            .outcome(.refused(discoverCopyLeftText(playlist: "I")), title: "I"),
        ])
    }

    // MARK: an unreadable journal

    func testAnUnreadableJournalDoesNothingAndPostsNothing() throws {
        for text in ["garbage", "{\"entries\":[],\"format\":2}"] {
            let f = F()
            try FileManager.default.createDirectory(at: f.paths.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let bytes = Data(text.utf8)
            try bytes.write(to: f.paths.journal)
            f.ops.copiesResults = [.success([F.copyA])]

            reconcile(f, atLaunch: true)
            reconcile(f, atLaunch: false)

            XCTAssertEqual(f.toasts, [])
            XCTAssertEqual(f.ops.calls, [])
            XCTAssertEqual(f.deleteCalls, [])
            XCTAssertEqual(f.restoreCalls, [])
            XCTAssertEqual(f.adoptCalls, [])
            XCTAssertEqual(try Data(contentsOf: f.paths.journal), bytes)
        }
    }

    func testAJournalWriteThatFailsDuringReconcileIsNotFatal() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [
            F.entry("I", .intent), F.entry("P", .preexisting, hex: F.hexA),
        ])
        journal.failWrites = { _ in true }
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]
        reconcile(f, atLaunch: true)
        XCTAssertEqual(journal.stored.map(\.state), [.intent, .preexisting])
        XCTAssertEqual(f.restoreCalls, [], "P holds no record")
        XCTAssertFalse(f.logs.filter { $0.contains("journal write failed") }.isEmpty)
    }

    // MARK: where the coordinator calls it

    func testTheLaunchSweepReconcilesBeforeItIsMarkedFinished() throws {
        let f = try seeded(F.entry("U", .uncertain, copySeen: true),
                           F.entry("C", .closed, priorRepeat: "all"))
        f.holdLaunch = true
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.toasts, [])
        // The restore seam runs inside reconcile: the sweep must not be finished yet,
        // so a play waiting in Rule 1 is still waiting.
        var finishedDuringReconcile: Bool?
        f.onRestore = { [unowned f] _ in finishedDuringReconcile = f.coordinator.launchSweep.isFinished }
        try XCTUnwrap(f.heldLaunchBody)()
        XCTAssertEqual(finishedDuringReconcile, false)
        XCTAssertTrue(f.coordinator.launchSweep.isFinished)
        XCTAssertEqual(f.toasts, [f.refused(discoverCopyLeftText(playlist: F.title))])
        XCTAssertEqual(f.restoreCalls, ["C"])
        XCTAssertEqual(try f.onDisk().first?.toldAtLaunch, true)
        XCTAssertEqual(f.events.prefix(2), ["sweep", "toast"])
    }

    func testAnOrdinaryDiscoverPlayReconcilesAfterAdmission() throws {
        let f = try seeded(F.entry("C", .closed, priorShuffle: true),
                           F.entry("U", .uncertain, copySeen: true))
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.restoreCalls, ["C"])                    // the launch reconcile
        XCTAssertEqual(f.toasts.count, 1)

        let outcome = f.coordinator.requestPlay(title: "Album", catalogIDs: ["1"], disableShuffle: false)
        guard case .completed(.confirmedPlaying) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(f.restoreCalls, ["C", "C"])               // and the one before the play
        // Not at launch: the uncertain entry is not repeated.
        XCTAssertEqual(f.toasts.filter { $0 == f.refused(discoverCopyLeftText(playlist: F.title)) }.count, 1)
    }

    func testASpanDACDiscoverPlayReconcilesAfterAdmission() throws {
        struct Library: SpanDACLibraryAdding {
            var canAdd: Bool { true }
            func add(catalogueIDs: [String]) throws {}
            func lookup(catalogueIDs: [String]) throws -> [String: String?] { [:] }
            func ensurePlaylist(name: String, catalogueIDs: [String]) throws -> (created: Bool, id: String, alias: String?) {
                throw SpanDACLibraryOpError.failed("refused")
            }
        }
        let f = try seeded(F.entry("C", .closed, priorShuffle: true))
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.restoreCalls, ["C"])

        let outcome = f.coordinator.requestSpanDACPlay(
            title: "Album", catalogIDs: ["1"], disableShuffle: false, library: Library(),
            currentStamp: { MusicTUIHandoffStamp(epoch: 1, dataEpoch: 1) })
        guard case .completed(.failedBeforePlay(_, .create)) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(f.restoreCalls, ["C", "C"])
    }

    func testWithoutCopySeamsNothingIsReconciledAndNoJournalIsRead() {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [F.entry("C", .closed, priorShuffle: true)])
        let f = F(journal: journal, wired: false)
        f.coordinator.startLaunchSweep()
        _ = f.coordinator.requestPlay(title: "Album", catalogIDs: ["1"], disableShuffle: false)
        XCTAssertEqual(journal.events, [])
        XCTAssertEqual(f.restoreCalls, [])
        XCTAssertTrue(f.coordinator.launchSweep.isFinished)
    }
}

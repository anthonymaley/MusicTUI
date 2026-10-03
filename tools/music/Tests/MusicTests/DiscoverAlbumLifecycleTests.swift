import XCTest
@testable import music

/// Album-cleanup step A2: an album play inside the lifecycle coordinator. The
/// slot it shares with copy plays, wiring, reconcile's album hand-off, the
/// transaction table, and the production toast poster. Fakes only.
final class DiscoverAlbumLifecycleTests: XCTestCase {
    private typealias F = A2Fixture

    private func copyRequest() -> DiscoverCopyRequest {
        DiscoverCopyRequest(playlistID: "pl.mix", playlistTitle: "Mix",
                            rows: dfhRows([.milliseconds(1000), .milliseconds(2000)]), selected: 0)
    }

    // MARK: Design test 19: one slot for both kinds

    func testAnAlbumIsBusyWhileACopyPlayHoldsTheSlot() {
        let f = F()
        f.coordinator.startLaunchSweep()
        guard case .reserved(let copy) = f.coordinator.reserveCopyPlay(copyRequest()) else {
            return XCTFail("copy not reserved")
        }
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .busy)
        f.coordinator.cancelCopyPlay(copy)
        guard case .reserved = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("album not reserved once the slot was free")
        }
    }

    func testACopyPlayIsBusyWhileAnAlbumHoldsTheSlot() {
        let f = F()
        f.coordinator.startLaunchSweep()
        guard case .reserved = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("album not reserved")
        }
        XCTAssertEqual(f.coordinator.reserveCopyPlay(copyRequest()), .busy)
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .busy)
    }

    func testTheSlotIsHeldForTheWholeAlbumPlayAndGivenBack() {
        let f = F()
        var duringEnsure: DiscoverCopyReserveOutcome?
        f.library.onEnsure = { duringEnsure = f.coordinator.reserveCopyPlay(self.copyRequest()) }
        var duringSequence: DiscoverCopyReserveOutcome?
        f.albumSequenceOverride = { commit, gate in
            duringSequence = f.coordinator.reserveCopyPlay(self.copyRequest())
            return gate { commit() } == .ran ? .listening : .refused(.sourceChanged)
        }
        f.play()
        XCTAssertEqual(duringEnsure, .busy)
        XCTAssertEqual(duringSequence, .busy)
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    func testTheSlotIsGivenBackAfterARefusedAlbum() {
        let f = F()
        f.beforeResult = nil
        f.play()
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    // MARK: Wiring

    func testAnAlbumIsNotWiredWithoutAlbumSeamsAndACopyStillIs() {
        let f = F(albumWired: false)
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .notWired)
        guard case .reserved = f.coordinator.reserveCopyPlay(copyRequest()) else {
            return XCTFail("copy not reserved")
        }
    }

    func testAnAlbumIsRefusedWhileExiting() {
        let f = F()
        f.coordinator.startLaunchSweep()
        f.coordinator.closeAdmission()
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .exiting)
    }

    func testACopyRequestStillTakesTheCopyPathWithAlbumsWired() {
        let f = F()
        f.coordinator.startLaunchSweep()
        guard case .reserved(let reservation) = f.coordinator.reserveCopyPlay(copyRequest()) else {
            return XCTFail("copy not reserved")
        }
        _ = f.coordinator.runCopyPlay(reservation, gate: f.gate.gate)
        XCTAssertEqual(f.ops.calls.first, "copies:pl.mix")
        XCTAssertEqual(f.relationsFake.calls, [])
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.sequenceTxns, [])
        XCTAssertTrue(f.states.allSatisfy { $0.name.hasPrefix("copy:") })
    }

    // MARK: Reconcile hands album entries to the album's replay

    func testReconcileHandsAnOpenAlbumEntryToTheAlbumReplayAtLaunchAndBeforeAPlay() {
        let open = albumTestEntry(state: .owned, hex: F.containerHex, songState: .pending)
        let f = F(entries: [open])
        f.play()
        XCTAssertEqual(f.replayCalls.map(\.txn), [albumTestTxn, albumTestTxn])
        XCTAssertEqual(f.replayCalls.map(\.atLaunch), [true, false])
        // The copy replay never saw it: no copies asked with an album id.
        XCTAssertFalse(f.ops.calls.contains("copies:\(albumTestAlbumID)"))
    }

    func testReconcileLeavesAlbumEntriesAloneWithoutAlbumSeams() {
        let open = albumTestEntry(state: .intent, songState: .pending)
        let f = F(albumWired: false, entries: [open])
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.replayCalls.count, 0)
        XCTAssertEqual(f.ops.calls, [])
        XCTAssertEqual(f.stored(), [open])
    }

    // MARK: The transaction table

    private func assertLegalAndNamed(_ f: F, file: StaticString = #filePath, line: UInt = #line) {
        guard let name = f.name else { return XCTFail("nothing minted", file: file, line: line) }
        XCTAssertEqual(f.states.first, .minted(name), file: file, line: line)
        XCTAssertTrue(name.hasPrefix(discoverPlaylistPrefix), file: file, line: line)
        XCTAssertTrue(name.hasSuffix(discoverPlaylistNameSeparator + albumTestAlbum), file: file, line: line)
        for state in f.states { XCTAssertEqual(state.name, name, file: file, line: line) }
        for (from, to) in zip(f.states, f.states.dropFirst()) {
            XCTAssertTrue(discoverTransitionIsLegal(from: from, to: to), "\(from) -> \(to)", file: file, line: line)
        }
        if let entry = f.entry {
            XCTAssertEqual(entry.containerName, name, file: file, line: line)
            XCTAssertTrue(name.contains(entry.txn), file: file, line: line)
        }
    }

    func testEveryTransitionOfAPlayIsLegalAndNamedByTheContainer() {
        let f = F()
        f.play()
        XCTAssertEqual(f.states.map(DFHC2Fixture.label), ["minted", "created", "ready", "positioning", "listening"])
        assertLegalAndNamed(f)
    }

    func testEveryTransitionOfEachRefusalIsLegalAndNamedByTheContainer() {
        let scenarios: [(String, (F) -> Void)] = [
            ("no B", { $0.beforeResult = nil }),
            ("gate moved", { $0.gate.scripted = [1: .sourceChanged] }),
            ("outcome unknown", { $0.library.ensureResults = [.failure(SpanDACLibraryOpError.outcomeUnknown("lost"))] }),
            ("not created", { $0.library.ensureResults = [.success((created: false, id: "p.x", alias: "1"))] }),
            ("no alias", { $0.library.ensureResults = [.success((created: true, id: "p.x", alias: nil)),
                                                       .success((created: false, id: "p.x", alias: nil))] }),
            ("never loads", { $0.player.trackCounts = [0] }),
            ("modes gate moved", { $0.gate.scripted = [2: .superseded] }),
            ("play gate moved", { $0.gate.scripted = [3: .sourceChanged] }),
            ("listening gate moved", { $0.gate.scripted = [4: .sourceChanged] }),
            ("won't play", { $0.player.playCopyResult = false }),
            ("unconfirmed", { $0.player.onConfirm = { _ in .notYet } }),
        ]
        for (label, setUp) in scenarios {
            let f = F()
            setUp(f)
            f.play()
            XCTAssertGreaterThan(f.states.count, 1, label)
            assertLegalAndNamed(f)
        }
    }

    func testTheContainerNameIsProtectedFromTheMintThroughPositioning() throws {
        let f = F()
        var protectedAtEnsure = false
        var protectedAtSequence = false
        f.library.onEnsure = { protectedAtEnsure = f.name.map(f.coordinator.protectedNames.contains) ?? false }
        f.albumSequenceOverride = { commit, gate in
            protectedAtSequence = f.name.map(f.coordinator.protectedNames.contains) ?? false
            return gate { commit() } == .ran ? .listening : .refused(.sourceChanged)
        }
        f.play()
        XCTAssertTrue(protectedAtEnsure)
        XCTAssertTrue(protectedAtSequence)
        XCTAssertEqual(f.coordinator.protectedNames, [])
    }

    func testAnAlbumPlayMintsOnlyAfterTheLaunchSweepAndReconcileRunBeforeIt() {
        let f = F()
        f.play()
        // The launch sweep body ran (reconcile at launch) before the mint;
        // the preflight's capability read happens before admission.
        XCTAssertFalse(f.states.isEmpty)
        XCTAssertEqual(f.coordinator.launchSweep, .finished(.swept))
    }

    // MARK: The production toast poster

    func testTheToastPosterPostsAsTheLifecycleAlwaysHas() {
        let status = StatusStore()
        let post = discoverToastPoster(status: status)
        post(.outcome(.refused("No."), title: "A"))
        XCTAssertEqual(status.current()?.text, "No.")
        XCTAssertEqual(status.current()?.isError, true)
        post(.progress("Finding 'T'…"))
        XCTAssertEqual(status.current()?.text, "Finding 'T'…")
        XCTAssertEqual(status.current()?.isError, false)
        XCTAssertNotNil(status.current(now: Date().addingTimeInterval(59)))
        XCTAssertNil(status.current(now: Date().addingTimeInterval(61)))
        post(.outcome(.playing(title: discoverAlbumPlayingTail(song: "T")), title: "A"))
        XCTAssertEqual(status.current()?.text, "Playing " + discoverAlbumPlayingTail(song: "T"))
        post(.startupCleanup)
        XCTAssertEqual(status.current()?.text, discoverStartupCleanupToastText)
    }
}

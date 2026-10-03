import XCTest
@testable import music

// Album-cleanup score step A5: what he is told at the end and at the next
// launch, and when an album entry closes (design 4.8, tests 20 and the
// telling half of 23; CH9, CH26). Fakes only.
final class DiscoverAlbumTellingTests: XCTestCase {

    private func ended(_ songs: [DiscoverAlbumSong], state: DiscoverCopyState = .listening,
                       containerGone: Bool? = true) -> DiscoverCopyEntry {
        albumTestEntry(state: state, hex: a5Hex, songs: songs, containerGone: containerGone)
    }

    private func settled(_ entry: DiscoverCopyEntry) -> A5Rig {
        let rig = A5Rig([entry])
        rig.cleaner.settle(txn: entry.txn)
        return rig
    }

    private let sideFile = "before-\(albumTestTxn).json"

    // MARK: Design test 20: the lines

    func testTheKeptLineIsQuietAndTheEntryCloses() {
        let rig = settled(ended([albumTestSong(1, state: .kept, keptReason: "loved"),
                                 albumTestSong(2, state: .deleted), albumTestSong(3, state: .deleted)]))
        XCTAssertEqual(rig.posts.toasts, [.progress("Kept 'Track 1' (loved) from 'Test Album'; removed the other 2.")])
        XCTAssertEqual(rig.entry()?.state, .closed)
        XCTAssertEqual(rig.entry()?.endTold, true)
        XCTAssertEqual(rig.beforeSet.calls, ["delete:\(sideFile)"], "B's side file goes on close")
    }

    func testEveryKeptLabel() {
        let rig = settled(ended([
            albumTestSong(1, state: .kept, keptReason: "loved"),
            albumTestSong(2, state: .kept, keptReason: "album"),
            albumTestSong(3, state: .kept, keptReason: "playlist", keptPlaylist: "House"),
            albumTestSong(4, state: .kept, keptReason: "couldn't check"),
        ]))
        XCTAssertEqual(rig.posts.toasts, [.progress(
            "Kept 'Track 1' (loved), 'Track 2' (album loved), 'Track 3' (in 'House') and 'Track 4' (couldn't check) from 'Test Album'.")])
    }

    func testTheLeftLineIsAnErrorAndTheEntryWaitsForTheLaunchRepeat() {
        let rig = settled(ended([albumTestSong(1, state: .uncertain), albumTestSong(2, state: .deleted)]))
        XCTAssertEqual(rig.posts.toasts, [.outcome(.refused(
            "MusicTUI left 'Track 1' from 'Test Album' in your library because it couldn't prove it added it."),
            title: albumTestAlbum)])
        XCTAssertEqual(rig.entry()?.state, .listening)
        XCTAssertTrue(rig.beforeSet.calls.isEmpty)
    }

    func testTheKeptPlusLeftLine() {
        let rig = settled(ended([albumTestSong(1, state: .kept, keptReason: "playlist", keptPlaylist: "House"),
                                 albumTestSong(2, state: .uncertain), albumTestSong(3, state: .uncertain),
                                 albumTestSong(4, state: .deleted)]))
        XCTAssertEqual(rig.posts.toasts, [.outcome(.refused(
            "Kept 'Track 1' (in 'House') from 'Test Album'; removed the other 1. "
                + "MusicTUI left 'Track 2' and 'Track 3' from 'Test Album' in your library because it couldn't prove it added them."),
            title: albumTestAlbum)])
    }

    func testTheAllRemovedLine() {
        let rig = settled(ended([albumTestSong(1, state: .deleted), albumTestSong(2, state: .preexisting),
                                 albumTestSong(3, state: .deleted)]))
        XCTAssertEqual(rig.posts.toasts, [.progress("Removed the songs 'Test Album' added.")])
        XCTAssertEqual(rig.entry()?.state, .closed)
    }

    func testNothingIsSaidWhenEverySongWasAlreadyHis() {
        let rig = settled(ended([albumTestSong(1, state: .preexisting), albumTestSong(2, state: .preexisting)]))
        XCTAssertTrue(rig.posts.toasts.isEmpty)
        XCTAssertEqual(rig.entry()?.state, .closed)
        XCTAssertEqual(rig.beforeSet.calls, ["delete:\(sideFile)"])
    }

    func testEndToldStopsASecondPost() {
        let entry = ended([albumTestSong(1, state: .uncertain), albumTestSong(2, state: .deleted)])
        let rig = settled(entry)
        rig.cleaner.settle(txn: albumTestTxn)
        rig.cleaner.settle(txn: albumTestTxn)
        XCTAssertEqual(rig.posts.toasts.count, 1)

        var told = entry
        told.endTold = true
        XCTAssertTrue(settled(told).posts.toasts.isEmpty)
    }

    func testAnEndLineThatCannotBeRecordedIsNotPosted() {
        let rig = A5Rig([ended([albumTestSong(1, state: .deleted)])])
        rig.journal.failWrites = { $0.hasPrefix("update:") }
        rig.cleaner.settle(txn: albumTestTxn)
        XCTAssertTrue(rig.posts.toasts.isEmpty)
        XCTAssertNotEqual(rig.entry()?.state, .closed)
        XCTAssertTrue(rig.beforeSet.calls.isEmpty)
    }

    func testNothingIsSaidOrClosedWhileASongIsUnfinished() {
        for state in [DiscoverAlbumSongState.owned, .pending, .intent] {
            let rig = settled(ended([albumTestSong(1, state: state), albumTestSong(2, state: .deleted)]))
            XCTAssertTrue(rig.posts.toasts.isEmpty, "\(state)")
            XCTAssertEqual(rig.entry()?.state, .listening)
        }
    }

    func testNothingIsSaidOrClosedWhileTheContainerIsThere() {
        let rig = settled(ended([albumTestSong(1, state: .deleted)], containerGone: nil))
        XCTAssertTrue(rig.posts.toasts.isEmpty)
        XCTAssertEqual(rig.entry()?.state, .listening)
    }

    // MARK: The launch repeat, once, and the close after it (CH9)

    func testTheLaunchRepeatHappensOnceAndTheEntryClosesAfterIt() throws {
        let entry = ended([albumTestSong(1, state: .uncertain), albumTestSong(2, state: .kept, keptReason: "loved")])
        let rig = settled(entry)
        let endLine = DiscoverToast.outcome(.refused(
            "Kept 'Track 2' (loved) from 'Test Album'. "
                + "MusicTUI left 'Track 1' from 'Test Album' in your library because it couldn't prove it added it."),
            title: albumTestAlbum)
        XCTAssertEqual(rig.posts.toasts, [endLine])
        XCTAssertEqual(rig.entry()?.state, .listening)

        let reconciler = a5Reconciler(rig)
        reconciler.replay(try XCTUnwrap(rig.entry()), atLaunch: false)
        XCTAssertEqual(rig.posts.toasts, [endLine], "not before a play")
        XCTAssertEqual(rig.entry()?.state, .listening)

        reconciler.replay(try XCTUnwrap(rig.entry()), atLaunch: true)
        let repeatLine = DiscoverToast.outcome(.refused(
            "MusicTUI left 'Track 1' from 'Test Album' in your library because it couldn't prove it added it."),
            title: albumTestAlbum)
        XCTAssertEqual(rig.posts.toasts, [endLine, repeatLine])
        XCTAssertEqual(rig.entry()?.songs?.first?.toldAtLaunch, true)
        XCTAssertEqual(rig.entry()?.state, .closed)
        XCTAssertEqual(rig.beforeSet.calls, ["delete:\(sideFile)"])

        reconciler.replay(try XCTUnwrap(rig.entry()), atLaunch: true)
        XCTAssertEqual(rig.posts.toasts.count, 2, "a closed entry is never told again")
    }

    func testAnUncertainEntryClosesOnceToldWithNoEndLine() {
        var song = albumTestSong(1, state: .uncertain)
        song.toldAtLaunch = true
        var entry = albumTestEntry(state: .uncertain, songs: [song, albumTestSong(2, state: .preexisting)])
        entry.uncertainReason = "not_created"
        let rig = settled(entry)
        XCTAssertTrue(rig.posts.toasts.isEmpty, "the refusal or reconcile that made it uncertain told him")
        XCTAssertEqual(rig.entry()?.state, .closed)
    }

    func testAnEntryStillResolvingItsOutcomeIsNotClosed() {
        var song = albumTestSong(1, state: .uncertain)
        song.toldAtLaunch = true
        var unknown = albumTestEntry(state: .uncertain, songs: [song])
        unknown.uncertainReason = "outcome_unknown"
        XCTAssertEqual(settled(unknown).entry()?.state, .uncertain)

        var intent = albumTestEntry(state: .intent, songs: [albumTestSong(1, state: .preexisting)])
        intent.writeSentAt = 1
        XCTAssertEqual(settled(intent).entry()?.state, .intent, "reconcile decides an intent, never settle")
    }

    // MARK: Design test 23 (telling half)

    func testASongTheGuardGaveUpOnIsKeptAsCouldntCheck() {
        let songs = [albumTestSong(1, state: .owned), albumTestSong(2, state: .owned), albumTestSong(3, state: .owned)]
        let rig = A5Rig([ended(songs)])
        rig.songGuard.outcomes = [2: [.retry(strikes: 1), .retry(strikes: 2), .gaveUp]]
        rig.cleaner.songPhase(txn: albumTestTxn)
        rig.queue.drain()
        for _ in 0..<2 {
            XCTAssertTrue(rig.posts.toasts.isEmpty)
            rig.clock.advance(DiscoverAlbumTiming.retryInterval)
            rig.cleaner.tick()
            rig.queue.drain()
        }
        XCTAssertEqual(rig.songGuard.calls, [1, 2, 3, 2, 2])
        XCTAssertEqual(rig.songStates(), [.deleted, .kept, .deleted])
        XCTAssertEqual(rig.posts.toasts, [.progress("Kept 'Track 2' (couldn't check) from 'Test Album'; removed the other 2.")])
        XCTAssertEqual(rig.entry()?.state, .closed)

        rig.clock.advance(DiscoverAlbumTiming.retryInterval)
        rig.cleaner.tick()
        XCTAssertEqual(rig.queue.count, 0, "never tried again")
    }

    func testTheEndToastHelper() {
        XCTAssertNil(discoverAlbumEndToast(ended([albumTestSong(1, state: .preexisting)])))
        XCTAssertEqual(discoverAlbumEndToast(ended([albumTestSong(1, state: .deleted)])),
                       .progress(discoverAlbumAllRemovedText(album: albumTestAlbum)))
    }

    // MARK: Helpers

    private func a5Reconciler(_ rig: A5Rig) -> DiscoverAlbumReconciler {
        DiscoverAlbumReconciler(seams: .init(
            journal: rig.journal, beforeSet: rig.beforeSet,
            relations: { FakeLibraryRelations() },
            findContainers: { _ in XCTFail("no find expected"); return nil },
            readEntryIDs: { _ in XCTFail("no E read expected"); return nil },
            deleteIfOwned: { _ in XCTFail("the container is already gone"); return .failed },
            adopt: { _, _ in XCTFail("no adopt expected") },
            startProof: { _ in XCTFail("no proof expected") },
            cleaner: rig.cleaner,
            spandacDataSelected: { true },
            post: { rig.posts.post($0) },
            now: { rig.clock.now },
            log: { _ in }))
    }
}

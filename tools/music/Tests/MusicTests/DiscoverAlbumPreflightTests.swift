import XCTest
@testable import music

/// A journal whose every read fails (album-cleanup A2 tests only).
private final class A2UnreadableJournal: DiscoverCopyJournalStore {
    func entries() throws -> [DiscoverCopyEntry] { throw DiscoverCopyJournalError.unreadable }
    func insert(_ entry: DiscoverCopyEntry) throws { throw DiscoverCopyJournalError.unreadable }
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        throw DiscoverCopyJournalError.unreadable
    }
}

/// Album-cleanup step A2, design test 2: S0a refuses with no write, no journal
/// write and no op beyond the capability read.
final class DiscoverAlbumPreflightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ rows: [DiscoverItem], selected: Int = 0) -> DiscoverCopyRequest {
        DiscoverCopyRequest(playlistID: albumTestAlbumID, playlistTitle: albumTestAlbum,
                            rows: rows, selected: selected, kind: .albumContainer)
    }

    private func ms(_ count: Int) -> [RowLength] { (1...count).map { .milliseconds(1000 * $0) } }

    /// Runs the preflight; returns the refusal and every toast it posted.
    private func preflight(_ request: DiscoverCopyRequest, offers: Bool = true,
                           journal: DiscoverCopyJournalStore = InMemoryDiscoverCopyJournalStore(),
                           relations: FakeLibraryRelations? = nil)
        -> (refusal: DiscoverRefusal?, toasts: [DiscoverToast]) {
        var toasts: [DiscoverToast] = []
        let reader = relations ?? FakeLibraryRelations(offers: offers)
        let refusal = discoverAlbumPreflightRefusal(relations: reader, request: request, journal: journal,
                                                    now: now, post: { toasts.append($0) })
        return (refusal, toasts)
    }

    private func refused(_ text: String) -> [DiscoverToast] { [.outcome(.refused(text), title: albumTestAlbum)] }

    // MARK: The capability

    func testAMissingCapabilityAsksForAnUpdateAndTouchesNothing() {
        let journal = InMemoryDiscoverCopyJournalStore()
        let relations = FakeLibraryRelations(offers: false)
        let result = preflight(request(albumTestRows(ms(3))), journal: journal, relations: relations)
        XCTAssertEqual(result.refusal, .libraryOpsNotOffered)
        XCTAssertEqual(result.toasts, refused(updateSpanDACToPlayOnMusicTUI))
        XCTAssertEqual(journal.events, [])
        XCTAssertEqual(relations.calls, [])
    }

    func testAMissingCapabilityThroughTheCoordinatorMintsNothingAndSendsNothing() {
        let f = A2Fixture()
        f.relationsFake.offers = false
        let outcome = f.play()
        XCTAssertEqual(outcome, .refused(.libraryOpsNotOffered))
        XCTAssertEqual(f.states, [])
        XCTAssertEqual(f.relationsFake.calls, [])
        XCTAssertEqual(f.library.calls, [])
        XCTAssertFalse(f.log.contains("B"))
        XCTAssertFalse(f.memory!.events.contains { $0.hasPrefix("insert") || $0.hasPrefix("update") })
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).calls, [])
        XCTAssertEqual(f.toasts, refused(updateSpanDACToPlayOnMusicTUI))
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    func testAPassingPreflightLetsThePlayThrough() {
        let result = preflight(request(albumTestRows(ms(3))))
        XCTAssertNil(result.refusal)
        XCTAssertEqual(result.toasts, [])
    }

    // MARK: Repeated songs and the size bound

    func testARepeatedCatalogueIDInTheSliceRefuses() {
        var rows = albumTestRows(ms(3))
        rows[2] = DiscoverItem(id: rows[1].id, name: "Track 3", subtitle: "Album Artist",
                               url: nil, artworkURL: nil, detail: .song, length: .milliseconds(3000))
        let result = preflight(request(rows))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverAlbumRepeatedSongText(album: albumTestAlbum)))
    }

    func testARepeatBeforeTheCursorIsNotInTheSlice() {
        var rows = albumTestRows(ms(3))
        rows[1] = DiscoverItem(id: rows[0].id, name: "Track 2", subtitle: "Album Artist",
                               url: nil, artworkURL: nil, detail: .song, length: .milliseconds(2000))
        XCTAssertNil(preflight(request(rows, selected: 1)).refusal)
    }

    func testOneHundredAndOneRowsRefuseAndOneHundredPass() {
        let result = preflight(request(albumTestRows(ms(101))))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverAlbumTooManyText))
        XCTAssertNil(preflight(request(albumTestRows(ms(100)))).refusal)
        XCTAssertNil(preflight(request(albumTestRows(ms(101)), selected: 1)).refusal)
    }

    // MARK: The reused length rules, over the slice (CH3)

    func testANullLengthOnTheLastSliceRowRefuses() {
        let result = preflight(request(albumTestRows([.milliseconds(1000), .milliseconds(2000), .null])))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverNoLengthText(title: "Track 3")))
    }

    func testANullLengthBeforeTheCursorIsNotInTheSlice() {
        XCTAssertNil(preflight(request(albumTestRows([.null, .milliseconds(2000), .milliseconds(3000)]),
                                       selected: 1)).refusal)
    }

    func testAMissingLengthKeyAsksForAnUpdate() {
        let result = preflight(request(albumTestRows([.milliseconds(1000), .absent])))
        XCTAssertEqual(result.refusal, .libraryOpsNotOffered)
        XCTAssertEqual(result.toasts, refused(updateSpanDACToPlayOnMusicTUI))
    }

    func testAMalformedLengthRefuses() {
        let result = preflight(request(albumTestRows([.milliseconds(1000), .malformed])))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverMalformedLengthText))
    }

    func testACursorOutsideTheRowsRefuses() {
        let result = preflight(request(albumTestRows(ms(2)), selected: 2))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverCopyChangedText(playlist: albumTestAlbum)))
    }

    // MARK: The journal

    func testAnUnreadableJournalRefuses() {
        let result = preflight(request(albumTestRows(ms(2))), journal: A2UnreadableJournal())
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverJournalUnwritableText(playlist: albumTestAlbum)))
    }

    private func journalWithSong(_ position: Int, deletedSecondsAgo: TimeInterval) -> InMemoryDiscoverCopyJournalStore {
        var song = albumTestSong(position, state: .deleted)
        song.deletedAt = now.timeIntervalSince1970 - deletedSecondsAgo
        let other = "B1B2C3D4-0000-4000-8000-00000000B1B0"
        let songs = (1...3).map { $0 == position ? song : albumTestSong($0, state: .preexisting) }
        return InMemoryDiscoverCopyJournalStore(entries: [albumTestEntry(txn: other, state: .closed, songs: songs)])
    }

    func testASongRemoved119SecondsAgoRefuses() {
        let result = preflight(request(albumTestRows(ms(3))), journal: journalWithSong(2, deletedSecondsAgo: 119))
        XCTAssertEqual(result.refusal, .preflight)
        XCTAssertEqual(result.toasts, refused(discoverAlbumRecentlyCleanedText(album: albumTestAlbum)))
    }

    func testASongRemoved121SecondsAgoDoesNotRefuse() {
        XCTAssertNil(preflight(request(albumTestRows(ms(3))), journal: journalWithSong(2, deletedSecondsAgo: 121)).refusal)
    }

    func testARecentRemovalOutsideTheSliceDoesNotRefuse() {
        XCTAssertNil(preflight(request(albumTestRows(ms(3)), selected: 2),
                               journal: journalWithSong(1, deletedSecondsAgo: 10)).refusal)
    }

    func testTheRecentRemovalRefusalThroughTheCoordinatorMintsNothing() {
        // The fixture's clock starts at this test's `now`, so the removal is 5 s old.
        let f = A2Fixture(entries: [journalWithSong(1, deletedSecondsAgo: 5).stored[0]])
        XCTAssertEqual(f.clock.now, now)
        let outcome = f.play()
        XCTAssertEqual(outcome, .refused(.preflight))
        XCTAssertEqual(f.states, [])
        XCTAssertEqual(f.relationsFake.calls, [])
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts, refused(discoverAlbumRecentlyCleanedText(album: albumTestAlbum)))
    }
}

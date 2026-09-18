import XCTest
@testable import music

/// Step 2, the served collection paths: the catalogue-id sender and the pure
/// decisions the collection call sites make before they send.
///
/// **Why these tests exist in this shape.** The 2026-09-17 review found that
/// `ActionRoutingTests` proves the matrix total and proves nothing about whether
/// anything consults it. These cover the other half: the request that actually
/// goes over the wire, and the id/row lists the call sites build. The call-site
/// binding itself is pinned separately, beside each call site.
final class BridgeCollectionQueueTests: XCTestCase {

    /// Captures the request lines Bridge would have received.
    private final class Wire {
        private(set) var lines: [String] = []
        let reply: String

        init(reply: String) { self.reply = reply }

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return reply }
        }

        var bodies: [[String: Any]] {
            lines.compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    private static let queueOK =
        #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"Teardrop","artist":"Massive Attack","queue":{"phase":"building","requested":2,"present":1,"index":0}}}"#

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.transport)
    }

    // MARK: - The catalogue-id sender

    /// The op and the order. Order is the whole promise of a queue, so it is
    /// asserted rather than the set.
    func testQueueByCatalogIDsSendsSliceQueueWithTheIdsInOrder() throws {
        let wire = Wire(reply: Self.queueOK)
        try control(wire).queue(catalogIDs: ["111", "222", "333"])

        let body = try XCTUnwrap(wire.bodies.first, "nothing was sent")
        XCTAssertEqual(body["op"] as? String, "slice.queue")
        XCTAssertEqual(body["ids"] as? [String], ["111", "222", "333"])
    }

    /// The app's decoder takes EXACTLY one of `ids` or `rows`. Sending both
    /// would be a request the app is entitled to reject outright.
    func testQueueByCatalogIDsNeverAlsoSendsRows() throws {
        let wire = Wire(reply: Self.queueOK)
        try control(wire).queue(catalogIDs: ["111"])

        let body = try XCTUnwrap(wire.bodies.first, "nothing was sent")
        XCTAssertNil(body["rows"], "sent both ids and rows; the app accepts only one")
    }

    /// One request, never two. Chunking would silently change what plays, which
    /// is the defect class the whole-or-nothing rule exists to prevent.
    func testAQueueIsOneRequestAndIsNeverSplit() throws {
        let wire = Wire(reply: Self.queueOK)
        try control(wire).queue(catalogIDs: (1...60).map(String.init))

        XCTAssertEqual(wire.lines.count, 1, "the queue was split across requests")
    }

    /// The app owns the 100-item bound and the resolution refusals; this side
    /// must carry their words through, not replace them with its own.
    func testAnAppRefusalKeepsItsOwnWords() {
        let refusal =
            #"{"ok":false,"op":"slice.queue","error":{"kind":"too_many","detail":"101 songs requested, limit 100"}}"#
        let wire = Wire(reply: refusal)

        XCTAssertThrowsError(try control(wire).queue(catalogIDs: ["1", "2"])) { error in
            guard case SourceAppError.refused(let detail) = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertEqual(detail, "101 songs requested, limit 100")
        }
    }

    // MARK: - Library and Playlist rows

    private func entry(_ name: String, _ artist: String, _ album: String?, index: Int = 1) -> TrackListEntry {
        TrackListEntry(index: index, name: name, artist: artist, isCurrent: false, album: album)
    }

    /// The triple is the only identity both sides share, and it travels in the
    /// order the caller chose.
    func testTracksBecomeRowsInOrder() throws {
        let tracks = [entry("One", "A", "Album", index: 1),
                      entry("Two", "A", "Album", index: 2)]

        let rows = try bridgeRows(from: tracks, named: "Album")

        XCTAssertEqual(rows, [SourceLibraryRow(title: "One", artist: "A", album: "Album"),
                              SourceLibraryRow(title: "Two", artist: "A", album: "Album")])
    }

    /// Whole or nothing. A track with no album cannot be matched on two fields
    /// out of three, so the SET is refused rather than quietly shortened.
    func testATrackWithNoAlbumRefusesTheWholeSetAndSaysHowMany() {
        let tracks = [entry("One", "A", "Album"),
                      entry("Two", "A", nil),
                      entry("Three", "A", nil)]

        XCTAssertThrowsError(try bridgeRows(from: tracks, named: "Mixed")) { error in
            let message = (error as? ActionError)?.message ?? "\(error)"
            XCTAssertEqual(message,
                           "2 of 3 tracks in 'Mixed' have no album, so Bridge cannot identify them")
        }
    }

    /// Shuffle is "play this set in random order": the caller reorders before
    /// building, so the SET must survive exactly.
    func testShufflingReordersWithoutChangingTheSet() throws {
        let tracks = (1...25).map { entry("T\($0)", "A", "Album", index: $0) }

        let rows = try bridgeRows(from: tracks.shuffled(), named: "Album")

        XCTAssertEqual(rows.count, tracks.count)
        XCTAssertEqual(Set(rows.map { $0.title }), Set(tracks.map { $0.name }))
    }

    // MARK: - Library collections: start-at-row and shuffle

    private func album(_ n: Int) -> [TrackListEntry] {
        (1...n).map { entry("T\($0)", "A", "Album", index: $0) }
    }

    /// `startAt` has no counterpart on the wire — `slice.queue` plays `ids[0]`
    /// first — so starting at a row means sending that row to the end, which is
    /// what the shipped Playlist path already does for Enter.
    func testStartingAtARowSendsThatRowToTheEnd() throws {
        let rows = try bridgeCollectionRows(tracks: album(5), shuffle: false, startAt: 3,
                                            named: "Album")

        XCTAssertEqual(rows.map { $0.title }, ["T3", "T4", "T5"])
    }

    func testStartingAtTheFirstRowSendsTheWholeAlbum() throws {
        let rows = try bridgeCollectionRows(tracks: album(4), shuffle: false, startAt: 1,
                                            named: "Album")

        XCTAssertEqual(rows.map { $0.title }, ["T1", "T2", "T3", "T4"])
    }

    /// Shuffle is the whole set in random order, so it ignores the start row —
    /// the same as the Music.app branch, which resets the index to 1 when
    /// shuffling.
    func testShufflingSendsTheWholeSetAndIgnoresTheStartRow() throws {
        let rows = try bridgeCollectionRows(tracks: album(6), shuffle: true, startAt: 4,
                                            named: "Album")

        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(Set(rows.map { $0.title }), Set(album(6).map { $0.name }))
    }

    /// The Music.app branch clamps an out-of-range start into the album, so the
    /// Bridge branch must clamp identically rather than refusing or sending
    /// nothing. (Discover deliberately does NOT clamp; that is a different
    /// call site with its own shipped rule.)
    func testAnOutOfRangeStartRowClampsTheSameWayMusicAppDoes() throws {
        XCTAssertEqual(try bridgeCollectionRows(tracks: album(3), shuffle: false, startAt: 99,
                                                named: "Album").map { $0.title }, ["T3"])
        XCTAssertEqual(try bridgeCollectionRows(tracks: album(3), shuffle: false, startAt: 0,
                                                named: "Album").map { $0.title },
                       ["T1", "T2", "T3"])
    }

    /// Slicing happens BEFORE the whole-or-nothing album check, so an
    /// undescribable track the user did not ask to play cannot veto the play.
    func testATrackWithNoAlbumBeforeTheStartRowDoesNotRefuseThePlay() throws {
        let tracks = [entry("Bad", "A", nil, index: 1),
                      entry("T2", "A", "Album", index: 2),
                      entry("T3", "A", "Album", index: 3)]

        let rows = try bridgeCollectionRows(tracks: tracks, shuffle: false, startAt: 2,
                                            named: "Album")

        XCTAssertEqual(rows.map { $0.title }, ["T2", "T3"])
    }

    /// But one inside the slice still refuses the whole request.
    func testATrackWithNoAlbumInsideTheSliceRefusesTheWholePlay() {
        let tracks = [entry("T1", "A", "Album", index: 1),
                      entry("Bad", "A", nil, index: 2)]

        XCTAssertThrowsError(try bridgeCollectionRows(tracks: tracks, shuffle: false,
                                                      startAt: 1, named: "Album"))
    }
}

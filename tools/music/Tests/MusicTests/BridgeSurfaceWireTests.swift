import XCTest
@testable import music

/// Slice 3, Part 2, P1: the wire adapters behind the provider surfaces (D1, D5),
/// driven through the real `SourceAppControl` with a scripted transport.
///
/// No socket, no Bridge, no REST: the transport records each request line and
/// answers from a script. What is pinned is the request each op sends, the
/// replies it decodes, and the failures it refuses on.
final class BridgeSurfaceWireTests: XCTestCase {

    // MARK: - Harness

    private final class Wire {
        private(set) var lines: [String] = []
        private(set) var libraryLines: [String] = []
        private var replies: [String]
        init(_ replies: String...) { self.replies = replies }

        func next() -> String { replies.isEmpty ? "{}" : replies.removeFirst() }

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return next() }
        }
        var libraryTransport: (String, String) throws -> String {
            { [self] _, line in libraryLines.append(line); return next() }
        }

        var requests: [[String: Any]] {
            (lines + libraryLines).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/unused", transport: wire.transport, libraryTransport: wire.libraryTransport)
    }

    /// The request as an object, with EXACTLY these keys: an extra key is as
    /// wrong as a missing one, because Bridge's decoder is strict.
    private func assertRequest(_ wire: Wire, _ expected: [String: Any],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(wire.requests.count, 1, "expected exactly one request", file: file, line: line)
        guard let sent = wire.requests.first else { return }
        XCTAssertEqual(Set(sent.keys), Set(expected.keys), file: file, line: line)
        XCTAssertTrue(NSDictionary(dictionary: sent).isEqual(to: expected),
                      "sent \(sent), expected \(expected)", file: file, line: line)
    }

    private func refusal(_ op: String, kind: String, detail: String = "d", extra: String = "") -> String {
        #"{"ok":false,"op":"\#(op)","error":{"kind":"\#(kind)","detail":"\#(detail)"\#(extra)}}"#
    }

    private static let station1 = #"{"id":"ra.978194965","name":"Apple Music 1","url":"https://music.apple.com/us/station/apple-music-1/ra.978194965","is_live":true,"artwork_url":"https://a/1.jpg"}"#
    private static let station2 = #"{"id":"ra.u-abc","name":"Anthony's Station","url":"https://music.apple.com/us/station/anthonys-station/ra.u-abc","is_live":false,"artwork_url":null}"#

    private static let appleMusic1 = Station(
        id: "ra.978194965", name: "Apple Music 1",
        url: "https://music.apple.com/us/station/apple-music-1/ra.978194965",
        isLive: true, artworkURL: "https://a/1.jpg")
    private static let personal = Station(
        id: "ra.u-abc", name: "Anthony's Station",
        url: "https://music.apple.com/us/station/anthonys-station/ra.u-abc",
        isLive: false, artworkURL: nil)

    // MARK: - Exact requests

    func testRecommendationsRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.recommendations","rails":[]}"#)
        _ = try control(wire).recommendations(limit: 12)
        assertRequest(wire, ["op": "slice.recommendations", "limit": 12])
        XCTAssertTrue(wire.libraryLines.isEmpty, "Discover keeps the ordinary transport")
    }

    func testContainerTracksRequestCarriesTheKind() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.containerTracks","items":[]}"#)
        let playlist = DiscoverItem(id: "pl.u-abc", name: "P", subtitle: nil, url: nil, artworkURL: nil,
                                    detail: .playlist(description: nil))
        _ = try control(wire).containerTracks(for: playlist)
        assertRequest(wire, ["op": "slice.containerTracks", "id": "pl.u-abc", "kind": "playlist"])
    }

    func testContainerTracksForAStationSpendsNoRequest() throws {
        let wire = Wire()
        let station = DiscoverItem(id: "ra.1", name: "S", subtitle: nil, url: nil, artworkURL: nil,
                                   detail: .station(isLive: false))
        XCTAssertEqual(try control(wire).containerTracks(for: station), [])
        XCTAssertTrue(wire.requests.isEmpty)
    }

    /// The shipped adapter's request, on the ordinary transport. Compared as a
    /// JSON object, not as bytes: neither `JSONEncoder` nor `JSONSerialization`
    /// fixes key order (observed here: the same call emitted `op,limit,term`
    /// on one run and `limit,op,term` on the next), so the shipped bytes were
    /// never stable beyond their keys and values.
    func testStationSearchRequestIsTheShippedRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.searchStations","stations":[]}"#)
        _ = try control(wire).searchStations(term: "jazz", limit: 25)
        assertRequest(wire, ["op": "slice.searchStations", "term": "jazz", "limit": 25])
        XCTAssertTrue(wire.libraryLines.isEmpty)
    }

    func testLiveStationsRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.liveStations","stations":[]}"#)
        _ = try control(wire).liveStations()
        assertRequest(wire, ["op": "slice.liveStations"])
    }

    func testPersonalStationsRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.personalStations","stations":[]}"#)
        _ = try control(wire).personalStations()
        assertRequest(wire, ["op": "slice.personalStations"])
    }

    func testStationLookupRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.station","station":null}"#)
        _ = try control(wire).station(id: "ra.978194965")
        assertRequest(wire, ["op": "slice.station", "id": "ra.978194965"])
    }

    func testCatalogueSearchRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.search","records":[]}"#)
        _ = try control(wire).searchCatalogue(term: "aja steely dan", limit: 10)
        assertRequest(wire, ["op": "slice.search", "term": "aja steely dan", "limit": 10])
    }

    func testRecentTracksRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.recentTracks","items":[]}"#)
        _ = try control(wire).recentTracks(limit: 10)
        assertRequest(wire, ["op": "slice.recentTracks", "limit": 10])
    }

    func testHeavyRotationRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.heavyRotation","items":[]}"#)
        _ = try control(wire).heavyRotation(limit: 7)
        assertRequest(wire, ["op": "slice.heavyRotation", "limit": 7])
    }

    /// The same request `queue(catalogIDs:)` sends, down the same long-timeout
    /// transport: never `library_ids`, never `start_required`.
    func testQueueReportingSkipsSendsTheShippedCatalogueQueue() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.queue"}"#, #"{"ok":true,"op":"slice.queue"}"#)
        let c = control(wire)
        try c.queue(catalogIDs: ["1440857781", "203709340"])
        _ = try c.queueReportingSkips(catalogIDs: ["1440857781", "203709340"])
        XCTAssertTrue(wire.lines.isEmpty, "a queue goes down the long-timeout transport")
        XCTAssertEqual(wire.libraryLines.count, 2)
        XCTAssertTrue(NSDictionary(dictionary: wire.requests[0]).isEqual(to: wire.requests[1]),
                      "not the shipped queue request")
        let body = try XCTUnwrap(wire.requests.last)
        XCTAssertEqual(Set(body.keys), ["op", "ids"])
        XCTAssertEqual(body["ids"] as? [String], ["1440857781", "203709340"])
    }

    // MARK: - Golden replies

    func testLiveStationsDecode() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.liveStations","stations":[\#(Self.station1),\#(Self.station2)]}"#)
        XCTAssertEqual(try control(wire).liveStations(), [Self.appleMusic1, Self.personal])
    }

    func testPersonalStationsDecode() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.personalStations","stations":[\#(Self.station2)]}"#)
        XCTAssertEqual(try control(wire).personalStations(), [Self.personal])
    }

    func testAnHonestlyEmptyStationListIsEmpty() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.liveStations","stations":[]}"#)
        XCTAssertEqual(try control(wire).liveStations(), [])
    }

    func testStationLookupDecodes() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.station","station":\#(Self.station1)}"#)
        XCTAssertEqual(try control(wire).station(id: "ra.978194965"), Self.appleMusic1)
    }

    /// `"station": null` is Apple not carrying the station: an answer, not an
    /// error.
    func testStationLookupNullIsNil() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.station","station":null}"#)
        XCTAssertNil(try control(wire).station(id: "ra.1"))
    }

    func testCatalogueSearchDecodesSongsAndAlbumsWithOptionalAlbum() throws {
        let wire = Wire("""
        {"ok":true,"op":"slice.search","records":[
          {"kind":"song","id":"1440857789","title":"Peg","subtitle":"Steely Dan","album":"Aja"},
          {"kind":"song","id":"203709340","title":"Deacon Blues","subtitle":"Steely Dan"},
          {"kind":"album","id":"1440857781","title":"Aja","subtitle":"Steely Dan"}]}
        """)
        XCTAssertEqual(try control(wire).searchCatalogue(term: "aja", limit: 10), [
            CatalogueRecord(kind: .song, catalogueID: "1440857789", title: "Peg", artist: "Steely Dan", album: "Aja"),
            CatalogueRecord(kind: .song, catalogueID: "203709340", title: "Deacon Blues", artist: "Steely Dan", album: nil),
            CatalogueRecord(kind: .album, catalogueID: "1440857781", title: "Aja", artist: "Steely Dan", album: nil),
        ])
    }

    /// A kind this build does not model is dropped, never guessed at (the
    /// Discover precedent): never cached as a song, never played.
    func testCatalogueSearchDropsAnUnknownKind() throws {
        let wire = Wire("""
        {"ok":true,"op":"slice.search","records":[
          {"kind":"music-video","id":"9","title":"V","subtitle":"X"},
          {"kind":"song","id":"1","title":"S","subtitle":"A"}]}
        """)
        XCTAssertEqual(try control(wire).searchCatalogue(term: "x", limit: 10).map(\.catalogueID), ["1"])
    }

    func testHistoryDecodesInApplesOrderWithNothingFiltered() throws {
        let reply = """
        {"ok":true,"op":"slice.recentTracks","items":[
          {"type":"songs","id":"1440857789","name":"Peg","artist":"Steely Dan","album":"Aja","catalog_id":"1440857789"},
          {"type":"library-songs","id":"i.abc","name":"Demo","artist":"Me"},
          {"type":"stations","id":"ra.978194965","name":"Apple Music 1"}]}
        """
        let expected = [
            HistoryItem(type: "songs", id: "1440857789", name: "Peg", artist: "Steely Dan", album: "Aja",
                        catalogueID: "1440857789"),
            HistoryItem(type: "library-songs", id: "i.abc", name: "Demo", artist: "Me", album: nil, catalogueID: nil),
            HistoryItem(type: "stations", id: "ra.978194965", name: "Apple Music 1", artist: nil, album: nil,
                        catalogueID: nil),
        ]
        XCTAssertEqual(try control(Wire(reply)).recentTracks(limit: 10), expected)
        XCTAssertEqual(try control(Wire(reply.replacingOccurrences(of: "slice.recentTracks",
                                                                    with: "slice.heavyRotation")))
                        .heavyRotation(limit: 10), expected)
    }

    func testQueueReportingSkipsReturnsSkippedUnavailable() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.queue","skipped_unavailable":1}"#)
        XCTAssertEqual(try control(wire).queueReportingSkips(catalogIDs: ["1", "2", "3"]), 1)
    }

    func testQueueReportingSkipsFromAnOlderBridgeIsZero() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.queue"}"#)
        XCTAssertEqual(try control(wire).queueReportingSkips(catalogIDs: ["1"]), 0)
    }

    /// The same rule the library queue keeps: a boolean, a negative, or a count
    /// that is not smaller than what was sent is not a count Bridge could send.
    func testQueueReportingSkipsRejectsWhatIsNotACount() {
        for raw in ["true", "-1", "2", "\"1\""] {
            let wire = Wire(#"{"ok":true,"op":"slice.queue","skipped_unavailable":\#(raw)}"#)
            XCTAssertThrowsError(try control(wire).queueReportingSkips(catalogIDs: ["1", "2"]), raw) {
                XCTAssertEqual($0 as? SourceAppError, .malformedReply(
                    "Bridge's queue reply has a skipped_unavailable that is not a count"), raw)
            }
        }
    }

    // MARK: - Contract violations fail the whole read

    private func assertUnreadable(_ reply: String, _ call: (SourceAppControl) throws -> Any,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try call(control(Wire(reply))), reply, file: file, line: line) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable, reply, file: file, line: line)
        }
    }

    func testAMissingCollectionIsUnreadableNotEmpty() {
        assertUnreadable(#"{"ok":true,"op":"slice.liveStations"}"#) { try $0.liveStations() }
        assertUnreadable(#"{"ok":true,"op":"slice.personalStations"}"#) { try $0.personalStations() }
        assertUnreadable(#"{"ok":true,"op":"slice.station"}"#) { try $0.station(id: "ra.1") as Any }
        assertUnreadable(#"{"ok":true,"op":"slice.search"}"#) { try $0.searchCatalogue(term: "x", limit: 10) }
        assertUnreadable(#"{"ok":true,"op":"slice.recentTracks"}"#) { try $0.recentTracks(limit: 10) }
        assertUnreadable(#"{"ok":true,"op":"slice.heavyRotation"}"#) { try $0.heavyRotation(limit: 10) }
    }

    /// A station is played by its URL in open mode and named by it in a
    /// favourite; a station with none cannot be a row.
    func testAStationWithNoURLFailsTheWholeRead() {
        let noURL = #"{"id":"ra.1","name":"No URL"}"#
        assertUnreadable(#"{"ok":true,"op":"slice.liveStations","stations":[\#(Self.station1),\#(noURL)]}"#) {
            try $0.liveStations()
        }
        assertUnreadable(#"{"ok":true,"op":"slice.personalStations","stations":[\#(noURL)]}"#) {
            try $0.personalStations()
        }
        assertUnreadable(#"{"ok":true,"op":"slice.station","station":\#(noURL)}"#) {
            try $0.station(id: "ra.1") as Any
        }
    }

    func testAStationThatIsNotAnObjectIsUnreadable() {
        assertUnreadable(#"{"ok":true,"op":"slice.station","station":"ra.1"}"#) { try $0.station(id: "ra.1") as Any }
        assertUnreadable(#"{"ok":true,"op":"slice.liveStations","stations":{}}"#) { try $0.liveStations() }
    }

    func testARecordMissingARequiredFieldIsUnreadable() {
        for record in [#"{"id":"1","title":"S","subtitle":"A"}"#,          // no kind
                       #"{"kind":"song","title":"S","subtitle":"A"}"#,     // no id
                       #"{"kind":"song","id":"1","subtitle":"A"}"#,        // no title
                       #"{"kind":"song","id":"1","title":"S"}"#,           // no subtitle
                       #"{"kind":"song","id":"1","title":"S","subtitle":"A","album":7}"#] {
            assertUnreadable(#"{"ok":true,"op":"slice.search","records":[\#(record)]}"#) {
                try $0.searchCatalogue(term: "x", limit: 10)
            }
        }
    }

    func testAHistoryItemMissingARequiredFieldIsUnreadable() {
        for item in [#"{"id":"1","name":"N"}"#,                            // no type
                     #"{"type":"songs","name":"N"}"#,                      // no id
                     #"{"type":"songs","id":"1"}"#,                        // no name
                     #"{"type":"songs","id":"1","name":"N","catalog_id":1}"#] {
            assertUnreadable(#"{"ok":true,"op":"slice.recentTracks","items":[\#(item)]}"#) {
                try $0.recentTracks(limit: 10)
            }
        }
    }

    // MARK: - Refusals, decoded on the kind

    private struct NewRead {
        let op: String
        let call: (SourceAppControl) throws -> Any
    }

    private let newReads: [NewRead] = [
        NewRead(op: "slice.liveStations") { try $0.liveStations() },
        NewRead(op: "slice.personalStations") { try $0.personalStations() },
        NewRead(op: "slice.station") { try $0.station(id: "ra.1") as Any },
        NewRead(op: "slice.search") { try $0.searchCatalogue(term: "x", limit: 10) },
        NewRead(op: "slice.recentTracks") { try $0.recentTracks(limit: 10) },
        NewRead(op: "slice.heavyRotation") { try $0.heavyRotation(limit: 10) },
    ]

    /// An older Bridge answers `unknown_op`; the op name travels, so the
    /// provider can say which capability is missing.
    func testUnknownOpIsUnsupportedNamingTheOp() {
        for read in newReads {
            let wire = Wire(refusal(read.op, kind: "unknown_op"))
            XCTAssertThrowsError(try read.call(control(wire)), read.op) {
                XCTAssertEqual($0 as? SourceAppError, .unsupported(read.op))
            }
        }
    }

    func testUnauthorizedWarmingAndStaleGenerationAsToday() {
        for read in newReads {
            XCTAssertThrowsError(try read.call(control(Wire(refusal(read.op, kind: "unauthorized"))))) {
                XCTAssertEqual($0 as? SourceAppError, .notAuthorized, read.op)
            }
            XCTAssertThrowsError(try read.call(control(Wire(refusal(read.op, kind: "warming", detail: "w",
                                                                    extra: #","retry_after":2.5"#))))) {
                XCTAssertEqual($0 as? SourceAppError, .warming("w", retryAfter: 2.5), read.op)
            }
            XCTAssertThrowsError(try read.call(control(Wire(refusal(read.op, kind: "stale_generation",
                                                                    detail: "s"))))) {
                XCTAssertEqual($0 as? SourceAppError, .staleGeneration("s"), read.op)
            }
            XCTAssertThrowsError(try read.call(control(Wire(refusal(read.op, kind: "not_found",
                                                                    detail: "Bridge's words"))))) {
                XCTAssertEqual($0 as? SourceAppError, .refused("Bridge's words"), read.op)
            }
        }
    }

    // MARK: - Defaults, so every older conformer compiles

    /// A `SourceControlling` written before Part 2: it implements only the
    /// requirements that existed then.
    private struct BeforePart2: SourceControlling {
        func status() throws -> SourceStatus { throw SourceAppError.unreadable }
        func resume() throws {}
        func pause() throws {}
        func next() throws {}
        func previous() throws {}
        func stop() throws {}
        func seek(toSeconds seconds: Double) throws {}
        func seek(byOffset seconds: Double) throws {}
        func queue(rows: [SourceLibraryRow]) throws {}
        func queue(catalogIDs: [String]) throws {}
        func playStation(id: String, named name: String) throws {}
        func librarySongs(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
        func queue(libraryIDs: [String], startRequired: Bool) throws -> Int { 0 }
        func libraryAlbums(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
        func libraryArtists(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
        func libraryAlbumTracks(albumID: String) throws -> MusicList { throw SourceAppError.unreadable }
        func libraryArtistAlbums(artistID: String) throws -> MusicList { throw SourceAppError.unreadable }
        func libraryArtistSongs(artistID: String) throws -> MusicList { throw SourceAppError.unreadable }
        func libraryPlaylists(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
        func libraryPlaylistTracks(playlistID: String, cursor: String?, limit: Int) throws -> MusicPage {
            throw SourceAppError.unreadable
        }
    }

    func testEveryNewMemberDefaultsToUnsupportedNamingItsOp() {
        let old: SourceControlling = BeforePart2()
        let album = DiscoverItem(id: "1", name: "A", subtitle: nil, url: nil, artworkURL: nil,
                                 detail: .album(trackCount: nil, year: nil, genre: nil))
        let cases: [(String, () throws -> Any)] = [
            ("slice.recommendations", { try old.recommendations(limit: 30) }),
            ("slice.containerTracks", { try old.containerTracks(for: album) }),
            ("slice.searchStations", { try old.searchStations(term: "x", limit: 25) }),
            ("slice.liveStations", { try old.liveStations() }),
            ("slice.personalStations", { try old.personalStations() }),
            ("slice.station", { try old.station(id: "ra.1") as Any }),
            ("slice.search", { try old.searchCatalogue(term: "x", limit: 10) }),
            ("slice.recentTracks", { try old.recentTracks(limit: 10) }),
            ("slice.heavyRotation", { try old.heavyRotation(limit: 10) }),
            ("slice.queue", { try old.queueReportingSkips(catalogIDs: ["1"]) }),
        ]
        for (op, call) in cases {
            XCTAssertThrowsError(try call(), op) {
                XCTAssertEqual($0 as? SourceAppError, .unsupported(op))
            }
        }
    }
}

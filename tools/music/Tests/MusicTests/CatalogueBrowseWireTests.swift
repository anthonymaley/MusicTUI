import XCTest
@testable import music

/// Catalogue search on Discover, S1: the TUI's own catalogue browse seam
/// (`CatalogueBrowsing`) and its wire, driven through the real
/// `SourceAppControl` with a scripted transport.
///
/// No socket, no SpanDAC, no REST: the transport records each request line and
/// answers from a script. What is pinned is that an older SpanDAC (no
/// `search.artist` + `slice.artistAlbums` capabilities) gets exactly today's
/// `slice.search` request, that a newer one gets `"artists": true`, that a
/// status read that fails is not mistaken for an older SpanDAC, and the
/// records each op decodes or refuses. The CLI's `searchCatalogue` path and
/// `CatalogueRecord` are untouched (`BridgeSurfaceWireTests`).
final class CatalogueBrowseWireTests: XCTestCase {

    // MARK: - Harness

    private final class Wire {
        private(set) var lines: [String] = []
        private var replies: [String]
        init(_ replies: String...) { self.replies = replies }

        func next() -> String { replies.isEmpty ? "{}" : replies.removeFirst() }

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return next() }
        }

        var requests: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/unused", transport: wire.transport)
    }

    private func provider(_ wire: Wire) -> BridgeMusicProvider {
        BridgeMusicProvider(control: control(wire))
    }

    /// The request as an object with EXACTLY these keys: SpanDAC's decoder is
    /// strict, so an extra key is as wrong as a missing one. Compared as an
    /// object, as `BridgeSurfaceWireTests` does, because `JSONSerialization`
    /// does not fix key order.
    private func assertSame(_ sent: [String: Any]?, _ expected: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let sent else { return XCTFail("no request", file: file, line: line) }
        XCTAssertEqual(Set(sent.keys), Set(expected.keys), file: file, line: line)
        XCTAssertTrue(NSDictionary(dictionary: sent).isEqual(to: expected),
                      "sent \(sent), expected \(expected)", file: file, line: line)
    }

    private static func status(_ capabilities: [String]) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"ok":true,"op":"slice.status","status":{"authorized":true,"capabilities":[\#(list)]}}"#
    }

    private static let bothCapabilities = status(["slice.search", "search.artist", "slice.artistAlbums"])
    private static let oldCapabilities = status(["slice.search", "slice.containerTracks"])
    private static let emptySearch = #"{"ok":true,"op":"slice.search","records":[]}"#

    private static let newerNote = "Artists need a newer SpanDAC on this Mac."
    private static let couldNotCheckNote = "Couldn't check SpanDAC for artist search."

    // MARK: - The slice.search request

    /// Without both capabilities the search request is today's: the same keys
    /// and values `searchCatalogue` sends, no `artists` key at all.
    func testWithoutTheCapabilitiesTheSearchRequestIsTodays() throws {
        let today = Wire(Self.emptySearch)
        _ = try control(today).searchCatalogue(term: "aja steely dan", limit: 10)

        for caps in [["slice.search"], ["slice.search", "search.artist"], ["slice.search", "slice.artistAlbums"]] {
            let wire = Wire(Self.status(caps), Self.emptySearch)
            let results = try control(wire).browseCatalogue(term: "aja steely dan", limit: 10)
            XCTAssertEqual(wire.requests.count, 2, "\(caps)")
            assertSame(wire.requests.first, ["op": "slice.status"])
            assertSame(wire.requests.last, ["op": "slice.search", "term": "aja steely dan", "limit": 10])
            assertSame(wire.requests.last, today.requests[0])
            XCTAssertFalse(results.artistsServed, "\(caps)")
            XCTAssertEqual(results.artistsNote, Self.newerNote, "\(caps)")
        }
    }

    func testBothCapabilitiesAddTheArtistsField() throws {
        let wire = Wire(Self.bothCapabilities, Self.emptySearch)
        let results = try control(wire).browseCatalogue(term: "steely dan", limit: 10)
        XCTAssertEqual(wire.requests.count, 2)
        assertSame(wire.requests.last, ["op": "slice.search", "term": "steely dan", "limit": 10, "artists": true])
        XCTAssertEqual(wire.requests.last?["artists"] as? Bool, true)
        XCTAssertTrue(results.artistsServed)
        XCTAssertNil(results.artistsNote)
    }

    // MARK: - Capabilities that cannot be read

    /// A status with no `capabilities` key is an older contract (as
    /// `capabilities()` reads it): an older SpanDAC, not a failed check.
    func testAbsentCapabilitiesReadAsAnOlderSpanDAC() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.status","status":{"authorized":true}}"#, Self.emptySearch)
        let results = try control(wire).browseCatalogue(term: "x", limit: 10)
        assertSame(wire.requests.last, ["op": "slice.search", "term": "x", "limit": 10])
        XCTAssertFalse(results.artistsServed)
        XCTAssertEqual(results.artistsNote, Self.newerNote)
    }

    /// A status read that fails, or answers something this build cannot read,
    /// is not an older SpanDAC: Albums and Songs still search, with today's
    /// request, and the note says the check failed.
    func testAFailedStatusReadIsNotAnOldServer() throws {
        let statuses = [
            #"{"ok":false,"op":"slice.status","error":{"kind":"busy","detail":"d"}}"#,
            #"{"ok":false,"op":"slice.status","error":{"kind":"refused","detail":"d"}}"#,
            "not json",
            #"{"ok":true,"op":"slice.status"}"#,
            #"{"ok":true,"op":"slice.status","status":"ready"}"#,
            #"{"ok":true,"op":"slice.status","status":{"capabilities":"search.artist"}}"#,
            #"{"ok":true,"op":"slice.status","status":{"capabilities":["search.artist",1]}}"#,
            #"{"ok":true,"op":"slice.status","status":{"capabilities":null}}"#,
        ]
        for status in statuses {
            let wire = Wire(status, Self.emptySearch)
            let results = try control(wire).browseCatalogue(term: "x", limit: 10)
            XCTAssertEqual(wire.requests.count, 2, status)
            assertSame(wire.requests.last, ["op": "slice.search", "term": "x", "limit": 10])
            XCTAssertFalse(results.artistsServed, status)
            XCTAssertEqual(results.artistsNote, Self.couldNotCheckNote, status)
        }
    }

    /// A status transport that throws (SpanDAC went away between the two
    /// requests' worth of time) is the same failed check.
    func testAThrowingStatusTransportIsAFailedCheck() throws {
        var lines: [String] = []
        let transport: (String, String) throws -> String = { _, line in
            lines.append(line)
            if line.contains("slice.status") { throw SourceAppError.timedOut }
            return Self.emptySearch
        }
        let results = try SourceAppControl(path: "/unused", transport: transport)
            .browseCatalogue(term: "x", limit: 10)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(results.artistsServed)
        XCTAssertEqual(results.artistsNote, Self.couldNotCheckNote)
    }

    // MARK: - Decoding

    func testRecordsAreGroupedInApplesOrderAndAnArtistNeedsNoSubtitle() throws {
        let wire = Wire(Self.bothCapabilities, """
        {"ok":true,"op":"slice.search","records":[
          {"kind":"song","id":"1440857789","title":"Peg","subtitle":"Steely Dan","album":"Aja"},
          {"kind":"artist","id":"36955","title":"Steely Dan"},
          {"kind":"album","id":"1440857781","title":"Aja","subtitle":"Steely Dan"},
          {"kind":"song","id":"203709340","title":"Deacon Blues","subtitle":"Steely Dan"},
          {"kind":"artist","id":"5","title":"Steely Dan Tribute","subtitle":"Tribute act"}]}
        """)
        let results = try control(wire).browseCatalogue(term: "steely dan", limit: 10)
        XCTAssertEqual(results, CatalogueSearchResults(
            artists: [
                CatalogueHit(kind: .artist, id: "36955", title: "Steely Dan", subtitle: nil, album: nil),
                CatalogueHit(kind: .artist, id: "5", title: "Steely Dan Tribute", subtitle: "Tribute act", album: nil),
            ],
            albums: [CatalogueHit(kind: .album, id: "1440857781", title: "Aja", subtitle: "Steely Dan", album: nil)],
            songs: [
                CatalogueHit(kind: .song, id: "1440857789", title: "Peg", subtitle: "Steely Dan", album: "Aja"),
                CatalogueHit(kind: .song, id: "203709340", title: "Deacon Blues", subtitle: "Steely Dan", album: nil),
            ],
            artistsServed: true, artistsNote: nil))
    }

    func testAnUnknownKindIsDropped() throws {
        let wire = Wire(Self.bothCapabilities, """
        {"ok":true,"op":"slice.search","records":[
          {"kind":"music-video","id":"9","title":"V","subtitle":"X"},
          {"kind":"playlist","id":"pl.1","title":"P"},
          {"kind":"song","id":"1","title":"S","subtitle":"A"}]}
        """)
        let results = try control(wire).browseCatalogue(term: "x", limit: 10)
        XCTAssertEqual(results.songs.map(\.id), ["1"])
        XCTAssertTrue(results.albums.isEmpty)
        XCTAssertTrue(results.artists.isEmpty)
    }

    /// An artist record from a SpanDAC that was not asked for artists is not
    /// shown: an older-capability search shows Albums and Songs only.
    func testArtistsNotAskedForAreNotShown() throws {
        let wire = Wire(Self.oldCapabilities, """
        {"ok":true,"op":"slice.search","records":[
          {"kind":"artist","id":"36955","title":"Steely Dan"},
          {"kind":"song","id":"1","title":"S","subtitle":"A"}]}
        """)
        let results = try control(wire).browseCatalogue(term: "x", limit: 10)
        XCTAssertTrue(results.artists.isEmpty)
        XCTAssertEqual(results.songs.map(\.id), ["1"])
    }

    /// Songs and albums still require `subtitle`; any record missing a
    /// required field fails the whole read, never a silently shorter list.
    func testARecordMissingARequiredFieldIsUnreadable() {
        let rows = [
            #"{"kind":"song","id":"1","title":"S"}"#,
            #"{"kind":"album","id":"1","title":"A"}"#,
            #"{"kind":"artist","id":"1"}"#,
            #"{"kind":"artist","title":"A"}"#,
            #"{"id":"1","title":"S","subtitle":"A"}"#,
            #"{"kind":"artist","id":"1","title":"A","subtitle":7}"#,
        ]
        for row in rows {
            let wire = Wire(Self.bothCapabilities, #"{"ok":true,"op":"slice.search","records":[\#(row)]}"#)
            XCTAssertThrowsError(try control(wire).browseCatalogue(term: "x", limit: 10), row) {
                XCTAssertEqual($0 as? SourceAppError, .unreadable, row)
            }
        }
        let noRecords = Wire(Self.bothCapabilities, #"{"ok":true,"op":"slice.search"}"#)
        XCTAssertThrowsError(try control(noRecords).browseCatalogue(term: "x", limit: 10)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    // MARK: - slice.artistAlbums

    func testArtistAlbumsRequest() throws {
        let wire = Wire(#"{"ok":true,"op":"slice.artistAlbums","records":[],"more":false}"#)
        _ = try control(wire).artistAlbums(artistID: "36955", limit: 25)
        XCTAssertEqual(wire.requests.count, 1, "no status read for the drill")
        assertSame(wire.requests.first, ["op": "slice.artistAlbums", "id": "36955", "limit": 25])
    }

    func testArtistAlbumsDecodesAlbumsAndMore() throws {
        let wire = Wire("""
        {"ok":true,"op":"slice.artistAlbums","more":true,"records":[
          {"kind":"album","id":"1440857781","title":"Aja","subtitle":"Steely Dan"},
          {"kind":"song","id":"9","title":"Stray","subtitle":"X"},
          {"kind":"album","id":"1440858123","title":"Gaucho","subtitle":"Steely Dan"}]}
        """)
        XCTAssertEqual(try control(wire).artistAlbums(artistID: "36955", limit: 25), ArtistAlbums(
            albums: [
                CatalogueHit(kind: .album, id: "1440857781", title: "Aja", subtitle: "Steely Dan", album: nil),
                CatalogueHit(kind: .album, id: "1440858123", title: "Gaucho", subtitle: "Steely Dan", album: nil),
            ],
            more: true))

        let last = Wire(#"{"ok":true,"op":"slice.artistAlbums","records":[],"more":false}"#)
        XCTAssertEqual(try control(last).artistAlbums(artistID: "1", limit: 25), ArtistAlbums(albums: [], more: false))
    }

    /// `more` is how the screen knows the list is the first 25, not all of
    /// them: absent, or anything but a JSON boolean, fails the read rather
    /// than presenting a prefix as complete.
    func testArtistAlbumsWithoutAReadableMoreIsUnreadable() {
        for more in ["", #","more":1"#, #","more":"true""#, #","more":null"#] {
            let reply = #"{"ok":true,"op":"slice.artistAlbums","records":[]\#(more)}"#
            XCTAssertThrowsError(try control(Wire(reply)).artistAlbums(artistID: "1", limit: 25), reply) {
                XCTAssertEqual($0 as? SourceAppError, .unreadable, reply)
            }
        }
        let noRecords = #"{"ok":true,"op":"slice.artistAlbums","more":false}"#
        XCTAssertThrowsError(try control(Wire(noRecords)).artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
        let noSubtitle = #"{"ok":true,"op":"slice.artistAlbums","more":false,"records":[{"kind":"album","id":"1","title":"A"}]}"#
        XCTAssertThrowsError(try control(Wire(noSubtitle)).artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    /// An older SpanDAC answers `unknown_op`: the control carries the op name,
    /// and the provider says it in the update-SpanDAC sentence style.
    func testArtistAlbumsFromAnOlderSpanDACSaysUpdate() {
        let reply = #"{"ok":false,"op":"slice.artistAlbums","error":{"kind":"unknown_op","detail":"d"}}"#
        XCTAssertThrowsError(try control(Wire(reply)).artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported("slice.artistAlbums"))
        }
        XCTAssertThrowsError(try provider(Wire(reply)).artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? MusicProviderError, .notImplemented(
                "This SpanDAC build can't list an artist's catalogue albums — update SpanDAC"))
        }
        XCTAssertEqual(BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.artistAlbums"),
                       "This SpanDAC build can't list an artist's catalogue albums — update SpanDAC")
    }

    /// SpanDAC's own refusal sentence (404 `unresolvable`) reaches the person
    /// verbatim, and is a refusal, not an empty list.
    func testArtistAlbumsRefusalTravelsVerbatim() {
        let reply = #"{"ok":false,"op":"slice.artistAlbums","error":{"kind":"unresolvable","detail":"That artist isn't in Apple Music's catalogue."}}"#
        XCTAssertThrowsError(try provider(Wire(reply)).artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? MusicProviderError, .refused("That artist isn't in Apple Music's catalogue."))
        }
    }

    // MARK: - The provider seam

    func testProviderBrowsesThroughTheControl() throws {
        let wire = Wire(Self.bothCapabilities, """
        {"ok":true,"op":"slice.search","records":[{"kind":"artist","id":"36955","title":"Steely Dan"}]}
        """)
        let results = try provider(wire).browseCatalogue(term: "steely dan", limit: 10)
        XCTAssertEqual(results.artists.map(\.id), ["36955"])
        XCTAssertTrue(results.artistsServed)
    }

    /// The same error translation as `searchCatalogue`: no `slice.search` at
    /// all is the existing update sentence.
    func testProviderTranslatesAnOlderSpanDACsSearchLikeSearchCatalogue() {
        let reply = #"{"ok":false,"op":"slice.search","error":{"kind":"unknown_op","detail":"d"}}"#
        XCTAssertThrowsError(try provider(Wire(Self.oldCapabilities, reply)).browseCatalogue(term: "x", limit: 10)) {
            XCTAssertEqual($0 as? MusicProviderError, .notImplemented(
                BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.search")))
        }
        XCTAssertThrowsError(try provider(Wire(reply)).searchCatalogue(term: "x", limit: 10)) {
            XCTAssertEqual($0 as? MusicProviderError, .notImplemented(
                BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.search")))
        }
    }

    /// A conformer that implements neither read says so when asked, in the
    /// update sentences, never an empty answer.
    func testDefaultsThrow() {
        struct Bare: CatalogueBrowsing {}
        XCTAssertThrowsError(try Bare().browseCatalogue(term: "x", limit: 10)) {
            XCTAssertEqual($0 as? MusicProviderError, .notImplemented(
                BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.search")))
        }
        XCTAssertThrowsError(try Bare().artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? MusicProviderError, .notImplemented(
                BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.artistAlbums")))
        }
    }

    /// A `SourceControlling` written before these members reads as an older
    /// SpanDAC that serves neither op.
    func testSourceControllingDefaultsReadAsAnOlderSpanDAC() {
        let old: SourceControlling = BeforeCatalogueBrowse()
        XCTAssertThrowsError(try old.browseCatalogue(term: "x", limit: 10)) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported("slice.search"))
        }
        XCTAssertThrowsError(try old.artistAlbums(artistID: "1", limit: 25)) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported("slice.artistAlbums"))
        }
    }

    private struct BeforeCatalogueBrowse: SourceControlling {
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
        func libraryPlaylistTracks(playlistID: String, cursor: String?, limit: Int, forQueue: Bool) throws -> MusicPage {
            throw SourceAppError.unreadable
        }
    }
}

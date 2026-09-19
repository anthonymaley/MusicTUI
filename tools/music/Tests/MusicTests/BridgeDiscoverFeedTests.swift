import XCTest
@testable import music

/// Step 3's Discover half: the feed as Bridge serves it, read with no developer
/// key (DoD 6).
///
/// No socket: the transport is injected, the same seam the other Bridge clients
/// use. What is pinned here is the TRANSLATION - the wire's rails and items into
/// the types `DiscoverScene` already renders - and the requests it sends.
final class BridgeDiscoverFeedTests: XCTestCase {

    // MARK: - Harness

    private final class Wire {
        private(set) var lines: [String] = []
        var reply: String
        init(reply: String) { self.reply = reply }

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return reply }
        }

        var requests: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
    }

    private func feed(_ wire: Wire) -> BridgeDiscoverFeed {
        BridgeDiscoverFeed(path: "/unused", transport: wire.transport)
    }

    /// The shape measured over the wire on 2026-09-18: a station ranked FIRST in
    /// a rail of albums.
    private static let railsReply = """
    {"ok":true,"op":"slice.recommendations","rails":[
      {"title":"Recently Played","items":[
        {"id":"ra.978194965","kind":"station","name":"Apple Music 1","artwork_url":"https://a/1.jpg"},
        {"id":"1440857781","kind":"album","name":"Aja","subtitle":"Steely Dan","artwork_url":"https://a/2.jpg"},
        {"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}
      ]},
      {"title":"Nothing Here","items":[]},
      {"title":"Made for You","items":[
        {"id":"pl.u-def","kind":"playlist","name":"Chill Mix","subtitle":"Apple Music"}
      ]}
    ]}
    """

    // MARK: - Rails

    func testRailsAskForRecommendationsWithTheLimit() throws {
        let wire = Wire(reply: Self.railsReply)
        _ = try feed(wire).rails(limit: 12)
        XCTAssertEqual(wire.requests.count, 1)
        XCTAssertEqual(wire.requests.first?["op"] as? String, "slice.recommendations")
        XCTAssertEqual(wire.requests.first?["limit"] as? Int, 12)
    }

    /// Order inside a rail is Apple's ranking. The station stays first.
    func testItemsKeepTheWiresOrderAndKinds() throws {
        let rails = try feed(Wire(reply: Self.railsReply)).rails(limit: 30)
        let first = try XCTUnwrap(rails.first)
        XCTAssertEqual(first.title, "Recently Played")
        XCTAssertEqual(first.items.map(\.kind), [.station, .album, .playlist])
        XCTAssertEqual(first.items.map(\.id), ["ra.978194965", "1440857781", "pl.u-abc"])
        XCTAssertEqual(first.items[1].subtitle, "Steely Dan")
        XCTAssertEqual(first.items[1].artworkURL, "https://a/2.jpg")
    }

    /// The wire spells it `artwork_url` (the app's `CodingKeys`). The first
    /// version read `artworkURL`, the Swift property's name, and these fixtures
    /// repeated the mistake, so every test passed while every Bridge row would
    /// have had no cover. Found by the live gate on 2026-09-19, not by a test:
    /// the fixture below is now a row copied from the real reply's shape.
    func testArtworkIsReadFromTheWiresOwnSpelling() throws {
        let wire = Wire(reply: """
        {"ok":true,"op":"slice.recommendations","rails":[{"title":"R","items":[
          {"kind":"album","id":"191395476","name":"Suicide Android - EP","subtitle":"Vector Lovers",
           "artwork_url":"https://is1-ssl.mzstatic.com/image/thumb/Music/x/512x512bb.jpg"}]}]}
        """)
        XCTAssertEqual(try feed(wire).rails(limit: 30).first?.items.first?.artworkURL,
                       "https://is1-ssl.mzstatic.com/image/thumb/Music/x/512x512bb.jpg")
    }

    /// Same rule the REST feed applies: a rail with nothing in it is an empty
    /// heading, not a row.
    func testAnEmptyRailIsDropped() throws {
        let rails = try feed(Wire(reply: Self.railsReply)).rails(limit: 30)
        XCTAssertEqual(rails.map(\.title), ["Recently Played", "Made for You"])
    }

    /// The scene keys its scroll state and its hero artwork off the rail id, so
    /// two rails must never share one. The wire sends no id.
    func testEveryRailGetsADistinctID() throws {
        let rails = try feed(Wire(reply: Self.railsReply)).rails(limit: 30)
        XCTAssertEqual(Set(rails.map(\.id)).count, rails.count)
    }

    /// RECORDED DEGRADATION (Anthony, 2026-09-19: left for v1). The wire carries
    /// no recently-played flag and the title is localised, so nothing is claimed
    /// from it. Bridge's rails stay in Apple's order.
    func testNoRailClaimsToBeRecentlyPlayed() throws {
        let rails = try feed(Wire(reply: Self.railsReply)).rails(limit: 30)
        XCTAssertFalse(rails.contains(where: \.isRecentlyPlayed))
    }

    /// A kind this build does not model is dropped, never guessed at: a rail one
    /// row shorter is a smaller wrong than a row whose Enter does the wrong thing.
    func testAnUnknownKindIsDropped() throws {
        let wire = Wire(reply: """
        {"ok":true,"op":"slice.recommendations","rails":[{"title":"R","items":[
          {"id":"1","kind":"music-video","name":"V"},
          {"id":"2","kind":"album","name":"A"}]}]}
        """)
        XCTAssertEqual(try feed(wire).rails(limit: 30).first?.items.map(\.id), ["2"])
    }

    // MARK: - A container's tracks

    private static let tracksReply = """
    {"ok":true,"op":"slice.containerTracks","items":[
      {"id":"801","kind":"song","name":"S1","subtitle":"A"},
      {"id":"802","kind":"song","name":"S2","subtitle":"A"}]}
    """

    private func item(_ id: String, _ detail: DiscoverItemDetail) -> DiscoverItem {
        DiscoverItem(id: id, name: "N", subtitle: nil, url: nil, artworkURL: nil, detail: detail)
    }

    /// The kind goes back on the wire. A catalogue id does not say whether it is
    /// an album or a playlist, and Bridge once read every one as an album.
    func testAPlaylistIsAskedForAsAPlaylist() throws {
        let wire = Wire(reply: Self.tracksReply)
        let tracks = try feed(wire).tracks(for: item("pl.u-abc", .playlist(description: nil)))
        XCTAssertEqual(wire.requests.first?["op"] as? String, "slice.containerTracks")
        XCTAssertEqual(wire.requests.first?["id"] as? String, "pl.u-abc")
        XCTAssertEqual(wire.requests.first?["kind"] as? String, "playlist")
        XCTAssertEqual(tracks.map(\.id), ["801", "802"])
        XCTAssertEqual(tracks.map(\.kind), [.song, .song])
    }

    func testAnAlbumIsAskedForAsAnAlbum() throws {
        let wire = Wire(reply: Self.tracksReply)
        _ = try feed(wire).tracks(for: item("1440857781", .album(trackCount: nil, year: nil, genre: nil)))
        XCTAssertEqual(wire.requests.first?["kind"] as? String, "album")
    }

    /// Same as the REST feed: a station has no track list, so none is asked for.
    func testAStationSpendsNoRequest() throws {
        let wire = Wire(reply: Self.tracksReply)
        XCTAssertEqual(try feed(wire).tracks(for: item("ra.1", .station(isLive: false))), [])
        XCTAssertTrue(wire.lines.isEmpty)
    }

    // MARK: - A malformed success is not an empty one

    /// An `ok` reply without the collection it promised is a contract
    /// violation, not "no recommendations" - the rule station search already
    /// keeps. An honest empty feed carries an empty array (Codex S1).
    func testAnOkReplyWithNoRailsKeyIsUnreadable() {
        let wire = Wire(reply: #"{"ok":true,"op":"slice.recommendations"}"#)
        XCTAssertThrowsError(try feed(wire).rails(limit: 30)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    func testAnHonestlyEmptyFeedIsEmpty() throws {
        let wire = Wire(reply: #"{"ok":true,"op":"slice.recommendations","rails":[]}"#)
        XCTAssertEqual(try feed(wire).rails(limit: 30), [])
    }

    func testARailWithNoItemsKeyIsUnreadable() {
        let wire = Wire(reply: #"{"ok":true,"op":"slice.recommendations","rails":[{"title":"R"}]}"#)
        XCTAssertThrowsError(try feed(wire).rails(limit: 30)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    /// A row of a KNOWN kind missing a required field is malformed. Dropping is
    /// reserved for a kind this build does not know, which is forward
    /// compatibility and a different thing.
    func testAKnownKindMissingItsNameIsUnreadable() {
        let wire = Wire(reply: """
        {"ok":true,"op":"slice.recommendations","rails":[{"title":"R","items":[{"id":"1","kind":"album"}]}]}
        """)
        XCTAssertThrowsError(try feed(wire).rails(limit: 30)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    func testAnOkTracksReplyWithNoItemsKeyIsUnreadable() {
        let wire = Wire(reply: #"{"ok":true,"op":"slice.containerTracks"}"#)
        XCTAssertThrowsError(try feed(wire).tracks(for: item("1", .album(trackCount: nil, year: nil, genre: nil)))) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    // MARK: - Refusals keep their words

    /// Bridge's own sentence reaches the person. No fallback, and no flattening
    /// into a generic failure.
    func testARefusalCarriesBridgesWords() {
        let wire = Wire(reply: """
        {"ok":false,"op":"slice.containerTracks","error":{"kind":"unresolvable",
         "detail":"That playlist isn't in Apple Music's catalogue."}}
        """)
        XCTAssertThrowsError(try feed(wire).tracks(for: item("pl.x", .playlist(description: nil)))) { error in
            XCTAssertEqual((error as? SourceAppError)?.message,
                           "Bridge refused: That playlist isn't in Apple Music's catalogue.")
        }
    }
}

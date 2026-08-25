import XCTest
@testable import music

final class HomeFeedTests: XCTestCase {
    /// Verbatim shape from the live probe (2026-08-25), trimmed to two rails and
    /// the fields we read. The real feed returned 17 rails.
    private let recommendationsJSON = """
    {"data":[
      {"id":"6-27s5hU6azhJY","type":"personal-recommendation",
       "attributes":{"isGroupRecommendation":false,"kind":"music-recommendations",
         "title":{"stringForDisplay":"Playlists Made for You"}},
       "relationships":{"contents":{"data":[
         {"id":"pl.pm-1","type":"playlists","attributes":{
           "name":"Your Essentials","curatorName":"Apple Music for Anthony Maley",
           "url":"https://music.apple.com/us/playlist/your-essentials/pl.pm-1",
           "artwork":{"url":"https://example.com/pl/{w}x{h}.jpg"}}}
       ]}}},
      {"id":"7-2Tqlz47h9yro","type":"personal-recommendation",
       "attributes":{"isGroupRecommendation":false,"kind":"recently-played",
         "title":{"stringForDisplay":"Recently Played"}},
       "relationships":{"contents":{"data":[
         {"id":"ra.u-01e4","type":"stations","attributes":{
           "name":"Anthony Maley’s Station","isLive":false,
           "url":"https://music.apple.com/us/station/anthony-maleys-station/ra.u-01e4",
           "artwork":{"url":"https://example.com/ra/{w}x{h}.jpg"}}},
         {"id":"1234","type":"albums","attributes":{
           "name":"Give It Up","artistName":"The Good Men",
           "url":"https://music.apple.com/us/album/give-it-up/1234",
           "artwork":{"url":"https://example.com/al/{w}x{h}.jpg"}}}
       ]}}}
    ]}
    """

    /// Verbatim shape from the live probe (2026-08-25) of /v1/me/recent/played.
    private let recentJSON = """
    {"data":[
      {"id":"ra.u-01e4","type":"stations","attributes":{
        "name":"Anthony Maley’s Station",
        "url":"https://music.apple.com/us/station/anthony-maleys-station/ra.u-01e4",
        "artwork":{"url":"https://example.com/ra/{w}x{h}.jpg"}}},
      {"id":"5678","type":"albums","attributes":{
        "name":"Wallys Groove - Single","artistName":"DJ Dan & Carabetta",
        "url":"https://music.apple.com/us/album/wallys-groove-single/5678",
        "artwork":{"url":"https://example.com/w/{w}x{h}.jpg"}}},
      {"id":"p.house","type":"playlists","attributes":{
        "name":"House",
        "url":"https://music.apple.com/us/playlist/house/p.house"}}
    ]}
    """

    /// Verbatim shape from the live probe (2026-08-25): both albums and
    /// playlists expose tracks under `relationships.tracks`, on the developer
    /// token alone.
    private let tracksJSON = """
    {"data":[{"id":"6776025177","type":"albums","attributes":{"name":"Arrêt Infini - EP"},
      "relationships":{"tracks":{"data":[
        {"id":"6776025431","type":"songs","attributes":{
          "name":"Arrêt Infini: , Pt. 1","artistName":"Fred Everything & Teuteu"}},
        {"id":"6776025436","type":"songs","attributes":{
          "name":"Arrêt Infini: , Pt. 2","artistName":"Fred Everything & Teuteu"}}
      ]}}}]}
    """

    private func feed(_ body: String, capture: ((String) -> Void)? = nil) -> HomeFeed {
        HomeFeed(storefront: "us", token: { "tok" }, fetch: { url in
            capture?(url)
            return body.data(using: .utf8)
        })
    }

    private func item(_ kind: HomeItemKind, id: String = "6776025177") -> HomeItem {
        HomeItem(id: id, kind: kind, name: "X", subtitle: nil, url: nil, artworkURL: nil)
    }

    // MARK: - Rails

    func testDecodesRecommendationRails() throws {
        let rails = try feed(recommendationsJSON).rails()
        XCTAssertEqual(rails.map(\.title), ["Playlists Made for You", "Recently Played"])
        XCTAssertEqual(rails.first?.id, "6-27s5hU6azhJY")
    }

    /// The feed carries its own Recently Played rail under a distinct `kind`, so
    /// Home can special-case it rather than string-matching the title.
    func testFlagsTheRecentlyPlayedRailByKindNotTitle() throws {
        let rails = try feed(recommendationsJSON).rails()
        XCTAssertEqual(rails.first?.isRecentlyPlayed, false)
        XCTAssertEqual(rails.last?.isRecentlyPlayed, true)
    }

    func testDecodesMixedItemTypesWithinARail() throws {
        let rails = try feed(recommendationsJSON).rails()
        let items = try XCTUnwrap(rails.last?.items)
        XCTAssertEqual(items.map(\.kind), [.station, .album])
        XCTAssertEqual(items.first?.name, "Anthony Maley’s Station")
        XCTAssertEqual(items.first?.url,
                       "https://music.apple.com/us/station/anthony-maleys-station/ra.u-01e4")
        XCTAssertEqual(items.last?.subtitle, "The Good Men")
    }

    /// A playlist has no artistName; the curator is the honest subtitle.
    func testUsesCuratorNameWhenThereIsNoArtist() throws {
        let rails = try feed(recommendationsJSON).rails()
        XCTAssertEqual(rails.first?.items.first?.subtitle, "Apple Music for Anthony Maley")
        XCTAssertEqual(rails.first?.items.first?.kind, .playlist)
    }

    func testRailsHitTheRecommendationsEndpoint() throws {
        var seen = ""
        _ = try feed(recommendationsJSON, capture: { seen = $0 }).rails()
        XCTAssertTrue(seen.contains("/v1/me/recommendations"), seen)
    }

    // MARK: - Recently played

    func testDecodesRecentlyPlayedAsMixedItems() throws {
        let items = try feed(recentJSON).recentlyPlayed()
        XCTAssertEqual(items.map(\.kind), [.station, .album, .playlist])
        XCTAssertEqual(items.map(\.name),
                       ["Anthony Maley’s Station", "Wallys Groove - Single", "House"])
    }

    /// Artwork is optional: the live House playlist row came back without any.
    func testToleratesAMissingArtwork() throws {
        let items = try feed(recentJSON).recentlyPlayed()
        XCTAssertNil(items.last?.artworkURL)
        XCTAssertEqual(items.first?.artworkURL, "https://example.com/ra/{w}x{h}.jpg")
    }

    func testRecentlyPlayedHitsTheRecentEndpoint() throws {
        var seen = ""
        _ = try feed(recentJSON, capture: { seen = $0 }).recentlyPlayed()
        XCTAssertTrue(seen.contains("/v1/me/recent/played"), seen)
    }

    // MARK: - Degradation

    /// An unknown resource type is skipped, not fatal: Apple can add one at any
    /// time and a Home tab that throws on it is worse than one that omits a row.
    func testSkipsUnknownItemTypes() throws {
        let json = """
        {"data":[{"id":"x","type":"music-videos","attributes":{"name":"V"}},
                 {"id":"5678","type":"albums","attributes":{"name":"A","artistName":"B"}}]}
        """
        let items = try feed(json).recentlyPlayed()
        XCTAssertEqual(items.map(\.name), ["A"])
    }

    /// A rail whose contents are empty has nothing to render, so it is dropped
    /// rather than shown as an empty heading.
    func testDropsEmptyRails() throws {
        let json = """
        {"data":[{"id":"r1","attributes":{"kind":"music-recommendations",
          "title":{"stringForDisplay":"Empty"}},
          "relationships":{"contents":{"data":[]}}}]}
        """
        XCTAssertEqual(try feed(json).rails().count, 0)
    }

    // MARK: - Drill-in

    func testDrillsIntoAnAlbumsTracks() throws {
        var seen = ""
        let tracks = try feed(tracksJSON, capture: { seen = $0 }).tracks(for: item(.album))
        XCTAssertTrue(seen.contains("/v1/catalog/us/albums/6776025177"), seen)
        XCTAssertTrue(seen.contains("include=tracks"), seen)
        XCTAssertEqual(tracks.map(\.name), ["Arrêt Infini: , Pt. 1", "Arrêt Infini: , Pt. 2"])
        XCTAssertEqual(tracks.first?.kind, .song)
        XCTAssertEqual(tracks.first?.subtitle, "Fred Everything & Teuteu")
    }

    func testDrillsIntoAPlaylistsTracks() throws {
        var seen = ""
        _ = try feed(tracksJSON, capture: { seen = $0 }).tracks(for: item(.playlist, id: "pl.pm-1"))
        XCTAssertTrue(seen.contains("/v1/catalog/us/playlists/pl.pm-1"), seen)
    }

    /// A station has no tracks relationship at all (the live API 400s with
    /// "No relationship found matching 'tracks'"), so don't spend a request on
    /// it. Stations are played, not browsed.
    func testDoesNotFetchTracksForAStation() throws {
        var fetched = false
        let f = HomeFeed(storefront: "us", token: { "tok" }, fetch: { _ in
            fetched = true
            return self.tracksJSON.data(using: .utf8)
        })
        XCTAssertEqual(try f.tracks(for: item(.station)).count, 0)
        XCTAssertFalse(fetched, "a station drill-in should not hit the network")
    }

    func testThrowsWithoutAUserToken() {
        let f = HomeFeed(storefront: "us", token: { nil }, fetch: { _ in Data() })
        XCTAssertThrowsError(try f.rails())
    }

    func testThrowsOnUnparseableBody() {
        XCTAssertThrowsError(try feed("not json").rails())
    }
}

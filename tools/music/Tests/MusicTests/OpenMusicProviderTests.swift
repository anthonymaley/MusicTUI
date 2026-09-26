import XCTest
@testable import music

/// Slice 3, Part 2, P3: `OpenMusicProvider`, Music.app mode's side of the
/// Discover and station surfaces.
///
/// **What these pin.** The open provider is a WRAPPER around the objects the
/// scenes already receive (`feed`, `catalog`, `opener`), never a re-derivation:
/// every read reaches the same object with the same arguments and rethrows the
/// same error, so a scene folded onto it behaves byte-for-byte as it ships
/// (codex-review-part2-1). Availability is the objects' presence (D4).
///
/// No network, no AppleScript, no Bridge: the feed, the catalogue's fetch and
/// the opener are all counting doubles.
final class OpenMusicProviderTests: XCTestCase {

    // MARK: - Doubles

    /// Records every call and answers from a script.
    private final class Feed: DiscoverFeedReading {
        var railLimits: [Int] = []
        var trackItems: [String] = []
        var railsResult: Result<[DiscoverRail], Error> = .success([])
        var tracksResult: Result<[DiscoverItem], Error> = .success([])

        func rails(limit: Int) throws -> [DiscoverRail] {
            railLimits.append(limit)
            return try railsResult.get()
        }
        func tracks(for item: DiscoverItem) throws -> [DiscoverItem] {
            trackItems.append(item.id)
            return try tracksResult.get()
        }
    }

    private final class Fetches {
        var urls: [String] = []
        var reply: Data? = Data(#"{"data":[]}"#.utf8)
        var status = 200
    }

    private func catalog(_ fetches: Fetches) -> RadioCatalog {
        RadioCatalog(storefront: "us", token: { "dev" }, fetch: { url in
            fetches.urls.append(url)
            guard let data = fetches.reply else { return nil }
            return RadioCatalogResponse(status: fetches.status, data: data)
        })
    }

    private final class CountingOpener: Opener {
        var opened: [String] = []
        func open(_ url: String) throws { opened.append(url) }
    }

    private let album = DiscoverItem(id: "700", name: "An Album", subtitle: "A", url: nil, artworkURL: nil,
                                     detail: .album(trackCount: 3, year: 2001, genre: nil))
    private let song = DiscoverItem(id: "801", name: "S1", subtitle: "A", url: nil, artworkURL: nil, detail: .song)

    private static let stationsJSON = """
    {"data":[{"id":"ra.978194965","type":"stations","attributes":{
      "name":"Apple Music 1","url":"https://music.apple.com/us/station/apple-music-1/ra.978194965",
      "isLive":true}}]}
    """

    // MARK: - Availability (D4)

    func testAvailabilityIsTheWrappedObjectsPresence() {
        let opener = CountingOpener()
        let both = OpenMusicProvider(discover: Feed(), catalog: catalog(Fetches()), opener: opener)
        XCTAssertTrue(both.feedAvailable)
        XCTAssertTrue(both.catalogueAvailable)

        let neither = OpenMusicProvider(discover: nil, catalog: nil, opener: opener)
        XCTAssertFalse(neither.feedAvailable)
        XCTAssertFalse(neither.catalogueAvailable)
    }

    // MARK: - Discover delegates to the feed

    func testRailsAreTheFeedsRailsAtTheSameLimit() throws {
        let feed = Feed()
        let rail = DiscoverRail(id: "r", title: "For You", items: [album], isRecentlyPlayed: false,
                                resourceTypes: [])
        feed.railsResult = .success([rail])
        let open = OpenMusicProvider(discover: feed, catalog: nil, opener: CountingOpener())

        XCTAssertEqual(try open.discoverRails(limit: 30), [rail])
        XCTAssertEqual(feed.railLimits, [30])
        XCTAssertEqual(feed.trackItems, [])
    }

    func testContainerTracksAreTheFeedsTracksForTheSameItem() throws {
        let feed = Feed()
        feed.tracksResult = .success([song])
        let open = OpenMusicProvider(discover: feed, catalog: nil, opener: CountingOpener())

        XCTAssertEqual(try open.containerTracks(for: album), [song])
        XCTAssertEqual(feed.trackItems, ["700"])
        XCTAssertEqual(feed.railLimits, [])
    }

    /// The shipped failure handling keys on the error's TYPE (a web-service
    /// failure has no words and keeps its old line), so the wrapper must not
    /// translate it.
    func testAFeedErrorIsRethrownUnchanged() {
        let feed = Feed()
        feed.railsResult = .failure(DiscoverFeedError.badResponse)
        feed.tracksResult = .failure(DiscoverFeedError.fetchFailed)
        let open = OpenMusicProvider(discover: feed, catalog: nil, opener: CountingOpener())

        XCTAssertThrowsError(try open.discoverRails(limit: 5)) {
            XCTAssertEqual($0 as? DiscoverFeedError, .badResponse)
        }
        XCTAssertThrowsError(try open.containerTracks(for: album)) {
            XCTAssertEqual($0 as? DiscoverFeedError, .fetchFailed)
        }
    }

    /// No feed is the shipped no-token state; a read asked of it anyway says so
    /// in the feed's own vocabulary and reaches nothing.
    func testWithNoFeedAReadIsTheFeedsNoTokenError() {
        let open = OpenMusicProvider(discover: nil, catalog: nil, opener: CountingOpener())
        XCTAssertThrowsError(try open.discoverRails(limit: 30)) {
            XCTAssertEqual($0 as? DiscoverFeedError, .noToken)
        }
        XCTAssertThrowsError(try open.containerTracks(for: album)) {
            XCTAssertEqual($0 as? DiscoverFeedError, .noToken)
        }
    }

    // MARK: - Stations delegate to the catalogue

    func testStationSearchIsTheCataloguesSearch() throws {
        let fetches = Fetches()
        fetches.reply = Data(#"{"results":{"stations":{"data":[{"id":"ra.1","type":"stations","attributes":{"name":"Jazz","url":"https://music.apple.com/us/station/jazz/ra.1"}}]}}}"#.utf8)
        let open = OpenMusicProvider(discover: nil, catalog: catalog(fetches), opener: CountingOpener())

        let hits = try open.searchStations(term: "jazz", limit: 25)

        XCTAssertEqual(hits.map(\.id), ["ra.1"])
        XCTAssertEqual(fetches.urls,
                       ["https://api.music.apple.com/v1/catalog/us/search?term=jazz&types=stations&limit=25"])
    }

    func testLiveAndPersonalAreTheCataloguesReads() throws {
        let fetches = Fetches()
        fetches.reply = Data(Self.stationsJSON.utf8)
        let open = OpenMusicProvider(discover: nil, catalog: catalog(fetches), opener: CountingOpener())

        XCTAssertEqual(try open.liveStations().map(\.name), ["Apple Music 1"])
        XCTAssertEqual(try open.personalStations().map(\.name), ["Apple Music 1"])
        XCTAssertEqual(fetches.urls, [
            "https://api.music.apple.com/v1/catalog/us/stations?filter[featured]=apple-music-live-radio",
            "https://api.music.apple.com/v1/catalog/us/stations?filter[identity]=personal",
        ])
    }

    /// `resolve` returning nil is normal (BBC Radio 1): the surface's nil.
    func testStationLookupIsTheCataloguesResolveAndNilStaysNil() throws {
        let fetches = Fetches()
        let open = OpenMusicProvider(discover: nil, catalog: catalog(fetches), opener: CountingOpener())

        XCTAssertNil(try open.station(id: "ra.1"))
        fetches.reply = Data(Self.stationsJSON.utf8)
        XCTAssertEqual(try open.station(id: "ra.978194965")?.name, "Apple Music 1")
        XCTAssertEqual(fetches.urls, [
            "https://api.music.apple.com/v1/catalog/us/stations?ids=ra.1",
            "https://api.music.apple.com/v1/catalog/us/stations?ids=ra.978194965",
        ])
    }

    func testACatalogueErrorIsRethrownUnchanged() {
        let fetches = Fetches()
        fetches.reply = nil
        let open = OpenMusicProvider(discover: nil, catalog: catalog(fetches), opener: CountingOpener())
        XCTAssertThrowsError(try open.liveStations()) {
            XCTAssertEqual($0 as? RadioCatalogError, .fetchFailed)
        }
    }

    func testWithNoCatalogueEveryReadIsTheCataloguesNoTokenError() {
        let open = OpenMusicProvider(discover: nil, catalog: nil, opener: CountingOpener())
        XCTAssertThrowsError(try open.searchStations(term: "x", limit: 25)) {
            XCTAssertEqual($0 as? RadioCatalogError, .noToken)
        }
        XCTAssertThrowsError(try open.liveStations()) { XCTAssertEqual($0 as? RadioCatalogError, .noToken) }
        XCTAssertThrowsError(try open.personalStations()) { XCTAssertEqual($0 as? RadioCatalogError, .noToken) }
        XCTAssertThrowsError(try open.station(id: "ra.1")) { XCTAssertEqual($0 as? RadioCatalogError, .noToken) }
    }

    // MARK: - Station play is the shipped opener path

    func testPlayOpensTheMusicSchemeURLExactlyOnce() throws {
        let opener = CountingOpener()
        let open = OpenMusicProvider(discover: nil, catalog: nil, opener: opener)

        try open.playStation(id: "ra.978194965", name: "Apple Music 1",
                             url: "https://music.apple.com/us/station/apple-music-1/ra.978194965")

        XCTAssertEqual(opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
    }

    func testPlayWithNoURLIsTheShippedSentenceAndOpensNothing() {
        let opener = CountingOpener()
        let open = OpenMusicProvider(discover: nil, catalog: nil, opener: opener)

        XCTAssertThrowsError(try open.playStation(id: "ra.1", name: "X", url: nil)) {
            XCTAssertEqual(($0 as? ActionError)?.message, "That station has no play URL.")
        }
        XCTAssertEqual(opener.opened, [])
    }

    func testPlayWithANonStationURLIsTheShippedErrorAndOpensNothing() {
        let opener = CountingOpener()
        let open = OpenMusicProvider(discover: nil, catalog: nil, opener: opener)

        XCTAssertThrowsError(try open.playStation(id: "1", name: "X", url: "https://music.apple.com/us/album/x/1")) {
            XCTAssertEqual($0 as? StationError, .notAStationURL("https://music.apple.com/us/album/x/1"))
        }
        XCTAssertEqual(opener.opened, [])
    }

    // MARK: - Only the surfaces Music.app mode serves by id (D1)

    func testConformsToDiscoverAndStationsOnly() {
        let open: Any = OpenMusicProvider(discover: nil, catalog: nil, opener: CountingOpener())
        XCTAssertTrue(open is DiscoverProviding)
        XCTAssertTrue(open is StationProviding)
        XCTAssertFalse(open is CataloguePlaying)
        XCTAssertFalse(open is CatalogueSearching)
        XCTAssertFalse(open is HistoryProviding)
        XCTAssertFalse(open is MusicDataProvider)
    }

    /// "No open conformer reaches Bridge": the file names no Bridge client.
    func testTheOpenProviderSourceNamesNoBridgeClient() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TUI/OpenMusicProvider.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for name in ["SourceControlling", "SourceAppClient", "SourceAppControl", "BridgeMusicProvider",
                     "BridgeDiscoverFeed", "SourceAppStationSearch"] {
            XCTAssertFalse(code.contains(name), "OpenMusicProvider names \(name)")
        }
    }
}

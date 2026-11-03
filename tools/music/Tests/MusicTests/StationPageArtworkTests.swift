// tools/music/Tests/MusicTests/StationPageArtworkTests.swift
//
// Station artwork from the station's public web page, for favourites the
// catalog API cannot resolve (BBC Radio 1 answers 404 on
// /v1/catalog/{us,gb}/stations/ra.1460912634, so it never gets art).
//
// Every fetch here is a fake `StationPageFetch`: no test touches the real
// network, Music.app, a socket, the keychain or ~/.config/music. Stores live
// in NSTemporaryDirectory().
import XCTest
@testable import music

/// Records every URL asked for and answers from a table; anything not in the
/// table is a 404 with an empty body. Thread-safe: the scene fetches off-thread.
final class FakeStationPages {
    private let lock = NSLock()
    private var pages: [String: RadioCatalogResponse?]
    private var _asked: [String] = []

    init(_ pages: [String: RadioCatalogResponse?] = [:]) { self.pages = pages }

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    var fetch: StationPageFetch {
        return { [self] url in
            lock.lock(); defer { lock.unlock() }
            _asked.append(url.absoluteString)
            if let hit = pages[url.absoluteString] { return hit }
            return RadioCatalogResponse(status: 404, data: Data())
        }
    }
}

final class StationPageArtworkTests: XCTestCase {
    static let radio1ID = "ra.1460912634"
    static let radio1US = "https://music.apple.com/us/station/bbc-radio-1/ra.1460912634"
    static let radio1GB = "https://music.apple.com/gb/station/bbc-radio-1/ra.1460912634"
    /// The real page's template, `{f}` normalised to jpg: `ArtworkStore.resolveURL`
    /// substitutes only `{w}x{h}`, as the catalog API's own templates need.
    static let radio1Template = "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/ef/df/a4/efdfa44c-f3d8-f369-40aa-e947133d9bb2/WorldDetails6019073929548110091.png/{w}x{h}bb.jpg"

    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/station-page-bbc-radio-1.html")
        return try Data(contentsOf: url)
    }

    static func page(_ data: Data) -> RadioCatalogResponse { RadioCatalogResponse(status: 200, data: data) }

    static func radio1(url: String = radio1GB, art: String? = nil) -> Station {
        Station(id: radio1ID, name: "Bbc Radio 1", url: url, isLive: nil, artworkURL: art)
    }

    private func tempStore() -> (StationStore, String) {
        let path = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        return (StationStore(path: path), path)
    }

    // MARK: extraction

    func testExtractsTheTemplateFromTheSavedRealPage() throws {
        let template = StationPageArtwork.template(inPage: try Self.fixture(), stationID: Self.radio1ID)
        XCTAssertEqual(template, Self.radio1Template)
        XCTAssertEqual(template.map { ArtworkStore.resolveURL($0, width: 300, height: 300) },
                       "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/ef/df/a4/efdfa44c-f3d8-f369-40aa-e947133d9bb2/WorldDetails6019073929548110091.png/300x300bb.jpg")
    }

    /// The template is taken only from the item whose id IS this station: a
    /// page whose serialized data carries only another station's art gives nil,
    /// not the wrong logo.
    func testArtworkBelongingToAnotherStationIsNotTaken() throws {
        let other = try String(data: Self.fixture(), encoding: .utf8)!
            .replacingOccurrences(of: Self.radio1ID, with: "ra.999")
        XCTAssertNil(StationPageArtwork.template(inPage: Data(other.utf8), stationID: Self.radio1ID))
    }

    func testAPageWithNoArtworkGivesNil() throws {
        let noArt = try String(data: Self.fixture(), encoding: .utf8)!
            .replacingOccurrences(of: "mzstatic.com", with: "example.invalid")
        XCTAssertNil(StationPageArtwork.template(inPage: Data(noArt.utf8), stationID: Self.radio1ID))
        XCTAssertNil(StationPageArtwork.template(inPage: Data("<html><body>Not Found</body></html>".utf8),
                                                 stationID: Self.radio1ID))
        XCTAssertNil(StationPageArtwork.template(inPage: Data(), stationID: Self.radio1ID))
    }

    // MARK: storefront order

    /// The station's own storefront first, then `us` (the gb page 404s for BBC
    /// Radio 1; the us page carries the art).
    func testOwnStorefrontFirstThenUS() throws {
        let pages = FakeStationPages([Self.radio1US: Self.page(try Self.fixture())])
        XCTAssertEqual(StationPageArtwork.lookup(Self.radio1(), fetch: pages.fetch), Self.radio1Template)
        XCTAssertEqual(pages.asked, [Self.radio1GB, Self.radio1US])
    }

    func testAHitOnTheOwnStorefrontStopsThere() throws {
        let pages = FakeStationPages([Self.radio1GB: Self.page(try Self.fixture())])
        XCTAssertEqual(StationPageArtwork.lookup(Self.radio1(), fetch: pages.fetch), Self.radio1Template)
        XCTAssertEqual(pages.asked, [Self.radio1GB])
    }

    func testAUSStationIsAskedOnce() {
        let pages = FakeStationPages()
        XCTAssertNil(StationPageArtwork.lookup(Self.radio1(url: Self.radio1US), fetch: pages.fetch))
        XCTAssertEqual(pages.asked, [Self.radio1US])
    }

    /// A transport failure on the own storefront still falls through to us.
    func testATransportFailureFallsThroughToUS() throws {
        let pages = FakeStationPages([Self.radio1GB: nil, Self.radio1US: Self.page(try Self.fixture())])
        XCTAssertEqual(StationPageArtwork.lookup(Self.radio1(), fetch: pages.fetch), Self.radio1Template)
        XCTAssertEqual(pages.asked, [Self.radio1GB, Self.radio1US])
    }

    /// A favourite saved with the music:// play URL is fetched over https.
    func testAMusicSchemeURLIsFetchedOverHTTPS() {
        let url = "music://music.apple.com/gb/station/bbc-radio-1/ra.1460912634"
        XCTAssertEqual(StationPageArtwork.pageURLs(for: Self.radio1(url: url)).map(\.absoluteString),
                       [Self.radio1GB, Self.radio1US])
    }

    /// A 200 whose body has no art for this station is a miss, and the next
    /// storefront is asked.
    func testANoArtPageOnTheOwnStorefrontFallsThrough() throws {
        let pages = FakeStationPages([Self.radio1GB: Self.page(Data("<html></html>".utf8)),
                                      Self.radio1US: Self.page(try Self.fixture())])
        XCTAssertEqual(StationPageArtwork.lookup(Self.radio1(), fetch: pages.fetch), Self.radio1Template)
    }

    // MARK: persistence and bounds

    func testBackfillSavesTheArtworkToStationsJSON() throws {
        let (store, path) = tempStore()
        let withArt = Station(id: "ra.978194965", name: "Apple Music 1",
                              url: "https://music.apple.com/us/station/apple-music-1/ra.978194965",
                              isLive: true, artworkURL: "https://example.invalid/{w}x{h}bb.jpg")
        try store.add(withArt)
        try store.add(Self.radio1())
        let pages = FakeStationPages([Self.radio1US: Self.page(try Self.fixture())])

        XCTAssertEqual(StationArtworkBackfill(store: store, fetch: pages.fetch).fillMissing(), [Self.radio1ID])

        // Read back from disk, not the cache: it is saved, so it is done once.
        let reread = StationStore(path: path).favorites()
        XCTAssertEqual(reread.map(\.id), ["ra.978194965", Self.radio1ID], "order kept")
        XCTAssertEqual(reread[1].artworkURL, Self.radio1Template)
        XCTAssertEqual(reread[1].name, "Bbc Radio 1")
        XCTAssertEqual(reread[1].url, Self.radio1GB)
        XCTAssertEqual(reread[0], withArt, "a favourite that has art is untouched")
        XCTAssertFalse(pages.asked.contains { $0.contains("ra.978194965") }, "and never fetched")

        // The next launch reads the saved art and fetches nothing.
        let nextLaunch = FakeStationPages()
        XCTAssertEqual(StationArtworkBackfill(store: StationStore(path: path), fetch: nextLaunch.fetch).fillMissing(), [])
        XCTAssertEqual(nextLaunch.asked, [])
    }

    /// A station whose page has no art is tried once per run: a second sweep
    /// and a later single fill ask nothing more.
    func testAFailedStationIsNotFetchedAgainInTheSameRun() throws {
        let (store, _) = tempStore()
        try store.add(Self.radio1())
        let pages = FakeStationPages()
        let backfill = StationArtworkBackfill(store: store, fetch: pages.fetch)

        XCTAssertEqual(backfill.fillMissing(), [])
        XCTAssertEqual(backfill.fillMissing(), [])
        XCTAssertFalse(backfill.fill(id: Self.radio1ID))
        XCTAssertEqual(pages.asked, [Self.radio1GB, Self.radio1US])
        XCTAssertNil(store.favorites()[0].artworkURL, "gradient, as today")
    }

    /// Filling a station removed meanwhile does not bring it back.
    func testArtworkForARemovedFavouriteIsDropped() throws {
        let (store, path) = tempStore()
        XCTAssertFalse(try store.setArtworkIfMissing(id: Self.radio1ID, url: Self.radio1Template))
        XCTAssertEqual(StationStore(path: path).favorites(), [])
    }

    /// Art a favourite already has is never overwritten by the page's.
    func testExistingArtworkIsNotReplaced() throws {
        let (store, _) = tempStore()
        try store.add(Self.radio1(art: "https://example.invalid/{w}x{h}bb.jpg"))
        XCTAssertFalse(try store.setArtworkIfMissing(id: Self.radio1ID, url: Self.radio1Template))
        XCTAssertEqual(store.favorites()[0].artworkURL, "https://example.invalid/{w}x{h}bb.jpg")
    }

    // MARK: the Radio tab

    private let snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    private func scene(_ store: StationStore, _ pages: FakeStationPages?) -> RadioScene {
        RadioScene(routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                               surface: .tui, makeSource: { SourceAppClient() }),
                   store: store, catalog: nil, stationPages: pages?.fetch)
    }

    private func tickUntil(_ s: RadioScene, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { _ = s.tick(snapshot: snapshot); usleep(2_000) }
    }

    /// Opening the tab backfills existing favourites off the main thread.
    func testTheRadioTabBackfillsExistingFavourites() throws {
        let (store, path) = tempStore()
        try store.add(Self.radio1())
        let pages = FakeStationPages([Self.radio1US: Self.page(try Self.fixture())])
        let s = scene(store, pages)

        tickUntil(s) { store.favorites().first?.artworkURL != nil }

        XCTAssertEqual(StationStore(path: path).favorites().first?.artworkURL, Self.radio1Template)
        tickUntil(s) { false }   // keep ticking: no second sweep
        XCTAssertEqual(pages.asked, [Self.radio1GB, Self.radio1US])
    }

    /// `a` + a station URL fills the new favourite's art from its page.
    func testAddingByURLFillsTheArtwork() throws {
        let (store, _) = tempStore()
        let pages = FakeStationPages([Self.radio1US: Self.page(try Self.fixture())])
        let s = scene(store, pages)
        _ = s.tick(snapshot: snapshot)   // the launch sweep: nothing to fill yet

        _ = s.handle(.char("a"))
        for c in Self.radio1GB { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)

        tickUntil(s) { store.favorites().first?.artworkURL != nil }
        XCTAssertEqual(store.favorites().first?.artworkURL, Self.radio1Template)
    }

    /// With no page fetcher wired (every other test's scene) nothing is fetched
    /// and the favourite keeps no art: the gradient, exactly as before.
    func testNoFetcherMeansNoBackfill() throws {
        let (store, _) = tempStore()
        try store.add(Self.radio1())
        let s = scene(store, nil)
        for _ in 0..<5 { _ = s.tick(snapshot: snapshot) }
        XCTAssertNil(store.favorites().first?.artworkURL)
    }
}

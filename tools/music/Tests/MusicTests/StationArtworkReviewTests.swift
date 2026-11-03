// tools/music/Tests/MusicTests/StationArtworkReviewTests.swift
//
// Codex review of 4771d98..9b1104d (station page artwork): the catalogue
// lookup must not erase page art, the launch sweep must show each cover as it
// lands with bounded concurrency, and the real fetcher's timeout must not race
// its callback. Fake fetchers and transports only: no real network, socket,
// Music.app, keychain or ~/.config/music.
import XCTest
@testable import music

final class StationArtworkReviewTests: XCTestCase {
    typealias T = StationPageArtworkTests

    private func tempStore() -> (StationStore, String) {
        let path = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        return (StationStore(path: path), path)
    }

    // MARK: 1. a catalogue lookup cannot erase page art

    /// Held interleaving: the page worker saves its template INSIDE the merge's
    /// window (after the merge has looked at the favourite, before it writes).
    /// The merge is one store operation, so the page write waits for it and
    /// lands after; the template survives on disk.
    func testPageArtSavedDuringTheMergeSurvives() throws {
        let (store, path) = tempStore()
        try store.add(T.radio1())
        let resolved = Station(id: T.radio1ID, name: "BBC Radio 1", url: T.radio1GB, isLive: true, artworkURL: nil)
        let pageWrote = DispatchSemaphore(value: 0)
        store.mergeWindowHook = {
            Thread.detachNewThread {
                _ = try? store.setArtworkIfMissing(id: T.radio1ID, url: T.radio1Template)
                pageWrote.signal()
            }
            // Gives the page write every chance to land inside the window; a
            // merge that holds the store lock makes this wait time out.
            _ = pageWrote.wait(timeout: .now() + 0.2)
        }
        XCTAssertTrue(try store.mergeResolved(resolved))
        store.mergeWindowHook = nil
        _ = pageWrote.wait(timeout: .now() + 5)

        let saved = StationStore(path: path).favorites()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.name, "BBC Radio 1", "the lookup's metadata is kept")
        XCTAssertEqual(saved.first?.isLive, true)
        XCTAssertEqual(saved.first?.artworkURL, T.radio1Template, "page art erased by the lookup")
    }

    /// Both sequential orders, for completeness.
    func testMergeKeepsSavedArtAndTakesTheLookupsArt() throws {
        let (store, _) = tempStore()
        try store.add(T.radio1(art: T.radio1Template))
        XCTAssertTrue(try store.mergeResolved(Station(id: T.radio1ID, name: "BBC Radio 1", url: T.radio1GB,
                                                      isLive: nil, artworkURL: nil)))
        XCTAssertEqual(store.favorites().first?.artworkURL, T.radio1Template)
        XCTAssertTrue(try store.mergeResolved(Station(id: T.radio1ID, name: "BBC Radio 1", url: T.radio1GB,
                                                      isLive: nil, artworkURL: "https://example.invalid/{w}x{h}bb.jpg")))
        XCTAssertEqual(store.favorites().first?.artworkURL, "https://example.invalid/{w}x{h}bb.jpg",
                       "art the catalogue gives wins")
    }

    /// A lookup that lands after the favourite was removed does not bring it
    /// back: the person's remove is the later intent.
    func testALookupForARemovedFavouriteDoesNotResurrectIt() throws {
        let (store, path) = tempStore()
        XCTAssertFalse(try store.mergeResolved(T.radio1()))
        XCTAssertEqual(StationStore(path: path).favorites(), [])
    }

    /// The same through the Radio tab: `a` adds, the catalogue lookup is posted,
    /// the favourite is removed before the tick drains it.
    func testTheRadioTabDoesNotResurrectARemovedFavourite() throws {
        let (store, path) = tempStore()
        let body = """
        {"data":[{"id":"\(T.radio1ID)","attributes":{"name":"BBC Radio 1","url":"\(T.radio1GB)","isLive":true}}]}
        """
        let catalog = RadioCatalog(storefront: "us", token: { "dev" }, fetch: { url in
            RadioCatalogResponse(status: 200, data: Data((url.contains("ids=") ? body : #"{"data":[]}"#).utf8))
        })
        let s = RadioScene(routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                                       surface: .tui, makeSource: { SourceAppClient() }),
                           store: store, catalog: catalog)
        _ = s.handle(.char("a"))
        for c in T.radio1GB { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)
        XCTAssertEqual(store.favorites().map(\.id), [T.radio1ID])

        let deadline = Date().addingTimeInterval(5)
        while s.postsOffered("lookup") < 1 && Date() < deadline { usleep(1_000) }
        XCTAssertEqual(s.postsOffered("lookup"), 1, "the lookup never posted")
        try store.remove(id: T.radio1ID)
        for _ in 0..<3 { _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])) }

        XCTAssertEqual(StationStore(path: path).favorites(), [], "the lookup re-added a removed favourite")
    }

    // MARK: 2. the launch sweep shows each cover as it lands, two at a time

    private func us(_ id: String) -> Station {
        Station(id: id, name: id, url: "https://music.apple.com/us/station/s/\(id)", isLive: nil, artworkURL: nil)
    }

    /// The first favourite's page is held; the second's answers at once. Its
    /// cover must repaint while the first is still held, not after the whole
    /// sweep.
    func testAFastFillRepaintsWhileASlowOneIsHeld() throws {
        let (store, path) = tempStore()
        try store.add(us("ra.111"))
        try store.add(T.radio1(url: T.radio1US))
        let pages = HeldStationPages(held: ["ra.111"], answers: [T.radio1US: T.page(try T.fixture())])
        defer { pages.releaseAll() }
        let s = RadioScene(routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                                       surface: .tui, makeSource: { SourceAppClient() }),
                           store: store, catalog: nil, stationPages: pages.fetch)
        let idle = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])
        let deadline = Date().addingTimeInterval(3)
        while s.pageArtRepaints == 0 && Date() < deadline { _ = s.tick(snapshot: idle); usleep(2_000) }

        XCTAssertEqual(s.pageArtRepaints, 1, "no repaint until the held fetch finished")
        XCTAssertTrue(pages.stillHeld("ra.111"), "the slow fetch was not still in flight")
        XCTAssertEqual(StationStore(path: path).favorites().last?.artworkURL, T.radio1Template)
    }

    /// Four favourites, every page held: at most two fetches are in flight.
    func testTheSweepFetchesAtMostTwoAtATime() throws {
        let (store, _) = tempStore()
        let ids = ["ra.1", "ra.2", "ra.3", "ra.4"]
        for id in ids { try store.add(us(id)) }
        let pages = HeldStationPages(held: Set(ids), answers: [:])
        let backfill = StationArtworkBackfill(store: store, fetch: pages.fetch)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { backfill.fillMissing(); done.signal() }

        let deadline = Date().addingTimeInterval(1)
        while pages.inFlight < 2 && Date() < deadline { usleep(1_000) }
        usleep(100_000)   // room for a third to start, if anything lets it
        XCTAssertEqual(pages.maxInFlight, 2)
        pages.releaseAll()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(Set(pages.asked), Set(ids.map { "https://music.apple.com/us/station/s/\($0)" }),
                       "every station asked once")
        XCTAssertEqual(pages.maxInFlight, 2)
    }
}

/// Holds fetches for the given station ids until released; answers others
/// from a table (anything else 404). Counts fetches in flight.
final class HeldStationPages {
    private let lock = NSLock()
    private let held: Set<String>
    private let answers: [String: RadioCatalogResponse]
    private let gate = DispatchSemaphore(value: 0)
    private var released = false
    private var waiting: Set<String> = []
    private var _asked: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0

    init(held: Set<String>, answers: [String: RadioCatalogResponse]) {
        self.held = held
        self.answers = answers
    }

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return _inFlight }
    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
    func stillHeld(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return waiting.contains(id) }

    func releaseAll() {
        lock.lock(); released = true; let n = waiting.count; lock.unlock()
        for _ in 0..<max(n, 8) { gate.signal() }
    }

    var fetch: StationPageFetch {
        return { [self] url in
            let id = url.lastPathComponent
            lock.lock()
            _asked.append(url.absoluteString)
            _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight)
            let hold = held.contains(id) && !released
            if hold { waiting.insert(id) }
            lock.unlock()
            if hold { _ = gate.wait(timeout: .now() + 10) }
            lock.lock(); _inFlight -= 1; waiting.remove(id); lock.unlock()
            return answers[url.absoluteString] ?? RadioCatalogResponse(status: 404, data: Data())
        }
    }
}

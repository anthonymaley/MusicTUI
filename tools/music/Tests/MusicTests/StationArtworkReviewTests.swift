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
}

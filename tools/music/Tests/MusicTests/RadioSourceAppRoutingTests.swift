// tools/music/Tests/MusicTests/RadioSourceAppRoutingTests.swift
//
// Radio's `/` search routed through an injected station source. Proves the two
// properties that matter for the temporary dogfood option: the guard now
// consults the SEARCH SOURCE rather than the REST catalog, and a source-app
// failure reaches the message line in words a person can act on.
//
// TEMPORARY, with the adapter it exercises.
import XCTest
@testable import music

private struct StubStationSearch: StationSearching {
    let result: Result<[Station], Error>
    func searchStations(term: String) throws -> [Station] { try result.get() }
}

final class RadioSourceAppRoutingTests: XCTestCase {
    private let frame = shellLayout(width: 80, height: 24)
    private let snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    private func makeScene(stationSearch: StationSearching?) -> RadioScene {
        let tmpPath = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        // catalog deliberately nil: this is the no-developer-key shape, which is
        // exactly the state the dogfood option has to work in.
        return RadioScene(routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"), surface: .tui, makeSource: { SourceAppClient() }), store: StationStore(path: tmpPath), catalog: nil, stationSearch: stationSearch)
    }

    private func commitSearch(_ scene: RadioScene, _ term: String) {
        _ = scene.handle(.char("/"))
        for c in term { _ = scene.handle(.char(c)) }
        _ = scene.handle(.enter)
    }

    /// Synchronous and deterministic: with a source injected and NO catalog, the
    /// commit must get past the auth guard. Before this change the guard tested
    /// `catalog`, so a keyless run refused here no matter what was injected.
    func testAnInjectedSourceGetsPastTheNoKeyGuard() {
        let scene = makeScene(stationSearch: StubStationSearch(result: .success([])))
        commitSearch(scene, "jazz")

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertFalse(out.contains("Search needs auth"),
                       "with a station source injected the search must run even with no developer key: \(out)")
        XCTAssertTrue(out.contains("Searching"),
                      "expected the in-flight message, got: \(out)")
    }

    /// And the inverse, so the test above cannot pass for the wrong reason:
    /// nothing injected and no catalog still refuses exactly as it does today.
    func testNoSourceAndNoCatalogStillRefuses() {
        let scene = makeScene(stationSearch: nil)
        commitSearch(scene, "jazz")

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("Search needs auth"),
                      "unset option with no key must behave exactly as before: \(out)")
    }

    /// A source-app failure must SAY the source app is the problem. The generic
    /// "Search failed" would send someone hunting for a network or catalogue
    /// fault when the answer is that the app is not running.
    ///
    /// Bounded, and a timeout is reported as FAILURE rather than read as
    /// success - this repo has already shipped an instrument that treated a
    /// timeout as an unchanged pass.
    func testSourceAppFailureNamesBridge() throws {
        let scene = makeScene(stationSearch: StubStationSearch(result: .failure(SourceAppError.notRunning)))
        commitSearch(scene, "jazz")

        let deadline = Date().addingTimeInterval(5)
        var out = ""
        while Date() < deadline {
            _ = scene.tick(snapshot: snapshot)
            out = scene.render(frame: frame, snapshot: snapshot)
            if out.contains("Bridge") { break }
            usleep(20_000)
        }
        XCTAssertTrue(out.contains("Bridge is not running"),
                      "expected Bridge's own refusal on the message line within 5s, got: \(out)")
    }

    /// Results from the source app land in the SAME list the REST route fills,
    /// which is what "display results using the existing Radio UI" means.
    func testResultsFromTheSourceAppRenderInTheExistingList() throws {
        let station = Station(id: "ra.978194965", name: "Apple Music 1",
                              url: "https://music.apple.com/us/station/apple-music-1/ra.978194965",
                              isLive: true, artworkURL: nil)
        let scene = makeScene(stationSearch: StubStationSearch(result: .success([station])))
        commitSearch(scene, "apple")

        let deadline = Date().addingTimeInterval(5)
        var out = ""
        while Date() < deadline {
            _ = scene.tick(snapshot: snapshot)
            out = scene.render(frame: frame, snapshot: snapshot)
            if out.contains("Apple Music 1") { break }
            usleep(20_000)
        }
        XCTAssertTrue(out.contains("Apple Music 1"),
                      "expected the brokered station in Radio's own list within 5s, got: \(out)")
    }
}

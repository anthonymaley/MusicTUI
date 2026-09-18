// tools/music/Tests/MusicTests/RadioSourceAppRoutingTests.swift
//
// Radio's `/` search, routed by the SELECTED OUTPUT rather than by an
// environment variable (step 3). Proves the properties that matter: with Bridge
// selected the search runs keyless - which is DoD 6's Radio half - with
// Music.app selected a keyless run refuses exactly as it ships, and a Bridge
// failure reaches the message line in words a person can act on.
//
// The searcher is no longer injected. It comes from the coordinator's source
// client, so these tests drive the mode and let the routing decide, which is the
// only shape that can catch a call site that stopped asking.
import XCTest
@testable import music

final class RadioSourceAppRoutingTests: XCTestCase {
    private let frame = shellLayout(width: 80, height: 24)
    private let snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    /// catalog deliberately nil throughout: this is the no-developer-key shape,
    /// which is exactly the state DoD 6's rename-away control puts the app in.
    private func makeScene(mode: PlaybackMode,
                           transport: @escaping (String, String) throws -> String) -> RadioScene {
        let tmpPath = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json")
        modeStore.set(mode)
        let routing = RoutingCoordinator(store: modeStore, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: transport) })
        return RadioScene(routing: routing, store: StationStore(path: tmpPath), catalog: nil)
    }

    private func stationsReply(_ stations: String) -> (String, String) throws -> String {
        { _, _ in #"{"ok":true,"op":"slice.searchStations","stations":[\#(stations)]}"# }
    }

    private var appleMusic1JSON: String {
        #"{"id":"ra.978194965","name":"Apple Music 1","url":"https://music.apple.com/us/station/apple-music-1/ra.978194965","is_live":true,"artwork_url":null}"#
    }

    private func commitSearch(_ scene: RadioScene, _ term: String) {
        _ = scene.handle(.char("/"))
        for c in term { _ = scene.handle(.char(c)) }
        _ = scene.handle(.enter)
    }

    /// Synchronous and deterministic: with a source injected and NO catalog, the
    /// commit must get past the auth guard. Before this change the guard tested
    /// `catalog`, so a keyless run refused here no matter what was injected.
    func testBridgeSelectedGetsPastTheNoKeyGuard() {
        let scene = makeScene(mode: .source, transport: stationsReply(""))
        commitSearch(scene, "jazz")

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertFalse(out.contains("Search needs auth"),
                       "with Bridge selected the search must run with no developer key: \(out)")
        XCTAssertTrue(out.contains("Searching"),
                      "expected the in-flight message, got: \(out)")
    }

    /// And the inverse, so the test above cannot pass for the wrong reason:
    /// nothing injected and no catalog still refuses exactly as it does today.
    func testMusicAppModeWithNoCatalogStillRefuses() {
        let scene = makeScene(mode: .musicApp, transport: stationsReply(""))
        commitSearch(scene, "jazz")

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("Search needs auth"),
                      "Music.app mode with no key must behave exactly as it ships: \(out)")
    }

    /// A source-app failure must SAY the source app is the problem. The generic
    /// "Search failed" would send someone hunting for a network or catalogue
    /// fault when the answer is that the app is not running.
    ///
    /// Bounded, and a timeout is reported as FAILURE rather than read as
    /// success - this repo has already shipped an instrument that treated a
    /// timeout as an unchanged pass.
    func testSourceAppFailureNamesBridge() throws {
        let scene = makeScene(mode: .source, transport: { _, _ in throw SourceAppError.notRunning })
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
        let scene = makeScene(mode: .source, transport: stationsReply(appleMusic1JSON))
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

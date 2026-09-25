import XCTest
@testable import music

/// Opening Library or Playlists while something is playing used to land on row
/// one, however far down the list the playing track was ("scroll/focus the
/// Playlists and Library lists to the currently playing row", from the
/// competitor scan). The snap happens on ARRIVAL only: a cursor that moved
/// under a browsing person would be worse than not snapping at all.
final class SnapToPlayingRowTests: XCTestCase {

    // MARK: - The pure decisions

    func testFindsThePlayingRowByTheSameKeyNowUses() {
        let rows = [(title: "Aquarama", artist: "Moomin"),
                    (title: "Lotus Flower", artist: "Radiohead"),
                    (title: "Nude", artist: "Radiohead")]
        XCTAssertEqual(indexOfPlayingRow(rows, track: "Nude", artist: "Radiohead"), 2)
        XCTAssertEqual(indexOfPlayingRow(rows, track: "Lotus Flower", artist: "Radiohead"), 1)
        XCTAssertNil(indexOfPlayingRow(rows, track: "Teardrop", artist: "Massive Attack"))
        XCTAssertNil(indexOfPlayingRow(rows, track: "", artist: "Radiohead"), "nothing playing")
    }

    func testFindsThePlayingPlaylistByItsCleanedContextName() {
        let names = ["Chill", "Top 25 Most Played", "Moon Safari"]
        XCTAssertEqual(indexOfPlayingPlaylist(names, contextName: "Top 25 Most Played"), 1)
        XCTAssertEqual(indexOfPlayingPlaylist(names, contextName: "moon safari"), 2)
        XCTAssertNil(indexOfPlayingPlaylist(names, contextName: ""))
        XCTAssertNil(indexOfPlayingPlaylist(names, contextName: "Something else"))
    }

    /// Two playlists can share a name, and the context carries a name, not an
    /// identity: focusing the first would put the cursor on a row the person
    /// never played, and their next Enter would act on it.
    func testADuplicateNameRefusesRatherThanGuessing() {
        XCTAssertNil(indexOfPlayingPlaylist(["Chill", "Moon Safari", "Chill"], contextName: "Chill"))
        XCTAssertEqual(indexOfPlayingPlaylist(["Chill", "Moon Safari", "chill "], contextName: "Moon Safari"), 1,
                       "an unambiguous name still matches")
    }

    // MARK: - The scenes

    private func playing(_ track: String, _ artist: String, context: String = "") -> NowPlayingSnapshot {
        var np = NowPlayingState()
        np.track = track; np.artist = artist; np.state = "playing"
        var snap = NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])
        snap.contextName = context
        return snap
    }

    private func routing() -> RoutingCoordinator {
        RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                           surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
    }

    private func librarySongs(_ songs: [(String, String)]) -> LibraryDataSources {
        LibraryDataSources(onAlbums: { _ in true },
                           onSongs: { page in
                               _ = page(songs.enumerated().map {
                                   LibrarySong(id: "s\($0.offset)", title: $0.element.0,
                                               artist: $0.element.1, album: "A")
                               })
                               return true
                           },
                           onArtists: { _ in true },
                           onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                           onAlbumCover: { _ in nil })
    }

    private func libraryScene(_ songs: [(String, String)]) -> LibraryScene {
        let status = StatusStore()
        return LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                            sources: librarySongs(songs), appQueue: AppQueueStore(),
                            status: status, actions: ActionRunner(status: status),
                            // Never the real ~/.config/music/artist-tiers.json (C2 isolation).
                            resultCache: temporaryResultCache().cache)
    }

    /// `[` and `]` cycle artists / albums / songs; three presses land on Songs
    /// from wherever the scene starts.
    private func toSongs(_ scene: LibraryScene) {
        for _ in 0..<LibrarySubView.allCases.count where scene.subViewForTest != .songs {
            _ = scene.handle(.char("]"))
        }
        XCTAssertEqual(scene.subViewForTest, .songs)
    }

    /// The songs stream in from a background read, so the scene may arrive
    /// before it has any rows: the snap waits for the first tick that can answer.
    private func settleLibrary(_ scene: LibraryScene, snapshot: NowPlayingSnapshot, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = scene.tick(snapshot: snapshot)
            if scene.navCursorForTest != 0 { return }
            usleep(10_000)
        }
    }

    func testOpeningLibraryPutsTheCursorOnThePlayingSong() {
        let scene = libraryScene([("Aquarama", "Moomin"), ("Lotus Flower", "Radiohead"), ("Nude", "Radiohead")])
        toSongs(scene)
        let snapshot = playing("Nude", "Radiohead")
        scene.becameActive()
        settleLibrary(scene, snapshot: snapshot)
        XCTAssertEqual(scene.navCursorForTest, 2)
    }

    /// Arrival only. A track change while the person is browsing must not move
    /// their cursor.
    func testALaterTrackChangeDoesNotMoveTheCursor() {
        let scene = libraryScene([("Aquarama", "Moomin"), ("Lotus Flower", "Radiohead"), ("Nude", "Radiohead")])
        toSongs(scene)
        scene.becameActive()
        settleLibrary(scene, snapshot: playing("Nude", "Radiohead"))
        XCTAssertEqual(scene.navCursorForTest, 2)
        _ = scene.tick(snapshot: playing("Aquarama", "Moomin"))
        XCTAssertEqual(scene.navCursorForTest, 2, "the cursor is the person's, once they are in the list")
    }

    func testOpeningPlaylistsPutsTheRailOnThePlayingPlaylist() {
        let status = StatusStore()
        let sources = PlaylistDataSources(onMeta: { _ in [:] }, onPreview: { _ in nil },
                                          onTracks: { _ in nil }, onArtworkMap: nil)
        let scene = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                                   playlists: ["Chill", "Top 25 Most Played", "Moon Safari"],
                                   sources: sources, appQueue: AppQueueStore(),
                                   status: status, actions: ActionRunner(status: status),
                                   metaCache: temporaryPlaylistMetaCache().cache)
        XCTAssertEqual(scene.railCursorForTest, 0)
        scene.becameActive()
        _ = scene.tick(snapshot: playing("Dreams", "Fleetwood Mac", context: "Moon Safari"))
        XCTAssertEqual(scene.railCursorForTest, 2)
    }

    func testNothingPlayingLeavesBothCursorsAlone() {
        let scene = libraryScene([("Aquarama", "Moomin"), ("Nude", "Radiohead")])
        toSongs(scene)
        scene.becameActive()
        _ = scene.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        XCTAssertEqual(scene.navCursorForTest, 0)
    }
}

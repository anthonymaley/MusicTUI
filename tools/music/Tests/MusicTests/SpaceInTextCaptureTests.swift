// tools/music/Tests/MusicTests/SpaceInTextCaptureTests.swift
//
// Regression coverage for the app-wide "can't type a space in a text box" bug:
// Terminal.swift parses 0x20 as the distinct KeyPress.space case (so the global
// play/pause binding works), but every raw-text-capture branch matched only
// .char(let c) — so .space fell through to `default: break` and vanished.
// Found when the user tried to search "radio 4" in Radio's add/search box.
//
// These drive each scene's `handle(_:)` directly (never `tick()`, so no
// background thread/network/disk-write path runs) and assert the rendered
// text box shows a literal space, exactly like `.char(" ")` would have.
import XCTest
@testable import music

final class SpaceInTextCaptureTests: XCTestCase {
    private let frame = shellLayout(width: 80, height: 24)
    private let snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    private func type(_ s: String, into handle: (KeyPress) -> SceneAction) {
        for c in s { _ = handle(.char(c)) }
    }

    // MARK: RadioScene — `a` add/search box

    func testRadioAddCaptureSpace() {
        let tmpPath = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        let store = StationStore(path: tmpPath)
        let scene = RadioScene(store: store, catalog: nil)

        _ = scene.handle(.char("a"))               // enter add/search mode
        type("radio", into: scene.handle)
        _ = scene.handle(.space)
        type("4", into: scene.handle)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("radio 4"), "expected add/search box to contain a literal space, got: \(out)")
    }

    // MARK: RadioScene — `/` filter box

    func testRadioFilterCaptureSpace() {
        let tmpPath = NSTemporaryDirectory() + "music-test-stations-\(UUID().uuidString).json"
        let store = StationStore(path: tmpPath)
        let scene = RadioScene(store: store, catalog: nil)

        _ = scene.handle(.char("/"))                // enter filter mode
        type("deep", into: scene.handle)
        _ = scene.handle(.space)
        type("house", into: scene.handle)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("deep house"), "expected filter box to contain a literal space, got: \(out)")
    }

    // MARK: LibraryScene — `/` filter box

    func testLibraryFilterCaptureSpace() {
        let status = StatusStore()
        let sources = LibraryDataSources(
            onAlbums: { _ in },
            onSongs: { _ in },
            onArtists: { _ in },
            onAlbumTracks: { _, _ in [] },
            onArtistAlbums: { _ in [] }
        )
        let scene = LibraryScene(backend: AppleScriptBackend(), sources: sources,
                                  appQueue: AppQueueStore(), status: status,
                                  actions: ActionRunner(status: status))

        _ = scene.handle(.char("/"))                // default sub-view is Artists, so filter is live
        type("deep", into: scene.handle)
        _ = scene.handle(.space)
        type("house", into: scene.handle)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("deep house"), "expected filter box to contain a literal space, got: \(out)")
    }

    // MARK: PlaylistsScene — `/` filter box

    func testPlaylistsFilterCaptureSpace() {
        let status = StatusStore()
        let sources = PlaylistDataSources(
            onMeta: { _ in [:] },
            onPreview: { _ in nil },
            onTracks: { _ in nil },
            onArtworkMap: nil
        )
        let scene = PlaylistsScene(backend: AppleScriptBackend(), playlists: ["Test Playlist"], sources: sources,
                                    appQueue: AppQueueStore(), status: status,
                                    actions: ActionRunner(status: status))

        _ = scene.handle(.char("/"))                // enter filter mode
        type("deep", into: scene.handle)
        _ = scene.handle(.space)
        type("house", into: scene.handle)

        let out = scene.render(frame: frame, snapshot: snapshot)
        XCTAssertTrue(out.contains("deep house"), "expected filter box to contain a literal space, got: \(out)")
    }

    // MARK: Regression guard — space must still resolve as the global
    // play/pause action when no scene is capturing text (unchanged by this fix,
    // asserted here so a future change to either side trips this test too).

    func testSpaceIsStillGlobalPlayPauseWhenNotCapturing() {
        XCTAssertEqual(resolveGlobalKey(.space), .playPause)
    }
}

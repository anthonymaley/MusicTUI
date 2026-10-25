import XCTest
@testable import music

/// Measures how many full-body repaints, and how many bytes of scene output, the
/// shell's poll-driven render decision costs per N playback polls. The shell
/// loop itself is not injectable, so this drives the same pieces it does: the
/// poller's `NowPlayingStore.write`, the loop's `readWithGeneration` + render
/// decision (`ShellRenderGate`), and a REAL scene's `render` for the bytes. Numbers print to stdout.
final class RenderRequestMeasurementTests: XCTestCase {
    private let polls = 30
    private let frame = shellLayout(width: 120, height: 40)

    private func routing() -> RoutingCoordinator {
        RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                           surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
    }

    private func libraryScene() -> LibraryScene {
        let status = StatusStore()
        let songs = (0..<40).map { LibrarySong(id: "s\($0)", title: "Song \($0)", artist: "Artist \($0 % 5)", album: "A") }
        let sources = LibraryDataSources(onAlbums: { _ in true },
                                         onSongs: { page in _ = page(songs); return true },
                                         onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        return LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                            sources: sources, appQueue: AppQueueStore(),
                            status: status, actions: ActionRunner(status: status),
                            resultCache: temporaryResultCache().cache)
    }

    /// Songs sub-view with the 40 rows landed, so the bytes are a populated list.
    private func loadedLibrary() -> LibraryScene {
        let scene = libraryScene()
        for _ in 0..<LibrarySubView.allCases.count where scene.subViewForTest != .songs { _ = scene.handle(.char("]")) }
        let deadline = Date().addingTimeInterval(2)
        let s = snap(position: 0, state: "paused")
        while Date() < deadline {
            _ = scene.tick(snapshot: s)
            if scene.render(frame: frame, snapshot: s).contains("Song 3") { break }
            usleep(10_000)
        }
        return scene
    }

    private func nowScene() -> NowPlayingScene {
        let status = StatusStore()
        return NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               status: status, actions: ActionRunner(status: status), routing: routing())
    }

    private func snap(position: Int, state: String) -> NowPlayingSnapshot {
        var np = NowPlayingState()
        np.track = "Nude"; np.artist = "Radiohead"; np.album = "In Rainbows"
        np.duration = 255; np.position = position; np.state = state
        return NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])
    }

    /// One scenario: `polls` poller writes, one loop iteration after each.
    private func run(_ label: String, scene: Scene, active: SceneID,
                     next: (Int) -> NowPlayingSnapshot) -> (renders: Int, bytes: Int) {
        let store = NowPlayingStore()
        var renders = 0, bytes = 0
        var decide = ShellRenderGate()
        // First iteration paints once, as the shell does at launch.
        for i in 0..<polls {
            store.write(next(i))
            let (s, g) = store.readWithGeneration()
            if decide.snapshotNeedsRender(snapshot: s, generation: g, active: active) {
                renders += 1
                bytes += scene.render(frame: frame, snapshot: s).utf8.count
            }
        }
        print("MEASURE \(label): polls=\(polls) renders=\(renders) bytes=\(bytes)")
        return (renders, bytes)
    }

    func testMeasurePausedLibrary() {
        let l = loadedLibrary()
        let r = run("paused-identical/Library", scene: l, active: .library) { _ in self.snap(position: 42, state: "paused") }
        XCTAssertEqual(r.renders, 1, "only the first paint; 29 identical polls repaint nothing")
    }
    func testMeasurePlayingLibrary() {
        let l = loadedLibrary()
        let r = run("playing/Library", scene: l, active: .library) { self.snap(position: 10 + $0, state: "playing") }
        XCTAssertEqual(r.renders, 1, "elapsed ticks do not repaint a tab that draws no progress")
    }
    func testMeasurePlayingNow() {
        let n = nowScene()
        let r = run("playing/Now", scene: n, active: .nowPlaying) { self.snap(position: 10 + $0, state: "playing") }
        XCTAssertEqual(r.renders, polls, "the Now tab's progress bar still advances every poll")
    }
}

// tools/music/Tests/MusicTests/ArtworkLivenessSceneTests.swift
import XCTest
@testable import music

/// Blocker 1 at the scene + shell-gate level. An idle Playlists screen (Music.app
/// rail, REST artwork map) asks for its hero cover once; the fetch fails
/// temporarily. Nobody touches a key and playback does not change, so
/// `ShellRenderGate` suppresses every repaint and `render` is never called
/// again. The cover must still recover: the scene's tick drives the store's
/// retry deadline and reports the landed cover as a change.
/// No network (injected fetcher), no osascript (`/usr/bin/true` backend, injected
/// name read), no real config (temporary meta cache, temp art dir), fake time.
final class ArtworkLivenessSceneTests: XCTestCase {

    private let frame = shellLayout(width: 110, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    func testAnIdlePlaylistsHeroRecoversFromATemporaryFailureOnTicksAlone() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-live-scene-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = ArtworkStoreLivenessTests.Clock()
        let calls = ArtworkStoreLivenessTests.Meter()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in
                                     calls.add(url)
                                     return calls.count == 1 ? .temporary : .data(Data([1, 2, 3]))
                                 },
                                 render: { _, _, h in Array(repeating: "LIVECOVER", count: max(1, h)) },
                                 now: clock.now)
        let status = StatusStore()
        let sources = PlaylistDataSources(onMeta: { _ in [:] }, onPreview: { _ in nil }, onTracks: { _ in nil },
                                          onArtworkMap: { ["road trip": (id: "pl.rt", url: "https://art.invalid/{w}x{h}.jpg")] })
        let routing = RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                         surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
        let scene = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                                   playlists: ["Road Trip"], sources: sources,
                                   appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                                   metaCache: temporaryPlaylistMetaCache().cache,
                                   artwork: store,
                                   loadMusicAppPlaylists: { .success(names: ["Road Trip"], subscription: []) })

        // Arrive: tick and paint until the hero has asked for its cover once.
        XCTAssertTrue(settleScene(scene) {
            _ = scene.render(frame: frame, snapshot: idle)
            return calls.count >= 1
        }, "the hero never asked for its cover")
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1)
        var last = scene.render(frame: frame, snapshot: idle)
        XCTAssertFalse(last.contains("LIVECOVER"), "the first fetch failed; the gradient shows")

        // Quiesce: tick (no paint) until the scene reports no change of its own.
        var gate = ShellRenderGate()
        XCTAssertTrue(gate.snapshotNeedsRender(snapshot: idle, generation: 1, active: .playlists))
        var quiet = 0
        for _ in 0..<400 where quiet < 20 {
            quiet = scene.tick(snapshot: idle) ? 0 : quiet + 1
            usleep(1_000)
        }
        XCTAssertEqual(quiet, 20, "the scene never went quiet")

        // Idle: 31 s of the shell loop at 4 Hz. Same snapshot, same generation,
        // no key: the gate never repaints. Only a tick may report a change, and
        // only then does this loop paint, exactly as Shell.swift does.
        var repaintsFromGate = 0
        var tickChanges = 0
        for _ in 0..<124 {
            clock.advance(0.25)
            if gate.snapshotNeedsRender(snapshot: idle, generation: 1, active: .playlists) { repaintsFromGate += 1 }
            store.waitUntilIdleForTesting()   // let any launched fetch land before the next tick reads artDirty
            if scene.tick(snapshot: idle) {
                tickChanges += 1
                last = scene.render(frame: frame, snapshot: idle)
            }
        }
        store.waitUntilIdleForTesting()
        if scene.tick(snapshot: idle) { tickChanges += 1; last = scene.render(frame: frame, snapshot: idle) }

        XCTAssertEqual(repaintsFromGate, 0, "the gate stays shut on an unchanged snapshot")
        XCTAssertEqual(calls.count, 2, "the retry deadline re-issued the fetch with no repaint and no key")
        XCTAssertGreaterThanOrEqual(tickChanges, 1, "the tick reported the landed cover")
        XCTAssertTrue(last.contains("LIVECOVER"), "the recovered cover is on screen")
    }
}

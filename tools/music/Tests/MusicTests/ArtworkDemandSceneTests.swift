// tools/music/Tests/MusicTests/ArtworkDemandSceneTests.swift
import XCTest
@testable import music

/// Demand ownership at the scene level (review round 2, 2026-10-25). The store
/// re-issues its remembered demand from `pump()`, so the demand must belong to
/// the scene's CURRENT view: validated at the top of each tick, after the
/// scene's own provenance and focus decisions and before the pump, never only
/// later in a hero render that some views never reach.
///
/// Every fetch here fails temporarily and is recorded; nothing reaches the
/// network, playback, osascript (`/usr/bin/true`), SpanDAC or ~/.config/music.
/// Time is one fake clock shared by the scene and the store.
final class ArtworkDemandSceneTests: XCTestCase {

    private let frame = shellLayout(width: 110, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - Library rig (Music.app source, REST-style cover per album)

    private final class LibraryRig {
        let clock = ArtworkStoreLivenessTests.Clock()
        let calls = ArtworkStoreLivenessTests.Meter()
        let dir: String
        let store: ArtworkStore
        let scene: LibraryScene

        static let urlA = "https://art.invalid/al.a.jpg"

        init() {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("art-demand-lib-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let calls = self.calls, clock = self.clock
            store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return .temporary },
                                 render: { _, _, h in Array(repeating: "COVER", count: max(1, h)) },
                                 now: clock.now)
            let sources = LibraryDataSources(
                onAlbums: { page in
                    page([LibraryAlbum(id: "al.a", name: "Kid A", artist: "Radiohead", trackCount: 10),
                          LibraryAlbum(id: "al.b", name: "Amnesiac", artist: "Radiohead", trackCount: 11)])
                },
                onSongs: { page in page([LibrarySong(id: "s1", title: "Idioteque", artist: "Radiohead", album: "Kid A")]) },
                onArtists: { page in page([LibraryArtist(id: "ar1", name: "Radiohead")]) },
                onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                onAlbumCover: { id in LibraryCover(key: "cov.\(id)", url: "https://art.invalid/\(id).jpg") })
            let routing = RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                             surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
            let status = StatusStore()
            scene = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                                 sources: sources, appQueue: AppQueueStore(), status: status,
                                 actions: ActionRunner(status: status),
                                 artwork: store,
                                 resultCache: temporaryResultCache().cache,
                                 now: { Date(timeIntervalSinceReferenceDate: clock.now()) },
                                 screenWidth: { 110 })
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }

        func requests(_ url: String) -> Int { calls.all.filter { $0 == url }.count }
    }

    /// Albums, cover A asked for once and failed temporarily; the hero shows A.
    private func libraryWithFailedCoverA() -> LibraryRig {
        let rig = LibraryRig()
        goToSubView(rig.scene, .albums)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Kid A") },
                      "the albums never loaded")
        // The cursor rests on A; the cover ladder answers; the hero asks once.
        XCTAssertTrue(settleScene(rig.scene) {
            rig.clock.advance(0.05)
            _ = rig.scene.render(frame: self.frame, snapshot: self.idle)
            return rig.calls.count >= 1
        }, "the hero never asked for cover A")
        rig.store.waitUntilIdleForTesting()
        XCTAssertEqual(rig.calls.all, [LibraryRig.urlA])
        return rig
    }

    /// Ticks only (no paint): the shell loop with the render gate shut.
    private func tickBeyondCooldown(_ rig: LibraryRig, seconds: Double = 25) {
        for _ in 0..<Int(seconds * 4) {
            rig.clock.advance(0.25)
            rig.store.waitUntilIdleForTesting()
            _ = rig.scene.tick(snapshot: idle)
        }
        rig.store.waitUntilIdleForTesting()
    }

    func testAFailedAlbumsCoverIsNotRetriedOnceSongsIsShowing() {
        let rig = libraryWithFailedCoverA()
        goToSubView(rig.scene, .songs)
        _ = rig.scene.tick(snapshot: idle)
        _ = rig.scene.render(frame: frame, snapshot: idle)   // the new view is painted
        tickBeyondCooldown(rig)
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 1, "Songs shows no cover; the old one must not be retried")
    }

    func testAFailedAlbumsCoverIsNotRetriedOnceTheRootArtistsListIsShowing() {
        let rig = libraryWithFailedCoverA()
        goToSubView(rig.scene, .artists)
        _ = rig.scene.tick(snapshot: idle)
        _ = rig.scene.render(frame: frame, snapshot: idle)
        tickBeyondCooldown(rig)
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 1, "the Artists list shows no cover")
    }

    func testAFailedAlbumsCoverIsNotRetriedUnderAnEmptyFilteredView() {
        let rig = libraryWithFailedCoverA()
        _ = rig.scene.handle(.char("/"))
        for c in "zzzz" { _ = rig.scene.handle(.char(c)) }
        _ = rig.scene.handle(.enter)
        _ = rig.scene.tick(snapshot: idle)
        XCTAssertTrue(rig.scene.render(frame: frame, snapshot: idle).contains("zzzz"), "the filter is on screen")
        tickBeyondCooldown(rig)
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 1, "a filter that matches nothing shows no cover")
    }

    /// The retry is already due when the focus moves; the very next tick runs
    /// before any paint of the new row, and must not fetch the old cover.
    func testARetryDueOnTheFirstTickAfterAFocusMoveIsNotIssued() {
        let rig = libraryWithFailedCoverA()
        rig.clock.advance(15)                    // A's cooldown has passed; no tick ran
        _ = rig.scene.handle(.down)              // focus moves to B
        _ = rig.scene.tick(snapshot: idle)       // first tick, before any paint
        rig.store.waitUntilIdleForTesting()
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 1, "the old demand was pumped before the new view was evaluated")
    }

    /// Same, with the sub-view changed instead of the row.
    func testARetryDueOnTheFirstTickAfterASubViewChangeIsNotIssued() {
        let rig = libraryWithFailedCoverA()
        rig.clock.advance(15)
        goToSubView(rig.scene, .songs)
        _ = rig.scene.tick(snapshot: idle)
        rig.store.waitUntilIdleForTesting()
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 1)
    }

    /// Leave the tab (no ticks), come back after the deadline to the same view:
    /// the cover is still wanted, so the first tick retries it, with no paint.
    func testReturningToTheSameCoverAfterTheDeadlineRetriesIt() {
        let rig = libraryWithFailedCoverA()
        rig.clock.advance(15)                    // away: nothing ticks
        rig.scene.becameActive()
        _ = rig.scene.tick(snapshot: idle)
        rig.store.waitUntilIdleForTesting()
        XCTAssertEqual(rig.requests(LibraryRig.urlA), 2, "the returned view still wants A")
    }

    // MARK: - Playlists: a return that lands on a different playlist

    func testReturningToPlaylistsOnADifferentPlaylistDoesNotRetryTheOldCover() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-demand-pl-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = ArtworkStoreLivenessTests.Clock()
        let calls = ArtworkStoreLivenessTests.Meter()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return .temporary },
                                 render: { _, _, h in Array(repeating: "COVER", count: max(1, h)) },
                                 now: clock.now)
        let status = StatusStore()
        let sources = PlaylistDataSources(onMeta: { _ in [:] }, onPreview: { _ in nil }, onTracks: { _ in nil },
                                          onArtworkMap: { ["road trip": (id: "pl.rt", url: "https://art.invalid/rt/{w}x{h}.jpg"),
                                                           "chill": (id: "pl.ch", url: "https://art.invalid/ch/{w}x{h}.jpg")] })
        let routing = RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "m-\(UUID().uuidString).json"),
                                         surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
        let scene = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                                   playlists: ["Road Trip", "Chill"], sources: sources,
                                   appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                                   metaCache: temporaryPlaylistMetaCache().cache,
                                   artwork: store,
                                   loadMusicAppPlaylists: { .success(names: ["Road Trip", "Chill"], subscription: []) })
        XCTAssertTrue(settleScene(scene) {
            _ = scene.render(frame: frame, snapshot: idle)
            return calls.count >= 1
        }, "the hero never asked for its cover")
        store.waitUntilIdleForTesting()
        let roadTrip = calls.all
        XCTAssertEqual(roadTrip.count, 1)
        XCTAssertTrue(roadTrip[0].contains("/rt/"))

        // Away past the deadline; back while "Chill" is playing: the arrival
        // snap moves the rail to Chill on the first tick, before any paint.
        clock.advance(15)
        scene.becameActive()
        var playing = idle
        playing.contextName = "Chill"
        _ = scene.tick(snapshot: playing)
        store.waitUntilIdleForTesting()
        _ = scene.tick(snapshot: playing)
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.all.filter { $0.contains("/rt/") }.count, 1,
                       "the returned view shows Chill; Road Trip's cover must not be retried")
    }
}

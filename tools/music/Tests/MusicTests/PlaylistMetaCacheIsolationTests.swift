// tools/music/Tests/MusicTests/PlaylistMetaCacheIsolationTests.swift
import XCTest
@testable import music

/// C0's test-isolation prerequisite, as a STANDING regression test rather than
/// only the score's manual `stat` diff at verification time (which proves one
/// run, not every future one). Two properties, mirroring
/// `LibrarySceneCacheIsolationTests` for `ResultCache`: the injected
/// `PlaylistMetaCache` is genuinely live (a Music.app-mode scene's background
/// refresh writes INTO it, and the seed reads FROM it), and the real
/// `~/.config/music/playlist-meta.json` is never touched in either direction.
final class PlaylistMetaCacheIsolationTests: XCTestCase {

    private let frame = shellLayout(width: 80, height: 24)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func routing() -> RoutingCoordinator {
        RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"),
                           surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
    }

    private func realModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PlaylistMetaCache.defaultPath))?[.modificationDate] as? Date
    }

    /// A Music.app-mode scene's background refresh writes into the INJECTED
    /// temporary cache, proving the injection is live, while the real file's
    /// own modification date (or absence) is unchanged.
    func testAMusicAppModeSceneWritesToTheInjectedPathNotTheReal() {
        let realExistedBefore = FileManager.default.fileExists(atPath: PlaylistMetaCache.defaultPath)
        let beforeModified = realModified()

        let (cache, path) = temporaryPlaylistMetaCache()
        let status = StatusStore()
        // Answers every requested index in one pass, so the background
        // refresh's `pending` set empties on its first batch and `save`
        // follows almost immediately — no 0.6s retry sleep to wait out.
        let sources = PlaylistDataSources(
            onMeta: { indices in
                var out: [Int: (Int, Int, Bool, String)] = [:]
                for i in indices { out[i] = (10 + i, 100, false, "") }
                return out
            },
            onPreview: { _ in nil },
            onTracks: { _ in nil },
            onArtworkMap: nil
        )
        _ = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                           playlists: ["A", "B"], sources: sources,
                           appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                           metaCache: cache)

        let deadline = Date().addingTimeInterval(3)
        var decoded: [String: CachedPlaylistMeta] = [:]
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let dict = try? JSONDecoder().decode([String: CachedPlaylistMeta].self, from: data),
               !dict.isEmpty {
                decoded = dict
                break
            }
            usleep(10_000)
        }
        XCTAssertEqual(decoded.count, 2, "the injected cache was never written — the injection is not live")
        XCTAssertEqual(decoded["A"]?.count, 10)
        XCTAssertEqual(decoded["B"]?.count, 11)

        let realExistsAfter = FileManager.default.fileExists(atPath: PlaylistMetaCache.defaultPath)
        XCTAssertEqual(realExistedBefore, realExistsAfter,
                       "the real playlist-meta.json's existence changed")
        if realExistedBefore {
            XCTAssertEqual(beforeModified, realModified(), "the real playlist-meta.json was rewritten")
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The seed reads the INJECTED cache: a pre-written temporary cache paints
    /// its count on the first render, with no background refresh needed.
    func testTheSeedReadsTheInjectedCache() {
        let (cache, path) = temporaryPlaylistMetaCache()
        cache.save(["Chill": CachedPlaylistMeta(count: 42, durationSec: 100, isSmart: false, specialKind: "")])

        let status = StatusStore()
        // No results, so nothing in the render can come from the background
        // refresh — a "42" in the first frame can only have come from the seed.
        let sources = PlaylistDataSources(onMeta: { _ in [:] }, onPreview: { _ in nil },
                                          onTracks: { _ in nil }, onArtworkMap: nil)
        let scene = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                                   playlists: ["Chill"], sources: sources,
                                   appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                                   metaCache: cache)

        let out = scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("42"), "the seed did not paint the injected cache's count on the first render: \(out)")
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A `PlaylistMetaCache` rooted in a fresh, unique temporary file, so a test
/// that exercises `PlaylistsScene`'s seed or background-refresh write never
/// touches the real `~/.config/music/playlist-meta.json`. Shared with
/// `SnapToPlayingRowTests` and `SpaceInTextCaptureTests` (C0).
func temporaryPlaylistMetaCache() -> (cache: PlaylistMetaCache, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("music-test-playlist-meta-\(UUID().uuidString).json").path
    return (PlaylistMetaCache(path: path), path)
}

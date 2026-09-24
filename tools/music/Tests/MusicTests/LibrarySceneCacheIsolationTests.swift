import XCTest
@testable import music

/// C2's test-isolation prerequisite, as a STANDING regression test rather
/// than only the score's manual `stat` diff at verification time (which
/// proves one run, not every future one). Two properties: the injected
/// `ResultCache` is genuinely live (a Music.app album walk writes INTO it,
/// and the tier filter reads FROM it), and the real
/// `~/.config/music/artist-tiers.json` is never touched in either direction.
final class LibrarySceneCacheIsolationTests: XCTestCase {

    private let frame = shellLayout(width: 100, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func routing() -> RoutingCoordinator {
        RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"),
                           surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
    }

    private var realTiersPath: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/music/artist-tiers.json"
    }

    /// A Music.app-mode album walk (`makeProvider` defaults to nil — no
    /// Bridge involved) writes `artist-tiers.json` into the INJECTED
    /// temporary directory, proving the injection is live, while the real
    /// file's own modification date (or absence) is unchanged.
    func testAMusicAppAlbumWalkWritesIntoTheInjectedDirectoryAndNeverTheRealOne() {
        let realExistedBefore = FileManager.default.fileExists(atPath: realTiersPath)
        let beforeModified = (try? FileManager.default.attributesOfItem(atPath: realTiersPath))?[.modificationDate] as? Date

        let (cache, dir) = temporaryResultCache()
        let status = StatusStore()
        let albums = [LibraryAlbum(id: "al1", name: "In Rainbows", artist: "Radiohead", trackCount: 10),
                     LibraryAlbum(id: "al2", name: "Amnesiac", artist: "Radiohead", trackCount: 3)]
        let sources = LibraryDataSources(
            onAlbums: { page in _ = page(albums); return true },
            onSongs: { _ in true }, onArtists: { _ in true },
            onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] }, onAlbumCover: { _ in nil })
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                             sources: sources, appQueue: AppQueueStore(), status: status,
                             actions: ActionRunner(status: status), resultCache: cache)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "the Music.app album walk never finished")

        // The walk-done write is a detached, best-effort background write —
        // poll the filesystem rather than assuming it landed the instant the
        // walk itself finished.
        let tiersPath = dir.appendingPathComponent("artist-tiers.json").path
        XCTAssertTrue(settlePath(tiersPath), "the injected cache was never written — the injection is not live")

        if realExistedBefore {
            let afterModified = (try? FileManager.default.attributesOfItem(atPath: realTiersPath))?[.modificationDate] as? Date
            XCTAssertEqual(beforeModified, afterModified, "the real artist-tiers.json was rewritten")
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: realTiersPath),
                           "the real artist-tiers.json was created where none existed")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// `a` (the tier filter) seeds from a PRE-WRITTEN temporary cache, and the
    /// real one is never read: a name that exists only in the injected cache
    /// shows up under the tier it was seeded into.
    func testTheTierFilterSeedsFromTheInjectedCacheAndNeverTheRealOne() {
        let (cache, dir) = temporaryResultCache()
        cache.rememberArtistTiers(ep: ["injected artist"], albums: [])

        let status = StatusStore()
        let sources = LibraryDataSources(
            onAlbums: { _ in true }, onSongs: { _ in true },
            onArtists: { page in _ = page([LibraryArtist(id: "ar1", name: "Injected Artist")]); return true },
            onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] }, onAlbumCover: { _ in nil })
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing(),
                             sources: sources, appQueue: AppQueueStore(), status: status,
                             actions: ActionRunner(status: status), resultCache: cache)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Injected Artist") },
                      "the artist list never loaded")
        // All -> 12"/EP: this is the seed-from-cache transition (`a`'s guard
        // is `epArtists.isEmpty, albumArtists.isEmpty`, both true here since
        // no album walk has run yet).
        _ = s.handle(.char("a"))
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Injected Artist"),
                      "the tier filter did not seed from the injected cache: \(out)")
        try? FileManager.default.removeItem(at: dir)
    }

    private func settlePath(_ path: String, seconds: Double = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            usleep(10_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }
}

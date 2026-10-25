import XCTest
@testable import music

/// The Music.app (AppleScript) branch starts its decorative work, the tracks
/// preview and the cover, only for an album the cursor has RESTED on, the same
/// `LibraryScene.bridgePreviewRest` the SpanDAC branch waits for. Before this
/// every row a held key passed started a library scan the moment the tick saw
/// it. An explicit Enter is not decorative: it reads at once and goes first.
///
/// Time moves only through the scene's `now` seam; the readers are fakes that
/// record what was asked; nothing touches Music.app, osascript, the SpanDAC
/// socket or the keychain, and nothing waits on a sleep-then-assert.
final class LibraryAppleScriptPreviewRestTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 3_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private final class Reads {
        private let lock = NSLock()
        private var tracks: [String] = []
        private var covers: [String] = []
        func track(_ title: String) -> [String] {
            lock.lock(); tracks.append(title); lock.unlock()
            return ["Tracks of \(title)"]
        }
        func cover(_ id: String) -> LibraryCover? {
            lock.lock(); covers.append(id); lock.unlock()
            return nil
        }
        var snapshot: (tracks: [String], covers: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (tracks, covers)
        }
    }

    private func makeScene(_ reads: Reads, clock: Clock, albums n: Int = 8) -> LibraryScene {
        let albums = (0..<n).map { LibraryAlbum(id: "al\($0)", name: "Album \($0)", artist: "Art", trackCount: 1) }
        let sources = LibraryDataSources(
            onAlbums: { page in _ = page(albums); return true },
            onSongs: { _ in true }, onArtists: { _ in true },
            onAlbumTracks: { title, _ in reads.track(title) }, onArtistAlbums: { _ in [] },
            onAlbumCover: { reads.cover($0) })
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        let routing = RoutingCoordinator(store: store, surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
        let status = StatusStore()
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                             sources: sources, appQueue: AppQueueStore(), status: status,
                             actions: ActionRunner(status: status),
                             resultCache: temporaryResultCache().cache,
                             now: clock.now, screenWidth: { 160 })
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the albums never loaded")
        return s
    }

    private func nothingKicked(_ s: LibraryScene) -> Bool {
        s.previewInFlightForTest.isEmpty && s.coverInFlightForTest.isEmpty
    }

    func testRapidFocusMovesFasterThanTheRestStartNoRead() {
        let reads = Reads()
        let clock = Clock()
        let s = makeScene(reads, clock: clock)
        XCTAssertTrue(nothingKicked(s), "the first row was read before it had rested")
        // Seven rows at 0.1 s each: no row is ever under the cursor for the rest.
        for _ in 1...7 {
            _ = s.handle(.down)
            clock.advance(0.1)
            _ = s.tick(snapshot: idle)
            XCTAssertTrue(nothingKicked(s), "a row the cursor was passing through was read")
        }
        let r = reads.snapshot
        XCTAssertEqual(r.tracks, [], "a tracks read started without a rest")
        XCTAssertEqual(r.covers, [], "a cover read started without a rest")
    }

    func testRestingStartsExactlyOneTracksReadAndOneCover() {
        let reads = Reads()
        let clock = Clock()
        let s = makeScene(reads, clock: clock)
        for _ in 1...5 { _ = s.handle(.down); clock.advance(0.05); _ = s.tick(snapshot: idle) }
        clock.advance(0.2)                      // 0.2 s on Album 5: not yet
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(nothingKicked(s), "a read started before the cursor had rested the full interval")
        clock.advance(LibraryScene.bridgePreviewRest - 0.2)     // exactly the rest
        _ = s.tick(snapshot: idle)
        XCTAssertEqual(s.previewInFlightForTest, ["al5"], "resting did not start the preview")
        XCTAssertEqual(s.coverInFlightForTest, ["al5"], "resting did not start the cover")
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al5"] != nil && s.coverCacheForTest.keys.contains("al5") },
                      "the rested album was never read")
        for _ in 0..<30 { _ = s.tick(snapshot: idle) }          // the clock stands still
        let r = reads.snapshot
        XCTAssertEqual(r.tracks, ["Album 5"], "not exactly one tracks read")
        XCTAssertEqual(r.covers, ["al5"], "not exactly one cover read")
    }

    func testEnterDuringTheRestWindowReadsAtOnce() {
        let reads = Reads()
        let clock = Clock()
        let s = makeScene(reads, clock: clock)
        _ = s.handle(.down)
        _ = s.tick(snapshot: idle)              // rest on Album 1 begins
        clock.advance(0.05)                     // well inside the window
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(nothingKicked(s))
        _ = s.handle(.enter)                    // open Album 1
        XCTAssertEqual(s.previewInFlightForTest, ["al1"], "Enter waited for the rest")
        _ = s.tick(snapshot: idle)
        XCTAssertEqual(s.coverInFlightForTest.union(s.coverCacheForTest.keys), ["al1"],
                       "the opened album's cover waited for the rest")
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] != nil && s.coverCacheForTest.keys.contains("al1") },
                      "the opened album was never read")
        XCTAssertEqual(reads.snapshot.tracks, ["Album 1"])
        XCTAssertEqual(reads.snapshot.covers, ["al1"])
    }
}

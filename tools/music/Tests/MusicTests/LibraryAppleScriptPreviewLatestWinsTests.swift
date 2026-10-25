import XCTest
@testable import music

/// The Music.app (AppleScript) branch of the Albums tracks preview and cover
/// ladder shares one serial queue so at most one library scan runs at a time.
/// Scrolling used to queue a tracks read and a cover read for EVERY album the
/// cursor passed, so the album finally opened waited behind a read per
/// abandoned row. Same principles as the SpanDAC branch: one active job, the
/// newest wanted focus wins, an explicit drill-in goes ahead of unsent
/// decorative jobs, and concurrency never rises above one.
///
/// Every reader is a fake held by an explicit gate; nothing here touches
/// Music.app, osascript, the SpanDAC socket or the keychain, and nothing waits
/// on a sleep-then-assert.
final class LibraryAppleScriptPreviewLatestWinsTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    /// Records each read in the order it STARTED, holds the first album's
    /// tracks read on a gate, and tracks the peak number running together.
    private final class Rig {
        private let lock = NSLock()
        private(set) var trackReads: [String] = []
        private(set) var coverReads: [String] = []
        private var running = 0
        private(set) var peak = 0
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        var held: String? = "Album 0"

        func tracks(_ title: String, _ artist: String) -> [String] {
            enter { trackReads.append(title) }
            if title == held { started.signal(); gate.wait() }
            leave()
            return ["Tracks of \(title)"]
        }
        func cover(_ id: String) -> LibraryCover? {
            enter { coverReads.append(id) }
            leave()
            return nil
        }
        private func enter(_ record: () -> Void) {
            lock.lock(); record(); running += 1; peak = max(peak, running); lock.unlock()
        }
        private func leave() { lock.lock(); running -= 1; lock.unlock() }
        func snapshot() -> (tracks: [String], covers: [String], peak: Int) {
            lock.lock(); defer { lock.unlock() }
            return (trackReads, coverReads, peak)
        }
    }

    private func makeScene(_ rig: Rig, albums n: Int) -> LibraryScene {
        let albums = (0..<n).map { LibraryAlbum(id: "al\($0)", name: "Album \($0)", artist: "Art", trackCount: 1) }
        let sources = LibraryDataSources(
            onAlbums: { page in _ = page(albums); return true },
            onSongs: { _ in true }, onArtists: { _ in true },
            onAlbumTracks: { rig.tracks($0, $1) }, onArtistAlbums: { _ in [] },
            onAlbumCover: { rig.cover($0) })
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        let routing = RoutingCoordinator(store: store, surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent") })
        let status = StatusStore()
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                             sources: sources, appQueue: AppQueueStore(), status: status,
                             actions: ActionRunner(status: status),
                             resultCache: temporaryResultCache().cache,
                             screenWidth: { 160 })
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the albums never loaded")
        return s
    }

    func testFastScrollThenOpenReadsOnlyTheHeldAlbumAndTheOpenedOneAndFetchesOnlyTheOpenedCover() {
        let rig = Rig()
        let s = makeScene(rig, albums: 10)
        // Album 0's tracks read goes out and is held.
        var spins = 0
        while rig.started.wait(timeout: .now() + .milliseconds(5)) == .timedOut, spins < 4000 {
            _ = s.tick(snapshot: idle); spins += 1
        }
        XCTAssertEqual(rig.snapshot().tracks, ["Album 0"], "album 0 was never read")
        // Scroll through albums 1...9, one tick per row, the way a held key does.
        for _ in 1...9 { _ = s.handle(.down); _ = s.tick(snapshot: idle) }
        _ = s.handle(.enter)                                    // open album 9
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        rig.gate.signal()                                       // album 0's read finishes
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al9"] != nil }, "the opened album was never read")
        XCTAssertTrue(settleScene(s) { rig.snapshot().covers.contains("al9") }, "the opened album's cover was never fetched")
        for _ in 0..<40 { _ = s.tick(snapshot: idle); usleep(2_000) }
        let done = rig.snapshot()
        XCTAssertEqual(done.tracks, ["Album 0", "Album 9"], "a read went out for an album the cursor had left")
        XCTAssertEqual(done.covers, ["al9"], "a cover was fetched for an album the cursor had left")
        XCTAssertEqual(done.peak, 1, "more than one library scan ran at once")
        XCTAssertEqual(s.trackCacheForTest["al9"], ["Tracks of Album 9"])
    }

    func testTheHeldAlbumsLateResultNeverLandsOnTheFocusedAlbumsPreview() {
        let rig = Rig()
        let s = makeScene(rig, albums: 4)
        var spins = 0
        while rig.started.wait(timeout: .now() + .milliseconds(5)) == .timedOut, spins < 4000 {
            _ = s.tick(snapshot: idle); spins += 1
        }
        for _ in 1...3 { _ = s.handle(.down); _ = s.tick(snapshot: idle) }   // focus album 3
        rig.gate.signal()
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al3"] != nil }, "the focused album was never read")
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] != nil })
        XCTAssertEqual(s.trackCacheForTest["al3"], ["Tracks of Album 3"], "another album's tracks landed on the focused row")
        XCTAssertEqual(s.trackCacheForTest["al0"], ["Tracks of Album 0"])
        XCTAssertNil(s.trackCacheForTest["al1"], "an abandoned album was read")
        XCTAssertNil(s.trackCacheForTest["al2"], "an abandoned album was read")
    }
}

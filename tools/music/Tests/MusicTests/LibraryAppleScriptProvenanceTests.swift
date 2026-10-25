import XCTest
@testable import music

/// A Music.app (AppleScript) preview or cover read that is still RUNNING when
/// the data source flips to SpanDAC and back must not leak into the library
/// that replaced it. `LibraryScene.appleGeneration` is bumped by the provenance
/// reset and carried by every job and result; the tick drops a result of an
/// older generation. These tests hold one read on a gate across a flip and
/// back, ask for the SAME album id again under the new generation (its own read
/// held too), then release the old read and prove it neither fills the new
/// generation's cache nor clears the new request's in-flight mark (which would
/// let the next tick start a duplicate read).
///
/// Time moves only through the scene's `now` seam; every reader is a fake held
/// by an explicit gate; nothing touches Music.app, osascript, the SpanDAC
/// socket or the keychain, and nothing waits on a sleep-then-assert.
final class LibraryAppleScriptProvenanceTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 4_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    /// Numbers each tracks read and each cover read in the order they START;
    /// a read whose number has a gate waits on it (bounded, so a failed test
    /// cannot hang), after announcing it started.
    private final class Rig {
        private let lock = NSLock()
        private var trackN = 0, coverN = 0
        private var trackGates: [Int: DispatchSemaphore] = [:]
        private var coverGates: [Int: DispatchSemaphore] = [:]
        private(set) var trackReads: [String] = []
        private(set) var coverReads: [String] = []
        let started = DispatchSemaphore(value: 0)

        func holdTracks(_ n: Int) { lock.lock(); trackGates[n] = DispatchSemaphore(value: 0); lock.unlock() }
        func holdCovers(_ n: Int) { lock.lock(); coverGates[n] = DispatchSemaphore(value: 0); lock.unlock() }
        func releaseTracks(_ n: Int) { lock.lock(); let g = trackGates[n]; lock.unlock(); g?.signal() }
        func releaseCovers(_ n: Int) { lock.lock(); let g = coverGates[n]; lock.unlock(); g?.signal() }

        func tracks(_ title: String) -> [String] {
            lock.lock(); let n = trackN; trackN += 1; trackReads.append(title); let g = trackGates[n]; lock.unlock()
            if let g { started.signal(); _ = g.wait(timeout: .now() + 10) }
            return ["\(title) read \(n)"]
        }
        func cover(_ id: String) -> LibraryCover? {
            lock.lock(); let n = coverN; coverN += 1; coverReads.append(id); let g = coverGates[n]; lock.unlock()
            if let g { started.signal(); _ = g.wait(timeout: .now() + 10) }
            return LibraryCover(key: "key \(n)", url: "url \(n)")
        }
        var counts: (tracks: Int, covers: Int) {
            lock.lock(); defer { lock.unlock() }
            return (trackReads.count, coverReads.count)
        }
    }

    private struct Rigged {
        let scene: LibraryScene
        let flag: BridgeSelectedFlag
        let clock: Clock
    }

    private func albumsPage(_ n: Int) -> String {
        let items = (0..<n).map {
            "{\"id\":\"al\($0)\",\"title\":\"Album \($0)\",\"artist\":\"Art\",\"track_count\":1,\"kind\":\"album\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":\(n),"items":[\(items)],"next_cursor":null}
        """
    }

    private func makeScene(_ rig: Rig) -> Rigged {
        let albums = (0..<2).map { LibraryAlbum(id: "al\($0)", name: "Album \($0)", artist: "Art", trackCount: 1) }
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumsPage(2), albumsPage(2)]])
        let flag = BridgeSelectedFlag(false)
        let clock = Clock()
        let sources = LibraryDataSources(
            onAlbums: { page in _ = page(albums); return true },
            onSongs: { _ in true }, onArtists: { _ in true },
            onAlbumTracks: { title, _ in rig.tracks(title) }, onArtistAlbums: { _ in [] },
            onAlbumCover: { rig.cover($0) })
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let status = StatusStore()
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                             sources: sources, appQueue: AppQueueStore(), status: status,
                             actions: ActionRunner(status: status),
                             makeProvider: {
                                 flag.selected
                                     ? BridgeMusicProvider(control: SourceAppControl(
                                         path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                                     : nil
                             },
                             warmUpSleep: { _ in },
                             resultCache: temporaryResultCache().cache,
                             now: clock.now, screenWidth: { 160 })
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the albums never loaded")
        return Rigged(scene: s, flag: flag, clock: clock)
    }

    /// Ticks until a held read announces it started (bounded).
    private func waitStarted(_ rig: Rig, _ s: LibraryScene, _ what: String) {
        var spins = 0
        while rig.started.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
            _ = s.tick(snapshot: idle); spins += 1
            if spins > 4000 { XCTFail("\(what) never started"); return }
        }
    }

    /// Music.app -> SpanDAC -> Music.app, the Albums list reloaded each time.
    private func flipAndBack(_ r: Rigged) {
        r.flag.selected = true
        XCTAssertTrue(settleScene(r.scene) { r.scene.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the SpanDAC albums never loaded")
        r.flag.selected = false
        XCTAssertTrue(settleScene(r.scene) { r.scene.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the Music.app albums never reloaded")
    }

    func testARunningTracksReadFromBeforeAFlipNeverLandsInTheNewGenerationOrRetiresItsRead() {
        let rig = Rig()
        rig.holdTracks(0); rig.holdTracks(1)
        let r = makeScene(rig)
        let s = r.scene
        r.clock.advance(LibraryScene.bridgePreviewRest)
        waitStarted(rig, s, "the first tracks read")                    // read 0: Album 0, held, generation 0
        XCTAssertEqual(rig.trackReads, ["Album 0"])
        flipAndBack(r)
        // The SAME album id is asked for again under the new generation; its
        // read queues behind the held one on the serial queue.
        r.clock.advance(LibraryScene.bridgePreviewRest)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(s.previewInFlightForTest.contains("al0"), "the new generation never asked for the album")
        rig.releaseTracks(0)                                            // the old read finishes and posts
        waitStarted(rig, s, "the new generation's tracks read")         // read 1 starts after read 0 posted
        _ = s.tick(snapshot: idle)                                      // drains the old result
        XCTAssertNil(s.trackCacheForTest["al0"], "the old library's tracks filled the new generation's cache")
        XCTAssertTrue(s.previewInFlightForTest.contains("al0"), "the old result retired the new generation's in-flight mark")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(rig.counts.tracks, 2, "a duplicate read started for the album already being read")
        rig.releaseTracks(1)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] != nil }, "the new generation's read never landed")
        XCTAssertEqual(s.trackCacheForTest["al0"], ["Album 0 read 1"])
        XCTAssertFalse(s.previewInFlightForTest.contains("al0"))
        XCTAssertEqual(rig.counts.tracks, 2)
    }

    func testARunningCoverReadFromBeforeAFlipNeverLandsInTheNewGenerationOrRetiresItsRead() {
        let rig = Rig()
        rig.holdCovers(0); rig.holdCovers(1)
        let r = makeScene(rig)
        let s = r.scene
        r.clock.advance(LibraryScene.bridgePreviewRest)
        waitStarted(rig, s, "the first cover read")                     // cover read 0: al0, held, generation 0
        XCTAssertEqual(rig.coverReads, ["al0"])
        flipAndBack(r)
        r.clock.advance(LibraryScene.bridgePreviewRest)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(s.coverInFlightForTest.contains("al0"), "the new generation never asked for the cover")
        rig.releaseCovers(0)
        waitStarted(rig, s, "the new generation's cover read")          // cover read 1 starts after read 0 posted
        _ = s.tick(snapshot: idle)
        XCTAssertFalse(s.coverCacheForTest.keys.contains("al0"), "the old library's cover filled the new generation's cache")
        XCTAssertTrue(s.coverInFlightForTest.contains("al0"), "the old result retired the new generation's in-flight mark")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(rig.counts.covers, 2, "a duplicate cover read started for the album already being read")
        rig.releaseCovers(1)
        XCTAssertTrue(settleScene(s) { s.coverCacheForTest.keys.contains("al0") }, "the new generation's cover never landed")
        XCTAssertEqual(s.coverCacheForTest["al0"] ?? nil, LibraryCover(key: "key 1", url: "url 1"))
        XCTAssertFalse(s.coverInFlightForTest.contains("al0"))
        XCTAssertEqual(rig.counts.covers, 2)
    }
}

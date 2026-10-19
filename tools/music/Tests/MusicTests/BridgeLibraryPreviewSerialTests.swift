import XCTest
@testable import music

/// SpanDAC serves MusicKit album-membership reads one at a time (four at once
/// took 5.8 s each against 1.5 s for one), and the Albums tracks preview used to
/// start a detached read per album the cursor focused, so scrolling past N
/// albums queued N reads and an Enter to open one waited behind all of them.
///
/// The fix: the preview reads only an album the cursor has RESTED on
/// (`LibraryScene.bridgePreviewRest`), through one serial queue, and a queued
/// read for an album that is no longer the wanted one is dropped unsent; an
/// Enter reuses the read in flight for its album, or takes a queued one over
/// and sends it at once. Time is moved by hand through the scene's `now` seam
/// and the width is pinned to three-zone; replies are held by the wire's gates,
/// so nothing here waits on a wall-clock interval.
final class BridgeLibraryPreviewSerialTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)
    private let op = "slice.libraryAlbumTracks"

    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 2_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private func albumsPage(_ n: Int) -> String {
        let items = (0..<n).map {
            "{\"id\":\"al\($0)\",\"title\":\"Album \($0)\",\"artist\":\"Art\",\"track_count\":1,\"kind\":\"album\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":\(n),"items":[\(items)],"next_cursor":null}
        """
    }

    private func tracksPage(_ tag: String) -> String {
        """
        {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,
         "items":[{"id":"t.\(tag)","title":"Track \(tag)","artist":"Art","kind":"song"}]}
        """
    }

    private func readIDs(_ wire: BridgeLibraryReadsWire) -> [String] {
        wire.sent(op).compactMap { $0["id"] as? String }
    }

    private func scene(_ wire: BridgeLibraryReadsWire, clock: Clock) -> LibraryScene {
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 now: clock.now, screenWidth: { 160 })
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("Album 0") },
                      "the albums never loaded")
        return s
    }

    /// Down one row, then rest long enough for the preview to want it.
    private func downAndRest(_ s: LibraryScene, _ clock: Clock) {
        _ = s.handle(.down)
        _ = s.tick(snapshot: idle)
        clock.advance(0.5)
        _ = s.tick(snapshot: idle)
    }

    private func wire(albums n: Int, reads: Int) -> BridgeLibraryReadsWire {
        let w = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumsPage(n)]])
        w.script(op, (0..<reads).map { tracksPage("\($0)") })
        return w
    }

    func testScrollingPastAlbumsNeverHasMoreThanOnePreviewReadInFlightAndOnlyTheRestingRowIsRead() {
        let w = wire(albums: 8, reads: 8)
        w.gate(op: op, at: 0)
        let clock = Clock()
        let s = scene(w, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { w.reached(op: self.op, at: 0) }, "the focused album was never previewed")
        // Rest on al1, al2, al3 while al0's read is still out.
        for _ in 0..<3 { downAndRest(s, clock) }
        for _ in 0..<10 { _ = s.tick(snapshot: idle); usleep(5_000) }
        XCTAssertEqual(readIDs(w), ["al0"], "a second read was sent while one was in flight")
        w.release(op: op, at: 0)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al3"] != nil }, "the row the cursor rests on was never read")
        XCTAssertEqual(readIDs(w), ["al0", "al3"], "a read went out for a row the cursor had left")
        XCTAssertEqual(w.peakConcurrent(op), 1)
        XCTAssertEqual(s.trackCacheForTest["al3"], ["Track 1"], "the tracks of the wrong album landed on the row")
    }

    func testScrollingWithoutRestingSendsNoReads() {
        let w = wire(albums: 8, reads: 8)
        let clock = Clock()
        let s = scene(w, clock: clock)
        for _ in 0..<7 {
            _ = s.handle(.down)
            clock.advance(0.03)
            for _ in 0..<3 { _ = s.tick(snapshot: idle); usleep(3_000) }
        }
        XCTAssertEqual(readIDs(w), [], "a read went out for a row the cursor was only passing")
    }

    func testEnterOnTheAlbumBeingPreviewedReusesThatReadInsteadOfSendingAnother() {
        let w = wire(albums: 3, reads: 3)
        w.gate(op: op, at: 0)
        let clock = Clock()
        let s = scene(w, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { w.reached(op: self.op, at: 0) })
        _ = s.handle(.enter)
        for _ in 0..<10 { _ = s.tick(snapshot: idle); usleep(5_000) }
        w.release(op: op, at: 0)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] == ["Track 0"] })
        XCTAssertEqual(readIDs(w), ["al0"], "Enter sent a second read for an album already being read")
    }

    func testEnterOnAnAlbumQueuedBehindAReadSendsItAtOnceAndTheQueuedReadIsNotRepeated() {
        let w = wire(albums: 4, reads: 4)
        w.gate(op: op, at: 0)
        let clock = Clock()
        let s = scene(w, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { w.reached(op: self.op, at: 0) })   // al0 out and held
        downAndRest(s, clock)                                              // al1 queued behind it
        for _ in 0..<5 { _ = s.tick(snapshot: idle); usleep(5_000) }
        XCTAssertEqual(readIDs(w), ["al0"])
        _ = s.handle(.enter)                                               // open al1
        XCTAssertTrue(settleScene(s) { w.reached(op: self.op, at: 1) }, "Enter waited behind the stale read")
        XCTAssertEqual(readIDs(w), ["al0", "al1"])
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Track 1"] }, "the opened album never loaded")
        // Free the held read, back out, and rest on al2: the queue runs al1's
        // taken-over job first (which must send nothing), then al2's.
        w.release(op: op, at: 0)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] != nil })
        _ = s.handle(.escape)
        downAndRest(s, clock)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al2"] != nil }, "al2 was never read")
        XCTAssertEqual(readIDs(w), ["al0", "al1", "al2"], "the queued read for the opened album was sent a second time")
        XCTAssertEqual(w.peakConcurrent(op), 2, "only the stale read in flight and the Enter read may overlap")
    }

    func testEnterBeforeTheCursorHasRestedStillReadsAtOnce() {
        let w = wire(albums: 3, reads: 3)
        let clock = Clock()
        let s = scene(w, clock: clock)
        _ = s.handle(.enter)   // no rest has elapsed
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] == ["Track 0"] })
        XCTAssertEqual(readIDs(w), ["al0"])
    }

    func testAReadForAnAlbumTheCursorLeftIsDroppedAndTheAlbumCanBePreviewedAgainWhenTheCursorReturns() {
        let w = wire(albums: 3, reads: 4)
        w.gate(op: op, at: 0)
        let clock = Clock()
        let s = scene(w, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { w.reached(op: self.op, at: 0) })   // al0 held
        downAndRest(s, clock)                                              // al1 queued
        downAndRest(s, clock)                                              // al2 queued; al1 no longer wanted
        _ = s.handle(.up); _ = s.handle(.up)                               // back to al0
        _ = s.tick(snapshot: idle)
        w.release(op: op, at: 0)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al0"] != nil })
        for _ in 0..<10 { _ = s.tick(snapshot: idle); usleep(5_000) }
        XCTAssertEqual(readIDs(w), ["al0"], "a read went out for a row the cursor had left")
        // Rest on al1 again: its dropped read is allowed back.
        downAndRest(s, clock)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] != nil }, "a dropped album could never be previewed again")
        XCTAssertEqual(readIDs(w), ["al0", "al1"])
    }
}

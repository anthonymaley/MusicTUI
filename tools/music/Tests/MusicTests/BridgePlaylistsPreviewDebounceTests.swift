import XCTest
@testable import music

/// The Bridge preview kick used to enqueue one `slice.libraryPlaylistTracks`
/// read per playlist the cursor passed, on a serial queue, and never cancelled
/// one for a row already scrolled past. SpanDAC serves library reads one at a
/// time (a big playlist is seconds), so scrolling to a playlist built a backlog
/// that a play of that playlist then waited behind.
///
/// The fix: a preview is only enqueued once the cursor has rested on a row for
/// `PlaylistsScene.bridgePreviewRest`, and a queued read whose row is no longer
/// the rail row is dropped when it reaches the front. Time is moved by hand
/// through the scene's `now` seam; nothing here reaches AppleScript (the
/// backend is `/usr/bin/true`, and Music.app-side sources are the spy's).
final class BridgePlaylistsPreviewDebounceTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let threeZoneFrame = shellLayout(width: 160, height: 30)

    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private func playlistsPage(_ n: Int) -> String {
        let items = (0..<n).map { "{\"id\":\"pl\($0)\",\"title\":\"Playlist \($0)\",\"kind\":\"playlist\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":\(n),
         "items":[\(items)],"next_cursor":null}
        """
    }

    private func tracksPage() -> String {
        """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":1,
         "items":[{"id":"i.a","title":"A","artist":"Art","kind":"song"}],
         "next_cursor":null,"skipped_videos":0}
        """
    }

    private func readIDs(_ wire: BridgeLibraryReadsWire) -> [String] {
        wire.sent("slice.libraryPlaylistTracks").compactMap { $0["id"] as? String }
    }

    private func scene(rows: Int, wire: BridgeLibraryReadsWire, clock: Clock) -> PlaylistsScene {
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   width: 160, now: clock.now)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: self.idle).contains("Playlist 0") },
                      "the rail never settled")
        return s
    }

    /// A tick at the current fake time, then a short real pause so a read the
    /// tick kicked has time to reach the wire before the caller looks.
    private func tickAndLetReadsRun(_ s: PlaylistsScene, times: Int = 6) {
        for _ in 0..<times { _ = s.tick(snapshot: idle); usleep(10_000) }
    }

    func testScrollingPastManyPlaylistsReadsOnlyWhereTheCursorRests() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(12)]])
        wire.script("slice.libraryPlaylistTracks", (0..<12).map { _ in tracksPage() })
        let clock = Clock()
        let s = scene(rows: 12, wire: wire, clock: clock)
        tickAndLetReadsRun(s)
        // Eleven downs, a tick after each, 30 ms apart: never rests anywhere.
        for _ in 0..<11 {
            _ = s.handle(.down)
            clock.advance(0.03)
            tickAndLetReadsRun(s, times: 2)
        }
        XCTAssertEqual(readIDs(wire), [], "a read went out for a row the cursor was only passing")
        // Rest on pl11.
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { !self.readIDs(wire).isEmpty }, "resting on a row never previewed it")
        tickAndLetReadsRun(s, times: 20)
        XCTAssertEqual(readIDs(wire), ["pl11"])
    }

    func testRestingOnARowStillPreviewsItAndNotBeforeTheRest() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(3)]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage()])
        let clock = Clock()
        let s = scene(rows: 3, wire: wire, clock: clock)
        tickAndLetReadsRun(s)
        XCTAssertEqual(readIDs(wire), [], "the preview was sent before the cursor had rested")
        clock.advance(0.1)
        tickAndLetReadsRun(s)
        XCTAssertEqual(readIDs(wire), [], "the preview was sent after only 100 ms")
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { !self.readIDs(wire).isEmpty }, "resting never previewed")
        tickAndLetReadsRun(s, times: 10)
        XCTAssertEqual(readIDs(wire), ["pl0"])
        XCTAssertTrue(settleScene(s) { s.render(frame: self.threeZoneFrame, snapshot: self.idle).contains("A") })
    }

    func testAQueuedReadForARowTheCursorHasLeftIsDroppedWithoutBeingSent() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(6)]])
        wire.script("slice.libraryPlaylistTracks", (0..<6).map { _ in tracksPage() })
        wire.gate(op: "slice.libraryPlaylistTracks", at: 0)   // pl0's read blocks the serial queue
        let clock = Clock()
        let s = scene(rows: 6, wire: wire, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 0) },
                      "pl0's read never started")
        // Rest on pl1, pl2, pl3 in turn: each is queued behind the blocked read.
        for _ in 0..<3 {
            _ = s.handle(.down)
            clock.advance(0.5)
            tickAndLetReadsRun(s, times: 3)
            clock.advance(0.5)
            tickAndLetReadsRun(s, times: 3)
        }
        // Rest on pl4, which the cursor stays on while the queue drains.
        _ = s.handle(.down)
        clock.advance(0.5)
        tickAndLetReadsRun(s, times: 3)
        clock.advance(0.5)
        tickAndLetReadsRun(s, times: 3)
        wire.release(op: "slice.libraryPlaylistTracks", at: 0)
        XCTAssertTrue(settleScene(s) { self.readIDs(wire).contains("pl4") }, "the resting row was never read")
        tickAndLetReadsRun(s, times: 20)
        XCTAssertEqual(readIDs(wire), ["pl0", "pl4"],
                       "reads for rows scrolled past reached SpanDAC after the cursor had left them")
    }

    func testADroppedReadIsReadAfterAllWhenTheCursorComesBack() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(3)]])
        wire.script("slice.libraryPlaylistTracks", (0..<4).map { _ in tracksPage() })
        wire.gate(op: "slice.libraryPlaylistTracks", at: 0)
        let clock = Clock()
        let s = scene(rows: 3, wire: wire, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 0) })
        _ = s.handle(.down)                                   // pl1 queued behind the blocked pl0
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)
        _ = s.handle(.up)                                     // back on pl0, whose read is in flight
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)
        wire.release(op: "slice.libraryPlaylistTracks", at: 0)
        tickAndLetReadsRun(s, times: 20)
        XCTAssertEqual(readIDs(wire), ["pl0"], "pl1's read was sent though the cursor had left it")
        _ = s.handle(.down)                                   // pl1 again: its in-flight mark was cleared
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { self.readIDs(wire).contains("pl1") },
                      "a dropped read left pl1 marked in flight, so it was never previewed")
    }

    func testAPlayNeverWaitsForABlockedPreviewRead() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(2)],
                                           "slice.queue": ["{\"ok\":true,\"op\":\"slice.queue\"}"],
                                           "slice.status": ["{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\"}}"]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage(), tracksPage()])
        wire.gate(op: "slice.libraryPlaylistTracks", at: 0)   // the preview read never returns until released
        let clock = Clock()
        let s = scene(rows: 2, wire: wire, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 0) })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty },
                      "the play waited behind the blocked preview read")
        wire.release(op: "slice.libraryPlaylistTracks", at: 0)
    }

    // MARK: - A queued preview is dropped when the preview context ends on the SAME row

    /// Preview reads only: the drill-in and a play walk with a larger limit.
    private func previewReadIDs(_ wire: BridgeLibraryReadsWire) -> [String] {
        wire.sent("slice.libraryPlaylistTracks")
            .filter { ($0["limit"] as? Int) == PlaylistsScene.bridgePreviewLimit }
            .compactMap { $0["id"] as? String }
    }

    /// pl0's preview blocks the serial queue; the cursor rests on pl1, so its
    /// preview is queued behind. Then `leave` ends the preview context while the
    /// cursor stays on pl1. Releasing the gate must not send pl1's preview.
    /// The scene is NOT ticked after the release: a tick would legitimately
    /// re-preview pl1 as a fresh read, which is not what is being asked.
    private func assertQueuedPreviewDropped(after leave: (PlaylistsScene) -> Void, _ what: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(4)],
                                           "slice.queue": ["{\"ok\":true,\"op\":\"slice.queue\"}"],
                                           "slice.status": ["{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\"}}"]])
        wire.script("slice.libraryPlaylistTracks", (0..<8).map { _ in tracksPage() })
        wire.gate(op: "slice.libraryPlaylistTracks", at: 0)
        let clock = Clock()
        let s = scene(rows: 4, wire: wire, clock: clock)
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 0) },
                      "pl0's read never started", file: file, line: line)
        _ = s.handle(.down)
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)   // pl1's preview is now queued
        leave(s)
        wire.release(op: "slice.libraryPlaylistTracks", at: 0)
        usleep(400_000)
        XCTAssertEqual(previewReadIDs(wire), ["pl0"], what, file: file, line: line)
    }

    func testAQueuedPreviewIsDroppedAfterDrillingIntoTheSameRow() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.right) },
                                   "a queued preview was sent after the cursor drilled into its row")
    }

    func testAQueuedPreviewIsDroppedAfterEnterDrillsIntoTheSameRow() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.enter) },
                                   "a queued preview was sent after Enter drilled into its row")
    }

    func testAQueuedPreviewIsDroppedAfterPPlaysThatRow() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.char("p")) },
                                   "a queued preview was sent after p played its row")
    }

    func testAQueuedPreviewIsDroppedAfterSPlaysThatRow() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.char("s")) },
                                   "a queued preview was sent after s played its row")
    }

    func testAQueuedPreviewIsDroppedAfterLeavingTheScene() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.escape) },
                                   "a queued preview was sent after the scene was left")
        assertQueuedPreviewDropped(after: { _ = $0.handle(.left) },
                                   "a queued preview was sent after ← left the scene")
    }

    // The cursor moves with NO tick before the queue advances: the token must be
    // revoked by the move itself, not at the next tick.

    func testAQueuedPreviewIsDroppedWhenDownMovesTheCursorBeforeAnyTick() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.down) },
                                   "pl1's queued read was sent after Down moved the cursor to pl2, with no tick between")
    }

    func testAQueuedPreviewIsDroppedWhenUpMovesTheCursorBeforeAnyTick() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.up) },
                                   "a queued read was sent after Up moved the cursor off its row")
    }

    func testAQueuedPreviewIsDroppedWhenHomeMovesTheCursorBeforeAnyTick() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.home) },
                                   "a queued read was sent after Home moved the cursor off its row")
    }

    func testAQueuedPreviewIsDroppedWhenEndMovesTheCursorBeforeAnyTick() {
        assertQueuedPreviewDropped(after: { _ = $0.handle(.end) },
                                   "a queued read was sent after End moved the cursor off its row")
    }

    func testAQueuedPreviewIsDroppedWhenAFilterReclampsTheCursorBeforeAnyTick() {
        assertQueuedPreviewDropped(after: { s in
            _ = s.handle(.char("/"))
            _ = s.handle(.char("3"))   // only "Playlist 3" is left, so the cursor clamps to it
        }, "a queued read was sent after a filter moved the cursor off its row")
    }

    func testAQueuedPreviewIsDroppedWhenTheLayoutStopsBeingThreeZone() {
        let width = ThreadSafeInt(160)
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(4)]])
        wire.script("slice.libraryPlaylistTracks", (0..<8).map { _ in tracksPage() })
        wire.gate(op: "slice.libraryPlaylistTracks", at: 0)
        let clock = Clock()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   width: 160, now: clock.now, widthProvider: { width.value })
        XCTAssertTrue(settleScene(s) { s.render(frame: self.threeZoneFrame, snapshot: self.idle).contains("Playlist 0") })
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 0) })
        _ = s.handle(.down)
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)
        clock.advance(0.5); tickAndLetReadsRun(s, times: 3)   // pl1 queued
        width.value = 120                                      // two-zone: the pane is gone
        tickAndLetReadsRun(s, times: 3)
        wire.release(op: "slice.libraryPlaylistTracks", at: 0)
        usleep(400_000)
        XCTAssertEqual(previewReadIDs(wire), ["pl0"], "a queued preview was sent after the layout dropped the pane")
    }

    func testRestingOnTheRailAfterAPlayStillPreviewsAFreshRead() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(2)],
                                           "slice.queue": ["{\"ok\":true,\"op\":\"slice.queue\"}"],
                                           "slice.status": ["{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\"}}"]])
        wire.script("slice.libraryPlaylistTracks", (0..<8).map { _ in tracksPage() })
        let clock = Clock()
        let s = scene(rows: 2, wire: wire, clock: clock)
        _ = s.handle(.char("p"))
        clock.advance(0.5)
        XCTAssertTrue(settleScene(s) { self.previewReadIDs(wire).contains("pl0") },
                      "invalidating on a play left the rail unable to preview ever again")
    }
}

final class ThreadSafeInt {
    private let lock = NSLock()
    private var v: Int
    init(_ v: Int) { self.v = v }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

import XCTest
@testable import music

/// The playlist TRACKS drill-in re-asks a stale snapshot like the rail does,
/// and a fresh replacement must never leave the cursor out of range or bound
/// to a different song.
final class BridgePlaylistsTracksReaskTests: XCTestCase {

    private let frame = shellLayout(width: 138, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let queueOK = "{\"ok\":true,\"op\":\"slice.queue\"}"
    private let statusOK = "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\"}}"

    private func rail(_ ids: [String]) -> String {
        let rows = ids.map { "{\"id\":\"\($0)\",\"title\":\"List \($0)\",\"kind\":\"playlist\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":\(ids.count),
         "items":[\(rows)],"next_cursor":null}
        """
    }
    private func tracks(_ ids: [String], stale: Bool, rev: String, skipped: Int = 0) -> String {
        let rows = ids.map { "{\"id\":\"\($0)\",\"title\":\"Song \($0)\",\"artist\":\"Art\",\"kind\":\"song\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":\(ids.count),"stale":\(stale),"refreshing":\(stale),
         "list_rev":"\(rev)","items":[\(rows)],"next_cursor":null,"skipped_videos":\(skipped)}
        """
    }
    private func ids(_ prefix: String, _ n: Int) -> [String] { (1...n).map { "\(prefix)\($0)" } }

    /// Rail [pl1, pl2]; the tracks reads are `replies` in arrival order, the
    /// second (the re-ask probe of the first drill-in) held until released.
    private func scene(_ replies: [String]) -> (PlaylistsScene, BridgeLibraryReadsWire) {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [rail(["pl1", "pl2"])],
                                           "slice.libraryPlaylistTracks": replies,
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.gate(op: "slice.libraryPlaylistTracks", at: 1)
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 138,
                                   now: { Date(timeIntervalSince1970: 0) })   // a frozen clock: the rest-gated preview read never fires
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("List pl1") })
        return (s, wire)
    }
    private func drill(_ s: PlaylistsScene, _ wire: BridgeLibraryReadsWire, expecting n: Int) {
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.count == n }, "stale tracks never shown")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylistTracks", at: 1) }, "no re-ask probe went out")
    }

    /// Codex's finding: the list shrank under a cursor near its end.
    func testAShorterFreshListClampsTheCursorAndRenderDoesNotTrap() {
        let (s, wire) = scene([tracks(ids("a", 60), stale: true, rev: "r1"),
                               tracks(ids("b", 3), stale: false, rev: "r2"),
                               tracks(ids("b", 3), stale: false, rev: "r2")])
        drill(s, wire, expecting: 60)
        for _ in 0..<59 { _ = s.handle(.down) }
        XCTAssertEqual(s.trackCursorForTest, 59)
        _ = s.render(frame: frame, snapshot: idle)
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.count == 3 }, "the fresh list never replaced the stale one")
        XCTAssertEqual(s.trackCursorForTest, 2)
        XCTAssertLessThanOrEqual(s.trackScrollForTest, s.trackCursorForTest)
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Song b3"))
        XCTAssertEqual(s.drilledListRevForTest, "r2")
        XCTAssertEqual(s.drilledTotalForTest, 3)
    }

    func testAnEmptyFreshListClampsToZeroAndRenders() {
        let (s, wire) = scene([tracks(ids("a", 5), stale: true, rev: "r1"),
                               tracks([], stale: false, rev: "r2"), tracks([], stale: false, rev: "r2")])
        drill(s, wire, expecting: 5)
        for _ in 0..<4 { _ = s.handle(.down) }
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.isEmpty })
        XCTAssertEqual(s.trackCursorForTest, 0)
        XCTAssertEqual(s.trackScrollForTest, 0)
        _ = s.render(frame: frame, snapshot: idle)
    }

    /// A row inserted above the cursor: the same song stays selected.
    func testTheSelectedTrackFollowsItsIdWhenARowIsInsertedAbove() {
        let (s, wire) = scene([tracks(["x", "y", "z"], stale: true, rev: "r1"),
                               tracks(["n", "x", "y", "z"], stale: false, rev: "r2"),
                               tracks(["n", "x", "y", "z"], stale: false, rev: "r2")])
        drill(s, wire, expecting: 3)
        _ = s.handle(.down)   // y
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.count == 4 })
        XCTAssertEqual(s.trackCursorForTest, 2, "the cursor stayed on index 1, which is now x")
        // A later play reads this (`listRev: bridgeTracksListRev`), so it must be the fresh read's.
        XCTAssertEqual(s.drilledListRevForTest, "r2")
    }

    /// A playlist may repeat a song: the SECOND occurrence stays the second.
    func testARepeatedSongKeepsItsOccurrence() {
        let (s, wire) = scene([tracks(["x", "y", "x"], stale: true, rev: "r1"),
                               tracks(["n", "x", "y", "x"], stale: false, rev: "r2"),
                               tracks(["n", "x", "y", "x"], stale: false, rev: "r2")])
        drill(s, wire, expecting: 3)
        _ = s.handle(.down); _ = s.handle(.down)   // the second x
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.count == 4 })
        XCTAssertEqual(s.trackCursorForTest, 3)
    }

    /// The cursor is on the SECOND x; the fresh list has only one. It must not
    /// jump to the first copy (Enter would then play a different row): the
    /// numeric cursor stays, clamped.
    func testARemovedOccurrenceKeepsTheNumericCursorNotAnotherCopy() {
        let (s, wire) = scene([tracks(["x", "y", "x"], stale: true, rev: "r1"),
                               tracks(["x", "y", "z"], stale: false, rev: "r2"),
                               tracks(["x", "y", "z"], stale: false, rev: "r2")])
        drill(s, wire, expecting: 3)
        _ = s.handle(.down); _ = s.handle(.down)   // the second x
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest == ["Song x", "Song y", "Song z"] })
        XCTAssertEqual(s.trackCursorForTest, 2, "the cursor jumped to another copy of the song")
    }

    func testASelectedTrackThatVanishedClampsInRange() {
        let (s, wire) = scene([tracks(ids("a", 6), stale: true, rev: "r1"),
                               tracks(["b1", "b2"], stale: false, rev: "r2"), tracks(["b1", "b2"], stale: false, rev: "r2")])
        drill(s, wire, expecting: 6)
        for _ in 0..<3 { _ = s.handle(.down) }
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest.count == 2 })
        XCTAssertEqual(s.trackCursorForTest, 1)
    }

    /// Left before the fresh list lands: it is dropped, and does not leak
    /// into the next drill-in either.
    func testALateResultAfterLeavingTheDrillInIsDropped() {
        // No reply for a re-walk: the drill-in is left while the probe is in
        // flight, so the re-walk's read is never made (the wire answers in
        // order, so a scripted reply for it would be handed to pl2 instead).
        let (s, wire) = scene([tracks(["a1", "a2"], stale: true, rev: "r1"),
                               tracks(["f1", "f2", "f3"], stale: false, rev: "r2"),
                               tracks(["p2"], stale: false, rev: "r9")])
        drill(s, wire, expecting: 2)
        let oldFeed = s.drilledFeedForTest
        _ = s.handle(.left)
        wire.release(op: "slice.libraryPlaylistTracks", at: 1)
        // Wait for the abandoned worker to actually finish (not a sleep).
        XCTAssertTrue(oldFeed?.waitForWorkersForTest(timeout: 5) ?? false, "the old worker never finished")
        _ = s.tick(snapshot: idle)
        // Leaving keeps the pane's last rows (as before); the fresh read must not touch them.
        XCTAssertEqual(s.drilledTrackTitlesForTest, ["Song a1", "Song a2"], "the dropped fresh read replaced the rows")
        XCTAssertEqual(s.drilledListRevForTest, "r1")
        _ = s.handle(.down)
        _ = s.handle(.enter)   // pl2
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest == ["Song p2"] },
                      "pl2 \(s.drilledPlaylistIDForTest ?? "nil") wire \(wire.sent("slice.libraryPlaylistTracks").map { $0["id"] as? String ?? "" }) cur \(s.railCursorForTest) " +
                      "pl2 showed: \(s.drilledTrackTitlesForTest)")
        _ = s.tick(snapshot: idle)
        XCTAssertEqual(s.drilledPlaylistIDForTest, "pl2")
        XCTAssertEqual(s.drilledTrackTitlesForTest, ["Song p2"], "the old playlist's fresh read leaked in")
        XCTAssertEqual(s.drilledListRevForTest, "r9")
        XCTAssertEqual(wire.sent("slice.libraryPlaylistTracks").map { $0["id"] as? String ?? "" }, ["pl1", "pl1", "pl2"],
                       "leaving during the probe still cost the old playlist a re-walk read")
    }
}

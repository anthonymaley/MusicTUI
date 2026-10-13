import XCTest
@testable import music

/// A drill-in reply (an album's tracks, an artist's albums) flagged stale or
/// refreshing is shown, then replaced by the first unflagged read, exactly as
/// the four root lists are (`LibraryReask`). Uses the shared support from
/// `BridgeLibraryTestSupport.swift`; the sleep is injected, so nothing waits.
final class BridgeLibraryDrillReaskTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],
     "next_cursor":null}
    """
    private let artistPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
    """

    private func tracks(_ ids: [String], stale: Bool) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"Radiohead\",\"album\":\"In Rainbows\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"stale\":\(stale),\"refreshing\":\(stale),\"items\":[\(items)]}"
    }
    private func artistAlbums(_ ids: [String], stale: Bool) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"A\($0)\",\"artist\":\"Radiohead\",\"track_count\":9,\"kind\":\"album\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryArtistAlbums\",\"generation\":3,\"stale\":\(stale),\"refreshing\":\(stale),\"items\":[\(items)]}"
    }
    private func artists(_ ids: [String], stale: Bool) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"R\($0)\",\"kind\":\"artist\"}" }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryArtists\",\"generation\":3,\"total\":\(ids.count),\"stale\":\(stale),\"refreshing\":\(stale),\"items\":[\(items)],\"next_cursor\":null}"
    }

    /// Waits for the re-ask to end, however it ended.
    private func finished(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 3) == .success }

    private func sceneAtAlbumTracks(_ wire: BridgeLibraryReadsWire, flag: BridgeSelectedFlag = BridgeSelectedFlag(true),
                                    waits: DrillWaits = DrillWaits(), ended: DispatchSemaphore? = nil) -> LibraryScene {
        let s = libraryTestScene(flag: flag, wire: wire, spy: LibraryAppleScriptSpy(), warmUpSleep: waits.record)
        if let ended { s.reaskFinishedForTest = { ended.signal() } }
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)
        return s
    }

    // MARK: - Album tracks

    func testAStaleAlbumTracksReplyIsReAskedAndTheFreshReadOverwritesTheCache() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
            "slice.libraryAlbumTracks": [tracks(["a", "b", "c"], stale: true),
                                         tracks(["a", "b", "c"], stale: false),
                                         tracks(["n", "a", "b", "c"], stale: false)]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 1)
        let waits = DrillWaits()
        let s = sceneAtAlbumTracks(wire, waits: waits)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Ta", "Tb", "Tc"] }, "the stale tracks were not shown")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) }, "no re-ask probe went out")
        _ = s.handle(.down)   // b
        XCTAssertEqual(s.navCursorForTest, 1)
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Tn", "Ta", "Tb", "Tc"] }, "the fresh read never overwrote the cache")
        XCTAssertEqual(s.navCursorForTest, 2, "the track cursor stayed on index 1, which is now a different track")
        XCTAssertEqual(waits.all, [LibraryReask.interval])
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 3)
    }

    func testTheTrackCursorIsClampedWhenTheFreshReadIsShorter() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
            "slice.libraryAlbumTracks": [tracks(["a", "b", "c"], stale: true),
                                         tracks(["a", "b", "c"], stale: false),
                                         tracks(["a"], stale: false)]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 1)
        let s = sceneAtAlbumTracks(wire)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"]?.count == 3 })
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) })
        _ = s.handle(.down); _ = s.handle(.down)
        XCTAssertEqual(s.navCursorForTest, 2)
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Ta"] })
        XCTAssertEqual(s.navCursorForTest, 0, "the cursor was left past the end of the shorter list")
    }

    func testAFreshAlbumTracksReplyIsNeverReAsked() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
            "slice.libraryAlbumTracks": [tracks(["a"], stale: false)]])
        let waits = DrillWaits()
        let s = sceneAtAlbumTracks(wire, waits: waits)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Ta"] })
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 1)
        XCTAssertTrue(waits.all.isEmpty)
    }

    func testAStaleAlbumIsNotKickedAgainWhileItsReAskWaits() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
            "slice.libraryAlbumTracks": [tracks(["a"], stale: true), tracks(["a"], stale: false), tracks(["n", "a"], stale: false)]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 1)
        let s = sceneAtAlbumTracks(wire)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) })
        for _ in 0..<20 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 2, "the album was read again while its re-ask waited")
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
    }

    func testAnAlbumTracksReAskThatOutlivedAProvenanceSwitchIsDropped() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
            "slice.libraryAlbumTracks": [tracks(["a"], stale: true), tracks(["n"], stale: false), tracks(["n"], stale: false)]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 1)
        let flag = BridgeSelectedFlag(true)
        let ended = DispatchSemaphore(value: 0)
        let s = sceneAtAlbumTracks(wire, flag: flag, ended: ended)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) })
        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest.isEmpty }, "the provenance reset never cleared the caches")
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
        XCTAssertTrue(finished(ended), "the re-ask never ended")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertTrue(s.trackCacheForTest.isEmpty, "a SpanDAC re-ask landed after the switch: \(s.trackCacheForTest)")
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 2, "the re-walk went out after the switch")
    }

    // MARK: - Artist albums

    private func sceneAtArtistAlbums(_ wire: BridgeLibraryReadsWire, flag: BridgeSelectedFlag = BridgeSelectedFlag(true),
                                     ended: DispatchSemaphore? = nil) -> LibraryScene {
        let s = libraryTestScene(flag: flag, wire: wire, spy: LibraryAppleScriptSpy())
        if let ended { s.reaskFinishedForTest = { ended.signal() } }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.enter)
        return s
    }

    func testAStaleArtistAlbumsListIsReplacedAndTheCursorFollowsTheSelectedAlbum() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
            "slice.libraryArtistAlbums": [artistAlbums(["x", "y"], stale: true),
                                          artistAlbums(["x", "y"], stale: false),
                                          artistAlbums(["new", "x", "y"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let s = sceneAtArtistAlbums(wire)
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["x", "y"] }, "the stale list was not shown")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        _ = s.handle(.down)
        XCTAssertEqual(s.navCursorForTest, 1)
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["new", "x", "y"] })
        XCTAssertEqual(s.navCursorForTest, 2, "the cursor stayed on index 1, which is now a different album")
    }

    func testTheArtistAlbumsCursorIsClampedWhenTheFreshListIsShorter() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
            "slice.libraryArtistAlbums": [artistAlbums(["x", "y", "z"], stale: true),
                                          artistAlbums(["x", "y", "z"], stale: false),
                                          artistAlbums(["x"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let s = sceneAtArtistAlbums(wire)
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.count == 3 })
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        _ = s.handle(.down); _ = s.handle(.down)
        XCTAssertEqual(s.navCursorForTest, 2)
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["x"] })
        XCTAssertEqual(s.navCursorForTest, 0)
    }

    func testAnArtistAlbumsReAskThatOutlivedAProvenanceSwitchIsDropped() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true),
                                          artistAlbums(["n"], stale: false), artistAlbums(["n"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let flag = BridgeSelectedFlag(true)
        let ended = DispatchSemaphore(value: 0)
        let s = sceneAtArtistAlbums(wire, flag: flag, ended: ended)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.isEmpty })
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(finished(ended), "the re-ask never ended")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertTrue(s.artistAlbumsForTest.isEmpty, "a SpanDAC re-ask landed after the switch")
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 2, "the re-walk went out after the switch")
    }

    func testAnArtistAlbumsReAskDoesNotPaintOnAnotherArtistsList() {
        let two = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":2,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"},{"id":"ar2","title":"Slowdive","kind":"artist"}],"next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [two],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true),
                                          artistAlbums(["x"], stale: false), artistAlbums(["other"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let ended = DispatchSemaphore(value: 0)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        s.reaskFinishedForTest = { ended.signal() }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)                                     // ar1
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        _ = s.handle(.escape)
        _ = s.handle(.down)
        _ = s.handle(.enter)                                     // ar2
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(finished(ended))
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["other"] })
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(s.artistAlbumsForTest.map(\.id), ["other"], "ar1's re-ask painted on ar2's list")
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 3, "ar1's re-ask went on to re-read after ar2 was opened")
    }

    // MARK: - Artists root keeps the selected artist by id

    func testAnArtistsReplacementKeepsTheSelectedArtistWhenARowIsInsertedAbove() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [
            artists(["x", "y"], stale: true), artists(["new", "x", "y"], stale: false), artists(["new", "x", "y"], stale: false)]])
        wire.gate(op: "slice.libraryArtists", at: 1)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Rx") })
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtists", at: 1) })
        _ = s.handle(.down)   // y
        XCTAssertEqual(s.navCursorForTest, 1)
        wire.release(op: "slice.libraryArtists", at: 1)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Rnew") })
        XCTAssertEqual(s.navCursorForTest, 2, "the cursor stayed on index 1, which is now a different artist")
    }
}

private final class DrillWaits {
    private let lock = NSLock()
    private var taken: [TimeInterval] = []
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return taken }
    func record(_ seconds: TimeInterval) { lock.lock(); taken.append(seconds); lock.unlock() }
}

/// Round 2: a re-ask belongs to what the person is looking at.
final class BridgeLibraryDrillReaskScopeTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func tracks(_ ids: [String], stale: Bool) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"R\",\"album\":\"Alb\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"stale\":\(stale),\"refreshing\":\(stale),\"items\":[\(items)]}"
    }
    private func artistAlbums(_ ids: [String], stale: Bool) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"A\($0)\",\"artist\":\"R\",\"track_count\":9,\"kind\":\"album\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryArtistAlbums\",\"generation\":3,\"stale\":\(stale),\"refreshing\":\(stale),\"items\":[\(items)]}"
    }
    private let boom = #"{"ok":false,"op":"slice.libraryArtistAlbums","error":{"kind":"bad_request","detail":"boom"}}"#
    private let twoArtists = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":2,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"},{"id":"ar2","title":"Slowdive","kind":"artist"}],"next_cursor":null}
    """
    private let threeAlbums = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":3,
     "items":[{"id":"al1","title":"First","artist":"R","track_count":1,"kind":"album"},
              {"id":"al2","title":"Second","artist":"R","track_count":1,"kind":"album"},
              {"id":"al3","title":"Third","artist":"R","track_count":1,"kind":"album"}],"next_cursor":null}
    """

    private func count(_ gate: Counter, _ n: Int) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { if gate.value >= n { return true }; usleep(2_000) }
        return gate.value >= n
    }

    // MARK: 1. an abandoned artist's FIRST read must not overwrite the current artist's

    func testAnAbandonedArtistsFirstReadDoesNotOverwriteTheCurrentArtistsReply() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [artistAlbums(["a"], stale: false), artistAlbums(["b"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 0)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        let reads = Counter(); s.artistAlbumsReadFinishedForTest = { reads.bump() }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)                                     // A: held
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 0) })
        _ = s.handle(.escape); _ = s.handle(.down); _ = s.handle(.enter)   // B
        XCTAssertTrue(count(reads, 1), "B's read never posted")
        wire.release(op: "slice.libraryArtistAlbums", at: 0)     // A posts LAST
        XCTAssertTrue(count(reads, 2), "A's read never ended")
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["b"] }, "B was left on Loading albums")
    }

    func testAnAbandonedArtistsFirstFailureDoesNotOverwriteTheCurrentArtistsFailure() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [boom, boom]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 0)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        let reads = Counter(); s.artistAlbumsReadFinishedForTest = { reads.bump() }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 0) })
        _ = s.handle(.escape); _ = s.handle(.down); _ = s.handle(.enter)
        XCTAssertTrue(count(reads, 1))
        wire.release(op: "slice.libraryArtistAlbums", at: 0)
        XCTAssertTrue(count(reads, 2))
        XCTAssertTrue(settleScene(s) { s.artistAlbumsFailureForTest != nil }, "B's failure was overwritten by A's")
    }

    // MARK: 2. a re-ask is tied to what is open

    func testBackingOutOfAnArtistStopsItsReAsk() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true), artistAlbums(["x"], stale: false),
                                          artistAlbums(["n"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        let ended = Counter(); s.reaskFinishedForTest = { ended.bump() }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        _ = s.handle(.escape)
        for _ in 0..<3 { _ = s.tick(snapshot: idle) }
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(count(ended, 1), "the re-ask never ended")
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 2, "the re-ask went on after the person backed out")
    }

    func testScrollingAcrossStaleAlbumsKeepsOnlyTheCurrentAlbumsReAskProbing() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [threeAlbums],
            "slice.libraryAlbumTracks": [
                tracks(["a"], stale: true), tracks(["a"], stale: false),   // album 1, its probe
                tracks(["b"], stale: true), tracks(["b"], stale: false),   // album 2
                tracks(["c"], stale: true), tracks(["c"], stale: false),   // album 3
                tracks(["n"], stale: false)]])                              // album 3's re-read
        for n in [1, 3, 5] { wire.gate(op: "slice.libraryAlbumTracks", at: n) }
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        let ended = Counter(); s.reaskFinishedForTest = { ended.bump() }
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Third") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) })
        _ = s.handle(.escape); while s.navCursorForTest < 1 { _ = s.handle(.down) }; _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 3) })
        _ = s.handle(.escape); while s.navCursorForTest < 2 { _ = s.handle(.down) }; _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 5) })
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 6)
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
        wire.release(op: "slice.libraryAlbumTracks", at: 3)
        XCTAssertTrue(count(ended, 2), "the superseded re-asks never ended")
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 6, "an album the person left kept re-asking")
        wire.release(op: "slice.libraryAlbumTracks", at: 5)
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al3"] == ["Tn"] }, "the current album's re-ask did not finish")
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 7)
    }

    /// Read by the scene's worker thread (`now: { clock.date }`) and written by
    /// the test thread, so the storage is lock-guarded.
    final class Clock {
        private let lock = NSLock()
        private var stored = Date(timeIntervalSince1970: 1_000_000)
        var date: Date {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: artist albums: a heartbeat-ended re-ask resumes; a spent one does not

    private func artistReaskScene(_ wire: BridgeLibraryReadsWire, clock: Clock, sleep: @escaping (TimeInterval) -> Void = { _ in },
                                  ended: Counter) -> LibraryScene {
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 warmUpSleep: sleep, now: { clock.date })
        s.reaskFinishedForTest = { ended.bump() }
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)
        return s
    }

    func testAnArtistAlbumsReAskEndedByLeavingTheTabResumesWhenTheTabTicksAgain() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true), artistAlbums(["x"], stale: false),
                                          artistAlbums(["x"], stale: false), artistAlbums(["n"], stale: false)]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 1)
        let clock = Clock(), ended = Counter()
        let s = artistReaskScene(wire, clock: clock, ended: ended)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 1) })
        clock.date.addTimeInterval(60)           // the tab stops ticking
        wire.release(op: "slice.libraryArtistAlbums", at: 1)
        XCTAssertTrue(count(ended, 1))
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 2, "the re-ask went on while the tab was not showing")
        XCTAssertEqual(s.artistAlbumsForTest.map(\.id), ["x"])
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["n"] }, "coming back never resumed the re-ask")
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 4)
    }

    func testAnArtistAlbumsReAskEndedByAMainThreadStallResumes() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true), artistAlbums(["x"], stale: false),
                                          artistAlbums(["n"], stale: false)]])
        let clock = Clock(), ended = Counter()
        // The first wait outlasts the heartbeat window while the main thread
        // is not ticking: a stall over 3 s.
        let stalled = Counter()
        let s = artistReaskScene(wire, clock: clock, sleep: { _ in
            if stalled.value == 0 { stalled.bump(); clock.date.addTimeInterval(10) }
        }, ended: ended)
        XCTAssertTrue(settleScene(s) { ended.value >= 1 }, "the stalled re-ask never ended")
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 1, "the stalled re-ask probed anyway")
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["n"] }, "the stalled re-ask never resumed")
    }

    func testASpentArtistAlbumsReAskDoesNotRestart() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [twoArtists],
            "slice.libraryArtistAlbums": [artistAlbums(["x"], stale: true)]])   // the probe is unscripted: it fails
        let clock = Clock(), ended = Counter()
        let s = artistReaskScene(wire, clock: clock, ended: ended)
        XCTAssertTrue(settleScene(s) { ended.value >= 1 }, "the attempt never ended")
        for _ in 0..<20 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").count, 2, "a spent attempt restarted")
        XCTAssertEqual(ended.value, 1)
    }

    // MARK: Music.app artist first read, adverse order

    func testAnAbandonedMusicAppArtistsFirstReadDoesNotOverwriteTheCurrentArtists() {
        let gate = DispatchSemaphore(value: 0)
        let spy = LibraryAppleScriptSpy()
        spy.artists = [LibraryArtist(id: "ar1", name: "Radiohead"), LibraryArtist(id: "ar2", name: "Slowdive")]
        let reads = Counter()
        let base = spy.sources()
        let sources = LibraryDataSources(
            onAlbums: base.onAlbums, onSongs: base.onSongs, onArtists: base.onArtists,
            onAlbumTracks: base.onAlbumTracks,
            onArtistAlbums: { id in
                if id == "ar1" { _ = gate.wait(timeout: .now() + 5) }
                reads.bump()
                return [LibraryAlbum(id: "alb-\(id)", name: "Album \(id)", artist: id, trackCount: 1)]
            },
            onAlbumCover: base.onAlbumCover)
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let wire = BridgeLibraryReadsWire()
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                             sources: sources, appQueue: AppQueueStore(), status: StatusStore(),
                             actions: ActionRunner(status: StatusStore()), makeProvider: { nil },
                             warmUpSleep: { _ in }, resultCache: temporaryResultCache().cache)
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Slowdive") })
        _ = s.handle(.enter)                                     // ar1: held
        _ = s.handle(.escape); _ = s.handle(.down); _ = s.handle(.enter)   // ar2
        XCTAssertTrue(count(reads, 1), "ar2's read never finished")
        gate.signal()                                            // ar1 lands LAST
        XCTAssertTrue(count(reads, 2))
        XCTAssertTrue(settleScene(s) { s.artistAlbumsForTest.map(\.id) == ["alb-ar2"] }, "ar2 was left on Loading albums")
    }


    func testLeavingTheLibraryTabStopsTheReAskAndReturningResumesIt() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [threeAlbums],
            "slice.libraryAlbumTracks": [tracks(["a"], stale: true), tracks(["a"], stale: false),
                                         tracks(["a"], stale: false), tracks(["n"], stale: false)]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 1)
        let clock = Clock()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), now: { clock.date })
        let ended = Counter(); s.reaskFinishedForTest = { ended.bump() }
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Third") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 1) })
        clock.date.addTimeInterval(60)          // no tick for a minute: the tab is not showing
        wire.release(op: "slice.libraryAlbumTracks", at: 1)
        XCTAssertTrue(count(ended, 1))
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").count, 2, "the re-ask went on while the tab was not showing")
        XCTAssertEqual(s.trackCacheForTest["al1"], ["Ta"])
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["al1"] == ["Tn"] }, "coming back never resumed the re-ask")
    }
}

private final class Counter {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

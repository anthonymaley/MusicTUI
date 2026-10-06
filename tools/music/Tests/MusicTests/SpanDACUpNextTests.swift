// tools/music/Tests/MusicTests/SpanDACUpNextTests.swift
import XCTest
@testable import music

/// SpanDAC's Up Next and cover fallback through the Now tab's EXISTING list and
/// art rung: the rows a play sent are kept, the status's `row` / `next_rows`
/// index them, and the poller hands the shared renderer ordinary
/// `TrackListEntry` rows. Fakes only: no real SpanDAC, no real Music.app.
final class SpanDACUpNextTests: XCTestCase {

    private let alias = "-596357614188841472"
    private let hex = "F7B94FE8D72CB600"

    private func song(_ n: Int, alias: String? = nil) -> MusicRow {
        var r = MusicRow(id: "i\(n)", title: "Song \(n)", artist: "Artist \(n)", album: "Album", kind: .song)
        r.alias = alias
        return r
    }

    private func reply(title: String, extra: String) -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"\#(title)","artist":"A"\#(extra),"queue":{"phase":"complete","requested":5,"present":5,"index":1}}}"#
    }

    private func status(title: String = "Song 1", extra: String) throws -> SourceStatus {
        let r = reply(title: title, extra: extra)
        return try SourceAppControl(path: "/nonexistent", transport: { _, _ in r }).status()
    }

    private func routing(reply: String) -> RoutingCoordinator {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.source)
        return RoutingCoordinator(store: modeStore, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in reply }) })
    }

    private func poll(_ routing: RoutingCoordinator, reply: String) -> NowPlayingSnapshot {
        let store = NowPlayingStore()
        let p = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                               routing: routing,
                               makeSourceClient: { SourceAppClient(path: "/nonexistent", transport: { _, _ in reply }) })
        p.tick()
        return store.read()
    }

    // MARK: - the wire

    func testStatusDecodesRowAndNextRowsAndDropsMalformed() throws {
        let s = try status(extra: #","row":1,"next_rows":[3,0,2]"#)
        XCTAssertEqual(s.row, 1)
        XCTAssertEqual(s.nextRows, [3, 0, 2])

        let absent = try status(extra: "")
        XCTAssertNil(absent.row)
        XCTAssertNil(absent.nextRows, "absent next_rows is not an empty list")

        let bad = try status(extra: #","row":true,"next_rows":[-1,"2",1.5,4,false]"#)
        XCTAssertNil(bad.row, "a boolean is not an index")
        XCTAssertEqual(bad.nextRows, [4])

        let many = (0..<30).map(String.init).joined(separator: ",")
        XCTAssertEqual(try status(extra: #","row":0,"next_rows":[\#(many)]"#).nextRows?.count, 20)
    }

    // MARK: - the window, pure

    func testWindowFollowsNextRowsThenFallsBackToSentOrder() throws {
        let sent = (0..<5).map { song($0) }
        let shuffled = spanDACQueueWindow(sent: sent, status: try status(title: "Song 1", extra: #","row":1,"next_rows":[4,0,9]"#))
        XCTAssertEqual(shuffled.current?.id, "i1")
        XCTAssertEqual(shuffled.entries.map(\.name), ["Song 1", "Song 4", "Song 0"], "out-of-range 9 is dropped")
        XCTAssertEqual(shuffled.entries.map(\.index), [2, 5, 1], "1-based place in the sent list")
        XCTAssertEqual(shuffled.entries.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(shuffled.entries.first?.album, "Album")

        let inOrder = spanDACQueueWindow(sent: sent, status: try status(title: "Song 3", extra: #","row":3"#))
        XCTAssertEqual(inOrder.entries.map(\.name), ["Song 3", "Song 4"])
    }

    func testWindowShowsNothingTheStatusDoesNotVouchFor() throws {
        let sent = (0..<3).map { song($0) }
        XCTAssertTrue(spanDACQueueWindow(sent: nil, status: try status(extra: #","row":0"#)).entries.isEmpty)
        XCTAssertTrue(spanDACQueueWindow(sent: sent, status: try status(extra: "")).entries.isEmpty, "no row")
        XCTAssertTrue(spanDACQueueWindow(sent: sent, status: try status(extra: #","row":3"#)).entries.isEmpty, "outside")
        let other = spanDACQueueWindow(sent: sent, status: try status(title: "Something Else", extra: #","row":1"#))
        XCTAssertNil(other.current, "a row whose title is not the one playing is not trusted")
        XCTAssertTrue(other.entries.isEmpty)
    }

    func testQueueRowsAreTheRowsBehindTheIDs() {
        let rows = (0..<6).map { song($0) }
        XCTAssertEqual(bridgeQueueRows(rows, shuffle: false, startAt: 3).map(\.id), bridgeQueueIDs(rows, shuffle: false, startAt: 3))
        XCTAssertEqual(bridgeQueueRows(rows, shuffle: false, startAt: 3).map(\.id), ["i2", "i3", "i4", "i5"])
        XCTAssertEqual(Set(bridgeQueueRows(rows, shuffle: true, startAt: 3).map(\.id)), Set(rows.map(\.id)))
    }

    // MARK: - the kept list

    func testThePlayedListAnswersOnlyUntilTheNextPlay() throws {
        let r = routing(reply: "{}")
        XCTAssertNil(r.spanDACPlayedRows())
        r.recordSpanDACPlay([song(0), song(1)])
        XCTAssertEqual(r.spanDACPlayedRows()?.map(\.id), ["i0", "i1"])
        try r.perform(.radioStationPlay, expecting: nil, musicApp: { _ in }, source: { _ in }, unaffected: {})
        XCTAssertNil(r.spanDACPlayedRows(), "a later play's status must not be read against this list")
    }

    /// The Library tab's real play path keeps exactly the rows whose ids it
    /// sent, aliases and all, from the row Enter was pressed on.
    func testALibraryPlayKeepsTheRowsItSent() {
        let tracks = ["t1", "t2", "t3"].map {
            "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"Radiohead\",\"album\":\"In Rainbows\",\"kind\":\"song\",\"alias\":\"-\($0.dropFirst())\"}"
        }.joined(separator: ",")
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2,"present":2,"index":0}}}"#
        let wire = BridgeLibraryReadsWire([
            "slice.libraryAlbums": [#"{"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,"items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],"next_cursor":null}"#],
            "slice.libraryAlbumTracks": ["{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(tracks)]}"],
            "slice.queue": [queued], "slice.status": [queued]])
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let r = RoutingCoordinator(store: store, surface: .tui,
                                   makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), routing: r)
        let frame = shellLayout(width: 140, height: 30)
        let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt2") })
        _ = s.handle(.down)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { r.spanDACPlayedRows() != nil })
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t2", "t3"])
        XCTAssertEqual(r.spanDACPlayedRows()?.map(\.id), ["t2", "t3"])
        XCTAssertEqual(r.spanDACPlayedRows()?.map(\.alias), ["-2", "-3"])
    }

    // MARK: - through the poller and the existing renderer

    func testPollerFeedsUpNextAndTheCoverFallbackFromTheSentRows() throws {
        let text = reply(title: "Song 1", extra: #","row":1,"next_rows":[3,2]"#)
        let r = routing(reply: text)
        r.recordSpanDACPlay([song(0), song(1, alias: alias), song(2), song(3)])
        let snap = poll(r, reply: text)
        XCTAssertEqual(snap.surrounding.map(\.name), ["Song 1", "Song 3", "Song 2"])
        XCTAssertEqual(snap.bridge?.persistentID, alias, "the sent row's alias stands in for a missing persistent_id")
        XCTAssertEqual(bridgeCoverSource(artworkURL: snap.bridge?.artworkURL, persistentID: snap.bridge?.persistentID),
                       .library(persistentID: hex), "the existing cover rung takes it from here")

        // The status's own persistent ID is never overridden.
        let own = reply(title: "Song 1", extra: #","row":1,"persistent_id":"-1""#)
        let r2 = routing(reply: own)
        r2.recordSpanDACPlay([song(0), song(1, alias: alias)])
        XCTAssertEqual(poll(r2, reply: own).bridge?.persistentID, "-1")

        // An older SpanDAC (no `row`) leaves Now as it was: no list, no stand-in.
        let old = reply(title: "Song 1", extra: "")
        let r3 = routing(reply: old)
        r3.recordSpanDACPlay([song(0), song(1, alias: alias)])
        let oldSnap = poll(r3, reply: old)
        XCTAssertTrue(oldSnap.surrounding.isEmpty)
        XCTAssertNil(oldSnap.bridge?.persistentID)
    }

    func testNowDrawsSpanDACsUpNextWithTheSharedListAndEnterStaysRefused() throws {
        let text = reply(title: "Song 1", extra: #","row":1,"next_rows":[3,2]"#)
        let r = routing(reply: text)
        r.recordSpanDACPlay([song(0), song(1), song(2), song(3)])
        let snap = poll(r, reply: text)

        let status = StatusStore()
        let scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                                    status: status, actions: ActionRunner(status: status), routing: r,
                                    bridgeCoverExtractor: { _, _ in nil })
        scene.tick(snapshot: snap)
        let plain = scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        XCTAssertTrue(plain.contains("Up Next"), plain)
        XCTAssertTrue(plain.contains("Song 3 \u{2014} Artist 3"), plain)
        XCTAssertTrue(plain.contains("Song 2 \u{2014} Artist 2"), plain)

        // Without rows, the SpanDAC Now has no Up Next at all, as before.
        var bare = snap; bare.surrounding = []
        scene.tick(snapshot: bare)
        XCTAssertFalse(scene.render(frame: shellLayout(width: 120, height: 40), snapshot: bare).contains("Up Next"))

        // Enter on a row: the queue jump is refused on SpanDAC (ruling 12.13).
        scene.tick(snapshot: snap)
        _ = scene.handle(.down)
        _ = scene.handle(.enter)
        XCTAssertEqual(status.current()?.text, "Jumping to a queue row is MusicTUI only in this version.")
    }
}

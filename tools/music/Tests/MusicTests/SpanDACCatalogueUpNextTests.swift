// tools/music/Tests/MusicTests/SpanDACCatalogueUpNextTests.swift
import XCTest
@testable import music

/// Up Next for a play SpanDAC queued by CATALOGUE id (the DJ's artist mix).
/// SpanDAC's status carries no `row` / `next_rows` for such a queue (they come
/// from the library roster only), so the kept rows are placed by the playing
/// song's exact title, which a catalogue queue cannot repeat (SpanDAC refuses
/// two songs with the same title). A library play without `row` stays empty.
/// Fakes only.
final class SpanDACCatalogueUpNextTests: XCTestCase {

    private func song(_ n: Int, title: String? = nil, album: String = "Album") -> MusicRow {
        MusicRow(id: "\(1000 + n)", title: title ?? "Song \(n)", artist: "Radiohead", album: album, kind: .song)
    }

    private func reply(title: String, extra: String = "", token: String = "tok-1",
                       queue: String = #""phase":"complete","requested":5,"present":5,"index":2"#) -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"\#(title)","artist":"Radiohead","queue_token":"\#(token)","queue":{\#(queue)}\#(extra)}}"#
    }

    private func status(title: String, extra: String = "", token: String = "tok-1",
                        queue: String = #""phase":"complete","requested":5,"present":5,"index":2"#) throws -> SourceStatus {
        let r = reply(title: title, extra: extra, token: token, queue: queue)
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

    func testACatalogueQueuePlacesThePlayingSongByTitleAndListsTheRowsAfterIt() throws {
        let sent = (0..<5).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true,
                                        status: try status(title: "Song 2"))
        XCTAssertEqual(window.current?.id, "1002")
        XCTAssertEqual(window.entries.map(\.name), ["Song 2", "Song 3", "Song 4"], "the current row, then the rest in sent order")
        XCTAssertEqual(window.entries.map(\.index), [3, 4, 5])
        XCTAssertEqual(window.entries.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(window.entries.first?.album, "Album")
    }

    func testTheTitleMatchIgnoresCaseAndSurroundingSpaces() throws {
        let sent = (0..<3).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true,
                                        status: try status(title: "  SONG 1 "))
        XCTAssertEqual(window.current?.id, "1001")
    }

    func testAStatusRowStillWinsOverTheTitleOnACatalogueQueue() throws {
        let sent = (0..<4).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true,
                                        status: try status(title: "Song 1", extra: #","row":1,"next_rows":[3]"#))
        XCTAssertEqual(window.entries.map(\.name), ["Song 1", "Song 3"])
    }

    func testNothingIsGuessedWhenTheTitleIsNotInTheListOrIsInItTwice() throws {
        let sent = [song(0), song(1, title: "Same"), song(2, title: "Same"), song(3)]
        let twice = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true, status: try status(title: "Same"))
        XCTAssertNil(twice.current, "two rows with the title: no row is chosen")
        XCTAssertTrue(twice.entries.isEmpty)
        let missing = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true, status: try status(title: "Elsewhere"))
        XCTAssertNil(missing.current)
        XCTAssertTrue(missing.entries.isEmpty)
    }

    func testAnotherQueuesTokenStillShowsNothing() throws {
        let sent = (0..<3).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true,
                                        status: try status(title: "Song 1", token: "tok-OTHER"))
        XCTAssertNil(window.current)
        XCTAssertTrue(window.entries.isEmpty)
    }

    func testAShuffledOrLostSongsCatalogueQueueListsOnlyTheCurrentSong() throws {
        let sent = (0..<5).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", sentOrderUnreliable: true, catalogue: true,
                                        status: try status(title: "Song 2"))
        XCTAssertEqual(window.current?.id, "1002", "the playing song is still known, so the album line and its place stand")
        XCTAssertEqual(window.entries.map(\.name), ["Song 2"], "no Up Next after it: the order is not the sent order")
    }

    /// A library play without a `row` is still unplaced: the title is no
    /// evidence there (a library queue can hold the same title twice).
    func testALibraryPlayWithNoRowIsStillNotPlaced() throws {
        let sent = (0..<3).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", status: try status(title: "Song 1"))
        XCTAssertNil(window.current)
        XCTAssertTrue(window.entries.isEmpty)
    }

    func testThePollerListsAMixThatWasRecordedAsCatalogue() throws {
        let text = reply(title: "Song 1")
        let r = routing(reply: text)
        r.recordSpanDACPlay((0..<4).map { song($0, album: $0 == 1 ? "OK Computer" : "Album") }, token: "tok-1", catalogue: true)
        let snap = poll(r, reply: text)
        XCTAssertEqual(snap.surrounding.map(\.name), ["Song 1", "Song 2", "Song 3"])
        XCTAssertEqual(snap.spanDACQueueToken, "tok-1")
        guard case .active(let np) = snap.outcome else { return XCTFail("not active") }
        XCTAssertEqual(np.album, "OK Computer")
        XCTAssertNil(snap.bridge?.persistentID, "a catalogue row has no library alias to stand in")
    }

    func testThePollerLeavesAnUnrecordedAsCatalogueMixAsItWas() throws {
        let text = reply(title: "Song 1")
        let r = routing(reply: text)
        r.recordSpanDACPlay((0..<4).map { song($0) }, token: "tok-1")
        XCTAssertTrue(poll(r, reply: text).surrounding.isEmpty)
    }

    // MARK: only rows the status proves are in the player

    private func futureNames(sent n: Int, queue: String) throws -> [String] {
        let sent = (0..<n).map { song($0) }
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", catalogue: true,
                                        status: try status(title: "Song 0", queue: queue))
        XCTAssertEqual(window.current?.title, "Song 0")
        return window.entries.dropFirst().map(\.name)
    }

    func testABuildingQueueShowsOnlyRowsBelowPresent() throws {
        XCTAssertEqual(try futureNames(sent: 50, queue: #""phase":"building","requested":50,"present":1,"index":0"#), [])
        XCTAssertEqual(try futureNames(sent: 50, queue: #""phase":"building","requested":50,"present":10,"index":0"#),
                       (1..<10).map { "Song \($0)" })
    }

    func testACompleteQueueShowsAllRemainingRows() throws {
        XCTAssertEqual(try futureNames(sent: 5, queue: #""phase":"complete","requested":5,"present":5,"index":0"#),
                       (1..<5).map { "Song \($0)" })
    }

    func testACompleteQueueOfFewerThanSentShowsOnlyUpToPresent() throws {
        XCTAssertEqual(try futureNames(sent: 5, queue: #""phase":"complete","requested":5,"present":3,"index":0"#),
                       ["Song 1", "Song 2"])
    }

    func testAnInvalidOrUnknownPhaseShowsOnlyTheCurrentSong() throws {
        XCTAssertEqual(try futureNames(sent: 5, queue: #""phase":"invalid","requested":5,"index":0"#), [])
        XCTAssertEqual(try futureNames(sent: 5, queue: #""phase":"somethingnew","requested":5,"present":5,"index":0"#), [])
        XCTAssertEqual(try futureNames(sent: 5, queue: #""requested":5,"present":5,"index":0"#), [])
    }

    func testALibraryQueueIsNotLimitedByPhase() throws {
        let sent = (0..<5).map { song($0) }
        let st = try status(title: "Song 0", extra: #","row":0,"next_rows":[1,2,3,4]"#,
                            queue: #""phase":"building","requested":5,"present":1,"index":0"#)
        let window = spanDACQueueWindow(sent: sent, token: "tok-1", status: st)
        XCTAssertEqual(window.entries.count, 5)
    }

    func testThePollerFlagsACatalogueQueueForNow() throws {
        let text = reply(title: "Song 1")
        let r = routing(reply: text)
        r.recordSpanDACPlay((0..<4).map { song($0) }, token: "tok-1", catalogue: true)
        XCTAssertTrue(poll(r, reply: text).spanDACQueueIsCatalogue)
    }
}

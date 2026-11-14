import XCTest
@testable import music

/// concert/catalogue-play, fix round: a filled play's reply carries the PLAN's counts
/// (reply before build, as for every catalogue queue), so the footer said "3 tracks,
/// 2 from Apple Music" before the build finished. When SpanDAC then reports the queue
/// `invalid` (an insert was not witnessed), the footer is corrected from that status,
/// once, with what was built; and a stop that could not be witnessed is not called
/// "stopped". A fake wire only: no real socket, no device.
final class CatalogueFillBuildFailureTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let onePlaylistPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"2018","kind":"playlist"}],"next_cursor":null}
    """

    private let rows: [(id: String, title: String, catalog: String?)] = [
        ("i.1", "One", "1001"), ("i.2", "Two", "1002"), ("i.3", "Three", nil), ("i.4", "Four", "1004"),
    ]

    private func tracksPage() -> String {
        let items = rows.map { row -> String in
            let catalog = row.catalog.map { ",\"catalog_id\":\"\($0)\"" } ?? ""
            return "{\"id\":\"\(row.id)\",\"title\":\"\(row.title)\",\"artist\":\"A\",\"kind\":\"song\"\(catalog)}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryPlaylistTracks\",\"generation\":3,\"total\":\(rows.count),"
            + "\"items\":[\(items)],\"next_cursor\":null,\"skipped_videos\":0}"
    }

    private func status(capabilities: String = "\"slice.queue\",\"queue.catalogue_fill\"", queue: String) -> String {
        "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\",\"title\":\"One\",\"artist\":\"A\","
            + "\"contract\":3,\"authorization\":\"authorized\",\"capabilities\":[\(capabilities)],\"queue\":\(queue)}}"
    }

    private let building = "{\"phase\":\"building\",\"requested\":3,\"present\":1,\"index\":0}"

    private func invalid(reason: String, requested: Int = 3, built: Int = 1) -> String {
        "{\"phase\":\"invalid\",\"requested\":\(requested),\"built_before_failure\":\(built),\"reason\":\"\(reason)\"}"
    }

    /// The wire answers `slice.status` from `statusQueue`, which a test changes after the play.
    private final class StatusSource {
        private let lock = NSLock()
        private var value: String
        init(_ v: String) { value = v }
        var current: String { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
    }

    /// Plays the playlist with `p` and returns once the footer says "Playing".
    private func playedRig(capabilities: String = "\"slice.queue\",\"queue.catalogue_fill\"",
                           queueReply: String, source: StatusSource,
                           file: StaticString = #filePath, line: UInt = #line)
        -> (wire: BridgeLibraryReadsWire, routing: RoutingCoordinator, status: StatusStore) {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage()])
        wire.handler = { op, _ in
            op == "slice.status" ? self.status(capabilities: capabilities, queue: source.current) : nil
        }
        let status = StatusStore()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120, routing: routing)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("2018") }, file: file, line: line)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, file: file, line: line)
        XCTAssertTrue(settleScene(s) { status.current()?.text.contains("Playing") == true }, file: file, line: line)
        return (wire, routing, status)
    }

    private func poller(routing: RoutingCoordinator, status: StatusStore) -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: AppleScriptCallCounter().backend, appQueue: AppQueueStore(),
                       queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                       routing: routing,
                       onBuildNotice: { status.post($0, error: true, untilStateChange: true) })
    }

    private func queueReply(filled: Int?) -> String {
        "{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":0,\"skipped_not_in_library\":1"
            + (filled.map { ",\"filled_from_catalogue\":\($0)" } ?? "") + "}"
    }

    // MARK: - the footer is corrected from the status, once

    func testAFilledPlaySaysThePlannedCountsAndABuildFailureCorrectsThemFromTheStatus() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2), source: source)
        XCTAssertEqual(r.status.current()?.text,
                       "Skipped 1 not in your library \u{00B7} Playing '2018' on SpanDAC \u{2014} 3 tracks, 2 from Apple Music.",
                       "the reply's counts are the plan's")
        let p = poller(routing: r.routing, status: r.status)
        // Still building: nothing to correct.
        p.tick()
        XCTAssertTrue(r.status.current()?.text.contains("3 tracks, 2 from Apple Music") == true)
        // The device could not witness insert 2: invalid, one song built, playback stopped.
        source.current = invalid(reason: "insert 2 of 3 failed: boom")
        p.tick()
        let corrected = r.status.current()
        XCTAssertEqual(corrected?.text, "'2018' stopped after 1 of 3 tracks: insert 2 of 3 failed: boom.")
        XCTAssertEqual(corrected?.isError, true)
        // Said once: a second poll of the same invalid status does not repost over a later message.
        r.status.post("Something else", ttl: 30)
        p.tick()
        XCTAssertEqual(r.status.current()?.text, "Something else")
    }

    func testAnUnloadThatFailedIsNeverCalledStopped() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2), source: source)
        source.current = invalid(reason: "insert 2 of 3 failed: boom; playback could not be stopped")
        poller(routing: r.routing, status: r.status).tick()
        let text = r.status.current()?.text ?? ""
        XCTAssertFalse(text.contains("stopped after"), text)
        XCTAssertEqual(text, "'2018' did not finish building after 1 of 3 tracks: insert 2 of 3 failed: boom; playback could not be stopped.")
        // The Now tab's own line agrees.
        let now = bridgeNow(from: SourceStatus(playback: "playing", title: "One", artist: "A", readiness: .ready,
                                               queuePhase: "invalid", queueRequested: 3, queuePresent: nil,
                                               queueReason: "insert 2 of 3 failed: boom; playback could not be stopped",
                                               queueBuiltBeforeFailure: 1))
        XCTAssertEqual(bridgeStatusLine(now),
                       "Failed: insert 2 of 3 failed: boom; playback could not be stopped. 1 of 3 built.")
    }

    func testAStoppedBuildKeepsTheNowTabsStoppedLine() {
        let now = bridgeNow(from: SourceStatus(playback: "idle", title: nil, artist: nil, readiness: .ready,
                                               queuePhase: "invalid", queueRequested: 3, queuePresent: nil,
                                               queueReason: "insert 2 of 3 failed: boom", queueBuiltBeforeFailure: 1))
        XCTAssertEqual(bridgeStatusLine(now), "Stopped: insert 2 of 3 failed: boom. 1 of 3 built.")
    }

    // MARK: - what is left alone

    func testAPlayThatFilledNothingIsNeverCorrectedByThisAndNeitherIsAnotherQueue() {
        // No filled songs in the reply: today's footer, today's behaviour, whatever the status later says.
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: nil), source: source)
        let before = r.status.current()?.text
        source.current = invalid(reason: "insert 2 of 3 failed: boom")
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before)
    }

    func testAnInvalidStatusForADifferentQueueSizeIsNotThisPlays() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2), source: source)
        let before = r.status.current()?.text
        source.current = invalid(reason: "insert 9 of 40 failed", requested: 40, built: 8)
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before, "another process's queue is not this play's footer")
    }

    func testALaterPlayRetiresTheWatch() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2), source: source)
        // Any later recorded play replaces what this one was watching.
        _ = r.routing.recordSpanDACPlay([], token: "other")
        source.current = invalid(reason: "insert 2 of 3 failed: boom")
        let before = r.status.current()?.text
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before)
    }
}

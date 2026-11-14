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

    /// `token` is the failed build's own `queue_token` (`failed_queue_token`): the identity
    /// the client matches its play on. The reply below carries "T-1".
    private func invalid(reason: String, requested: Int = 3, built: Int = 1, token: String? = "T-1") -> String {
        let named = token.map { ",\"failed_queue_token\":\"\($0)\"" } ?? ""
        return "{\"phase\":\"invalid\",\"requested\":\(requested),\"built_before_failure\":\(built),"
            + "\"reason\":\"\(reason)\"\(named)}"
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

    /// `beforePost` runs between the poller deciding to post and the post itself: the window an
    /// interleaving play can start in.
    private func poller(routing: RoutingCoordinator, status: StatusStore,
                        beforePost: @escaping () -> Void = {}) -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: AppleScriptCallCounter().backend, appQueue: AppQueueStore(),
                       queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                       routing: routing,
                       onBuildNotice: { text, claim in
                           beforePost()
                           status.post(text, error: true, untilStateChange: true, claiming: claim)
                       })
    }

    /// A coordinator and footer with a play recorded the way the scene records a filled one, but
    /// the footer NOT yet posted: for the interleavings the scene's own timing makes hard to hit.
    private func recordedFill(source: StatusSource, token: String = "T-1")
        -> (routing: RoutingCoordinator, status: StatusStore, serial: Int) {
        let wire = BridgeLibraryReadsWire([:])
        wire.handler = { op, _ in
            op == "slice.status" ? self.status(queue: source.current) : nil
        }
        let status = StatusStore()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let serial = routing.recordSpanDACPlay([], token: token)
        routing.recordSpanDACFill(serial: serial, name: "2018", expected: 3, token: token)
        return (routing, status, serial)
    }

    private func queueReply(filled: Int?, token: String? = "T-1") -> String {
        "{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":0,\"skipped_not_in_library\":1"
            + (filled.map { ",\"filled_from_catalogue\":\($0)" } ?? "")
            + (token.map { ",\"queue_token\":\"\($0)\"" } ?? "") + "}"
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

    /// Codex 258728fe B1: the queue SIZE does not identify a play. Another process's queue
    /// that failed at the same requested size, under its own token, is not this footer's.
    func testAnInvalidStatusForADifferentPlayAtTheSameSizeIsNotThisPlays() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2), source: source)
        let before = r.status.current()?.text
        source.current = invalid(reason: "insert 2 of 3 failed: somebody else's", requested: 3, built: 1, token: "T-OTHER")
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before, "same size, another play's token: not this play's footer")
        // A failure that names no build at all (an older device, or a failure before any
        // assignment) cannot be matched either, and is never guessed to be this play's.
        source.current = invalid(reason: "insert 2 of 3 failed: unnamed", token: nil)
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before, "no token: not matched")
        // And this play's own failure, still on the status afterwards, is still found.
        source.current = invalid(reason: "insert 2 of 3 failed: boom")
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, "'2018' stopped after 1 of 3 tracks: insert 2 of 3 failed: boom.")
    }

    /// A filled play whose reply carried no `queue_token` has no identity to match: it
    /// watches nothing, and says what it said.
    func testAFilledPlayWhoseReplyCarriedNoTokenIsNotWatched() {
        let source = StatusSource(building)
        let r = playedRig(queueReply: queueReply(filled: 2, token: nil), source: source)
        let before = r.status.current()?.text
        source.current = invalid(reason: "insert 2 of 3 failed: boom")
        poller(routing: r.routing, status: r.status).tick()
        XCTAssertEqual(r.status.current()?.text, before)
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

    // MARK: - one play's footer is never overwritten by another's, in either order (Codex 258728fe B3)

    /// The failure arrives while the play has not yet posted its own "Playing" footer (the
    /// poller runs on its own thread): the correction waits for it, instead of being the older
    /// post and overwritten. The invalid status stays on the wire, so the next poll finds it.
    func testAFailureSeenBeforeThePlaysOwnFooterWaitsForItAndThenCorrectsIt() {
        let source = StatusSource(invalid(reason: "insert 2 of 3 failed: boom"))
        let r = recordedFill(source: source)
        let p = poller(routing: r.routing, status: r.status)
        p.tick()
        XCTAssertNil(r.status.current(), "nothing posted: the play has not posted its footer")
        // The scene posts the play's line, then says so.
        r.status.post("Playing '2018' on SpanDAC \u{2014} 3 tracks, 2 from Apple Music.", untilStateChange: true)
        p.tick()
        XCTAssertEqual(r.status.current()?.text, "Playing '2018' on SpanDAC \u{2014} 3 tracks, 2 from Apple Music.",
                       "the footer is not marked posted until the scene says so: still waiting")
        r.routing.filledFooterPosted(serial: r.serial)
        p.tick()
        XCTAssertEqual(r.status.current()?.text, "'2018' stopped after 1 of 3 tracks: insert 2 of 3 failed: boom.",
                       "the correction is the newer post, and it stays")
    }

    /// A newer play starts between the poller deciding to correct and the post: its serial moved
    /// first, so the older play's failure claims nothing and the newer footer is left alone.
    func testANewerPlayThatStartsBetweenTheCheckAndThePostIsNotOverwritten() {
        let source = StatusSource(invalid(reason: "insert 2 of 3 failed: boom"))
        let r = recordedFill(source: source)
        r.routing.filledFooterPosted(serial: r.serial)
        var newerStarted = false
        let serialBefore = r.routing.playSerial
        let p = poller(routing: r.routing, status: r.status) {
            // Another chosen-music play reaches a branch (its serial moves; it has recorded
            // nothing yet, so the fill is still on record), then posts its own footer.
            try? r.routing.perform(.playlistPlay, expecting: r.routing.stamp, origin: .spandacLibrary,
                                   musicApp: { _ in }, source: { _ in }, unaffected: {})
            r.status.post("Playing 'Newer' on SpanDAC \u{2014} 5 tracks.", untilStateChange: true)
            newerStarted = true
        }
        p.tick()
        XCTAssertTrue(newerStarted)
        XCTAssertEqual(r.routing.playSerial, serialBefore + 1, "the newer play was admitted")
        XCTAssertEqual(r.status.current()?.text, "Playing 'Newer' on SpanDAC \u{2014} 5 tracks.",
                       "the older play's failure did not overwrite the newer play's footer")
        // And it is not delivered later either.
        p.tick()
        XCTAssertEqual(r.status.current()?.text, "Playing 'Newer' on SpanDAC \u{2014} 5 tracks.")
    }

    /// A failure is claimed once, at the moment it posts, so two polls of the same status say it once.
    func testAClaimedFailureIsNotClaimedAgain() {
        let source = StatusSource(invalid(reason: "insert 2 of 3 failed: boom"))
        let r = recordedFill(source: source)
        r.routing.filledFooterPosted(serial: r.serial)
        let failure = r.routing.filledBuildFailure(status: SourceStatus(
            playback: "idle", title: nil, artist: nil, readiness: .ready, queuePhase: "invalid", queueRequested: 3,
            queuePresent: nil, queueReason: "x", queueBuiltBeforeFailure: 1, queueFailedToken: "T-1"))
        let f = try! XCTUnwrap(failure)
        XCTAssertTrue(r.routing.claim(f))
        XCTAssertFalse(r.routing.claim(f))
    }
}

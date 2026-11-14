import XCTest
@testable import music

/// C3: the Playlists tab's preview, tracks level and every play, sourced
/// from Bridge with no join. Uses the shared `BridgeLibraryReadsWire` /
/// `BridgeSelectedFlag` / `playlistsTestScene` / `settleScene` from
/// `BridgeLibraryTestSupport.swift` and `BridgePlaylistsTestSupport.swift`.
///
/// **Width matters here in a way it didn't for C2.** Three-zone layout
/// (>=138 cols) kicks the PREVIEW automatically the instant the rail settles
/// on a row with focus at the rail (C3 item 1) — so any test that scripts
/// `slice.libraryPlaylistTracks` replies for its OWN drill-in or play must
/// either also account for that automatic read, or (simpler, and what most
/// tests below do) run at two-zone width (96-137), which still renders the
/// hero — where most of these assertions live — but never kicks the preview
/// at all. Only the tests that are actually ABOUT the preview, or that need
/// the right-hand PANE (three-zone-only) rendered, use `threeZoneFrame`.
final class BridgePlaylistsPlaySceneTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 30)             // two-zone: hero renders, no preview kick
    private let threeZoneFrame = shellLayout(width: 160, height: 30)    // three-zone: pane renders, preview kicks
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let onePlaylistPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"Chill","kind":"playlist"}],"next_cursor":null}
    """
    private let queueOK = """
    {"ok":true,"op":"slice.queue"}
    """
    private let statusOK = """
    {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
    """

    private func tracksPage(_ items: [(id: String, title: String, artist: String)], total: Int? = nil,
                            skipped: Int = 0, next: String? = nil) -> String {
        let rows = items.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":\(total ?? items.count),
         "items":[\(rows)],"next_cursor":\(nextJSON),"skipped_videos":\(skipped)}
        """
    }

    /// Settles the rail on the one scripted playlist, at the rail focus, at
    /// two-zone width (no automatic preview read).
    private func settledScene(wire: BridgeLibraryReadsWire, flag: BridgeSelectedFlag = BridgeSelectedFlag(true),
                              status: StatusStore = StatusStore(), actions: ActionRunner? = nil) -> PlaylistsScene {
        let s = playlistsTestScene(flag: flag, wire: wire, spy: PlaylistAppleScriptSpy(), status: status,
                                   actions: actions, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") },
                      "the rail never settled on the scripted playlist")
        return s
    }

    /// The tracks walk's `done` flag lands in a SEPARATE drain from the rows
    /// themselves (the background walk sets them under two different lock
    /// acquisitions) — `settleScene` stops ticking the instant its own
    /// condition (the rows rendering) is true, which can be a tick or two
    /// BEFORE `done` lands. A guard keyed on `bridgeTracksDone` (Enter/`p`'s
    /// "still loading" check) needs it too, so this flushes a few more ticks
    /// after the rows are visible.
    private func flushTicks(_ s: PlaylistsScene, count: Int = 20) {
        for _ in 0..<count { _ = s.tick(snapshot: idle); usleep(2_000) }
    }

    // MARK: - The preview (three-zone only — this is what kicks it)

    func testFocusingABridgePlaylistSendsTracksWithItsIdAndLimit50() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")])])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty },
                      "no preview read was ever sent")
        let req = wire.sent("slice.libraryPlaylistTracks").first!
        XCTAssertEqual(req["id"] as? String, "pl1")
        XCTAssertEqual(req["limit"] as? Int, 50)
    }

    func testThePaneShowsTheTitlesAndTheHeroShowsNTracksFromTotal() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")], total: 25)])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Track A") },
                      "the preview pane never showed the title")
        let out = s.render(frame: threeZoneFrame, snapshot: idle)
        XCTAssertTrue(out.contains("Track A") && out.contains("Artist A"))
        XCTAssertTrue(out.contains("25 tracks"), "the hero never showed the total: \(out)")
    }

    func testOnPreviewAndOnTracksStayAtZero() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")])])
        let spy = PlaylistAppleScriptSpy()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy, width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        XCTAssertEqual(spy.count("onPreview"), 0)
        XCTAssertEqual(spy.count("onTracks"), 0)
    }

    func testAtWidth120NoPreviewReadIsSent() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        let s = settledScene(wire: wire)
        // Settle a few more ticks so a (wrongly-sent) preview read would have
        // had time to land.
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").isEmpty, "a preview read was sent at two-zone width")
    }

    // MARK: - The drill-in (two-zone: no automatic preview to account for)

    func testEnterOnTheRailSendsTracksWithLimit500AndNoCursor() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        let req = wire.sent("slice.libraryPlaylistTracks").first!
        XCTAssertEqual(req["limit"] as? Int, 500)
        XCTAssertNil(req["cursor"])
    }

    func testTwoPagesLandingBeforeOneTickBothShow() {
        let page1 = tracksPage([("i.a", "Alpha", "A")], total: 2, next: "c1")
        let page2 = tracksPage([("i.b", "Zulu", "Z")], total: 2)
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.libraryPlaylistTracks": [page1, page2]])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Zulu") },
                      "the second page never landed")
        let out = s.render(frame: threeZoneFrame, snapshot: idle)
        XCTAssertTrue(out.contains("Alpha") && out.contains("Zulu"), "a page was dropped: \(out)")
    }

    func testASecondDrillInOfTheSamePlaylistSendsANewRead() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")]),
                                                     tracksPage([("i.a", "Track A", "Artist A")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.sent("slice.libraryPlaylistTracks").count >= 1 })
        _ = s.handle(.left)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { wire.sent("slice.libraryPlaylistTracks").count >= 2 },
                      "a second drill-in of the same playlist did not send a new read")
    }

    func testAFailedPageTwoReadClearsTheRowsAndShowsTheSentenceAndEnterSendsNoQueue() {
        let page1 = tracksPage([("i.a", "Alpha", "A")], total: 2, next: "c1")
        let failure = """
        {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"upstream","upstream_kind":"other","detail":"Couldn't read that playlist from your library."}}
        """
        // The queue and status are scripted so a play that wrongly went ahead WOULD succeed.
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.libraryPlaylistTracks": [page1, failure],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        let status = StatusStore(); let actions = ActionRunner(status: status)
        let s = settledScene(wire: wire, status: status, actions: actions)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: threeZoneFrame, snapshot: idle).contains("Couldn't read that playlist from your library")
        }, "the failure sentence never showed")
        let out = s.render(frame: threeZoneFrame, snapshot: idle)
        XCTAssertFalse(out.contains("Alpha"), "the first page's row was still shown after the failure: \(out)")

        _ = s.handle(.enter)   // Enter at the tracks level, with the walk failed
        actions.waitUntilIdle()   // any play it queued has run to its end
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "Enter sent a queue after the walk failed")
    }

    // MARK: - Plays (two-zone: isolates the play's own read from the auto-preview)

    func testEnterOnTrackKSendsOneQueueWithRowsKAndOnwardInOrderWithARepeat() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks",
                    [tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art"), ("i.a", "A", "Art")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)   // drill in
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("B") })
        flushTicks(s)
        _ = s.handle(.down)    // track index 1 (0-based), i.e. row 2
        _ = s.handle(.enter)   // play from here
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, "no queue was ever sent")
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual(req["library_ids"] as? [String], ["i.b", "i.a"])
        XCTAssertNil(req["rows"])
        XCTAssertNil(req["ids"])
        // Enter on a specific track row is a chosen start point (Codex's
        // review, Bridge-as-built) — `start_required` must be true.
        XCTAssertEqual(req["start_required"] as? Bool, true)
    }

    func testPAtTheRailSendsAFreshTracksReadBeforeItsQueueEvenWithACachedPreview() {
        // THREE-zone deliberately: this is the one test that wants the
        // preview to have already run, then proves `p` reads again anyway.
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks",
                    [tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art")]),   // the preview's own read
                     tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art")])])  // p's fresh read
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        // Let the preview cache land first.
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        let beforeP = wire.sent("slice.libraryPlaylistTracks").count
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { wire.sent("slice.libraryPlaylistTracks").count > beforeP },
                      "p did not send a fresh read even though a preview was cached")
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual(req["library_ids"] as? [String], ["i.a", "i.b"])
        // `p` at the rail is a whole-collection play — `start_required` must
        // be sent explicitly as `false`, even though the read was fresh.
        XCTAssertEqual(req["start_required"] as? Bool, false)
    }

    func testSSendsTheSameSetOfIds() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.char("s"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual(Set(req["library_ids"] as? [String] ?? []), ["i.a", "i.b"])
        // `s` shuffles the whole playlist, no chosen start row —
        // `start_required` must be sent explicitly as `false`.
        XCTAssertEqual(req["start_required"] as? Bool, false)
    }

    func testPAtTheTracksLevelWhenTheWalkIsDoneSendsNoNewRead() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("B") })
        flushTicks(s)
        let readsBeforeP = wire.sent("slice.libraryPlaylistTracks").count
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertEqual(wire.sent("slice.libraryPlaylistTracks").count, readsBeforeP,
                       "p at the tracks level, walk done, sent a new read")
    }

    // MARK: - F4/C4: `for_queue` on the fresh whole-playlist play walk

    /// The rail `p` walk is exactly the read `playBridgePlaylist` sends when
    /// there are no cached rows (the branch this whole step is scoped to) —
    /// every page of it must carry `for_queue: true`, not just the first.
    func testPAtTheRailSendsForQueueTrueOnEveryPageOfItsFreshRead() {
        let page1 = tracksPage([("i.a", "Alpha", "A")], total: 2, next: "c1")
        let page2 = tracksPage([("i.b", "Zulu", "Z")], total: 2)
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [page1, page2])
        let s = settledScene(wire: wire)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { wire.sent("slice.libraryPlaylistTracks").count >= 2 },
                      "the second page of the fresh walk never landed")
        for req in wire.sent("slice.libraryPlaylistTracks") {
            XCTAssertEqual(req["for_queue"] as? Bool, true, "a page of p's fresh read did not carry for_queue:true")
        }
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
    }

    /// A page-1 `too_large` refusal (Bridge's F4 wire behaviour) must reach
    /// the footer verbatim through the existing `walkError` path, with no
    /// second page read and — because the whole action throws before ever
    /// building the id list — no `slice.queue` sent at all.
    func testPageOneTooLargeRefusalReachesTheFooterVerbatimWithNoSecondPageAndNoQueue() {
        let sentence = "'Chill' has 767 songs SpanDAC can play, which is more than the 100 SpanDAC can queue."
        let refusal = """
        {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"too_large","detail":"\(sentence)"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [refusal])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text == sentence },
                      "got: \(String(describing: status.current()?.text))")
        XCTAssertEqual(wire.sent("slice.libraryPlaylistTracks").count, 1,
                       "a page-1 too_large refusal must not be followed by a second page read")
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "a page-1 too_large refusal must never reach slice.queue")
    }

    /// The preview kick (limit 50, three-zone auto-read) is not the fresh
    /// whole-playlist play walk and must carry no `for_queue` at all.
    func testThePreviewReadCarriesNoForQueue() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")])])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        let req = wire.sent("slice.libraryPlaylistTracks").first!
        XCTAssertEqual(req["limit"] as? Int, 50)
        XCTAssertNil(req["for_queue"], "the preview read must not carry for_queue")
    }

    /// The drill-in feed (Enter on the rail) is not the fresh whole-playlist
    /// play walk either, and must carry no `for_queue`.
    func testTheDrillInFeedCarriesNoForQueue() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "Track A", "Artist A")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        let req = wire.sent("slice.libraryPlaylistTracks").first!
        XCTAssertEqual(req["limit"] as? Int, 500)
        XCTAssertNil(req["for_queue"], "the drill-in read must not carry for_queue")
    }

    /// Against a fake OLDER Bridge — one that answers a normal page and never
    /// even looks at the extra key, exactly what a synthesized `Decodable`
    /// dropping an unknown field produces — `p` still sends `for_queue` (the
    /// client is unconditional about it) and still queues normally: the
    /// client depends on nothing Bridge does with the field, only on what it
    /// sends.
    func testAgainstAFakeOldBridgeThatIgnoresForQueuePStillQueuesNormally() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art"), ("i.b", "B", "Art")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let read = wire.sent("slice.libraryPlaylistTracks").first!
        XCTAssertEqual(read["for_queue"] as? Bool, true)
        let queueReq = wire.sent("slice.queue").first!
        XCTAssertEqual(queueReq["library_ids"] as? [String], ["i.a", "i.b"])
        XCTAssertEqual(queueReq["start_required"] as? Bool, false)
    }

    // MARK: - Refusals and failures

    func test101RowPlaylistSendsAll101IdsAndBridgesOver100SentenceReachesTheFooterVerbatim() {
        let ids = (1...101).map { "i.\($0)" }
        let refusal = """
        {"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in SpanDAC; 101 were requested."}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.queue": [refusal]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage(ids.map { ($0, $0, "Art") })])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual((req["library_ids"] as? [String])?.count, 101)
        XCTAssertEqual(req["start_required"] as? Bool, false,
                       "a whole-playlist `p` must send start_required explicitly as false")
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "A queue holds at most 100 songs in SpanDAC; 101 were requested."
        }, "the over-100 sentence never reached the footer verbatim: \(String(describing: status.current()?.text))")
    }

    func testRepeatedTitleReachesTheFooterInBridgesWords() {
        let refusal = """
        {"ok":false,"op":"slice.queue","error":{"kind":"repeated_title","detail":"That playlist holds one song twice, so SpanDAC can't play it."}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.queue": [refusal]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art"), ("i.a", "A", "Art")])])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "That playlist holds one song twice, so SpanDAC can't play it."
        })
    }

    func testUnsupportedItemAndNotInLibraryOnADrillInShowInThePaneAndPSendsNoQueue() {
        for (kind, detail) in [("unsupported_item", "1 of 5 items in that playlist aren't songs, and SpanDAC plays only songs."),
                               ("not_in_library", "1 of 4 tracks in that playlist aren't in your library, so SpanDAC can't play them.")] {
            let failure = """
            {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"\(kind)","detail":"\(detail)"}}
            """
            // The queue and status are scripted so a play that wrongly went ahead WOULD succeed.
            let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                               "slice.libraryPlaylistTracks": [failure],
                                               "slice.queue": [queueOK], "slice.status": [statusOK]])
            wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
            let status = StatusStore(); let actions = ActionRunner(status: status)
            let s = settledScene(wire: wire, status: status, actions: actions)
            _ = s.handle(.enter)
            XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains(detail) },
                          "kind \(kind) never showed")
            _ = s.handle(.char("p"))
            actions.waitUntilIdle()   // any play it queued has run to its end
            XCTAssertTrue(wire.sent("slice.queue").isEmpty, "kind \(kind): p sent a queue after the drill-in failed")
        }
    }

    func testAnEmptyPlaylistRefusesWithNoQueue() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([])])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text == "'Chill' has no songs SpanDAC can play." })
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
    }

    // MARK: - Skipped videos (Revision 3, D11)

    func testAPageWithTotal40AndSkippedVideos2ShowsInTheHeroAndThePane() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        // Three-zone: the preview consumes the first scripted reply, the
        // drill-in the second — both carry the same total/skipped so either
        // one landing satisfies the hero assertion.
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2),
                                                     tracksPage(songs, total: 40, skipped: 2)])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 160)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Chill") })
        XCTAssertTrue(settleScene(s) {
            s.render(frame: threeZoneFrame, snapshot: idle).contains("40 tracks \u{00B7} 2 videos skipped")
        }, "the hero never showed the skip suffix")
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: threeZoneFrame, snapshot: idle).contains("Tracks 40 \u{00B7} 2 videos skipped")
        }, "the tracks pane header never showed the skip suffix")
    }

    func testPOnItSendsThe40SongIdsInOrderAndTheFooterMatches() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual((req["library_ids"] as? [String])?.count, 40)
        XCTAssertEqual(req["library_ids"] as? [String], songs.map(\.0))
        XCTAssertEqual(req["start_required"] as? Bool, false,
                       "a whole-playlist `p` must send start_required explicitly as false")
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 40 of 42 from 'Chill' on SpanDAC: 2 videos skipped."
        }, "got: \(String(describing: status.current()?.text))")
    }

    func testEnterOnTrack5SendsRows5Through40AndTheFooterMatches() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        // Two-zone: no preview, so the one scripted reply is the drill-in's own.
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.enter)   // drill in
        // Wait for the drill-in's rows to be INSTALLED (the tracks pane header
        // carries the drained total/skipped), not merely for the request to be
        // sent, then flush the walk's separate `done`.
        XCTAssertTrue(settleScene(s) {
            s.render(frame: threeZoneFrame, snapshot: idle).contains("Tracks 40 \u{00B7} 2 videos skipped")
        }, "the tracks pane never showed its loaded header")
        flushTicks(s)
        for _ in 0..<4 { _ = s.handle(.down) }   // cursor at row index 4 -> track 5
        let selected = "\(ANSICode.inverse)05  Track 5"
        XCTAssertTrue(s.render(frame: threeZoneFrame, snapshot: idle).contains(selected),
                      "track 5 is not the selected row before Enter")
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        guard let req = wire.sent("slice.queue").first else { XCTFail("no slice.queue was sent"); return }
        XCTAssertEqual((req["library_ids"] as? [String])?.count, 36)
        XCTAssertEqual(req["library_ids"] as? [String], songs[4...].map(\.0))
        // Enter on track 5 is a chosen start point — `start_required` must
        // be true.
        XCTAssertEqual(req["start_required"] as? Bool, true)
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 'Chill' on SpanDAC from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped."
        }, "got: \(String(describing: status.current()?.text))")
    }

    // MARK: - songs the output's library does not hold (2026-11-11)
    //
    // The output SpanDAC may be a phone whose library lacks songs the Mac's has.
    // The playlist play asks it to leave those out, and says how many it did.

    private func queueReply(skippedNotInLibrary: Int?) -> String {
        let field = skippedNotInLibrary.map { ",\"skipped_not_in_library\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":0\(field)}"
    }

    func testPOnAPlaylistAsksTheOutputToSkipSongsNotInItsLibraryAndLeadsTheFooterWithTheCount() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedNotInLibrary: 12)], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual(req["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(req["start_required"] as? Bool, false)
        XCTAssertEqual((req["library_ids"] as? [String])?.count, 40, "every id is still sent: the output decides")
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Skipped 12 not in your library \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 28 tracks."
        }, "got: \(String(describing: status.current()?.text))")
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true,
                       "something was left out: the line stays")
    }

    func testEnterOnATrackAsksToSkipToo_StartRequiredStaysAsComputed() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedNotInLibrary: 1)], "slice.status": [statusOK]])
        wire.stickyStatus = true
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Tracks 40") })
        flushTicks(s)
        for _ in 0..<4 { _ = s.handle(.down) }
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual(req["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(req["start_required"] as? Bool, true)
        XCTAssertEqual(req["library_ids"] as? [String], songs[4...].map(\.0))
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Skipped 1 not in your library \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 35 tracks."
        }, "got: \(String(describing: status.current()?.text))")
    }

    /// The Mac's own read already left some out (its count rides with the rows);
    /// the output leaves out more. They are different songs, so the line adds them.
    func testTheOutputsCountAddsToTheOnesTheReadAlreadySkipped() {
        let songs = (1...10).map { ("i.\($0)", "Track \($0)", "Art") }
        let page = """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":10,
         "items":[\(songs.map { "{\"id\":\"\($0.0)\",\"title\":\"\($0.1)\",\"artist\":\"Art\",\"kind\":\"song\"}" }.joined(separator: ","))],
         "next_cursor":null,"skipped_videos":0,"skipped_not_in_library":2}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedNotInLibrary: 3)], "slice.status": [statusOK]])
        wire.stickyStatus = true
        wire.script("slice.libraryPlaylistTracks", [page])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Skipped 5 not in your library \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 7 tracks."
        }, "got: \(String(describing: status.current()?.text))")
    }

    /// An older SpanDAC ignores the field and sends no count: today's line.
    func testAReplyWithoutTheCountLeavesTodaysLine() {
        let songs = (1...10).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedNotInLibrary: nil)], "slice.status": [statusOK]])
        wire.stickyStatus = true
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 10)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(settleScene(s) { status.current()?.text == "Playing 'Chill' on SpanDAC \u{2014} 10 tracks." },
                      "got: \(String(describing: status.current()?.text))")
    }

    // MARK: - a repeated song is asked for once BY THE OUTPUT (2026-11-12)
    //
    // The output SpanDAC refuses a list in which one id appears twice, or two
    // different ids share a title (exact, case-sensitive; the artist does not
    // count). Only the device knows which copy it can resolve and play, so the
    // client sends EVERY row and asks (`skip_repeated: true`); the device keeps
    // the first copy that survived everything else and says how many it dropped
    // (`skipped_repeated`). The footer says it as `repeatedSongsNotice` does.

    private func queueReply(skippedNotInLibrary: Int?, skippedRepeated: Int?) -> String {
        let a = skippedNotInLibrary.map { ",\"skipped_not_in_library\":\($0)" } ?? ""
        let b = skippedRepeated.map { ",\"skipped_repeated\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":0\(a)\(b)}"
    }

    /// Plays `rows` from the rail (`p`), or from track `fromTrack` (Enter), with
    /// the output's reply saying it left out `outputNotInLibrary` and
    /// `outputRepeated`; returns what was sent, the recorded rows and the footer.
    private func playForRepeats(rows: [(id: String, title: String, artist: String)], fromTrack: Int? = nil,
                                skipped: Int = 0, outputNotInLibrary: Int? = nil, outputRepeated: Int? = nil,
                                file: StaticString = #filePath, line: UInt = #line)
        -> (request: [String: Any]?, recorded: [String], footer: String?, stays: Bool?, sentCount: Int) {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedNotInLibrary: outputNotInLibrary,
                                                                      skippedRepeated: outputRepeated)],
                                           "slice.status": [statusOK]])
        wire.stickyStatus = true
        wire.script("slice.libraryPlaylistTracks", [tracksPage(rows, total: rows.count, skipped: skipped)])
        let status = StatusStore()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120, routing: routing)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") }, file: file, line: line)
        if let fromTrack {
            _ = s.handle(.enter)
            XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("Tracks \(rows.count)") },
                          file: file, line: line)
            flushTicks(s)
            for _ in 1..<fromTrack { _ = s.handle(.down) }
            _ = s.handle(.enter)
        } else {
            _ = s.handle(.char("p"))
        }
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, file: file, line: line)
        // Let the footer land.
        _ = settleScene(s) { status.current()?.text.contains("Playing") == true }
        let recorded = routing.spanDACPlay()?.rows.map(\.id) ?? []
        let sentIDs = wire.sent("slice.queue").first?["library_ids"] as? [String]
        return (wire.sent("slice.queue").first, recorded, status.current()?.text,
                status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, sentIDs?.count ?? 0)
    }

    func testEveryRowIsSentAndBothFlagsRideOnThePlaylistPlayAndTheFooterSaysTheDevicesCount() {
        let rows = [("i.1", "Slow Fade", "Daniel Avery"), ("i.2", "B", "Art"),
                    ("i.3", "Slow Fade", "Daniel Avery"), ("i.1", "Slow Fade", "Daniel Avery")]
        let r = playForRepeats(rows: rows, outputRepeated: 2)
        XCTAssertEqual(r.request?["library_ids"] as? [String], ["i.1", "i.2", "i.3", "i.1"],
                       "the client never drops a repeat: the device knows which copy it can play")
        XCTAssertEqual(r.request?["skip_repeated"] as? Bool, true)
        XCTAssertEqual(r.request?["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(r.recorded, ["i.1", "i.2", "i.3", "i.1"],
                       "Up Next is recorded from the rows sent; the device numbers by request position")
        XCTAssertEqual(r.footer, "Skipped 2 repeats \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 2 tracks.")
        XCTAssertEqual(r.stays, true)
    }

    func testAListWithNoRepeatsSendsAndSaysWhatItDidBeforeAndAnOlderDeviceSendsNoCount() {
        let rows = (1...5).map { ("i.\($0)", "Track \($0)", "Art") }
        let r = playForRepeats(rows: rows)
        XCTAssertEqual(r.request?["library_ids"] as? [String], rows.map(\.0))
        XCTAssertEqual(r.recorded, rows.map(\.0))
        XCTAssertEqual(r.footer, "Playing 'Chill' on SpanDAC \u{2014} 5 tracks.")
        XCTAssertNotEqual(r.stays, true, "nothing was left out: the line expires as it did")
    }

    /// Six song rows and one video: the playlist has 7 members. The device left out
    /// 1 not in its library and 2 repeats; 3 played, of 7, never of 5.
    func testTheVideoFormTotalKeepsEverySongSentAndEveryVideo() {
        let rows = [("i.1", "X", "A"), ("i.2", "Y", "A"), ("i.3", "X", "A"), ("i.4", "Z", "A"),
                    ("i.5", "Z", "A"), ("i.6", "W", "A")]
        let r = playForRepeats(rows: rows, skipped: 1, outputNotInLibrary: 1, outputRepeated: 2)
        XCTAssertEqual(r.sentCount, 6)
        XCTAssertEqual(r.footer, "Skipped 1 not in your library, 2 repeats \u{00B7} "
                                 + "Playing 3 of 7 from 'Chill' on SpanDAC: 1 video skipped.")
        XCTAssertEqual(r.recorded, rows.map(\.0))
    }

    func testAFromRowPlaySendsFromThePickedRowOnAndKeepsStartRequired() {
        let r = playForRepeats(rows: [("i.1", "P", "A"), ("i.2", "X", "A"), ("i.3", "Z", "A"), ("i.4", "X", "A")],
                               fromTrack: 2, outputRepeated: 1)
        XCTAssertEqual(r.request?["library_ids"] as? [String], ["i.2", "i.3", "i.4"])
        XCTAssertEqual(r.request?["start_required"] as? Bool, true)
        XCTAssertEqual(r.request?["skip_repeated"] as? Bool, true)
        XCTAssertEqual(r.recorded, ["i.2", "i.3", "i.4"])
        XCTAssertEqual(r.footer, "Skipped 1 repeat \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 2 tracks.")
    }

    func testBridgePlaylistPlayMessageSaysRepeatsInTheProtectedLeadAndCountsThemOutOfTheNumerator() {
        // No repeats: byte-identical to before (the parameter defaults to 0).
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 0, skippedUnavailable: 1, startAt: 1, shuffle: false),
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 0, skippedUnavailable: 1, skippedRepeated: 0,
                                      startAt: 1, shuffle: false))
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 0, skippedUnavailable: 1, skippedRepeated: 1,
                                      startAt: 1, shuffle: false),
            "Skipped 1 repeat \u{00B7} Playing 'X' on SpanDAC \u{2014} 23 tracks. 1 song isn't available to SpanDAC.")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 53, skippedVideos: 2, skippedUnavailable: 1,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, skippedRepeated: 3, startAt: 1, shuffle: false),
            "Skipped 30 not in your library, 3 repeats \u{00B7} "
            + "Playing 19 of 55 from 'X' on SpanDAC: 2 videos skipped. 1 song isn't available to SpanDAC.")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 40, skippedVideos: 2, skippedUnavailable: 0, skippedRepeated: 1,
                                      startAt: 5, shuffle: false),
            "Skipped 1 repeat \u{00B7} Playing 'X' on SpanDAC from track 5 \u{2014} 39 tracks; "
            + "2 videos in this playlist skipped.")
    }

    /// The footer is cut at `width - 4` and the playlist name is unbounded, so the
    /// repeat sentence leads, after the not-in-library one, never trailing the name.
    /// Both leads together are 68 columns, so both survive from 73 columns up; the
    /// repeat lead alone survives at 50.
    func testTheRepeatDisclosureSurvivesTheFooterCutWithALongPlaylistName() {
        let longName = String(repeating: "A very long playlist name ", count: 6)
        let both = bridgePlaylistPlayMessage(name: longName, queued: 240, skippedVideos: 3, skippedUnavailable: 2,
                                             skippedNotInLibrary: 30, skippedByOutput: 30, skippedRepeated: 1,
                                             startAt: 1, shuffle: false)
        let bothLead = "Skipped 30 not in your library, 1 repeat \u{00B7} "
        let repeatOnly = bridgePlaylistPlayMessage(name: longName, queued: 240, skippedVideos: 3, skippedUnavailable: 2,
                                                   skippedRepeated: 1, startAt: 1, shuffle: false)
        let repeatLead = "Skipped 1 repeat \u{00B7} "
        XCTAssertTrue(both.hasPrefix(bothLead), both)
        XCTAssertTrue(repeatOnly.hasPrefix(repeatLead), repeatOnly)
        for width in [50, 73, 80, 120] {
            let cut = max(1, shellLayout(width: width, height: 30).width - 4)
            XCTAssertTrue(truncText(both, to: cut).hasPrefix(bothLead), "both counts at \(width) columns")
        }
        for width in [50, 80] {
            let cut = max(1, shellLayout(width: width, height: 30).width - 4)
            XCTAssertTrue(truncText(repeatOnly, to: cut).hasPrefix(repeatLead), "repeats alone at \(width) columns")
        }
        // At 50 columns both leads do not fit in one line; the not-in-library one,
        // first since 2026-11-07, is the one that stays whole.
        let cut50 = max(1, shellLayout(width: 50, height: 30).width - 4)
        XCTAssertTrue(truncText(both, to: cut50).hasPrefix(bothLead), "the whole compact lead survives at 50 columns")
    }

    /// The footer the scene really posts with both counts from the device, cut at
    /// the shell's footer width (`frame.width - 4`, Shell.swift) at the narrowest
    /// width that holds both leads, with a long playlist name.
    func testThePostedFooterWithBothCountsKeepsTheRepeatDisclosureWhenCutAtTheNarrowestWidthThatHoldsBothLeads() {
        let rows = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let r = playForRepeats(rows: rows, outputNotInLibrary: 30, outputRepeated: 1)
        let lead = "Skipped 30 not in your library, 1 repeat \u{00B7} "
        XCTAssertEqual(r.footer, lead + "Playing 'Chill' on SpanDAC \u{2014} 9 tracks.")
        XCTAssertEqual(lead.count, 43)
        let width = lead.count + 5
        let cut = max(1, shellLayout(width: width, height: 30).width - 4)
        XCTAssertEqual(truncText(r.footer ?? "", to: cut), String((lead + "Playing").prefix(cut - 1)) + "\u{2026}",
                       "at \(width) columns the footer reads exactly the two leads, then an ellipsis")
        XCTAssertTrue(truncText(r.footer ?? "", to: cut).contains("1 repeat"))
    }

    /// 2026-11-12 (Anthony 10:59): one compact lead that counts entries and claims
    /// nothing about "plays once".
    func testTheSkipLeadHasThreeFormsAndSingularAndPluralForBothParts() {
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 30, repeated: 1), "Skipped 30 not in your library, 1 repeat \u{00B7} ")
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 1, repeated: 2), "Skipped 1 not in your library, 2 repeats \u{00B7} ")
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 30, repeated: 0), "Skipped 30 not in your library \u{00B7} ")
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 0, repeated: 1), "Skipped 1 repeat \u{00B7} ")
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 0, repeated: 2), "Skipped 2 repeats \u{00B7} ")
        XCTAssertEqual(bridgeSkipLead(notInLibrary: 0, repeated: 0), "")
        XCTAssertEqual(bridgeNotInLibraryPrefix(3), "Skipped 3 not in your library \u{00B7} ")
    }

    func testThreeCopiesOfOneSongReadAsTwoRepeatsNotTwoRepeatedSongs() {
        let rows = [("i.1", "Slow Fade", "A"), ("i.1", "Slow Fade", "A"), ("i.1", "Slow Fade", "A")]
        let r = playForRepeats(rows: rows, outputRepeated: 2)
        XCTAssertEqual(r.footer, "Skipped 2 repeats \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 1 tracks.")
    }

    func testTheCombinedLeadWithVideos() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "Chill", queued: 6, skippedVideos: 1, skippedUnavailable: 0,
                                      skippedNotInLibrary: 1, skippedByOutput: 1, skippedRepeated: 2, startAt: 1, shuffle: false),
            "Skipped 1 not in your library, 2 repeats \u{00B7} Playing 3 of 7 from 'Chill' on SpanDAC: 1 video skipped.")
    }

    // MARK: - Addendum U: unavailable songs, end to end (U-R5/U-R6)

    private func queueReply(skippedUnavailable: Int) -> String {
        "{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":\(skippedUnavailable)}"
    }

    /// The full wire-to-footer path for a playlist play that has BOTH a
    /// video skip (D11) and an unavailable song (Addendum U) — the two
    /// notices must compose, not one replace the other.
    func testPOnAPlaylistWithBothAVideoSkipAndAnUnavailableSongComposesBothNotices() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueReply(skippedUnavailable: 1)], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        // The client still SENDS every id it resolved (U-R3's drop happens on
        // Bridge, not here) — only the displayed count and the footer change.
        XCTAssertEqual((wire.sent("slice.queue").first?["library_ids"] as? [String])?.count, 40)
        // `p` is a whole-collection play — no chosen start row — so
        // `start_required` is sent explicitly as `false` (Codex's review
        // f70150a0: Bridge now refuses an absent field as legacy).
        XCTAssertEqual(wire.sent("slice.queue").first?["start_required"] as? Bool, false)
        // The denominator is the ORIGINAL whole-playlist count (40 songs + 2
        // videos = 42), never reduced by skippedUnavailable too.
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 39 of 42 from 'Chill' on SpanDAC: 2 videos skipped. 1 song isn't available to SpanDAC."
        }, "got: \(String(describing: status.current()?.text))")
    }

    /// A reply with no `skipped_unavailable` field (an older Bridge) reads 0
    /// — no notice, and the count is unaffected, for a playlist play with a
    /// video skip already present (so this isolates the ABSENT-field case
    /// from the all-zero case `testWithZeroSkippedTheFooterIsUnchanged` covers).
    func testAQueueReplyWithNoSkippedUnavailableFieldAddsNoNoticeToAVideoSkipPlaylist() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.stickyStatus = true   // a play reads SpanDAC's capabilities before it queues
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 40 of 42 from 'Chill' on SpanDAC: 2 videos skipped."
        }, "got: \(String(describing: status.current()?.text))")
    }

    func testWithOneVideoSkippedTheFooterSaysOneVideo() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "Chill", queued: 24, skippedVideos: 1, skippedUnavailable: 0, startAt: 1, shuffle: false),
            "Playing 24 of 25 from 'Chill' on SpanDAC: 1 video skipped.")
    }

    func testWithZeroSkippedTheFooterIsUnchanged() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "Chill", queued: 10, skippedVideos: 0, skippedUnavailable: 0, startAt: 1, shuffle: false),
            "Playing 'Chill' on SpanDAC \u{2014} 10 tracks.")
    }

    func test101SongPlaylistWith2SkippedVideosPOverBoundKeepsBridgesSentenceVerbatimWithNoSkipNotice() {
        let ids = (1...101).map { "i.\($0)" }
        let refusal = """
        {"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in SpanDAC; 101 were requested."}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.queue": [refusal]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage(ids.map { ($0, $0, "Art") }, total: 101, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertEqual((wire.sent("slice.queue").first?["library_ids"] as? [String])?.count, 101)
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "A queue holds at most 100 songs in SpanDAC; 101 were requested."
        }, "got: \(String(describing: status.current()?.text)) — the sentence must be verbatim with no skip notice")
    }

    func testBridgePlaylistPlayMessageAllFormsAndBothPlurals() {
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 1, skippedVideos: 0, skippedUnavailable: 0, startAt: 1, shuffle: false),
                       "Playing 'X' on SpanDAC \u{2014} 1 tracks.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 2, skippedUnavailable: 0, startAt: 1, shuffle: false),
                       "Playing 24 of 26 from 'X' on SpanDAC: 2 videos skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 2, skippedUnavailable: 0, startAt: 1, shuffle: true),
                       "Playing 24 of 26 from 'X' on SpanDAC: 2 videos skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 36, skippedVideos: 2, skippedUnavailable: 0, startAt: 5, shuffle: false),
                       "Playing 'X' on SpanDAC from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 1, skippedVideos: 2, skippedUnavailable: 0, startAt: 40, shuffle: false),
                       "Playing 'X' on SpanDAC from track 40 \u{2014} 1 track; 2 videos in this playlist skipped.")
    }

    /// Addendum U (U-R6): the unavailable-song notice composes AFTER
    /// whatever the video-skip form already produced — for all three forms,
    /// never replacing them. `queued` is the ids SENT; the displayed count
    /// is reduced by `skippedUnavailable` in every form.
    /// The songs SpanDAC left out because they are not in the library
    /// (2026-11-07) lead the line, short: the exact wording, both numbers, and
    /// what follows (the existing line, untouched).
    func testNotInLibraryPrefixWordingAndComposition() {
        XCTAssertEqual(bridgeNotInLibraryPrefix(0), "")
        XCTAssertEqual(bridgeNotInLibraryPrefix(1), "Skipped 1 not in your library \u{00B7} ")
        XCTAssertEqual(bridgeNotInLibraryPrefix(3), "Skipped 3 not in your library \u{00B7} ")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 0, skippedUnavailable: 0, skippedNotInLibrary: 3,
                                      startAt: 1, shuffle: false),
            "Skipped 3 not in your library \u{00B7} Playing 'X' on SpanDAC \u{2014} 24 tracks.")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 2, skippedUnavailable: 1, skippedNotInLibrary: 1,
                                      startAt: 1, shuffle: false),
            "Skipped 1 not in your library \u{00B7} Playing 23 of 26 from 'X' on SpanDAC: 2 videos skipped. "
            + "1 song isn't available to SpanDAC.")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 0, skippedUnavailable: 0, startAt: 1, shuffle: false),
            "Playing 'X' on SpanDAC \u{2014} 24 tracks.", "no skip, no prefix: the old sentence byte for byte")
        // The hand-off report leads every line with it, ahead of "Playing ...".
        var report = HandoffPlayReport()
        report.skippedVideos = 1
        report.skippedNotInLibrary = 2
        report.skippedUnavailable = 1
        report.repeatedSongs = 1
        XCTAssertEqual(report.skipPrefix, "Skipped 2 not in your library \u{00B7} ")
        XCTAssertEqual(report.notice, "1 video skipped. 1 song isn't available to SpanDAC. 1 repeated song plays once.",
                       "the trailing notice no longer carries it")
        XCTAssertEqual(LibraryProvenance.playingOnMusicTUI("X", report: report),
                       "Skipped 2 not in your library \u{00B7} Playing 'X' on MusicTUI. "
                       + "1 video skipped. 1 song isn't available to SpanDAC. 1 repeated song plays once.")
        XCTAssertNil(HandoffPlayReport().notice)
        XCTAssertNil(HandoffPlayReport().skipPrefix)
        XCTAssertFalse(HandoffPlayReport().saysAnything)
        var only = HandoffPlayReport()
        only.skippedNotInLibrary = 1
        XCTAssertNil(only.notice)
        XCTAssertTrue(only.saysAnything, "a skip alone keeps the line until something changes")
    }

    /// The footer is cut at `width - 4` (Shell.swift) and the playlist name is
    /// unbounded. At 50 and 80 columns, with a long name and with videos and
    /// unavailable songs beside the skip: every ordinary line begins with the skip,
    /// and the one line that is a warning (Music didn't confirm the play) keeps its
    /// own first words, the skip following it.
    func testTheFooterCutAt50And80ColumnsKeepsTheSkipFirstExceptOnTheUnconfirmedWarning() {
        let longName = String(repeating: "A very long playlist name ", count: 6)
        let prefix = "Skipped 12 not in your library \u{00B7} "
        var ordinary: [(String, String)] = []
        ordinary.append(("playlist play", bridgePlaylistPlayMessage(name: longName, queued: 240, skippedVideos: 3,
                                                                     skippedUnavailable: 2, skippedNotInLibrary: 12,
                                                                     startAt: 1, shuffle: false)))
        ordinary.append(("whole play", bridgeWholePlayMessage(
            name: longName,
            result: SpanDACPlayResult(queue: .complete(requested: 240, present: nil), skippedUnavailable: 2,
                                      skippedVideos: 3, skippedNotInLibrary: 12, queued: 240, requested: 240,
                                      queueToken: "t"))))
        var report = HandoffPlayReport()
        report.skippedVideos = 3
        report.skippedUnavailable = 2
        report.skippedNotInLibrary = 12
        ordinary.append(("hand-off", LibraryProvenance.playingOnMusicTUI(longName, report: report)))
        let warning = unconfirmedPlayLine(title: longName, trailer: report.skipTrailer, notice: report.notice)
        XCTAssertTrue(warning.hasPrefix(playNotStartedWarning(longName)), "the warning is first and unchanged")
        XCTAssertTrue(warning.contains(" \u{00B7} skipped 12 songs not in your library"), "the skip follows it")
        XCTAssertEqual(bridgeNotInLibraryTrailer(1), " \u{00B7} skipped 1 song not in your library")
        for width in [50, 80] {
            let frame = shellLayout(width: width, height: 30)
            let cut = max(1, frame.width - 4)
            for (label, line) in ordinary {
                XCTAssertTrue(truncText(line, to: cut).hasPrefix(prefix), "\(label) at \(width) columns")
            }
            let shown = truncText(warning, to: cut)
            XCTAssertTrue(shown.hasPrefix("Play was requested, but Music didn't confirm"),
                          "the warning at \(width) columns showed \(shown)")
            XCTAssertFalse(shown.hasPrefix("Skipped"), "the skip must not push the warning off the footer")
        }
    }

    // MARK: - an accepted queue whose follow-up status read fails (Codex, 2026-11-11)
    //
    // The queue reply is the only place the output's skip counts live. When SpanDAC
    // ACCEPTS the queue and the status read after it fails, the play was started and
    // is unconfirmed: the footer says so (warning first, unchanged in shape) and the
    // counts follow it, instead of an error that hides a play that happened.

    /// Plays `p` on "Chill" with a queue reply carrying the counts and a status that
    /// answers until the queue is served and fails after it. Returns the wire, the
    /// footer and whether it stays.
    private func playWithStatusFailingAfterTheQueue(
        statusAfterQueue: String, rows: [(id: String, title: String, artist: String)]? = nil,
        notInLibrary: Int?, repeated: Int?, unavailable: Int = 0, width: Int = 120,
        file: StaticString = #filePath, line: UInt = #line)
        -> (wire: BridgeLibraryReadsWire, footer: String?, stays: Bool?, recorded: [String], routing: RoutingCoordinator) {
        let songs = rows ?? (1...10).map { ("i.\($0)", "Track \($0)", "Art") }
        let a = notInLibrary.map { ",\"skipped_not_in_library\":\($0)" } ?? ""
        let b = repeated.map { ",\"skipped_repeated\":\($0)" } ?? ""
        let queue = "{\"ok\":true,\"op\":\"slice.queue\",\"queue_token\":\"tok-1\",\"skipped_unavailable\":\(unavailable)\(a)\(b)}"
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.queue": [queue]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: songs.count)])
        // The handler runs under the wire's own lock, so it keeps its own flag instead of
        // asking the wire what it has sent.
        var queueServed = false
        wire.handler = { op, _ in
            if op == "slice.queue" { queueServed = true; return nil }
            guard op == "slice.status" else { return nil }
            // OK until the queue has been served (the play's capability read), failing after.
            return queueServed ? statusAfterQueue : self.statusOK
        }
        let status = StatusStore()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: width, routing: routing)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") }, file: file, line: line)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, file: file, line: line)
        _ = settleScene(s) { status.current()?.text.contains("SpanDAC") == true }
        return (wire, status.current()?.text,
                status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange,
                routing.spanDACPlay()?.rows.map(\.id) ?? [], routing)
    }

    private let statusRefused = """
    {"ok":false,"op":"slice.status","error":{"kind":"player_disconnected","detail":"the player stopped answering"}}
    """

    func testAnAcceptedQueueWhoseStatusReadFailsKeepsBothCountsInAnUnconfirmedFooterAndSendsTheQueueOnce() {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: 3, repeated: 1)
        XCTAssertEqual(r.wire.sent("slice.queue").count, 1, "an accepted queue is never sent again")
        XCTAssertEqual(r.footer, "Play was requested, but SpanDAC didn't confirm 'Chill' started."
                       + " \u{00B7} skipped 3 not in your library, 1 repeat")
        XCTAssertEqual(r.stays, true, "an unconfirmed play's line stays until something changes")
        XCTAssertEqual(r.recorded.count, 10, "the rows sent are still kept for Up Next")
    }

    /// A status as SpanDAC answers it later: the playing row by request index, the token, and NO
    /// `next_rows` (an older device, or one that leaves them out).
    private func laterStatus(title: String, row: Int, token: String?, nextRows: String = "") throws -> SourceStatus {
        let t = token.map { ",\"queue_token\":\"\($0)\"" } ?? ""
        let reply = "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\",\"contract\":3,"
            + "\"authorization\":\"authorized\",\"title\":\"\(title)\",\"artist\":\"Art\",\"row\":\(row)\(nextRows)\(t)}}"
        return try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
    }

    /// Review of 6c6aaba: the rows are kept in REQUEST order so SpanDAC's indices still
    /// land, but when the device skipped songs the sent order is not the player's, and a
    /// later status without `next_rows` must not fall back to "every sent row after this".
    func testAfterAnAcceptedQueueWithSkipsAStatusWithoutNextRowsListsNoSkippedSongAsQueued() throws {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: 3, repeated: 1)
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        XCTAssertEqual(play.rows.count, 10, "request indices are preserved")
        let status = try laterStatus(title: "Track 1", row: 0, token: "tok-1")
        let window = spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                        catalogue: play.catalogue, status: status)
        XCTAssertEqual(window.entries.map(\.name), ["Track 1"], "the playing row only: its successors are unknown")
        // What a later status DOES name is still listed, by request index.
        let named = try laterStatus(title: "Track 1", row: 0, token: "tok-1", nextRows: ",\"next_rows\":[2,5]")
        XCTAssertEqual(spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                          catalogue: play.catalogue, status: named).entries.map(\.name),
                       ["Track 1", "Track 3", "Track 6"])
    }

    /// The same fallback on the CONFIRMED path (a readable status after the queue): the
    /// output's own skip counts make the sent order unreliable there too.
    func testAConfirmedPlayWithOutputSkipsAlsoListsNothingFromAStatusWithoutNextRows() throws {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusOK, notInLibrary: 3, repeated: nil)
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        let status = try laterStatus(title: "Track 1", row: 0, token: "tok-1")
        XCTAssertEqual(spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                          catalogue: play.catalogue, status: status).entries.map(\.name), ["Track 1"])
    }

    /// No skips: the sent order IS the player's, so the fallback stays (nothing regresses).
    func testAPlayWithNoSkipsStillFallsBackToTheSentOrder() throws {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: nil, repeated: nil)
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        let status = try laterStatus(title: "Track 1", row: 0, token: "tok-1")
        XCTAssertEqual(spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                          catalogue: play.catalogue, status: status).entries.count, 10)
    }

    /// The token kept from the unconfirmed play is the one a later jump sends, and the
    /// window the jump's reply draws is gated by it.
    func testTheTokenKeptFromAnUnconfirmedPlayDrivesALaterJumpAndStatus() throws {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: 3, repeated: 1)
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        XCTAssertEqual(play.token, "tok-1", "kept although the status read failed")
        let jumpStatus = "{\"playback\":\"playing\",\"contract\":3,\"authorization\":\"authorized\","
            + "\"title\":\"Track 3\",\"artist\":\"Art\",\"row\":2,\"capabilities\":[\"slice.status\",\"queue.jump\"],"
            + "\"queue_token\":\"tok-1\"}"
        let wire = BridgeLibraryReadsWire(["slice.queueJump": [
            "{\"ok\":true,\"op\":\"slice.queueJump\",\"status\":\(jumpStatus),\"queue_token\":\"tok-1\"}"]])
        wire.handler = { op, _ in
            op == "slice.status" ? "{\"ok\":true,\"op\":\"slice.status\",\"status\":\(jumpStatus)}" : nil
        }
        let client = SourceAppClient(path: "/nonexistent", transport: wire.transport)
        let result = try jumpSpanDACQueue(routing: r.routing, client: client, displayedToken: "tok-1", entryIndex: 3)
        let sent = wire.sent("slice.queueJump").first
        XCTAssertEqual(sent?["queue_token"] as? String, "tok-1")
        XCTAssertEqual(sent?["row"] as? Int, 2, "the request index, whatever the device skipped")
        XCTAssertEqual(spanDACQueueJumpEntries(routing: r.routing, result: result).map(\.name), ["Track 3"],
                       "no skipped song shown as queued after the jump either")
        // A status for another queue is not this play's.
        let other = try laterStatus(title: "Track 1", row: 0, token: "tok-other")
        XCTAssertTrue(spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                         catalogue: play.catalogue, status: other).entries.isEmpty)
    }

    /// Codex for-later (2026-11-13): the token kept from an unconfirmed play must still
    /// work for what a person does next. A queue jump to an Up Next row asks SpanDAC for
    /// that song's request index under the kept token (skipped songs shift nothing), and
    /// a later status naming the token and its `next_rows` lists exactly those rows.
    func testTheRetainedTokenSurvivesALaterQueueJumpAfterAnUnconfirmedPlay() throws {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: 3, repeated: 1)
        XCTAssertTrue(r.footer?.hasPrefix("Play was requested, but SpanDAC didn't confirm") ?? false, "\(String(describing: r.footer))")
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        XCTAssertEqual(play.token, "tok-1", "the unconfirmed play kept the queue reply's token")
        XCTAssertTrue(play.sentOrderUnreliable, "and the sent order is recorded as one that cannot stand in for the queue")

        // SpanDAC answers again: it is playing request row 0 and says which rows follow.
        let playing = """
        {"ok":true,"op":"slice.status","status":{"playback":"playing","title":"Track 1","artist":"Art","contract":3,
         "authorization":"authorized","capabilities":["slice.status","queue.jump"],"row":0,"next_rows":[2,4,6],
         "queue_token":"tok-1","queue":{"phase":"complete","requested":10,"present":6,"index":0}}}
        """
        r.wire.handler = { op, _ in op == "slice.status" ? playing : nil }
        r.wire.script("slice.queueJump", [
            #"{"ok":true,"op":"slice.queueJump","status":{"playback":"playing","title":"Track 5","artist":"Art","contract":3,"authorization":"authorized","row":4,"next_rows":[6],"queue_token":"tok-1"},"queue_token":"tok-1"}"#,
        ])
        let client = SourceAppClient(path: "/nonexistent", transport: r.wire.transport)
        let status = try client.control.status()
        let entries = spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable, status: status).entries
        XCTAssertEqual(entries.map(\.name), ["Track 1", "Track 3", "Track 5", "Track 7"],
                       "the window lists the rows SpanDAC vouched for, by the retained token")
        let target = try XCTUnwrap(entries.first { $0.name == "Track 5" })
        _ = try jumpSpanDACQueue(routing: r.routing, client: client, displayedToken: "tok-1", entryIndex: target.index)
        let jump = try XCTUnwrap(r.wire.sent("slice.queueJump").first)
        XCTAssertEqual(jump["queue_token"] as? String, "tok-1")
        XCTAssertEqual(play.rows[try XCTUnwrap(jump["row"] as? Int)].id, "i.5", "the jump asked for another song than the one shown")
        // A token that is not the kept one is the other queue's, refused and never sent.
        XCTAssertThrowsError(try jumpSpanDACQueue(routing: r.routing, client: client, displayedToken: "tok-other", entryIndex: 2)) {
            XCTAssertEqual(($0 as? ActionError)?.message, sourceChangedNothingPlayed)
        }
        XCTAssertEqual(r.wire.sent("slice.queueJump").count, 1)
    }

    func testTheUnavailableCountSurvivesAFailedStatusReadToo() {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusRefused, notInLibrary: nil,
                                                   repeated: nil, unavailable: 2)
        XCTAssertEqual(r.footer, "Play was requested, but SpanDAC didn't confirm 'Chill' started."
                       + " 2 songs aren't available to SpanDAC.")
        XCTAssertEqual(r.stays, true)
    }

    func testAWarmingStatusAfterAnAcceptedQueueDoesNotReplayTheQueue() {
        let warming = """
        {"ok":false,"op":"slice.status","error":{"kind":"warming","detail":"preparing your library","retry_after":0.5}}
        """
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: warming, notInLibrary: 3, repeated: nil)
        XCTAssertEqual(r.wire.sent("slice.queue").count, 1, "a status that is warming must not re-send an accepted queue")
        XCTAssertEqual(r.footer, "Play was requested, but SpanDAC didn't confirm 'Chill' started."
                       + " \u{00B7} skipped 3 songs not in your library")
    }

    func testAReadableStatusAfterTheQueueStillPostsTheOrdinaryLine() {
        let r = playWithStatusFailingAfterTheQueue(statusAfterQueue: statusOK, notInLibrary: 3, repeated: 1)
        XCTAssertEqual(r.footer, "Skipped 3 not in your library, 1 repeat \u{00B7} Playing 'Chill' on SpanDAC \u{2014} 6 tracks.")
    }

    func testTheUnconfirmedSpanDACWarningKeepsItsFirstWordsAndWhatTheSkipSaysFollowsAt50And80And120Columns() {
        let line = bridgePlaylistPlayUnconfirmedMessage(name: "Chill", skippedVideos: 0, skippedUnavailable: 0,
                                                        skippedNotInLibrary: 3, skippedRepeated: 1)
        for width in [50, 80, 120] {
            let cut = max(1, shellLayout(width: width, height: 30).width - 4)
            let shown = truncText(line, to: cut)
            XCTAssertTrue(shown.hasPrefix("Play was requested, but SpanDAC didn't conf"), "\(width): \(shown)")
            XCTAssertFalse(shown.hasPrefix("Skipped"), "\(width): the skip must not push the warning off")
        }
        // The known limit (ruling 2026-11-07 10:45): the warning fills the footer, so
        // the trailing counts show only where the width holds them.
        XCTAssertFalse(truncText(line, to: 46).contains("repeat"))
        XCTAssertFalse(truncText(line, to: 76).contains("repeat"))
        XCTAssertTrue(truncText(line, to: 116).contains("1 repeat"))
    }

    // MARK: - Large counts in the footer at 50 and 80 columns (2026-11-14)
    //
    // The accepted limit (ruling 2026-11-07 10:45) is that a count may be cut off at 50 and
    // 80 columns. What must not happen is a count cut INSIDE its digits, which reads as a
    // smaller number ("skipped 1" for 1,234).

    /// The footer as the shell draws it: cut at `width - 4` (Shell.swift).
    private func shownFooter(_ line: String, atColumns width: Int) -> String {
        truncFooterText(line, to: max(1, shellLayout(width: width, height: 30).width - 4))
    }

    func testTheLeadWithLargeCountsStaysWholeAt50And80Columns() {
        let line = bridgePlaylistPlayMessage(name: "Chill", queued: 9000, skippedVideos: 0, skippedUnavailable: 0,
                                             skippedNotInLibrary: 1234, skippedRepeated: 56, startAt: 1, shuffle: false)
        let lead = "Skipped 1234 not in your library, 56 repeats \u{00B7} "
        XCTAssertTrue(line.hasPrefix(lead), line)
        for width in [50, 80] {
            XCTAssertTrue(shownFooter(line, atColumns: width).hasPrefix("Skipped 1234 not in your library, 56 repeats"),
                          "\(width): \(shownFooter(line, atColumns: width))")
        }
    }

    func testAnUnconfirmedLineNeverShowsACountCutInsideItsDigits() {
        for name in ["Chill", "Chills", "Chillz", "Chillzz", "Mix", "Roadtrip!"] {
            let line = bridgePlaylistPlayUnconfirmedMessage(name: name, skippedVideos: 0, skippedUnavailable: 0,
                                                            skippedNotInLibrary: 1234, skippedRepeated: 56)
            for width in 50...100 {
                let shown = shownFooter(line, atColumns: width)
                // A digit just before the ellipsis is a number cut short, unless the whole
                // number is there (the cut fell at its end, so it was not cut).
                guard shown.hasSuffix("\u{2026}"), let before = shown.dropLast().last, before.isNumber else { continue }
                let digits = shown.dropLast().reversed().prefix { $0.isNumber }.reversed()
                XCTAssertTrue(["1234", "56"].contains(String(digits)),
                              "\(name) at \(width): \(shown)")
            }
        }
        // The case that was cut inside "1234": five-letter name at 80 columns.
        let line = bridgePlaylistPlayUnconfirmedMessage(name: "Chill", skippedVideos: 0, skippedUnavailable: 0,
                                                        skippedNotInLibrary: 1234, skippedRepeated: 56)
        XCTAssertEqual(shownFooter(line, atColumns: 80),
                       "Play was requested, but SpanDAC didn't confirm 'Chill' started. \u{00B7} skipped \u{2026}")
    }

    func testTruncFooterTextIsTruncTextExceptThatItNeverEndsInsideANumber() {
        XCTAssertEqual(truncFooterText("short", to: 20), "short")
        XCTAssertEqual(truncFooterText("Playing 'Chill' on SpanDAC", to: 12), truncText("Playing 'Chill' on SpanDAC", to: 12))
        XCTAssertEqual(truncFooterText("skipped 1234 songs", to: 11), "skipped \u{2026}")
        XCTAssertEqual(truncFooterText("skipped 1,234 songs", to: 11), "skipped \u{2026}")
        XCTAssertEqual(truncFooterText("skipped 1,234 songs", to: 12), "skipped \u{2026}")
        // At the number's end it is whole, and kept.
        XCTAssertEqual(truncFooterText("skipped 1234 songs", to: 13), "skipped 1234\u{2026}")
        XCTAssertEqual(truncFooterText("skipped 1234 songs", to: 14), "skipped 1234 \u{2026}")
    }

    func testTheSkipTrailerHasFourFormsAndKeepsTheMusicAppFormByteForByte() {
        XCTAssertEqual(bridgeSkipTrailer(notInLibrary: 1, repeated: 0), " \u{00B7} skipped 1 song not in your library")
        XCTAssertEqual(bridgeSkipTrailer(notInLibrary: 12, repeated: 0), " \u{00B7} skipped 12 songs not in your library")
        XCTAssertEqual(bridgeSkipTrailer(notInLibrary: 0, repeated: 2), " \u{00B7} skipped 2 repeats")
        XCTAssertEqual(bridgeSkipTrailer(notInLibrary: 12, repeated: 1),
                       " \u{00B7} skipped 12 not in your library, 1 repeat")
        XCTAssertEqual(bridgeSkipTrailer(notInLibrary: 0, repeated: 0), "")
        XCTAssertEqual(bridgeNotInLibraryTrailer(12), bridgeSkipTrailer(notInLibrary: 12, repeated: 0))
    }

    func testBridgePlaylistPlayMessageComposesWithEveryVideoSkipForm() {
        // v == 0: the plain form, with the notice trailing it.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 0, skippedUnavailable: 1, startAt: 1, shuffle: false),
            "Playing 'X' on SpanDAC \u{2014} 24 tracks. 1 song isn't available to SpanDAC.")
        // v > 0, whole playlist: the "N of M" form. M is the ORIGINAL
        // whole-playlist member count (queued + skippedVideos), never
        // reduced by skippedUnavailable too — 25 + 2 = 27, not 26.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 2, skippedUnavailable: 1, startAt: 1, shuffle: false),
            "Playing 24 of 27 from 'X' on SpanDAC: 2 videos skipped. 1 song isn't available to SpanDAC.")
        // v > 0, from track k: the "from track k" form, with the notice trailing it.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 38, skippedVideos: 2, skippedUnavailable: 2, startAt: 5, shuffle: false),
            "Playing 'X' on SpanDAC from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped. 2 songs aren't available to SpanDAC.")
    }

    /// The songs the OUTPUT left out (`skippedByOutput`) were sent, so they stay in
    /// the whole-playlist denominator; they only leave the played count.
    func testSongsTheOutputSkippedLeaveTheCountButNeverTheTotal() {
        // 53 sent, 30 missing on the phone, 2 videos: 23 played of 55.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 53, skippedVideos: 2, skippedUnavailable: 0,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, startAt: 1, shuffle: false),
            "Skipped 30 not in your library \u{00B7} Playing 23 of 55 from 'X' on SpanDAC: 2 videos skipped.")
        // Plus one unavailable: 22 played, still of 55.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 53, skippedVideos: 2, skippedUnavailable: 1,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, startAt: 1, shuffle: false),
            "Skipped 30 not in your library \u{00B7} Playing 22 of 55 from 'X' on SpanDAC: 2 videos skipped. "
            + "1 song isn't available to SpanDAC.")
        // No videos: the plain line, 23 tracks.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, startAt: 1, shuffle: false),
            "Skipped 30 not in your library \u{00B7} Playing 'X' on SpanDAC \u{2014} 23 tracks.")
        // From a row: the from-track form counts what played.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 40, skippedVideos: 2, skippedUnavailable: 0,
                                      skippedNotInLibrary: 17, skippedByOutput: 17, startAt: 5, shuffle: false),
            "Skipped 17 not in your library \u{00B7} Playing 'X' on SpanDAC from track 5 \u{2014} 23 tracks; "
            + "2 videos in this playlist skipped.")
        // The Mac's own read skips (in skippedNotInLibrary, not skippedByOutput) change nothing but the prefix.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 53, skippedVideos: 2, skippedUnavailable: 0,
                                      skippedNotInLibrary: 35, skippedByOutput: 30, startAt: 1, shuffle: false),
            "Skipped 35 not in your library \u{00B7} Playing 23 of 55 from 'X' on SpanDAC: 2 videos skipped.")
    }

    // MARK: - Warming (two-zone: keeps the scripted warming sequence exclusive to the read under test)

    func testAColdReadWaitsOnTheHintThenPlays() {
        let warming = """
        {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"warming","detail":"preparing your library","retry_after":0.5}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [warming, tracksPage([("i.a", "A", "Art")])])
        let status = StatusStore()
        let releaseRetry = DispatchSemaphore(value: 0)
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, warmUpSleep: { _ in releaseRetry.wait(timeout: .now() + 5) }, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text.contains("will play when it's ready") == true },
                      "the warming status never showed")
        releaseRetry.signal()
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, "the retry never landed and played")
    }

    func testOneThatNeverWarmsGivesUpAfterWaitsSummingToExactly60() {
        let warming = """
        {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let requests = Int(LibraryWarmUp.maxTotalWait / LibraryWarmUp.maxWait) + 1
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.libraryPlaylistTracks": Array(repeating: warming, count: requests)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, warmUpSleep: { _ in }, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text == LibraryWarmUp.gaveUp },
                      "got: \(String(describing: status.current()?.text))")
    }

    /// The budget is shared across the tracks read and the queue: 45s spent
    /// warming on the read leaves only 15s more for a `warming` queue.
    func testTheBudgetIsSharedFortyFiveSecondsOnTheReadLeavesFifteenMore() {
        // 9 waits of 5.0s (clamped to maxWait) = 45s spent on the tracks read.
        let readWarming = """
        {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let queueWarming = """
        {"ok":false,"op":"slice.queue","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let readCount = 9
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [onePlaylistPage],
            "slice.libraryPlaylistTracks": Array(repeating: readWarming, count: readCount) + [tracksPage([("i.a", "A", "Art")])],
            "slice.queue": Array(repeating: queueWarming, count: 10),
        ])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, warmUpSleep: { _ in }, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s, seconds: 5) { status.current()?.text == LibraryWarmUp.gaveUp },
                      "got: \(String(describing: status.current()?.text))")
    }

    // MARK: - Live gate (2026-09-24): filter + warm-up-retry cursor defect

    /// Reproduces the live gate finding exactly: a filter typed while Bridge
    /// is still warming, the 60s warm-up budget gives up, `r` retries, and
    /// the fresh page puts the filter's one match at index 1 — NOT index 0.
    /// `plCursor` indexes the WHOLE unfiltered list directly, so a
    /// bounds-only clamp (`plCursor >= vis.count`) left it sitting at row 0
    /// ("2018") while the rail rendered only the filtered row ("Top 25 Most
    /// Played") with no cursor mark, and the hero/`p` read the wrong row too
    /// (`PlaylistsScene.swift`'s `reclampBridgeCursorToFilter`, called after
    /// both `replace` and `append`, is the fix).
    func testFilterTypedWhileWarmingGiveUpThenRetryLandsCursorOnTheFilteredRowAndPlaysIt() {
        let warming = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let requests = Int(LibraryWarmUp.maxTotalWait / LibraryWarmUp.maxWait) + 1
        let retryPage = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl-2018","title":"2018","kind":"playlist"},
                  {"id":"pl-top25","title":"Top 25 Most Played","kind":"playlist"}],
         "next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": Array(repeating: warming, count: requests)])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 120)

        // Filter typed WHILE Bridge is still warming, before any row exists —
        // committed with Enter (exits typing mode, keeps `filterText`) so the
        // later `r` reaches the retry handler rather than the filter box.
        _ = s.handle(.char("/"))
        for c in "Top 25" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("SpanDAC is still preparing your library - press r to retry")
        }, "it never gave up visibly")

        wire.script("slice.libraryPlaylists", [retryPage])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art")])])
        wire.script("slice.queue", [queueOK])
        wire.script("slice.status", [statusOK])
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") })

        XCTAssertEqual(s.railNamesForTest, ["Top 25 Most Played"], "the filter must still exclude '2018'")
        XCTAssertEqual(s.railCursorForTest, 1,
                       "cursor must land on 'Top 25 Most Played' (index 1), not stay at row 0 ('2018')")
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played"),
                      "the hero must show the filtered row, not '2018'")

        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").contains { ($0["id"] as? String) == "pl-top25" },
                      "p never read the filtered row's own tracks")
        XCTAssertFalse(wire.sent("slice.libraryPlaylistTracks").contains { ($0["id"] as? String) == "pl-2018" },
                       "p read '2018' — the row hidden by the filter — instead of the visible one")
    }

    /// Codex's follow-up (971b9659): `reclampBridgeCursorToFilter`'s
    /// `vis.first ?? 0` fallback, when the filter matches NOTHING, leaves
    /// `plCursor` at the bounds-valid-but-HIDDEN row 0. `currentBridgeRow()`
    /// checked only array bounds, so a zero-match filter still silently
    /// exposed row 0 to the hero, the auto-preview kick, `p`, `s`, Enter and
    /// `→`. Fixed by making `currentBridgeRow()` itself require membership in
    /// `bridgeVisibleIndices()`, not just bounds.
    func testAZeroMatchFilterHidesTheHeroAndBlocksPSEnterAndRight() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        let status = StatusStore(); let actions = ActionRunner(status: status)
        let s = settledScene(wire: wire, status: status, actions: actions)   // rail settled on "Chill" (two-zone: no preview auto-kick)
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Chill"))

        _ = s.handle(.char("/"))
        for c in "zzz-no-match" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)   // commit filter, exit typing mode

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Chill"), "a zero-match filter must hide the hero, not show the hidden row 0")
        XCTAssertEqual(s.railNamesForTest, [])

        let before = wire.requestCount
        _ = s.handle(.char("p"))
        _ = s.handle(.char("s"))
        _ = s.handle(.enter)   // now the drill-in Enter (filtering already false)
        let enterFeed = s.drilledFeedForTest
        _ = s.handle(.right)
        let rightFeed = s.drilledFeedForTest
        // Everything those keys could have started has run to its end: the
        // queued plays, and a tracks walk if a drill-in opened one.
        actions.waitUntilIdle()
        XCTAssertTrue(enterFeed?.waitForWorkersForTest(timeout: 5) ?? true, "a drill-in walk from Enter never finished")
        XCTAssertTrue(rightFeed?.waitForWorkersForTest(timeout: 5) ?? true, "a drill-in walk from → never finished")
        XCTAssertEqual(wire.requestCount, before,
                       "p/s/Enter/→ sent a request against a row the filter hides")
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").isEmpty)
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
    }

    /// The other half of the same fix: once a LATER page (an append, landing
    /// after the first) supplies the filter's first match, that row must
    /// become selectable again — the fix is a strict membership check, not a
    /// blanket "never trust plCursor".
    func testALaterAppendSupplyingTheFirstMatchingRowMakesItSelectable() {
        let page1 = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl-alpha","title":"Alpha","kind":"playlist"}],"next_cursor":"c1"}
        """
        let page2 = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl-zebra","title":"Zebra Point","kind":"playlist"}],"next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [page1, page2]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 120)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Alpha") })
        _ = s.handle(.char("/"))
        for c in "Zebra" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)

        let hidden = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(hidden.contains("Alpha"), "a zero-match filter must hide the hero")
        XCTAssertEqual(s.railNamesForTest, [])

        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art")])])
        wire.script("slice.queue", [queueOK])
        wire.script("slice.status", [statusOK])
        wire.release(op: "slice.libraryPlaylists", at: 1)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Zebra Point") },
                      "the matching row from the appended page never became selectable")
        XCTAssertEqual(s.railNamesForTest, ["Zebra Point"])

        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").contains { ($0["id"] as? String) == "pl-zebra" },
                      "p never acted on the newly-visible appended row")
    }

    // MARK: - Provenance at play time

    func testABridgeRailTheFlagFlippedThenPBeforeAnyTickShowsMusicAppSelectedBridgeList() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        let flag = BridgeSelectedFlag(true)
        let spy = PlaylistAppleScriptSpy()
        let status = StatusStore()
        let s = playlistsTestScene(flag: flag, wire: wire, spy: spy, status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        flag.selected = false   // flip, no tick yet
        let requestsBefore = wire.requestCount
        _ = s.handle(.char("p"))
        XCTAssertEqual(status.current()?.text, LibraryProvenance.musicAppSelectedBridgeList)
        XCTAssertEqual(wire.requestCount, requestsBefore, "the wire saw a request after the mismatch")
        XCTAssertEqual(spy.count("loadMusicAppPlaylists"), 0)
    }

    func testAMusicAppRailWithTheFlagSetThenPBeforeAnyTickShowsBridgeSelectedMusicAppList() {
        let wire = BridgeLibraryReadsWire()
        let flag = BridgeSelectedFlag(false)
        let spy = PlaylistAppleScriptSpy()
        let status = StatusStore()
        let s = playlistsTestScene(flag: flag, wire: wire, spy: spy, status: status, names: ["Music.app Playlist"])
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Music.app Playlist") })
        flag.selected = true   // flip, no tick yet
        _ = s.handle(.char("p"))
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
        XCTAssertEqual(wire.requestCount, 0, "the wire saw a request after the mismatch")
    }

    // MARK: - Music.app mode

    func testMusicAppModePAndEnterReachTheInjectedBackendAndNeverTheWire() {
        let wire = BridgeLibraryReadsWire()
        let spy = PlaylistAppleScriptSpy()
        let status = StatusStore(); let actions = ActionRunner(status: status)
        let s = playlistsTestScene(flag: BridgeSelectedFlag(false), wire: wire, spy: spy, status: status,
                                   names: ["My Playlist"], actions: actions)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("My Playlist") })
        _ = s.handle(.char("p"))
        actions.waitUntilIdle()   // the play it queued has run to its end
        XCTAssertEqual(wire.requestCount, 0, "Music.app mode's p reached the wire")
    }

    // MARK: - Codex before-push: playTrack checks the data selection before any AppleScript read

    /// The residual race the fix closes: the SCENE still thinks MusicTUI's
    /// own data is selected (`makeProvider()` nil, so `railSource == .musicApp`
    /// and Enter routes to `playTrack`), but by the time the action actually
    /// runs on `ActionRunner`'s queue, the coordinator's data selection
    /// already reads SpanDAC (this coordinator predates the data axis, so a
    /// `.source` output carries SpanDAC data) — the source switched in between. `playTrack` must refuse WITHOUT
    /// running `fetchPlaylistTracks`'s AppleScript first; `/usr/bin/true`
    /// alone can't prove that (it "succeeds" either way), so this counts real
    /// invocations with `AppleScriptCallCounter`.
    func testPlayTrackMakesZeroAppleScriptCallsWhenBridgeIsSelectedAtActionExecutionTime() {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)   // routing.mode reads .source when the action finally runs
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent") })
        let counter = AppleScriptCallCounter()
        let sources = PlaylistDataSources(onMeta: { _ in [:] }, onPreview: { _ in nil },
                                          onTracks: { _ in nil }, onArtworkMap: nil)
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let s = PlaylistsScene(backend: counter.backend, routing: routing, playlists: ["Chill"], sources: sources,
                               appQueue: AppQueueStore(), status: status, actions: actions,
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: { nil })   // the SCENE still thinks Music.app is selected — the race
        XCTAssertEqual(s.railSourceForTest, .musicApp)

        _ = s.handle(.enter)   // rail: kicks loadFull (onTracks -> nil, so it lands a fallback empty preview), focus -> .tracks
        // `fullCache[plCursor]` is private; settle by ticking for long enough
        // that the fallback preview (a trivial, synchronous `onTracks` nil)
        // has certainly landed, rather than polling an unobservable field.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            _ = s.tick(snapshot: idle)
            usleep(5_000)
        }
        _ = s.handle(.enter)   // tracks level: playTrack, with routing.mode already .source

        actions.waitUntilIdle()   // the action queue has run playTrack to its end
        XCTAssertEqual(counter.callCount, 0, "playTrack ran an AppleScript call before checking routing.mode")
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
    }

    // MARK: - The tracks feed re-asks a stale reply

    /// A drilled-in tracks pane re-asks like the top-level lists; the cursor
    /// safety of the swap is covered in `BridgePlaylistsTracksReaskTests`.
    func testAFlaggedTracksReplyIsReAskedAndTheFreshOneReplacesIt() {
        let flaggedTracks = """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":1,"stale":true,"refreshing":true,
         "items":[{"id":"i.a","title":"Old","artist":"Art","kind":"song"}],"next_cursor":null,"skipped_videos":0}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage]])
        wire.script("slice.libraryPlaylistTracks", [flaggedTracks, tracksPage([("i.b", "New", "Art")]),
                                                     tracksPage([("i.b", "New", "Art")])])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains("New") },
                      "the fresh tracks never replaced the stale ones")
        XCTAssertEqual(wire.sent("slice.libraryPlaylistTracks").count, 3)
        XCTAssertFalse(s.render(frame: threeZoneFrame, snapshot: idle).contains("Old"))
    }
}

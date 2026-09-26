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
    private func settledScene(wire: BridgeLibraryReadsWire, flag: BridgeSelectedFlag = BridgeSelectedFlag(true)) -> PlaylistsScene {
        let s = playlistsTestScene(flag: flag, wire: wire, spy: PlaylistAppleScriptSpy(), width: 120)
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
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.libraryPlaylistTracks": [page1, failure]])
        let s = settledScene(wire: wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: threeZoneFrame, snapshot: idle).contains("Couldn't read that playlist from your library")
        }, "the failure sentence never showed")
        let out = s.render(frame: threeZoneFrame, snapshot: idle)
        XCTAssertFalse(out.contains("Alpha"), "the first page's row was still shown after the failure: \(out)")

        _ = s.handle(.enter)   // Enter at the tracks level, with the walk failed
        Thread.sleep(forTimeInterval: 0.1)
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
        let sentence = "'Chill' has 767 songs Bridge can play, which is more than the 100 Bridge can queue."
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
        {"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in Bridge; 101 were requested."}}
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
            status.current()?.text == "A queue holds at most 100 songs in Bridge; 101 were requested."
        }, "the over-100 sentence never reached the footer verbatim: \(String(describing: status.current()?.text))")
    }

    func testRepeatedTitleReachesTheFooterInBridgesWords() {
        let refusal = """
        {"ok":false,"op":"slice.queue","error":{"kind":"repeated_title","detail":"That playlist holds one song twice, so Bridge can't play it."}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.queue": [refusal]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage([("i.a", "A", "Art"), ("i.a", "A", "Art")])])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "That playlist holds one song twice, so Bridge can't play it."
        })
    }

    func testUnsupportedItemAndNotInLibraryOnADrillInShowInThePaneAndPSendsNoQueue() {
        for (kind, detail) in [("unsupported_item", "1 of 5 items in that playlist aren't songs, and Bridge plays only songs."),
                               ("not_in_library", "1 of 4 tracks in that playlist aren't in your library, so Bridge can't play them.")] {
            let failure = """
            {"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"\(kind)","detail":"\(detail)"}}
            """
            let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                               "slice.libraryPlaylistTracks": [failure]])
            let s = settledScene(wire: wire)
            _ = s.handle(.enter)
            XCTAssertTrue(settleScene(s) { s.render(frame: threeZoneFrame, snapshot: idle).contains(detail) },
                          "kind \(kind) never showed")
            _ = s.handle(.char("p"))
            Thread.sleep(forTimeInterval: 0.1)
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
        XCTAssertTrue(settleScene(s) { status.current()?.text == "'Chill' has no songs Bridge can play." })
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
            status.current()?.text == "Playing 40 of 42 from 'Chill' on Bridge: 2 videos skipped."
        }, "got: \(String(describing: status.current()?.text))")
    }

    func testEnterOnTrack5SendsRows5Through40AndTheFooterMatches() {
        let songs = (1...40).map { ("i.\($0)", "Track \($0)", "Art") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queueOK], "slice.status": [statusOK]])
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylistTracks").isEmpty })
        for _ in 0..<4 { _ = s.handle(.down) }   // cursor at row index 4 -> track 5
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        let req = wire.sent("slice.queue").first!
        XCTAssertEqual((req["library_ids"] as? [String])?.count, 36)
        XCTAssertEqual(req["library_ids"] as? [String], songs[4...].map(\.0))
        // Enter on track 5 is a chosen start point — `start_required` must
        // be true.
        XCTAssertEqual(req["start_required"] as? Bool, true)
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 'Chill' on Bridge from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped."
        }, "got: \(String(describing: status.current()?.text))")
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
            status.current()?.text == "Playing 39 of 42 from 'Chill' on Bridge: 2 videos skipped. 1 song isn't available to Bridge."
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
        wire.script("slice.libraryPlaylistTracks", [tracksPage(songs, total: 40, skipped: 2)])
        let status = StatusStore()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty })
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 40 of 42 from 'Chill' on Bridge: 2 videos skipped."
        }, "got: \(String(describing: status.current()?.text))")
    }

    func testWithOneVideoSkippedTheFooterSaysOneVideo() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "Chill", queued: 24, skippedVideos: 1, skippedUnavailable: 0, startAt: 1, shuffle: false),
            "Playing 24 of 25 from 'Chill' on Bridge: 1 video skipped.")
    }

    func testWithZeroSkippedTheFooterIsUnchanged() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "Chill", queued: 10, skippedVideos: 0, skippedUnavailable: 0, startAt: 1, shuffle: false),
            "Playing 'Chill' on Bridge \u{2014} 10 tracks.")
    }

    func test101SongPlaylistWith2SkippedVideosPOverBoundKeepsBridgesSentenceVerbatimWithNoSkipNotice() {
        let ids = (1...101).map { "i.\($0)" }
        let refusal = """
        {"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in Bridge; 101 were requested."}}
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
            status.current()?.text == "A queue holds at most 100 songs in Bridge; 101 were requested."
        }, "got: \(String(describing: status.current()?.text)) — the sentence must be verbatim with no skip notice")
    }

    func testBridgePlaylistPlayMessageAllFormsAndBothPlurals() {
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 1, skippedVideos: 0, skippedUnavailable: 0, startAt: 1, shuffle: false),
                       "Playing 'X' on Bridge \u{2014} 1 tracks.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 2, skippedUnavailable: 0, startAt: 1, shuffle: false),
                       "Playing 24 of 26 from 'X' on Bridge: 2 videos skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 24, skippedVideos: 2, skippedUnavailable: 0, startAt: 1, shuffle: true),
                       "Playing 24 of 26 from 'X' on Bridge: 2 videos skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 36, skippedVideos: 2, skippedUnavailable: 0, startAt: 5, shuffle: false),
                       "Playing 'X' on Bridge from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped.")
        XCTAssertEqual(bridgePlaylistPlayMessage(name: "X", queued: 1, skippedVideos: 2, skippedUnavailable: 0, startAt: 40, shuffle: false),
                       "Playing 'X' on Bridge from track 40 \u{2014} 1 track; 2 videos in this playlist skipped.")
    }

    /// Addendum U (U-R6): the unavailable-song notice composes AFTER
    /// whatever the video-skip form already produced — for all three forms,
    /// never replacing them. `queued` is the ids SENT; the displayed count
    /// is reduced by `skippedUnavailable` in every form.
    func testBridgePlaylistPlayMessageComposesWithEveryVideoSkipForm() {
        // v == 0: the plain form, with the notice trailing it.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 0, skippedUnavailable: 1, startAt: 1, shuffle: false),
            "Playing 'X' on Bridge \u{2014} 24 tracks. 1 song isn't available to Bridge.")
        // v > 0, whole playlist: the "N of M" form. M is the ORIGINAL
        // whole-playlist member count (queued + skippedVideos), never
        // reduced by skippedUnavailable too — 25 + 2 = 27, not 26.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 25, skippedVideos: 2, skippedUnavailable: 1, startAt: 1, shuffle: false),
            "Playing 24 of 27 from 'X' on Bridge: 2 videos skipped. 1 song isn't available to Bridge.")
        // v > 0, from track k: the "from track k" form, with the notice trailing it.
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "X", queued: 38, skippedVideos: 2, skippedUnavailable: 2, startAt: 5, shuffle: false),
            "Playing 'X' on Bridge from track 5 \u{2014} 36 tracks; 2 videos in this playlist skipped. 2 songs aren't available to Bridge.")
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
            s.render(frame: frame, snapshot: idle).contains("Bridge is still preparing your library - press r to retry")
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
        let s = settledScene(wire: wire)   // rail settled on "Chill" (two-zone: no preview auto-kick)
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
        _ = s.handle(.right)
        Thread.sleep(forTimeInterval: 0.2)
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
        let s = playlistsTestScene(flag: BridgeSelectedFlag(false), wire: wire, spy: spy, names: ["My Playlist"])
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("My Playlist") })
        _ = s.handle(.char("p"))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(wire.requestCount, 0, "Music.app mode's p reached the wire")
    }

    // MARK: - Codex before-push: playTrack checks routing.mode before any AppleScript read

    /// The residual race the fix closes: the SCENE still thinks Music.app is
    /// selected (`makeProvider()` nil, so `railSource == .musicApp` and Enter
    /// routes to `playTrack`), but by the time the action actually runs on
    /// `ActionRunner`'s queue, `routing.mode` already reads `.source` — the
    /// output flipped to Bridge in between. `playTrack` must refuse WITHOUT
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
        let s = PlaylistsScene(backend: counter.backend, routing: routing, playlists: ["Chill"], sources: sources,
                               appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
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

        Thread.sleep(forTimeInterval: 0.3)   // let the action queue run
        XCTAssertEqual(counter.callCount, 0, "playTrack ran an AppleScript call before checking routing.mode")
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
    }
}

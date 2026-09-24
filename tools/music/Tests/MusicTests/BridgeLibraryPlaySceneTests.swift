import XCTest
@testable import music

/// C3: the Library tab's drill-in, tracks and play, by Bridge ids only — no
/// `(title, artist, album)` join. Uses the shared `BridgeLibraryReadsWire` /
/// `LibraryAppleScriptSpy` / `libraryTestScene` from `BridgeLibraryTestSupport.swift`.
final class BridgeLibraryPlaySceneTests: XCTestCase {

    // >= 138 columns for `.three` zone mode (rail + hero + right pane), so
    // the right pane's track titles are actually rendered — at 100 columns
    // (`.two` mode) the right pane never draws at all, which is not this
    // test's property to prove.
    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],
     "next_cursor":null}
    """
    private func trackReply(_ ids: [String]) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"Radiohead\",\"album\":\"In Rainbows\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(items)]}"
    }
    private static let queued = """
    {"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A",
     "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
    """
    /// Addendum U: the same success reply, with `skipped_unavailable` set.
    /// `Self.queued` above (no field at all) is the "absent -> 0, older
    /// Bridge" case, exercised by every test that already uses it unedited.
    private static func queuedReply(skippedUnavailable: Int) -> String {
        """
        {"ok":true,"op":"slice.queue","skipped_unavailable":\(skippedUnavailable),
         "status":{"playback":"playing","title":"T","artist":"A",
         "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
        """
    }

    private func settleQueued(_ wire: BridgeLibraryReadsWire, seconds: Double = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !wire.sent("slice.queue").isEmpty { return true }
            usleep(5_000)
        }
        return !wire.sent("slice.queue").isEmpty
    }

    // MARK: - Album tracks

    // Named for what the body actually does (drills in via Enter), not
    // "focusing" — the `.three`-zone-mode PROACTIVE preview kick (fired by
    // merely focusing a row while browsing, before any Enter) depends on
    // `ScreenFrame.current()`'s real terminal width, which is test-environment
    // dependent and not this test's to assume; `testAStaleAlbumTracksResult…`
    // below drills in explicitly for the same reason.
    func testDrillingIntoABridgeAlbumSendsLibraryAlbumTracksAndTheSpyIsNeverAsked() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)   // drill into the album's tracks

        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryAlbumTracks").isEmpty })
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").first?["id"] as? String, "al1")
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt1") })
        XCTAssertEqual(spy.count("onAlbumTracks"), 0)
        XCTAssertEqual(spy.count("onAlbumCover"), 0, "Bridge albums must get the gradient, never a cover fetch")
    }

    // MARK: - Album play

    func testEnterOnATrackSendsLibraryIdsFromThatRowOnwardInOrder() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": [Self.queued]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt2") })
        _ = s.handle(.down)     // row 2 (0-indexed cursor 1)
        _ = s.handle(.enter)    // play from row 2 onward

        XCTAssertTrue(settleQueued(wire))
        let req = wire.sent("slice.queue").first
        XCTAssertEqual(req?["library_ids"] as? [String], ["t2", "t3"])
        XCTAssertNil(req?["rows"], "the join's row shape must never be sent")
        XCTAssertNil(req?["ids"], "the catalogue-id shape must never be sent")
        // Enter on a specific track row is a chosen start point (Codex's
        // review, Bridge-as-built) — `start_required` must be true.
        XCTAssertEqual(req?["start_required"] as? Bool, true)
    }

    func testPOnTheAlbumRailSendsEveryId() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": [Self.queued]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))

        XCTAssertTrue(settleQueued(wire))
        let req = wire.sent("slice.queue").first
        XCTAssertEqual(req?["library_ids"] as? [String], ["t1", "t2", "t3"])
        // `p` on the rail is a whole-collection play, no chosen start row —
        // `start_required` must be sent explicitly as `false` (Codex's
        // review f70150a0: an absent field is now treated as legacy and
        // refused, so omission is no longer valid).
        XCTAssertEqual(req?["start_required"] as? Bool, false)
    }

    func testSOnTheAlbumRailSendsTheSameSetInSomeOrder() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": [Self.queued]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("s"))

        XCTAssertTrue(settleQueued(wire))
        let req = wire.sent("slice.queue").first
        let ids = req?["library_ids"] as? [String] ?? []
        XCTAssertEqual(Set(ids), Set(["t1", "t2", "t3"]))
        // `s` shuffles the whole rail's collection, no chosen start row —
        // `start_required` must be sent explicitly as `false`.
        XCTAssertEqual(req?["start_required"] as? Bool, false)
    }

    // MARK: - Addendum U: unavailable songs (U-R5/U-R6)

    func testPOnAnAlbumWithOneUnavailableSongReducesTheCountAndAppendsTheSingularNotice() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": [Self.queuedReply(skippedUnavailable: 1)],
                                          "slice.status": [Self.queued]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleQueued(wire))
        // library_ids still carries every row the client sent (U-R3's drop
        // happens on Bridge, not here) — the client only reduces the COUNT
        // it displays and appends the notice.
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "t3"])
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 'In Rainbows' on Bridge \u{2014} 2 tracks. 1 song isn't available to Bridge."
        }, "got: \(String(describing: status.current()?.text))")
    }

    func testPOnAnArtistWithTwoUnavailableSongsAppendsThePluralNotice() {
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let songs = trackReply(["t1", "t2", "t3", "t4"]).replacingOccurrences(of: "libraryAlbumTracks", with: "libraryArtistSongs")
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
                                          "slice.libraryArtistSongs": [songs],
                                          "slice.queue": [Self.queuedReply(skippedUnavailable: 2)],
                                          "slice.status": [Self.queued]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleQueued(wire))
        // Artists have no track-level entry point — `p` here is always a
        // whole-collection play, so `start_required` must be sent explicitly
        // as `false`.
        XCTAssertEqual(wire.sent("slice.queue").first?["start_required"] as? Bool, false)
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 'Radiohead' on Bridge \u{2014} 2 tracks. 2 songs aren't available to Bridge."
        }, "got: \(String(describing: status.current()?.text))")
    }

    /// A reply with NO `skipped_unavailable` field at all (an older Bridge,
    /// or simply nothing to report) reads 0 — the count and the sentence stay
    /// exactly what they were before Addendum U.
    func testAReplyWithNoSkippedUnavailableFieldShowsNoNoticeAndTheFullCount() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": [Self.queued],
                                          "slice.status": [Self.queued]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleQueued(wire))
        XCTAssertTrue(settleScene(s) {
            status.current()?.text == "Playing 'In Rainbows' on Bridge \u{2014} 3 tracks."
        }, "got: \(String(describing: status.current()?.text))")
    }

    // MARK: - Failures

    func testAFailedTracksReadShowsBridgesSentenceInThePane() {
        let noAccess = """
        {"ok":false,"op":"slice.libraryAlbumTracks","error":{"kind":"unauthorized","detail":"no access"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage], "slice.libraryAlbumTracks": [noAccess]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)

        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Bridge has not been granted Apple Music access")
        }, "the pane never showed Bridge's own sentence")
    }

    func testAnEmptyAlbumRefusesWithNoQueue() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": ["""
                                          {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,"items":[]}
                                          """]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { usleep(10_000) }
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "an empty album sent a queue")
    }

    // MARK: - Artist drill-in and play

    func testEnterOnABridgeArtistSendsLibraryArtistAlbumsAndTheSpyIsNeverAsked() {
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let artistAlbums = """
        {"ok":true,"op":"slice.libraryArtistAlbums","generation":3,
         "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}]}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage], "slice.libraryArtistAlbums": [artistAlbums]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.enter)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        XCTAssertEqual(wire.sent("slice.libraryArtistAlbums").first?["id"] as? String, "ar1")
        XCTAssertEqual(spy.count("onArtistAlbums"), 0)
    }

    func testPOnABridgeArtistSendsLibraryArtistSongsThenQueue() {
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let songs = trackReply(["t1", "t2"]).replacingOccurrences(of: "libraryAlbumTracks", with: "libraryArtistSongs")
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
                                          "slice.libraryArtistSongs": [songs],
                                          "slice.queue": [Self.queued]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))

        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryArtistSongs").isEmpty })
        XCTAssertTrue(settleQueued(wire))
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2"])
    }

    func testTooLargeReachesTheFooterVerbatimAndNoQueueIsSent() {
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let tooLarge = """
        {"ok":false,"op":"slice.libraryArtistSongs",
         "error":{"kind":"too_large","detail":"Radiohead has more than 100 songs, which is more than Bridge can queue."}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage], "slice.libraryArtistSongs": [tooLarge]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))

        XCTAssertTrue(settleScene(s) { status.current()?.text != nil })
        XCTAssertEqual(status.current()?.text,
                       "Radiohead has more than 100 songs, which is more than Bridge can queue.")
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "too_large still sent a queue")
    }

    // MARK: - A Bridge refusal reaches the footer in its own words
    // (moved here from BridgeCollectionCallSiteTests, C3 item 8)

    func testABridgeQueueRefusalReachesTheFooterInItsOwnWords() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                          "slice.queue": ["""
                                          {"ok":false,"op":"slice.queue","error":{"kind":"repeated_title",
                                           "detail":"another song titled 'T' is playing or queued"}}
                                          """]])
        let status = StatusStore()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))

        XCTAssertTrue(settleScene(s) { status.current()?.text != nil })
        let text = status.current()?.text ?? ""
        XCTAssertTrue(text.contains("another song titled 'T' is playing or queued"),
                      "Bridge's own reason was lost; got: \(text)")
        XCTAssertNotEqual(text, "Play failed.")
        XCTAssertEqual(status.current()?.isError, true)
    }

    // MARK: - Provenance at play time

    func testAListFlippedToMusicAppBeforeAnyTickRefusesWithMusicAppSelectedBridgeList() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                          "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])]])
        let spy = LibraryAppleScriptSpy()
        let flag = BridgeSelectedFlag(true)
        let status = StatusStore()
        let s = libraryTestScene(flag: flag, wire: wire, spy: spy, status: status)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })

        flag.selected = false   // output flips to Music.app, before any further tick
        _ = s.handle(.char("p"))   // dispatch reads `currentAlbumSource`/`makeProvider()` fresh at keypress

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { usleep(10_000) }
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "a play reached Bridge after the flip")
        XCTAssertEqual(spy.count("onAlbumTracks") + spy.count("onAlbums"), 0,
                      "a play ran AppleScript instead of refusing")
    }

    // MARK: - Provenance/epoch on the track and artist-albums inboxes
    // (Codex before-push review, 2026-09-23)

    /// An album-tracks fetch kicked while Bridge was selected, gated so it is
    /// still in flight when the output switches away and back, must be
    /// dropped when it finally lands — even though the SAME album id is
    /// reopened under the fresh output and a FRESH fetch for that same id
    /// has already landed by then. Before the epoch tag, `previewInFlight`
    /// (cleared by the provenance reset) let the reopen kick a second fetch
    /// while the abandoned first one was still out there; an id-only guard
    /// could not tell the two apart when they finally both landed.
    func testAStaleAlbumTracksResultIsDroppedAfterAnOutputSwitchEvenForTheSameAlbumId() {
        let staleTracks = trackReply(["stale1", "stale2", "stale3"])
        let freshTracks = trackReply(["fresh1", "fresh2", "fresh3"])
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage, albumPage],
                                          "slice.libraryAlbumTracks": [staleTracks, freshTracks]])
        wire.gate(op: "slice.libraryAlbumTracks", at: 0)
        let flag = BridgeSelectedFlag(true)
        let s = libraryTestScene(flag: flag, wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.enter)   // drill in: kicks the FIRST (gated, soon-to-be-stale) fetch
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbumTracks", at: 0) },
                      "the first (soon-to-be-stale) tracks request never went out")

        flag.selected = false                                  // output switches away, mid-fetch
        _ = s.tick(snapshot: idle)                             // applyProvenance runs the reset synchronously
        flag.selected = true                                   // ...and back to Bridge
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "Albums never reloaded from Bridge after the flip back")
        _ = s.handle(.enter)   // reopen the SAME album: kicks the SECOND, fresh, unblocked fetch
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tfresh1") },
                      "the fresh tracks never landed")

        wire.release(op: "slice.libraryAlbumTracks", at: 0)    // now let the STALE fetch land
        // Give the stale post a moment to reach the inbox, THEN drain it —
        // `render` alone never calls `tick`, so without this the drain (where
        // the epoch guard lives) never runs and the test would pass
        // vacuously regardless of the fix. Proven red-then-green against
        // this exact test.
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Tstale1"), "a stale Bridge tracks result landed after an output switch: \(out)")
        XCTAssertTrue(out.contains("Tfresh1"), "the fresh result was overwritten by the stale one")
    }

    /// Same property, for the artist-albums drill-in: a fetch kicked for
    /// artist X, gated so it outlives an output switch away and back, is
    /// dropped when it lands even though artist X is reopened (a fresh drill
    /// re-fetches every time) and its own fresh result has already landed.
    func testAStaleArtistAlbumsResultIsDroppedAfterAnOutputSwitchEvenForTheSameArtistId() {
        let artistPage = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
         "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
        """
        let staleAlbums = """
        {"ok":true,"op":"slice.libraryArtistAlbums","generation":3,
         "items":[{"id":"al-stale","title":"Stale Album","artist":"Radiohead","track_count":3,"kind":"album"}]}
        """
        let freshAlbums = """
        {"ok":true,"op":"slice.libraryArtistAlbums","generation":3,
         "items":[{"id":"al-fresh","title":"Fresh Album","artist":"Radiohead","track_count":3,"kind":"album"}]}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage, artistPage],
                                          "slice.libraryArtistAlbums": [staleAlbums, freshAlbums]])
        wire.gate(op: "slice.libraryArtistAlbums", at: 0)
        let flag = BridgeSelectedFlag(true)
        let s = libraryTestScene(flag: flag, wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.enter)   // drill in: kicks the FIRST (gated, soon-to-be-stale) fetch
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryArtistAlbums", at: 0) },
                      "the first artist-albums request never went out")

        flag.selected = false                                  // output switches away, mid-fetch
        _ = s.tick(snapshot: idle)                             // applyProvenance runs the reset synchronously
        flag.selected = true                                   // ...and back to Bridge
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") },
                      "Artists never reloaded from Bridge after the flip back")
        _ = s.handle(.enter)   // reopen the SAME artist: kicks the SECOND, fresh, unblocked fetch
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Fresh Album") },
                      "the fresh artist-albums result never landed")

        wire.release(op: "slice.libraryArtistAlbums", at: 0)   // now let the STALE fetch land
        // Give the stale post a moment to reach the inbox, THEN drain it —
        // `render` alone never calls `tick`, so without this the drain (where
        // the epoch guard lives) never runs and the test would pass
        // vacuously regardless of the fix. Proven red-then-green against
        // this exact test.
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Stale Album"),
                      "a stale artist-albums result landed after an output switch: \(out)")
        XCTAssertTrue(out.contains("Fresh Album"), "the fresh result was overwritten by the stale one")
    }

    // MARK: - Music.app mode: unaffected

    func testMusicAppModeAlbumPlayReachesTheInjectedResolversAndNeverTheWire() {
        let wire = BridgeLibraryReadsWire()
        let spy = LibraryAppleScriptSpy()
        spy.albums = [LibraryAlbum(id: "al1", name: "In Rainbows", artist: "Radiohead", trackCount: 3)]
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { usleep(10_000) }
        XCTAssertEqual(wire.requestCount, 0, "Music.app mode reached Bridge's wire")
    }
}

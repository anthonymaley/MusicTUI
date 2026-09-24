import XCTest
@testable import music

/// C2: the Library tab's Albums and Artists lists sourced from Bridge, and
/// D7's provenance switch, at the scene level. Uses the shared
/// `BridgeLibraryReadsWire` / `LibraryAppleScriptSpy` / `libraryTestScene`
/// from `BridgeLibraryTestSupport.swift`.
final class BridgeLibraryListsSceneTests: XCTestCase {

    private let frame = shellLayout(width: 100, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"},
              {"id":"al2","title":"Mezzanine","artist":"Massive Attack","track_count":11,"kind":"album"}],
     "next_cursor":null}
    """
    private let artistPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
    """
    private let songPage = """
    {"ok":true,"op":"slice.librarySongs","generation":3,"total":1,
     "items":[{"id":"s1","title":"Nude","artist":"Radiohead","album":"In Rainbows","kind":"song"}],
     "next_cursor":null}
    """

    // MARK: - Bridge rows, no AppleScript

    func testBridgeAlbumsCarryBridgeIdsAndTheSpyIsNeverAsked() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Mezzanine"))
        XCTAssertEqual(spy.count("onAlbums"), 0, "Albums asked Music.app instead of Bridge")
    }

    func testBridgeArtistsCarryBridgeIdsAndTheSpyIsNeverAsked() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        XCTAssertEqual(spy.count("onArtists"), 0, "Artists asked Music.app instead of Bridge")
    }

    func testTheHeadersShowBridgesOwnCounts() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage], "slice.libraryArtists": [artistPage]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Albums \u{2014} Bridge library (2)") })
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Artists \u{2014} Bridge library (1)") })
    }

    // MARK: - Warming and failure

    /// A no-op `warmUpSleep` makes the whole warm-up-then-give-up sequence
    /// complete in well under a millisecond of wall clock, which is truer to
    /// how fast a canned wire answers than any real Bridge would — so the
    /// INTERMEDIATE "still warming" state is real but transient, and needs a
    /// gate to observe deterministically rather than a polling race.
    func testWarmingShowsPreparingYourLibrary() {
        let releaseRetry = DispatchSemaphore(value: 0)
        let warming = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [warming, albumPage]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 warmUpSleep: { _ in releaseRetry.wait(timeout: .now() + 5) })

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s, seconds: 3) { s.render(frame: frame, snapshot: idle).contains("Preparing your library") },
                      "warming was never shown before the retry was released")
        releaseRetry.signal()
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "the retry never landed the successful page")
    }

    /// A 5.0 s hint (clamped to `maxWait`) needs only 12 retries (13
    /// requests) to spend the 60 s budget, rather than 240 at the 0.25 s
    /// floor — cheaper to script and to run. No gate needed here: unlike the
    /// "shows Preparing" test above, this only needs the FINAL state, which
    /// (once `BridgeListFeed.drain()`'s failure is level state, not one-shot)
    /// persists once reached.
    func testAgivesUpVisiblyAfterExhaustingTheBudget() {
        let warming = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let requests = Int(LibraryWarmUp.maxTotalWait / LibraryWarmUp.maxWait) + 1
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": Array(repeating: warming, count: requests)])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 warmUpSleep: { _ in })   // no real sleep: instant in test

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Bridge is still preparing your library - press r to retry")
        }, "it never gave up visibly")
    }

    func testABridgeAlbumsFailureShowsBridgesSentenceAndRRewalksBridgeOnly() {
        let noAccess = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"unauthorized","detail":"no access"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [noAccess]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("press r to retry")
        }, "the Bridge failure never showed")
        XCTAssertEqual(spy.count("onAlbums"), 0)

        wire.script("slice.libraryAlbums", [albumPage])
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "r did not re-walk Bridge")
        XCTAssertEqual(spy.count("onAlbums"), 0, "the retry read Music.app")
    }

    func testAnOlderBridgeShowsTheUpdateBridgeSentence() {
        let unknownOp = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"unknown_op","detail":"no such op"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [unknownOp]])
        let spy = LibraryAppleScriptSpy()
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("This Bridge build can't list your albums \u{2014} update Bridge")
        })
        XCTAssertEqual(spy.count("onAlbums"), 0, "an older-Bridge refusal fell back to Music.app")
    }

    // MARK: - Live gate (2026-09-24): the same filter + warm-up-retry defect, checked here

    /// The coordinator's live-gate finding (`PlaylistsScene`'s `plCursor`
    /// pointing outside the filtered set after a warm-up-retry) does NOT
    /// reproduce here: `LibraryScene`'s `nav.cursor` is a position WITHIN the
    /// filtered list itself (`focusedAlbum()`/`selectionUnderCursor()` read
    /// `src[vis[nav.cursor]]`), never an absolute index into the unfiltered
    /// `albums` array the way `PlaylistsScene.plCursor` indexes
    /// `bridgePlaylistRows` directly — so the existing bounds-only clamp
    /// (`nav.cursor >= visible`) is already correct: whatever `nav.cursor`
    /// is, `vis[nav.cursor]` is always a filtered row. This test proves it
    /// empirically with the exact same scenario as the Playlists one: a
    /// filter typed while warming, give-up, `r` retry, and the fresh page's
    /// filter match NOT at row 0 (`albumPage` puts "In Rainbows" at index 0,
    /// "Mezzanine" at index 1 — filtering to "Mezzanine" only).
    func testFilterTypedWhileWarmingGiveUpThenRetryLandsOnTheFilteredAlbumNotIndexZero() {
        let warming = """
        {"ok":false,"op":"slice.libraryAlbums","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let requests = Int(LibraryWarmUp.maxTotalWait / LibraryWarmUp.maxWait) + 1
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": Array(repeating: warming, count: requests)])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 warmUpSleep: { _ in })

        goToSubView(s, .albums)
        // Filter typed WHILE warming, before any row exists — committed with
        // Enter so the later `r` reaches the retry handler, not the filter box.
        _ = s.handle(.char("/"))
        for c in "Mezzanine" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Bridge is still preparing your library - press r to retry")
        }, "it never gave up visibly")

        wire.script("slice.libraryAlbums", [albumPage])   // "In Rainbows" at 0, "Mezzanine" at 1
        _ = s.handle(.char("r"))
        // Codex's review (971b9659): waiting on `.contains("Mezzanine")` is
        // NOT proof the replacement row landed — the filter box echoes back
        // the typed text itself ("Mezzanine") the instant it's typed, well
        // before the retry ever lands anything, so that wait could pass
        // vacuously against an empty list. `renderRail`'s row label is
        // `"<name> — <artist>"` ("Mezzanine — Massive Attack"); the artist
        // half can ONLY come from an actual rendered row, never the filter
        // echo, so waiting on it proves the row itself landed.
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Massive Attack") },
                      "the replacement row never actually landed, not just the filter echo")

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("In Rainbows"), "the filter must still exclude 'In Rainbows'")
        // `nav.cursor` is a FILTERED-list position: with exactly one visible
        // row, it must be 0 (not an unfiltered index of 1).
        XCTAssertEqual(s.navCursorForTest, 0)

        // Strengthen further: assert the SELECTED album's identity via the
        // drill-in request itself, not just the cursor's numeric position.
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryAlbumTracks").isEmpty },
                      "Enter on the filtered row never drilled in")
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").first?["id"] as? String, "al2",
                       "the drill-in read the wrong album — 'In Rainbows' (al1), not the filtered 'Mezzanine' (al2)")
    }

    // MARK: - Music.app mode: unaffected

    func testInMusicAppModeAllThreeListsComeFromTheSpyAndNoHeaderNamesALibrary() {
        let wire = BridgeLibraryReadsWire()
        let spy = LibraryAppleScriptSpy()
        spy.albums = [LibraryAlbum(id: "al1", name: "In Rainbows", artist: "Radiohead", trackCount: 10)]
        spy.artists = [LibraryArtist(id: "ar1", name: "Radiohead")]
        spy.songs = [LibrarySong(id: "s1", title: "Nude", artist: "Radiohead", album: "In Rainbows")]
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Nude") })

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Bridge library"), "a header named Bridge in Music.app mode: \(out)")
        XCTAssertEqual(wire.requestCount, 0, "Music.app mode reached the wire at all")
    }

    // MARK: - Provenance (D7)

    func testFlippingToBridgeReloadsAlbumsFromBridgeAndDropsTheOldRows() {
        let wire = BridgeLibraryReadsWire()
        let spy = LibraryAppleScriptSpy()
        spy.albums = [LibraryAlbum(id: "al-musicapp", name: "Music.app Album", artist: "X", trackCount: 5)]
        let flag = BridgeSelectedFlag(false)
        let s = libraryTestScene(flag: flag, wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Music.app Album") })

        wire.script("slice.libraryAlbums", [albumPage])
        flag.selected = true
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryAlbums").isEmpty },
                      "the flip never asked Bridge for albums")
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") },
                      "Albums never reloaded from Bridge")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Music.app Album"), "the old Music.app rows were still on screen: \(out)")
    }

    func testFlippingToMusicAppReloadsAlbumsFromTheSpyAndAsksBridgeNoFurther() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage]])
        let spy = LibraryAppleScriptSpy()
        spy.albums = [LibraryAlbum(id: "al-musicapp", name: "Music.app Album", artist: "X", trackCount: 5)]
        let flag = BridgeSelectedFlag(true)
        let s = libraryTestScene(flag: flag, wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        let bridgeRequestsBeforeFlip = wire.sent("slice.libraryAlbums").count

        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Music.app Album") },
                      "Albums never reloaded from Music.app")
        XCTAssertEqual(wire.sent("slice.libraryAlbums").count, bridgeRequestsBeforeFlip,
                       "the flip back to Music.app asked Bridge again")
    }

    /// A Songs walk from Bridge, flipped mid-walk (page 2 gated), never shows
    /// a Bridge row after the reset — the epoch check in `loadSongsFromBridge`.
    func testASongsWalkFlippedMidWalkNeverShowsABridgeRowAfterTheReset() {
        let page1 = """
        {"ok":true,"op":"slice.librarySongs","generation":3,"total":2,
         "items":[{"id":"s1","title":"Nude","artist":"Radiohead","album":"In Rainbows","kind":"song"}],
         "next_cursor":"c1"}
        """
        let wire = BridgeLibraryReadsWire(["slice.librarySongs": [page1]])
        wire.gate(op: "slice.librarySongs", at: 1)
        let spy = LibraryAppleScriptSpy()
        let flag = BridgeSelectedFlag(true)
        let s = libraryTestScene(flag: flag, wire: wire, spy: spy)

        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.librarySongs", at: 1) },
                      "never reached the gated second page")
        flag.selected = false   // flip away from Bridge while page 2 is in flight
        XCTAssertTrue(settleScene(s) { s.songsForTest.isEmpty }, "the provenance reset never cleared the list")
        wire.release(op: "slice.librarySongs", at: 1)
        // Give the abandoned walk a moment to try to land its second page.
        Thread.sleep(forTimeInterval: 0.2)
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Nude"), "a Bridge row landed after the list had reset to Music.app: \(out)")
    }

    /// Same property as the Songs test above, for the Albums LIST walk (not
    /// the drill-in inboxes — those have their own tests in
    /// `BridgeLibraryPlaySceneTests`): a page still in flight when the output
    /// flips away must never land after the reset, even though `albumsFeed`
    /// itself is the SAME instance across the flip (only its epoch changes).
    func testAnAlbumsWalkFlippedMidWalkNeverShowsABridgeRowAfterTheReset() {
        let page1 = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
         "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],
         "next_cursor":"c1"}
        """
        // A genuine second page (not "unscripted"), so accepting it after the
        // reset would be visibly wrong — a bad_request from an exhausted
        // script would fail the walk anyway and prove nothing.
        let page2 = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
         "items":[{"id":"al2","title":"Stale Second Page","artist":"Radiohead","track_count":8,"kind":"album"}],
         "next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [page1, page2]])
        wire.gate(op: "slice.libraryAlbums", at: 1)
        let spy = LibraryAppleScriptSpy()
        let flag = BridgeSelectedFlag(true)
        let s = libraryTestScene(flag: flag, wire: wire, spy: spy)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbums", at: 1) },
                      "never reached the gated second page")
        flag.selected = false   // flip away from Bridge while page 2 is in flight
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("(no albums)") },
                      "the provenance reset never cleared the list")
        wire.release(op: "slice.libraryAlbums", at: 1)
        // Give the abandoned walk a moment to try to land its second page,
        // THEN drain — `render` alone never calls `tick`, so without this the
        // test would pass vacuously regardless of whether the epoch guard
        // (already exercised at the unit level in `BridgeListFeedTests`) held.
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("In Rainbows") || out.contains("Stale Second Page"),
                       "a Bridge album landed after the list had reset to Music.app: \(out)")
    }

    // MARK: - `/` filtering on Bridge Albums and Artists (live-gate finding, 2026-09-23)
    //
    // Root cause: `tick`'s drain of `albumsFeed`/`artistsFeed` used
    // `if let replace = drain.replace { … } else if !drain.append.isEmpty { … }`.
    // `BridgeListFeed` can hand back BOTH a non-nil `replace` (page 1 of the
    // current attempt) and a non-empty `append` (every later page landed
    // since the last drain) in the SAME `Drained` value — which is the normal
    // case once a fast local-socket walk outruns the scene's tick cadence,
    // as a multi-thousand-row real library does. The `else if` silently
    // dropped every page after the first whenever both arrived together, so
    // `albums`/`artists` held only page 1 while the header (which reads
    // Bridge's wire `total`, never `albums.count`) still showed the true
    // count — unfiltered browsing looked populated, but filtering for
    // anything sorted past page 1 always found nothing.

    /// Two pages land UNGATED, so the background walk can race ahead of the
    /// scene's first `tick()` and have BOTH pages sitting in the feed before
    /// anything drains them — the exact race the bug needed. Filtering for
    /// the second page's album must find it.
    func testFilteringBridgeAlbumsFindsARowFromAPageThatLandedAfterTheFirst() {
        let page1 = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
         "items":[{"id":"al1","title":"Alpha Album","artist":"AAA","track_count":10,"kind":"album"}],
         "next_cursor":"c1"}
        """
        let page2 = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
         "items":[{"id":"al2","title":"Drone Logic","artist":"Daniel Avery","track_count":12,"kind":"album"}],
         "next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [page1, page2]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Drone Logic") },
                      "the second page's album never appeared unfiltered — before even trying the filter")

        _ = s.handle(.char("/"))
        for c in "Drone" { _ = s.handle(.char(c)) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Drone Logic"), "filtering hid a row from a page appended after the first")
        XCTAssertFalse(out.contains("Alpha Album"), "the filter matched a row it should have excluded")
    }

    /// Same race, for Artists.
    func testFilteringBridgeArtistsFindsARowFromAPageThatLandedAfterTheFirst() {
        let page1 = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":2,
         "items":[{"id":"ar1","title":"Alpha Artist","kind":"artist"}],"next_cursor":"c1"}
        """
        let page2 = """
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":2,
         "items":[{"id":"ar2","title":"Daniel Avery","kind":"artist"}],"next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [page1, page2]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Daniel Avery") },
                      "the second page's artist never appeared unfiltered — before even trying the filter")

        _ = s.handle(.char("/"))
        for c in "Daniel" { _ = s.handle(.char(c)) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Daniel Avery"), "filtering hid a row from a page appended after the first")
        XCTAssertFalse(out.contains("Alpha Artist"), "the filter matched a row it should have excluded")
    }

    /// The other named symptom: a filter typed BEFORE any rows arrive (while
    /// the list still reads "Loading…") must still match correctly once the
    /// rows land — the filter and the row set are both read live at render
    /// time, never snapshotted at the moment typing started.
    func testAFilterTypedBeforeAlbumsArriveStillMatchesOnceTheyLoad() {
        let albumPage = """
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":2,
         "items":[{"id":"al1","title":"Drone Logic","artist":"Daniel Avery","track_count":12,"kind":"album"},
                  {"id":"al2","title":"Other Album","artist":"Someone Else","track_count":8,"kind":"album"}],
         "next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage]])
        wire.gate(op: "slice.libraryAlbums", at: 0)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Loading albums") },
                      "never observed the pre-load state")
        _ = s.handle(.char("/"))
        for c in "Drone" { _ = s.handle(.char(c)) }
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Loading albums"),
                      "typing the filter should not itself reveal rows before they arrive")

        wire.release(op: "slice.libraryAlbums", at: 0)
        XCTAssertTrue(settleScene(s) {
            let out = s.render(frame: frame, snapshot: idle)
            return out.contains("Drone Logic") || out.contains("no matches")
        })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Drone Logic"), "a filter typed before the rows arrived never matched once they loaded")
        XCTAssertFalse(out.contains("Other Album"), "the filter matched a row it should have excluded")
    }
}

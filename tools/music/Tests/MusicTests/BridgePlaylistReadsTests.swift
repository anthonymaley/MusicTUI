import XCTest
@testable import music

/// C1: the two Part B reads (`slice.libraryPlaylists`, `slice.libraryPlaylistTracks`)
/// at the transport and provider seam — framing, row decoding, the "older
/// Bridge" (`unknown_op`) path, and the shared warm-up budget a PLAY needs
/// across a playlist's pages and its queue (D5). No scene is built here;
/// `BridgePlaylistsListSceneTests` (C2) proves the scene wiring.
///
/// Canned through the real `SourceAppControl(path:transport:libraryTransport:)`,
/// the same discipline `BridgeLibraryReadsTests` (Part A) uses, so these
/// exercise the framing and refusal decoding the app actually uses, not a
/// second copy of them.
final class BridgePlaylistReadsTests: XCTestCase {

    private final class Wire {
        private(set) var sentOnMain: [String] = []
        private(set) var sentOnLibrary: [String] = []
        private var replies: [String]
        init(_ replies: [String]) { self.replies = replies }

        func mainTransport(_ path: String, _ line: String) throws -> String {
            sentOnMain.append(line)
            return nextReply()
        }
        func libraryTransport(_ path: String, _ line: String) throws -> String {
            sentOnLibrary.append(line)
            return nextReply()
        }
        private func nextReply() -> String {
            replies.isEmpty ? "{}" : replies.removeFirst()
        }
        func decoded(_ line: String?) -> [String: Any] {
            guard let data = line?.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return body
        }
        var firstLibraryRequest: [String: Any] { decoded(sentOnLibrary.first) }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.mainTransport,
                         libraryTransport: wire.libraryTransport)
    }

    private func provider(_ wire: Wire) -> BridgeMusicProvider {
        BridgeMusicProvider(control: control(wire))
    }

    // MARK: - Requests

    func testTheListSendsItsOpAndLimitAndTheCursorOnlyWhenGiven() throws {
        let noCursor = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":59,
         "items":[],"next_cursor":null}
        """])
        _ = try control(noCursor).libraryPlaylists(cursor: nil, limit: 100)
        XCTAssertEqual(noCursor.sentOnMain.count, 0, "the playlist list went over the wrong transport")
        XCTAssertEqual(noCursor.firstLibraryRequest["op"] as? String, "slice.libraryPlaylists")
        XCTAssertEqual(noCursor.firstLibraryRequest["limit"] as? Int, 100)
        XCTAssertNil(noCursor.firstLibraryRequest["cursor"], "a first page sends no cursor at all")

        let withCursor = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":59,
         "items":[],"next_cursor":null}
        """])
        _ = try control(withCursor).libraryPlaylists(cursor: "p1:abc", limit: 100)
        XCTAssertEqual(withCursor.firstLibraryRequest["cursor"] as? String, "p1:abc")
    }

    func testTheTracksReadSendsOpIDAndLimitAndTheCursorOnlyWhenGiven() throws {
        let noCursor = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":25,
         "items":[],"next_cursor":null,"skipped_videos":0}
        """])
        _ = try control(noCursor).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(noCursor.sentOnMain.count, 0, "the tracks page went over the wrong transport")
        XCTAssertEqual(noCursor.firstLibraryRequest["op"] as? String, "slice.libraryPlaylistTracks")
        XCTAssertEqual(noCursor.firstLibraryRequest["id"] as? String, "pl1")
        XCTAssertEqual(noCursor.firstLibraryRequest["limit"] as? Int, 500)
        XCTAssertNil(noCursor.firstLibraryRequest["cursor"], "a first page sends no cursor at all")

        let withCursor = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":25,
         "items":[],"next_cursor":null,"skipped_videos":0}
        """])
        _ = try control(withCursor).libraryPlaylistTracks(playlistID: "pl1", cursor: "t1:abc", limit: 500)
        XCTAssertEqual(withCursor.firstLibraryRequest["cursor"] as? String, "t1:abc")
    }

    /// A regression pin: adding `id` (defaulted nil) to the shared
    /// `libraryPage` helper must not change the songs request, which never
    /// sends one.
    func testTheSongsRequestBodyIsUnchanged() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":3,"total":0,
         "items":[],"next_cursor":null}
        """])
        _ = try control(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertEqual(Set(wire.firstLibraryRequest.keys), ["op", "limit"],
                       "the songs request grew or lost a key: \(wire.firstLibraryRequest)")
    }

    // MARK: - Replies: the list

    func testPlaylistRowsDecodeWithKindPlaylist() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
         "items":[{"id":"pl1","title":"Top 25 Most Played","kind":"playlist"}],
         "next_cursor":null}
        """])
        let page = try control(wire).libraryPlaylists(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows, [MusicRow(id: "pl1", title: "Top 25 Most Played", artist: "",
                                            album: nil, kind: .playlist)])
    }

    func testASongRowOrAnUnknownKindInThePlaylistListIsUnreadableAndNotDropped() {
        let songRow = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
         "items":[{"id":"s1","title":"T","kind":"song"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(songRow).libraryPlaylists(cursor: nil, limit: 100)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("a song row in the playlist list was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("song"), "did not name the wrong kind: \(what)")
        }
        let unknownKind = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
         "items":[{"id":"s1","title":"T","kind":"mixtape"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(unknownKind).libraryPlaylists(cursor: nil, limit: 100)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("an unknown kind in the playlist list was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("mixtape"), "did not name the unknown kind: \(what)")
        }
    }

    // MARK: - Replies: the tracks

    func testATracksReplyWithNoTotalOrNoNextCursorIsUnreadable() {
        let noTotal = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,
         "items":[],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(noTotal).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply for missing total, got \(error)")
            }
        }
        let noNextCursor = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
         "items":[]}
        """])
        XCTAssertThrowsError(try control(noNextCursor).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply for missing next_cursor, got \(error)")
            }
        }
    }

    func testAPlaylistRowOrAnUnknownKindAmongTheTracksIsUnreadableAndNotDropped() {
        let playlistRow = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":1,
         "items":[{"id":"pl2","title":"T","kind":"playlist"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(playlistRow).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("a playlist row among the tracks was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("playlist"), "did not name the wrong kind: \(what)")
        }
        let unknownKind = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":1,
         "items":[{"id":"x1","title":"T","kind":"mixtape"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(unknownKind).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("an unknown kind among the tracks was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("mixtape"), "did not name the unknown kind: \(what)")
        }
    }

    /// Groundwork, not yet used by any play path: a playlist track row may carry
    /// `catalog_id` (the song's Apple Music catalogue id). It is read onto
    /// `MusicRow.catalogID`; a row without it, or with a value that is not a
    /// digit string, reads exactly as before with `catalogID` nil.
    func testPlaylistTrackRowsDecodeAnOptionalCatalogueID() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":5,"skipped_videos":0,
         "items":[
          {"id":"i.a","title":"A","artist":"X","album":"Al","kind":"song","alias":"-1","catalog_id":"1097861387"},
          {"id":"i.b","title":"B","artist":"X","album":"Al","kind":"song","alias":"-2"},
          {"id":"i.c","title":"C","artist":"X","album":"Al","kind":"song","catalog_id":""},
          {"id":"i.d","title":"D","artist":"X","album":"Al","kind":"song","catalog_id":"12ab"},
          {"id":"i.e","title":"E","artist":"X","album":"Al","kind":"song","catalog_id":42}],
         "next_cursor":null}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.rows.map(\.id), ["i.a", "i.b", "i.c", "i.d", "i.e"])
        XCTAssertEqual(page.rows.map(\.catalogID), ["1097861387", nil, nil, nil, nil])
        // Nothing else about a row moved: alias still rides, and a row with no
        // catalogue id equals the row this client has always built.
        XCTAssertEqual(page.rows.map(\.alias), ["-1", "-2", nil, nil, nil])
        XCTAssertEqual(page.rows[1], MusicRow(id: "i.b", title: "B", artist: "X", album: "Al",
                                              kind: .song, alias: "-2"))
    }

    /// `catalog_id` is read on the SpanDAC library path only for song rows of
    /// this op; the songs list's rows (which never carry one) are unchanged.
    func testSongsListRowsHaveNoCatalogueID() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":3,"total":1,
         "items":[{"id":"i.a","title":"A","artist":"X","album":"Al","kind":"song","alias":"-1"}],
         "next_cursor":null}
        """])
        let page = try control(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows.first?.catalogID, nil)
        XCTAssertEqual(page.rows.first?.alias, "-1")
    }

    func testRepeatedIdsInATracksPageAreAllKeptInOrder() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":3,
         "items":[{"id":"i.a","title":"A","kind":"song"},
                  {"id":"i.b","title":"B","kind":"song"},
                  {"id":"i.a","title":"A","kind":"song"}],
         "next_cursor":null,"skipped_videos":0}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.rows.map(\.id), ["i.a", "i.b", "i.a"],
                       "a repeated member was collapsed instead of kept")
    }

    // MARK: - C1a: skipped_videos (Revision 3, D9/D11)

    func testAPageWithSkippedVideosTwoDecodesAsSkippedVideosTwo() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":40,
         "items":[],"next_cursor":null,"skipped_videos":2}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.skippedVideos, 2)
    }

    func testAPageWithSkippedVideosZeroDecodesAsZero() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":25,
         "items":[],"next_cursor":null,"skipped_videos":0}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.skippedVideos, 0)
    }

    func testAPageWithSkippedVideosAbsentNegativeOrAStringIsUnreadable() {
        let cases: [(label: String, body: String)] = [
            ("absent", """
             {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
              "items":[],"next_cursor":null}
             """),
            ("-1", """
             {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
              "items":[],"next_cursor":null,"skipped_videos":-1}
             """),
            ("\"2\"", """
             {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
              "items":[],"next_cursor":null,"skipped_videos":"2"}
             """),
        ]
        for c in cases {
            let wire = Wire([c.body])
            XCTAssertThrowsError(try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500),
                                 "skipped_videos \(c.label) was read as a page") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for skipped_videos \(c.label), got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_videos"), "did not name the fault: \(what)")
            }
        }
    }

    // MARK: - skip_not_in_library: the opt-in request field (2026-11-07)

    private let emptyTracksPage = """
    {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
     "items":[],"next_cursor":null,"skipped_videos":0}
    """

    /// ABSENT unless a client that shows the notice asks: the request is the one
    /// older SpanDAC and every other caller (the CLI) always sent.
    func testThePlaylistTracksRequestCarriesTheOptInOnlyWhenAsked() throws {
        let plain = Wire([emptyTracksPage])
        _ = try control(plain).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertNil(plain.firstLibraryRequest["skip_not_in_library"], "never an explicit false")
        let asked = Wire([emptyTracksPage])
        _ = try control(asked).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500, forQueue: true,
                                                     skipNotInLibrary: true)
        XCTAssertEqual(asked.firstLibraryRequest["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(asked.firstLibraryRequest["for_queue"] as? Bool, true)
        let off = Wire([emptyTracksPage])
        _ = try control(off).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500, forQueue: false,
                                                   skipNotInLibrary: false)
        XCTAssertNil(off.firstLibraryRequest["skip_not_in_library"])
    }

    /// The provider the TUI builds asks (pages and queue walks); the one the CLI
    /// builds, `BridgeMusicProvider(control:)`, never does, so `music bridge play`
    /// keeps its whole-playlist refusal.
    func testOnlyTheTUIsProviderAsksToSkip() throws {
        let cli = Wire([emptyTracksPage, emptyTracksPage])
        _ = try provider(cli).playlistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        _ = try provider(cli).playlistTracksForQueue(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertTrue(cli.sentOnLibrary.allSatisfy { cli.decoded($0)["skip_not_in_library"] == nil },
                      "the CLI's provider sent the opt-in")
        let tui = Wire([emptyTracksPage, emptyTracksPage])
        let skipping = BridgeMusicProvider(control: control(tui), skipsNotInLibrary: true)
        _ = try skipping.playlistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        _ = try skipping.playlistTracksForQueue(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(tui.sentOnLibrary.count, 2)
        XCTAssertTrue(tui.sentOnLibrary.allSatisfy { tui.decoded($0)["skip_not_in_library"] as? Bool == true },
                      "a TUI page or queue walk did not carry the opt-in")
    }

    // MARK: - skipped_not_in_library (2026-11-07)

    func testAPageNamesThePlaylistOnlySongsSpanDACSkipped() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":22,
         "items":[],"next_cursor":null,"skipped_videos":1,"skipped_not_in_library":3}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.skippedNotInLibrary, 3)
        XCTAssertEqual(page.skippedVideos, 1, "the video count is read as before")
    }

    func testAPageWithoutTheKeyIsZeroSkippedNotInLibrary() throws {
        // Sent only when more than 0, and never by an older SpanDAC.
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":25,
         "items":[],"next_cursor":null,"skipped_videos":0}
        """])
        let page = try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)
        XCTAssertEqual(page.skippedNotInLibrary, 0)
    }

    func testASkippedNotInLibraryThatIsNotACountIsUnreadable() {
        for (label, value) in [("-1", "-1"), ("\"2\"", "\"2\""), ("null", "null"), ("1.5", "1.5")] {
            let wire = Wire(["""
            {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":0,
             "items":[],"next_cursor":null,"skipped_videos":0,"skipped_not_in_library":\(value)}
            """])
            XCTAssertThrowsError(try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500),
                                 "skipped_not_in_library \(label) was read as a page") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for \(label), got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_not_in_library"), "did not name the fault: \(what)")
            }
        }
    }

    /// Only `libraryPlaylistTracks` requires the field: an albums page with no
    /// `skipped_videos` at all still decodes, exactly as it did before C1a.
    func testAnAlbumsPageWithNoSkippedVideosStillDecodes() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":0,
         "items":[],"next_cursor":null}
        """])
        let page = try control(wire).libraryAlbums(cursor: nil, limit: 100)
        XCTAssertEqual(page.skippedVideos, 0)
    }

    // MARK: - Refusal decoding, on the KIND

    func testWarmingKeepsItsHintOnAPlaylistTracksRead() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.libraryPlaylistTracks",
         "error":{"kind":"warming","detail":"preparing your library","retry_after":0.5}}
        """])
        XCTAssertThrowsError(try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            guard case SourceAppError.warming(let why, let retryAfter) = error else {
                return XCTFail("expected warming, got \(error)")
            }
            XCTAssertEqual(why, "preparing your library")
            XCTAssertEqual(retryAfter, 0.5)
        }
    }

    func testStaleGenerationOnEitherOpGivesStaleGeneration() {
        for op in ["slice.libraryPlaylists", "slice.libraryPlaylistTracks"] {
            let wire = Wire(["""
            {"ok":false,"op":"\(op)",
             "error":{"kind":"stale_generation","detail":"That playlist changed while you were reading it; start again."}}
            """])
            if op == "slice.libraryPlaylists" {
                XCTAssertThrowsError(try control(wire).libraryPlaylists(cursor: nil, limit: 100)) { error in
                    XCTAssertEqual(error as? SourceAppError,
                                   .staleGeneration("That playlist changed while you were reading it; start again."))
                }
            } else {
                XCTAssertThrowsError(try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
                    XCTAssertEqual(error as? SourceAppError,
                                   .staleGeneration("That playlist changed while you were reading it; start again."))
                }
            }
        }
    }

    func testUnsupportedItemNotInLibraryLibraryChangedAndUpstreamAreRefusedWithTheirDetailVerbatim() {
        let cases: [(kind: String, detail: String)] = [
            ("unsupported_item", "1 of 25 items in that playlist aren't songs, and SpanDAC plays only songs."),
            ("not_in_library", "1 of 25 tracks in that playlist aren't in your library, so SpanDAC can't play them."),
            ("library_changed", "1 of 25 tracks of that playlist aren't in SpanDAC's copy of your library yet. SpanDAC is re-reading your library; try again in a moment."),
            ("upstream", "Couldn't read that playlist from your library."),
        ]
        for c in cases {
            let wire = Wire(["""
            {"ok":false,"op":"slice.libraryPlaylistTracks",
             "error":{"kind":"\(c.kind)","detail":"\(c.detail)"}}
            """])
            XCTAssertThrowsError(try control(wire).libraryPlaylistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
                XCTAssertEqual(error as? SourceAppError, .refused(c.detail), "kind \(c.kind)")
            }
        }
    }

    // MARK: - unknown_op: an older Bridge

    func testUnknownOpOnEachOfTheTwoGivesNotImplementedWithItsExactSentence() {
        func unknownOp(_ op: String) -> String {
            """
            {"ok":false,"op":"\(op)","error":{"kind":"unknown_op","detail":"no such op"}}
            """
        }
        let expectations: [(call: (BridgeMusicProvider) throws -> Void, op: String, sentence: String)] = [
            ({ _ = try $0.libraryPlaylists(cursor: nil, limit: 100) }, "slice.libraryPlaylists",
             "This SpanDAC build can't list your playlists — update SpanDAC"),
            ({ _ = try $0.playlistTracks(playlistID: "pl1", cursor: nil, limit: 500) }, "slice.libraryPlaylistTracks",
             "This SpanDAC build can't list a playlist's tracks — update SpanDAC"),
        ]
        for e in expectations {
            let wire = Wire([unknownOp(e.op)])
            XCTAssertThrowsError(try e.call(provider(wire)), "op \(e.op)") { error in
                guard case MusicProviderError.notImplemented(let sentence) = error else {
                    return XCTFail("expected notImplemented for \(e.op), got \(error)")
                }
                XCTAssertEqual(sentence, e.sentence)
            }
        }
    }

    // MARK: - A provider written before Part B keeps compiling and answers the same way

    private struct BeforePartB: MusicDataProvider {
        func librarySongs(cursor: String?, limit: Int) throws -> MusicPage {
            throw MusicProviderError.notImplemented("not used here")
        }
        func play(ids: [String]) throws -> BridgeNow.Queue {
            throw MusicProviderError.notImplemented("not used here")
        }
        func nowPlaying() throws -> SourceStatus {
            throw MusicProviderError.notImplemented("not used here")
        }
    }

    func testAProviderThatImplementsOnlyTheOriginalMethodsGetsNotImplementedFromBothNewOnes() {
        let p = BeforePartB()
        XCTAssertThrowsError(try p.libraryPlaylists(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This SpanDAC build can't list your playlists — update SpanDAC"))
        }
        XCTAssertThrowsError(try p.playlistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This SpanDAC build can't list a playlist's tracks — update SpanDAC"))
        }
    }

    // MARK: - walkLibraryPages' shared budget (D5, C1)

    /// A play's caller-owned budget is carried straight through a restart:
    /// 40s already spent leaves only 20s, not a fresh 60, and the walk gives
    /// up after exactly 60s of TOTAL waiting across both attempts.
    func testAnInjectedBudgetIsSharedAcrossPagesAndAcrossTheRestart() {
        let budget = WarmUpBudget()
        // Spend 40s directly against the budget before the walk ever runs, the
        // same technique `WarmUpPatienceTests.testOneBudgetIsSharedAcrossTwoCalls`
        // uses to control the exact amount spent without depending on a hint.
        var spent: TimeInterval = 0
        while spent < 40 {
            guard let wait = budget.nextWait(forHint: 5.0) else { break }
            spent += wait
        }
        XCTAssertEqual(spent, 40, accuracy: 0.0001)

        var slept: [TimeInterval] = []
        var calls = 0
        var restarts = 0
        let error = walkLibraryPages(fetch: { _, _ in
            calls += 1
            if calls == 1 {
                // Forces exactly one restart.
                return MusicPage(rows: [], nextCursor: "c1", total: 0, generation: 1)
            }
            if calls == 2 {
                throw MusicProviderError.staleGeneration("changed")
            }
            // Only 20s remain of the ORIGINAL budget: warming at a 5s hint
            // gives up after 4 more waits, not a fresh 12.
            throw MusicProviderError.warming("still going", retryAfter: 5.0)
        }, onPage: { _ in true }, onRestart: { restarts += 1 },
           sleep: { slept.append($0) }, budget: budget)

        XCTAssertEqual(restarts, 1)
        guard case .warming(let why, _) = error else {
            return XCTFail("expected a warming give-up, got \(String(describing: error))")
        }
        XCTAssertEqual(why, LibraryWarmUp.gaveUp)
        XCTAssertEqual(slept.reduce(0, +), 20, accuracy: 0.0001,
                       "the restart was given a fresh budget instead of sharing the caller's")
        XCTAssertEqual(budget.waited, 60, accuracy: 0.0001,
                       "the walk did not give up at exactly 60s of total waiting")
    }

    /// With no budget passed, behaviour is exactly what it was before C1: a
    /// fresh budget per attempt. `WarmUpPatienceTests.testAWalksRestartGetsAFreshBudget`
    /// proves this same property and stays green, unedited — this test is the
    /// explicit "no budget" counterpart to the shared-budget test above.
    func testWithNoBudgetEachAttemptStillGetsItsOwnFreshBudget() {
        var calls = 0
        let error = walkLibraryPages(fetch: { _, _ in
            calls += 1
            if calls == 1 {
                return MusicPage(rows: [], nextCursor: "c1", total: 0, generation: 1)
            }
            if calls == 2 {
                throw MusicProviderError.staleGeneration("changed")
            }
            if calls == 3 {
                // The restarted attempt must still retry a `warming` reply,
                // which only happens if its budget was not already spent.
                throw MusicProviderError.warming("hold on", retryAfter: 0.25)
            }
            return MusicPage(rows: [], nextCursor: nil, total: 0, generation: 2)
        }, onPage: { _ in true }, onRestart: {}, sleep: { _ in })
        XCTAssertNil(error, "the restarted attempt's budget was already spent")
    }

    // MARK: - Addendum U: `skipped_unavailable` on `slice.queue` (U-R5/U-R6)

    private func queueReply(skippedUnavailable: Int?) -> String {
        let field = skippedUnavailable.map { ",\"skipped_unavailable\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.queue\"\(field)}"
    }

    func testQueueDecodesSkippedUnavailableZeroOneAndN() throws {
        for n in [0, 1, 5] {
            // n + 1 ids sent, so `skipped < libraryIDs.count` always holds —
            // a successful, non-empty queue keeps at least one song (Codex's
            // review, f2ac2693: this test previously accepted 5 skips for a
            // single requested id, which the bound check now correctly rejects).
            let ids = (0...n).map { "i.\($0)" }
            let wire = Wire([queueReply(skippedUnavailable: n)])
            let skipped = try control(wire).queue(libraryIDs: ids)
            XCTAssertEqual(skipped, n)
        }
    }

    func testQueueWithNoSkippedUnavailableFieldReadsZero() throws {
        let wire = Wire([queueReply(skippedUnavailable: nil)])
        let skipped = try control(wire).queue(libraryIDs: ["i.a"])
        XCTAssertEqual(skipped, 0, "an older SpanDAC's reply, with no field at all, must read as 0")
    }

    func testQueueWithANegativeOrNonIntegerSkippedUnavailableIsUnreadable() {
        for bad in ["-1", "\"2\""] {
            let wire = Wire(["{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":\(bad)}"])
            XCTAssertThrowsError(try control(wire).queue(libraryIDs: ["i.a"]), "skipped_unavailable \(bad) was read") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for skipped_unavailable \(bad), got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_unavailable"), "did not name the fault: \(what)")
            }
        }
    }

    /// Codex's review (f2ac2693): `JSONSerialization` bridges a JSON boolean
    /// to an `NSNumber` that `as? Int` happily unwraps (`true` -> 1, `false`
    /// -> 0), so `skipped_unavailable` MUST be rejected on its underlying
    /// type, not merely accepted because it casts.
    func testQueueWithABooleanSkippedUnavailableIsUnreadable() {
        for bad in ["true", "false"] {
            let wire = Wire(["{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":\(bad)}"])
            XCTAssertThrowsError(try control(wire).queue(libraryIDs: ["i.a"]), "skipped_unavailable \(bad) was read") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for skipped_unavailable \(bad), got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_unavailable"), "did not name the fault: \(what)")
            }
        }
    }

    /// Codex's review: a successful, non-empty queue keeps at least one song
    /// (an all-unavailable request refuses instead — U-R4), so a count equal
    /// to or greater than the number of ids SENT is not a count Bridge could
    /// honestly have sent.
    func testQueueWithASkippedUnavailableAtOrAboveTheRequestCountIsUnreadable() {
        for skipped in [2, 3] {   // == count, and > count
            let wire = Wire([queueReply(skippedUnavailable: skipped)])
            XCTAssertThrowsError(try control(wire).queue(libraryIDs: ["i.a", "i.b"]),
                                 "skipped_unavailable \(skipped) for 2 ids was read") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for skipped_unavailable \(skipped) of 2, got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_unavailable"), "did not name the fault: \(what)")
            }
        }
    }

    /// Addendum U (U-R4), the Bridge-as-built wire kind: both new refusals
    /// travel as `"kind":"unavailable"`, decoded explicitly (not left to the
    /// generic `default` case) and shown verbatim, never reduced to a
    /// generic failure.
    func testQueueRefusalKindUnavailableShowsTheDetailVerbatim() {
        let cases = [
            "None of those songs are available to SpanDAC.",
            "'Urban Jungles' isn't available to SpanDAC.",
        ]
        for detail in cases {
            let wire = Wire(["""
            {"ok":false,"op":"slice.queue","error":{"kind":"unavailable","detail":"\(detail)"}}
            """])
            XCTAssertThrowsError(try control(wire).queue(libraryIDs: ["i.a"])) { error in
                XCTAssertEqual(error as? SourceAppError, .refused(detail))
            }
            // And through the provider's translation, exactly as any other
            // refusal reaches the footer — Bridge's own words, unreduced.
            let providerWire = Wire(["""
            {"ok":false,"op":"slice.queue","error":{"kind":"unavailable","detail":"\(detail)"}}
            """])
            XCTAssertThrowsError(try provider(providerWire).play(ids: ["i.a"])) { error in
                guard case MusicProviderError.refused(let message) = error else {
                    return XCTFail("expected .refused, got \(error)")
                }
                XCTAssertEqual(message, detail)
            }
        }
    }

    // MARK: - Addendum U (Bridge-as-built): `start_required` on the request

    /// `slice.queue` goes over the long-timeout `libraryTransport` (a queue may
    /// wait on the player preparing its first song, and one retry of that), so
    /// these read `sentOnLibrary`.
    ///
    /// Codex's review (f70150a0): Bridge now treats an ABSENT `start_required`
    /// as a legacy request and refuses it, so the client must send an
    /// explicit boolean on EVERY call — omission is no longer a valid way to
    /// say `false`.
    func testQueueSendsStartRequiredExplicitlyEveryTime() throws {
        let wireTrue = Wire([queueReply(skippedUnavailable: 0)])
        _ = try control(wireTrue).queue(libraryIDs: ["i.a"], startRequired: true)
        XCTAssertEqual(wireTrue.decoded(wireTrue.sentOnLibrary.first)["start_required"] as? Bool, true)

        let wireFalse = Wire([queueReply(skippedUnavailable: 0)])
        _ = try control(wireFalse).queue(libraryIDs: ["i.a"], startRequired: false)
        XCTAssertEqual(wireFalse.decoded(wireFalse.sentOnLibrary.first)["start_required"] as? Bool, false,
                       "false must be SENT explicitly, not omitted")

        // The default (no argument at all — every caller written before this
        // field existed, and `BridgeMusicProviderTests`' one direct call)
        // still sends the key, as `false`.
        let wireDefault = Wire([queueReply(skippedUnavailable: 0)])
        _ = try control(wireDefault).queue(libraryIDs: ["i.a"])
        XCTAssertEqual(wireDefault.decoded(wireDefault.sentOnLibrary.first)["start_required"] as? Bool, false)
    }

    /// `BridgeMusicProvider.play(ids:)`'s one remaining caller (`playSong`, a
    /// single specific song) always sends `start_required: true`.
    func testProviderPlaySendsStartRequiredTrue() throws {
        let wire = Wire([queueReply(skippedUnavailable: 0), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """])
        _ = try provider(wire).play(ids: ["i.a"])
        XCTAssertEqual(wire.decoded(wire.sentOnLibrary.first)["start_required"] as? Bool, true)
    }

    func testProviderPlayReportingSkipsSendsWhicheverStartRequiredItIsGiven() throws {
        for want in [true, false] {
            let wire = Wire([queueReply(skippedUnavailable: 0), """
            {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
            """])
            _ = try provider(wire).playReportingSkips(ids: ["i.a"], startRequired: want)
            let req = wire.decoded(wire.sentOnLibrary.first)
            XCTAssertEqual(req["start_required"] as? Bool, want)
        }
    }

    // MARK: - `skip_not_in_library` on `slice.queue` (2026-11-11)
    //
    // A phone's library lacks playlist-only songs the Mac's holds, so a playlist
    // play's whole id list was refused. The Playlists scene's play asks the output
    // SpanDAC to leave those ids out; nothing else does.

    private func queueReply(skippedUnavailable: Int?, skippedNotInLibrary: Int?) -> String {
        let a = skippedUnavailable.map { ",\"skipped_unavailable\":\($0)" } ?? ""
        let b = skippedNotInLibrary.map { ",\"skipped_not_in_library\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.queue\"\(a)\(b)}"
    }

    func testTheLibraryQueueBodyCarriesTheFlagOnlyWhenAskedAndNeverChangesTheRest() {
        let plain = SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: false)
        XCTAssertNil(plain["skip_not_in_library"], "absent unless asked: an older request's bytes are unchanged")
        XCTAssertEqual(Set(plain.keys), ["op", "library_ids", "start_required"])
        let skipping = SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: true, skipNotInLibrary: true)
        XCTAssertEqual(skipping["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(skipping["start_required"] as? Bool, true, "start_required stays as computed")
        XCTAssertEqual(skipping["library_ids"] as? [String], ["i.a"])
        XCTAssertNil(SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: false,
                                                       skipNotInLibrary: false)["skip_not_in_library"],
                     "false is never sent: absent is the older request")
    }

    func testAskingToSkipSendsTheFlagAndReadsTheCountBack() throws {
        let wire = Wire([queueReply(skippedUnavailable: 1, skippedNotInLibrary: 30)])
        let sent = try control(wire).queueRetainingToken(libraryIDs: (0..<53).map { "i.\($0)" }, startRequired: false,
                                                         skipNotInLibrary: true)
        XCTAssertEqual(wire.decoded(wire.sentOnLibrary.first)["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(sent.skippedNotInLibrary, 30)
        XCTAssertEqual(sent.skippedUnavailable, 1)
    }

    func testAReplyWithoutTheCountReadsZeroAndNotAskingNeverSendsTheFlag() throws {
        let asked = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil)])
        XCTAssertEqual(try control(asked).queueRetainingToken(libraryIDs: ["i.a", "i.b"], startRequired: false,
                                                              skipNotInLibrary: true).skippedNotInLibrary, 0,
                       "an older SpanDAC ignores the flag and sends no count")
        let plain = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil)])
        _ = try control(plain).queueRetainingToken(libraryIDs: ["i.a"], startRequired: false)
        XCTAssertNil(plain.decoded(plain.sentOnLibrary.first)["skip_not_in_library"])
        let plainQueue = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil)])
        _ = try control(plainQueue).queue(libraryIDs: ["i.a"], startRequired: true)
        XCTAssertNil(plainQueue.decoded(plainQueue.sentOnLibrary.first)["skip_not_in_library"])
    }

    func testAMalformedNotInLibraryCountIsRefusedLikeEveryOtherCount() {
        // 3 ids sent: a count of 3 or more is not one SpanDAC could have sent (an
        // all-missing request is refused instead), and a boolean is not a count.
        for bad in ["-1", "3", "7", "1.5", "true", "false", "\"2\""] {
            let wire = Wire(["{\"ok\":true,\"op\":\"slice.queue\",\"skipped_not_in_library\":\(bad)}"])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(libraryIDs: ["i.a", "i.b", "i.c"], startRequired: false,
                                                                       skipNotInLibrary: true),
                                 "skipped_not_in_library \(bad) was read") { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply for \(bad), got \(error)")
                }
                XCTAssertTrue(what.contains("skipped_not_in_library"), "did not name the fault: \(what)")
            }
        }
    }

    func testTheTwoSkipCountsTogetherMustLeaveASurvivingSong() throws {
        let ids = ["i.a", "i.b", "i.c", "i.d"]
        // Together equal to, or above, the ids sent: nothing could have played.
        for (u, n) in [(2, 2), (1, 3), (3, 1), (3, 3)] {
            let wire = Wire([queueReply(skippedUnavailable: u, skippedNotInLibrary: n)])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                                       skipNotInLibrary: true),
                                 "\(u)+\(n) of 4 was read") { error in
                guard case SourceAppError.malformedReply = error else {
                    return XCTFail("expected malformedReply for \(u)+\(n), got \(error)")
                }
            }
        }
        // Together below the ids sent: both counts come back.
        let ok = Wire([queueReply(skippedUnavailable: 1, skippedNotInLibrary: 2)])
        let sent = try control(ok).queueRetainingToken(libraryIDs: ids, startRequired: false, skipNotInLibrary: true)
        XCTAssertEqual(sent.skippedUnavailable, 1)
        XCTAssertEqual(sent.skippedNotInLibrary, 2)
        // Each alone is still checked against the ids sent.
        for (u, n) in [(4, 0), (0, 4), (-1, 0), (0, -1)] {
            let wire = Wire([queueReply(skippedUnavailable: u, skippedNotInLibrary: n)])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                                       skipNotInLibrary: true), "\(u),\(n)")
        }
        // A single count one short of the ids sent is still fine.
        let alone = Wire([queueReply(skippedUnavailable: 3, skippedNotInLibrary: nil)])
        XCTAssertEqual(try control(alone).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                              skipNotInLibrary: true).skippedUnavailable, 3)
    }

    // MARK: - skip_repeated on slice.queue(library_ids:) (2026-11-12)
    //
    // The device refuses a list that repeats an id or an exact title. The
    // Playlists scene's play asks it to keep the first copy of each instead;
    // nothing else does.

    private func queueReply(skippedUnavailable: Int?, skippedNotInLibrary: Int?, skippedRepeated: Int?) -> String {
        let a = skippedUnavailable.map { ",\"skipped_unavailable\":\($0)" } ?? ""
        let b = skippedNotInLibrary.map { ",\"skipped_not_in_library\":\($0)" } ?? ""
        let c = skippedRepeated.map { ",\"skipped_repeated\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.queue\"\(a)\(b)\(c)}"
    }

    func testTheLibraryQueueBodyCarriesSkipRepeatedOnlyWhenAsked() {
        let plain = SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: false)
        XCTAssertNil(plain["skip_repeated"])
        XCTAssertEqual(Set(plain.keys), ["op", "library_ids", "start_required"])
        let notInLibraryOnly = SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: false,
                                                                 skipNotInLibrary: true)
        XCTAssertNil(notInLibraryOnly["skip_repeated"], "the two opt-ins are independent")
        let both = SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: true,
                                                     skipNotInLibrary: true, skipRepeated: true)
        XCTAssertEqual(both["skip_repeated"] as? Bool, true)
        XCTAssertEqual(both["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(both["start_required"] as? Bool, true)
        XCTAssertNil(SourceAppControl.libraryQueueBody(libraryIDs: ["i.a"], startRequired: false,
                                                       skipRepeated: false)["skip_repeated"],
                     "false is never sent: absent is the older request")
    }

    func testAskingToSkipRepeatsSendsTheFlagAndReadsTheCountBack() throws {
        let wire = Wire([queueReply(skippedUnavailable: 1, skippedNotInLibrary: 30, skippedRepeated: 2)])
        let sent = try control(wire).queueRetainingToken(libraryIDs: (0..<53).map { "i.\($0)" }, startRequired: false,
                                                         skipNotInLibrary: true, skipRepeated: true)
        let body = wire.decoded(wire.sentOnLibrary.first)
        XCTAssertEqual(body["skip_repeated"] as? Bool, true)
        XCTAssertEqual(body["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(sent.skippedRepeated, 2)
        XCTAssertEqual(sent.skippedNotInLibrary, 30)
        XCTAssertEqual(sent.skippedUnavailable, 1)
    }

    func testAnOlderDeviceThatIgnoresTheFlagSendsNoCountAndItReadsZero() throws {
        let wire = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil, skippedRepeated: nil)])
        XCTAssertEqual(try control(wire).queueRetainingToken(libraryIDs: ["i.a", "i.b"], startRequired: false,
                                                             skipNotInLibrary: true, skipRepeated: true).skippedRepeated, 0)
        let plain = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil, skippedRepeated: nil)])
        _ = try control(plain).queueRetainingToken(libraryIDs: ["i.a"], startRequired: false, skipNotInLibrary: true)
        XCTAssertNil(plain.decoded(plain.sentOnLibrary.first)["skip_repeated"], "the three-argument form never asks")
        let plainQueue = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil, skippedRepeated: nil)])
        _ = try control(plainQueue).queue(libraryIDs: ["i.a"], startRequired: true)
        XCTAssertNil(plainQueue.decoded(plainQueue.sentOnLibrary.first)["skip_repeated"])
    }

    func testAMalformedRepeatedCountIsRefusedLikeEveryOtherCount() {
        for bad in ["-1", "3", "7", "1.5", "true", "false", "\"2\""] {
            let wire = Wire(["{\"ok\":true,\"op\":\"slice.queue\",\"skipped_repeated\":\(bad)}"])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(libraryIDs: ["i.a", "i.b", "i.c"], startRequired: false,
                                                                       skipNotInLibrary: true, skipRepeated: true),
                                 "\(bad) of 3 was read") { error in
                guard case SourceAppError.malformedReply = error else {
                    return XCTFail("expected malformedReply for \(bad), got \(error)")
                }
            }
        }
    }

    /// All three counts together must leave a surviving song (6057a18's rule,
    /// extended): a queue keeps at least the first song of the effective queue.
    func testTheThreeSkipCountsTogetherMustLeaveASurvivingSong() throws {
        let ids = ["i.a", "i.b", "i.c", "i.d", "i.e"]
        for (u, n, r) in [(1, 1, 3), (0, 2, 3), (2, 0, 3), (1, 1, 5), (0, 0, 5), (2, 2, 1), (4, 0, 1)] {
            let wire = Wire([queueReply(skippedUnavailable: u, skippedNotInLibrary: n, skippedRepeated: r)])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                                       skipNotInLibrary: true, skipRepeated: true),
                                 "\(u)+\(n)+\(r) of 5 was read") { error in
                guard case SourceAppError.malformedReply = error else {
                    return XCTFail("expected malformedReply for \(u)+\(n)+\(r), got \(error)")
                }
            }
        }
        // Together one short of the ids sent: every count comes back.
        let ok = Wire([queueReply(skippedUnavailable: 1, skippedNotInLibrary: 1, skippedRepeated: 2)])
        let sent = try control(ok).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                       skipNotInLibrary: true, skipRepeated: true)
        XCTAssertEqual([sent.skippedUnavailable, sent.skippedNotInLibrary, sent.skippedRepeated], [1, 1, 2])
        // Repeats alone, one short of the ids sent, are fine.
        let alone = Wire([queueReply(skippedUnavailable: nil, skippedNotInLibrary: nil, skippedRepeated: 4)])
        XCTAssertEqual(try control(alone).queueRetainingToken(libraryIDs: ids, startRequired: false,
                                                              skipNotInLibrary: true, skipRepeated: true).skippedRepeated, 4)
    }

    func testTheProviderSendsSkipRepeatedOnlyWhenTheCallerAsks() throws {
        let wire = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: 1, skippedRepeated: 1), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """, queueReply(skippedUnavailable: 0, skippedNotInLibrary: 1, skippedRepeated: nil), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """, queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil, skippedRepeated: nil), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """])
        let provider = BridgeMusicProvider(control: control(wire), skipsNotInLibrary: true)
        let asked = try provider.playRetainingToken(ids: ["i.a", "i.b", "i.c"], startRequired: false,
                                                    skipNotInLibrary: true, skipRepeated: true)
        XCTAssertEqual(wire.decoded(wire.sentOnLibrary[0])["skip_repeated"] as? Bool, true)
        XCTAssertEqual(asked.skippedRepeated, 1)
        XCTAssertEqual(asked.skippedNotInLibrary, 1)
        let notInLibraryOnly = try provider.playRetainingToken(ids: ["i.a", "i.b", "i.c"], startRequired: false,
                                                               skipNotInLibrary: true)
        XCTAssertNil(wire.decoded(wire.sentOnLibrary[1])["skip_repeated"])
        XCTAssertEqual(notInLibraryOnly.skippedRepeated, 0)
        let plain = try provider.playRetainingToken(ids: ["i.a"], startRequired: true)
        XCTAssertNil(wire.decoded(wire.sentOnLibrary[2])["skip_repeated"])
        XCTAssertEqual(plain.skippedRepeated, 0)
    }

    func testTheProviderSendsTheFlagOnlyWhenTheCallerAsksEvenIfItSkipsPlaylistReads() throws {
        let wire = Wire([queueReply(skippedUnavailable: 0, skippedNotInLibrary: 2), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """, queueReply(skippedUnavailable: 0, skippedNotInLibrary: nil), """
        {"ok":true,"op":"slice.status","status":{"playback":"playing"}}
        """])
        // The TUI's output player skips playlist-only songs on its READS; that
        // must not leak into every library-id queue (marked sets, albums, Songs).
        let skipsReads = BridgeMusicProvider(control: control(wire), skipsNotInLibrary: true)
        let asked = try skipsReads.playRetainingToken(ids: ["i.a", "i.b", "i.c"], startRequired: false, skipNotInLibrary: true)
        XCTAssertEqual(wire.decoded(wire.sentOnLibrary[0])["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(asked.skippedNotInLibrary, 2)
        let plain = try skipsReads.playRetainingToken(ids: ["i.a"], startRequired: true)
        XCTAssertNil(wire.decoded(wire.sentOnLibrary[1])["skip_not_in_library"])
        XCTAssertEqual(plain.skippedNotInLibrary, 0)
    }
}

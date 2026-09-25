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
            ("unsupported_item", "1 of 25 items in that playlist aren't songs, and Bridge plays only songs."),
            ("not_in_library", "1 of 25 tracks in that playlist aren't in your library, so Bridge can't play them."),
            ("library_changed", "1 of 25 tracks of that playlist aren't in Bridge's copy of your library yet. Bridge is re-reading your library; try again in a moment."),
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
             "This Bridge build can't list your playlists — update Bridge"),
            ({ _ = try $0.playlistTracks(playlistID: "pl1", cursor: nil, limit: 500) }, "slice.libraryPlaylistTracks",
             "This Bridge build can't list a playlist's tracks — update Bridge"),
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
                           .notImplemented("This Bridge build can't list your playlists — update Bridge"))
        }
        XCTAssertThrowsError(try p.playlistTracks(playlistID: "pl1", cursor: nil, limit: 500)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't list a playlist's tracks — update Bridge"))
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
        XCTAssertEqual(skipped, 0, "an older Bridge's reply, with no field at all, must read as 0")
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
            "None of those songs are available to Bridge.",
            "'Urban Jungles' isn't available to Bridge.",
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
}

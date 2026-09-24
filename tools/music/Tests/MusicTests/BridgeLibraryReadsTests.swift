import XCTest
@testable import music

/// C1: the five slice-2 reads (D1/D2) at the transport and provider seam —
/// framing, row decoding, and the "older Bridge" (`unknown_op`) path. No scene
/// is built here; `BridgeLibraryListsSceneTests` (C2) proves the scene wiring.
///
/// Canned through the real `SourceAppControl(path:transport:libraryTransport:)`,
/// so these exercise the framing and refusal decoding the app actually uses,
/// not a second copy of them.
final class BridgeLibraryReadsTests: XCTestCase {

    /// A canned Bridge with two transports, so a test can tell "the library
    /// transport was asked" apart from "the short-timeout transport was asked"
    /// — the same distinction `slice.librarySongs` already relies on.
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

    // MARK: - Paged lists: framing

    func testEachListSendsItsOpAndLimitOverTheLibraryTransport() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":3012,
         "items":[],"next_cursor":null}
        """])
        _ = try control(wire).libraryAlbums(cursor: nil, limit: 50)
        XCTAssertEqual(wire.sentOnMain.count, 0, "an album page went over the wrong transport")
        XCTAssertEqual(wire.firstLibraryRequest["op"] as? String, "slice.libraryAlbums")
        XCTAssertEqual(wire.firstLibraryRequest["limit"] as? Int, 50)
        XCTAssertNil(wire.firstLibraryRequest["cursor"], "a first page sends no cursor at all")
    }

    func testACursorIsSentOnlyWhenGiven() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1801,
         "items":[],"next_cursor":null}
        """])
        _ = try control(wire).libraryArtists(cursor: "r1:abc", limit: 100)
        XCTAssertEqual(wire.firstLibraryRequest["cursor"] as? String, "r1:abc")
    }

    // MARK: - Paged lists: row decoding

    func testAlbumRowsCarryTrackCountAndANullNextCursorIsTerminal() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
         "items":[{"id":"a1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],
         "next_cursor":null}
        """])
        let page = try control(wire).libraryAlbums(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows, [MusicRow(id: "a1", title: "In Rainbows", artist: "Radiohead",
                                            album: nil, kind: .album, trackCount: 10)])
        XCTAssertNil(page.nextCursor)
    }

    func testMissingFieldsOnAnAlbumOrArtistPageAreUnreadable() {
        for missing in ["items", "generation", "total", "next_cursor"] {
            var fields: [String: String] = [
                "\"generation\"": ":3", "\"total\"": ":1",
                "\"items\"": ":[]", "\"next_cursor\"": ":null",
            ]
            fields.removeValue(forKey: "\"\(missing)\"")
            let body = fields.map { "\($0.key)\($0.value)" }.joined(separator: ",")
            let wire = Wire(["""
            {"ok":true,"op":"slice.libraryAlbums",\(body)}
            """])
            XCTAssertThrowsError(try control(wire).libraryAlbums(cursor: nil, limit: 100),
                                 "missing \(missing) was read as a page") { error in
                guard case SourceAppError.malformedReply = error else {
                    return XCTFail("expected malformedReply for missing \(missing), got \(error)")
                }
            }
        }
    }

    func testAnAlbumRowWithNoTrackCountANegativeOneOrAStringOneIsUnreadable() {
        for trackCountJSON in ["", "\"track_count\":-1,", "\"track_count\":\"10\","] {
            let wire = Wire(["""
            {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
             "items":[{"id":"a1","title":"T","artist":"A",\(trackCountJSON)"kind":"album"}],
             "next_cursor":null}
            """])
            XCTAssertThrowsError(try control(wire).libraryAlbums(cursor: nil, limit: 100)) { error in
                guard case SourceAppError.malformedReply(let what) = error else {
                    return XCTFail("expected malformedReply, got \(error)")
                }
                XCTAssertTrue(what.contains("track_count"), "did not name the fault: \(what)")
            }
        }
    }

    func testASongRowOrAnUnknownKindInTheAlbumListIsUnreadableAndNotDropped() {
        let songRow = Wire(["""
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
         "items":[{"id":"s1","title":"T","artist":"A","kind":"song"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(songRow).libraryAlbums(cursor: nil, limit: 100)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("a song row in the album list was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("song"), "did not name the wrong kind: \(what)")
        }
        let unknownKind = Wire(["""
        {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
         "items":[{"id":"s1","title":"T","artist":"A","kind":"mixtape"}],"next_cursor":null}
        """])
        XCTAssertThrowsError(try control(unknownKind).libraryAlbums(cursor: nil, limit: 100)) { error in
            guard case SourceAppError.malformedReply(let what) = error else {
                return XCTFail("an unknown kind in the album list was dropped instead of refused: \(error)")
            }
            XCTAssertTrue(what.contains("mixtape"), "did not name the unknown kind: \(what)")
        }
    }

    // MARK: - Containers: framing

    func testEachContainerSendsIdOverTheLibraryTransport() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,"items":[]}
        """])
        _ = try control(wire).libraryAlbumTracks(albumID: "a1")
        XCTAssertEqual(wire.sentOnMain.count, 0)
        XCTAssertEqual(wire.firstLibraryRequest["op"] as? String, "slice.libraryAlbumTracks")
        XCTAssertEqual(wire.firstLibraryRequest["id"] as? String, "a1")
    }

    func testAContainerReplyWithNoGenerationOrNoItemsIsUnreadable() {
        let noGeneration = Wire(["""
        {"ok":true,"op":"slice.libraryAlbumTracks","items":[]}
        """])
        XCTAssertThrowsError(try control(noGeneration).libraryAlbumTracks(albumID: "a1")) { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)")
            }
        }
        let noItems = Wire(["""
        {"ok":true,"op":"slice.libraryAlbumTracks","generation":3}
        """])
        XCTAssertThrowsError(try control(noItems).libraryAlbumTracks(albumID: "a1")) { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)")
            }
        }
    }

    func testAWrongKindOrUnknownKindRowInAlbumTracksIsUnreadable() {
        let wrongKind = Wire(["""
        {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,
         "items":[{"id":"al1","title":"T","artist":"A","kind":"album"}]}
        """])
        XCTAssertThrowsError(try control(wrongKind).libraryAlbumTracks(albumID: "a1"),
                             "a wrong-kind row shortened the album instead of refusing it") { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)")
            }
        }
        let unknownKind = Wire(["""
        {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,
         "items":[{"id":"x1","title":"T","artist":"A","kind":"mixtape"}]}
        """])
        XCTAssertThrowsError(try control(unknownKind).libraryAlbumTracks(albumID: "a1"),
                             "an unknown-kind row was dropped instead of refusing the whole album") { error in
            guard case SourceAppError.malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)")
            }
        }
    }

    func testWarmingKeepsItsHintOnAContainerRead() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.libraryAlbumTracks",
         "error":{"kind":"warming","detail":"preparing your library","retry_after":0.5}}
        """])
        XCTAssertThrowsError(try control(wire).libraryAlbumTracks(albumID: "a1")) { error in
            guard case SourceAppError.warming(let why, let retryAfter) = error else {
                return XCTFail("expected warming, got \(error)")
            }
            XCTAssertEqual(why, "preparing your library")
            XCTAssertEqual(retryAfter, 0.5)
        }
    }

    // MARK: - Refusal decoding, on the KIND

    func testStaleGenerationOnAlbumsGivesStaleGeneration() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.libraryAlbums",
         "error":{"kind":"stale_generation","detail":"start again"}}
        """])
        XCTAssertThrowsError(try control(wire).libraryAlbums(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? SourceAppError, .staleGeneration("start again"))
        }
    }

    func testTooLargeNotInLibraryAndLibraryChangedAreRefusedWithTheirDetailVerbatim() {
        let cases: [(kind: String, detail: String)] = [
            ("too_large", "That artist's songs are too large for Bridge to send at once."),
            ("not_in_library", "That album isn't in your library any more."),
            ("library_changed", "1 of 10 tracks of that album aren't in Bridge's copy of your library yet."),
        ]
        for c in cases {
            let wire = Wire(["""
            {"ok":false,"op":"slice.libraryAlbumTracks",
             "error":{"kind":"\(c.kind)","detail":"\(c.detail)"}}
            """])
            XCTAssertThrowsError(try control(wire).libraryAlbumTracks(albumID: "a1")) { error in
                XCTAssertEqual(error as? SourceAppError, .refused(c.detail), "kind \(c.kind)")
            }
        }
    }

    // MARK: - unknown_op: an older Bridge

    func testUnknownOpOnEachOfTheFiveGivesNotImplementedWithItsExactSentence() {
        func unknownOp(_ op: String) -> String {
            """
            {"ok":false,"op":"\(op)","error":{"kind":"unknown_op","detail":"no such op"}}
            """
        }
        let expectations: [(call: (BridgeMusicProvider) throws -> Void, op: String, sentence: String)] = [
            ({ _ = try $0.libraryAlbums(cursor: nil, limit: 100) }, "slice.libraryAlbums",
             "This Bridge build can't list your albums — update Bridge"),
            ({ _ = try $0.libraryArtists(cursor: nil, limit: 100) }, "slice.libraryArtists",
             "This Bridge build can't list your artists — update Bridge"),
            ({ _ = try $0.albumTracks(albumID: "a1") }, "slice.libraryAlbumTracks",
             "This Bridge build can't list an album's tracks — update Bridge"),
            ({ _ = try $0.artistAlbums(artistID: "r1") }, "slice.libraryArtistAlbums",
             "This Bridge build can't list an artist's albums — update Bridge"),
            ({ _ = try $0.artistSongs(artistID: "r1") }, "slice.libraryArtistSongs",
             "This Bridge build can't play an artist — update Bridge"),
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

    // MARK: - A provider written before D1/D2 keeps compiling and answers the same way

    /// Exactly the shape of the `Fake` in `BridgeLibrarySceneTests`'
    /// `LibrarySongWalkTests`: only the three original methods. Proves the
    /// protocol extension's defaults, not a second implementation of them.
    private struct BeforeSlice2: MusicDataProvider {
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

    func testAProviderThatImplementsOnlyTheThreeOriginalMethodsGetsNotImplementedFromEachNewOne() {
        let p = BeforeSlice2()
        XCTAssertThrowsError(try p.libraryAlbums(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't list your albums — update Bridge"))
        }
        XCTAssertThrowsError(try p.libraryArtists(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't list your artists — update Bridge"))
        }
        XCTAssertThrowsError(try p.albumTracks(albumID: "a1")) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't list an album's tracks — update Bridge"))
        }
        XCTAssertThrowsError(try p.artistAlbums(artistID: "r1")) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't list an artist's albums — update Bridge"))
        }
        XCTAssertThrowsError(try p.artistSongs(artistID: "r1")) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This Bridge build can't play an artist — update Bridge"))
        }
    }

    // MARK: - SourceReadiness

    func testSourceReadinessFromUnsupportedGivesTheStatedSentence() {
        XCTAssertEqual(SourceReadiness.from(SourceAppError.unsupported("slice.libraryAlbums")),
                       .unavailable("Bridge is older than this MusicTUI — update Bridge"))
    }

    // MARK: - walkLibraryPages, generic over the fetch (D1)

    private func albumPage(_ ids: [String], generation: Int?, next: String?) -> MusicPage {
        MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                  nextCursor: next, total: ids.count, generation: generation)
    }

    func testWalkLibraryPagesFollowsEveryCursorOverAFakeAlbumsFetch() {
        var script: [Result<MusicPage, MusicProviderError>] = [
            .success(albumPage(["a"], generation: 1, next: "c1")),
            .success(albumPage(["b"], generation: 1, next: nil)),
        ]
        var seen: [String] = []
        let error = walkLibraryPages(fetch: { _, _ in
            guard !script.isEmpty else { throw MusicProviderError.unavailable("unscripted") }
            switch script.removeFirst() {
            case .success(let page): return page
            case .failure(let e): throw e
            }
        }, onPage: { seen += $0.rows.map(\.id); return true }, onRestart: { XCTFail("nothing changed") })
        XCTAssertNil(error)
        XCTAssertEqual(seen, ["a", "b"])
    }

    func testWalkLibraryPagesRestartsOnceOnAGenerationChangeAndStopsOnASecond() {
        var script: [MusicPage] = [
            albumPage(["a"], generation: 1, next: "c1"),
            albumPage(["b"], generation: 2, next: "c2"),
            albumPage(["z"], generation: 3, next: nil),
        ]
        var seen: [String] = []
        var restarts = 0
        let error = walkLibraryPages(fetch: { _, _ in script.removeFirst() },
                                     onPage: { seen += $0.rows.map(\.id); return true },
                                     onRestart: { restarts += 1; seen = [] })
        XCTAssertNil(error)
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(seen, ["z"])

        var twice: [MusicPage] = [
            albumPage(["a"], generation: 1, next: "c1"),
            albumPage(["b"], generation: 2, next: "c2"),
        ]
        let secondChange = walkLibraryPages(fetch: { _, _ in
            guard !twice.isEmpty else { throw MusicProviderError.staleGeneration("changed twice") }
            return twice.removeFirst()
        }, onPage: { _ in true }, onRestart: {})
        XCTAssertEqual(secondChange, .staleGeneration("changed twice"))
    }

    // MARK: - bridgeQueueIDs

    func testBridgeQueueIDsStartAndShuffle() {
        let rows = (1...5).map { MusicRow(id: "s\($0)", title: "T\($0)", artist: "A", album: nil, kind: .song) }
        XCTAssertEqual(bridgeQueueIDs(rows, shuffle: false, startAt: 1), ["s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(bridgeQueueIDs(rows, shuffle: false, startAt: 3), ["s3", "s4", "s5"])
        XCTAssertEqual(bridgeQueueIDs(rows, shuffle: false, startAt: 0), ["s1", "s2", "s3", "s4", "s5"],
                       "an out-of-range start clamps to 1")
        XCTAssertEqual(bridgeQueueIDs(rows, shuffle: false, startAt: 99), ["s5"],
                       "an out-of-range start clamps to the last row")
        XCTAssertEqual(Set(bridgeQueueIDs(rows, shuffle: true, startAt: 3)), Set(rows.map(\.id)),
                       "shuffle ignores the start row but sends every id")
        XCTAssertEqual(bridgeQueueIDs([], shuffle: false, startAt: 1), [])
    }
}

import XCTest
@testable import music

/// The Bridge half of the provider seam, against a canned wire.
///
/// These are the rules that make "two modes, two libraries" safe: a row carries
/// the id its own backend gave it, a page is only ever part of ONE observation
/// of the library, and a library that changed underneath a paged read restarts
/// rather than being stitched together from two.
final class BridgeMusicProviderTests: XCTestCase {

    /// A canned Bridge, through the real `SourceAppControl` — so these tests
    /// exercise the framing, the size limit and the refusal decoding the app
    /// actually uses, not a second copy of them.
    private final class Wire {
        private(set) var sent: [String] = []
        private var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func transport(_ path: String, _ line: String) throws -> String {
            sent.append(line)
            return replies.isEmpty ? "{}" : replies.removeFirst()
        }
        var firstRequest: [String: Any] {
            guard let data = sent.first?.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return body
        }
    }

    private func provider(_ wire: Wire) -> BridgeMusicProvider {
        BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent", transport: wire.transport))
    }

    private let firstPage = """
    {"ok":true,"op":"slice.librarySongs","generation":42,"total":15646,"items":[
      {"id":"1109715151","title":"Lotus Flower","artist":"Radiohead","album":"The King of Limbs","kind":"song"},
      {"id":"1440894737","title":"Aquarama","artist":"Moomin","album":"Aquarama - Single","kind":"song"}],
     "next_cursor":"djE6NDI6MjoxCg=="}
    """

    func testAPageCarriesRowsWithTheirOwnIdsAndThePlaceMarker() throws {
        let wire = Wire([firstPage])
        let page = try provider(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows[0], MusicRow(id: "1109715151", title: "Lotus Flower",
                                              artist: "Radiohead", album: "The King of Limbs", kind: .song))
        XCTAssertEqual(page.total, 15646)
        XCTAssertEqual(page.generation, 42)
        XCTAssertEqual(page.nextCursor, "djE6NDI6MjoxCg==")
        XCTAssertEqual(wire.firstRequest["op"] as? String, "slice.librarySongs")
        XCTAssertEqual(wire.firstRequest["limit"] as? Int, 100)
        XCTAssertNil(wire.firstRequest["cursor"], "a first page sends no cursor at all")
    }

    /// The cursor is opaque: it goes back exactly as it came, unparsed.
    func testTheCursorIsHandedBackUntouched() throws {
        let wire = Wire([firstPage, firstPage])
        _ = try provider(wire).librarySongs(cursor: "djE6NDI6MjoxCg==", limit: 50)
        XCTAssertEqual(wire.firstRequest["cursor"] as? String, "djE6NDI6MjoxCg==")
        XCTAssertEqual(wire.firstRequest["limit"] as? Int, 50)
    }

    /// A library that changed mid-read is its own outcome, because the list has
    /// to restart rather than mix two observations.
    func testAStaleGenerationIsItsOwnFailure() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"stale_generation",
         "detail":"the library changed while you were reading it; start again"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: "old", limit: 100)) { error in
            guard case MusicProviderError.staleGeneration = error else {
                return XCTFail("expected staleGeneration, got \(error)")
            }
        }
    }

    /// The kind decides, not the sentence. Bridge is free to reword its detail
    /// — this one says nothing like the old matched phrase — and the list must
    /// still RESTART rather than tell the person their library failed to load.
    func testAStaleGenerationIsRecognisedWhateverItsWording() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"stale_generation",
         "detail":"snapshot 42 has been replaced by snapshot 43"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: "old", limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .staleGeneration("snapshot 42 has been replaced by snapshot 43"),
                           "a reworded stale generation was demoted to a hard refusal")
        }
    }

    /// And the inverse: a refusal that merely READS like one is not one. Nothing
    /// in this path branches on prose any more, in either direction.
    func testARefusalThatMerelySoundsStaleIsStillARefusal() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"bad_request",
         "detail":"the library changed while you were reading it is not a valid cursor"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: "junk", limit: 100)) { error in
            guard case MusicProviderError.refused = error else {
                return XCTFail("a wording coincidence was read as a stale generation: \(error)")
            }
        }
    }

    func testAnOrdinaryRefusalStaysARefusal() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"bad_request","detail":"limit must be 1...500"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 9000)) { error in
            XCTAssertEqual(error as? MusicProviderError, .refused("limit must be 1...500"))
        }
    }

    func testNoAccessReadsAsUnavailableNotAsARefusal() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"unauthorized","detail":"no access"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge has not been granted Apple Music access"))
        }
    }

    /// A kind this build does not know is dropped rather than read as a song —
    /// the rule the Discover feed already follows for unknown rail kinds.
    func testAnUnknownKindIsDroppedNotGuessed() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":2,"items":[
          {"id":"a","title":"A","artist":"x","album":"y","kind":"song"},
          {"id":"b","title":"B","artist":"x","album":"y","kind":"hologram"}],
         "next_cursor":null}
        """])
        let page = try provider(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows.map(\.id), ["a"])
        XCTAssertNil(page.nextCursor)
    }

    /// A row with no album is legal, and stays legal.
    func testARowWithNoAlbumIsStillAGoodRow() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,"items":[
          {"id":"a","title":"A","artist":"x","kind":"song"}],
         "next_cursor":null}
        """])
        let page = try provider(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertEqual(page.rows.map(\.id), ["a"])
        XCTAssertNil(page.rows[0].album)
    }

    /// **This reverses the rule this test used to assert.** A row with no id or
    /// no title was DROPPED, which made a malformed page indistinguishable from
    /// a genuinely shorter one — a person shown a library missing songs, with
    /// nothing to tell them so. On the library path an unreadable row now makes
    /// the whole PAGE unreadable, and the thrown sentence names the fault.
    func testARowMissingItsIdentityMakesTheWholePageUnreadable() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":3,"items":[
          {"id":"a","title":"A","artist":"x","kind":"song"},
          {"title":"no id","artist":"x","album":"y","kind":"song"}],
         "next_cursor":null}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page contains a row with no id"),
                           "a malformed row was quietly dropped, shortening the library")
        }
    }

    func testARowMissingItsTitleMakesTheWholePageUnreadable() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,"items":[
          {"id":"c","artist":"x","album":"y","kind":"song"}],
         "next_cursor":null}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page contains a row with no title (id c)"))
        }
    }

    /// The two rules meet at the `kind` FIELD, and do not conflict: a row that
    /// NAMES a kind this build does not serve is complete and honest, and is
    /// dropped; a row with no kind at all cannot be told apart from a truncated
    /// one, and refuses the page.
    func testARowWithNoKindAtAllIsNotAnUnknownKind() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,"items":[
          {"id":"a","title":"A","artist":"x","album":"y"}],
         "next_cursor":null}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page contains a row with no kind (id a)"))
        }
    }

    // MARK: - A page must satisfy the contract

    /// A MISSING `next_cursor` key is not "this is the last page". Read as one,
    /// a page that lost its cursor ended the walk and the rest of the library
    /// silently did not exist.
    func testAMissingNextCursorKeyIsUnreadableWhileAnExplicitNullIsTerminal() throws {
        let absent = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,
         "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}]}
        """])
        XCTAssertThrowsError(try provider(absent).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page is missing next_cursor"),
                           "a page with no cursor at all was read as the last page")
        }

        let explicitNull = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,"next_cursor":null,
         "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}]}
        """])
        let page = try provider(explicitNull).librarySongs(cursor: nil, limit: 100)
        XCTAssertNil(page.nextCursor, "an explicit null is the end of the list")
        XCTAssertEqual(page.rows.map(\.id), ["a"])
    }

    func testANextCursorOfTheWrongTypeIsUnreadable() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,"next_cursor":7,
         "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}]}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page has a next_cursor that is neither text nor null"))
        }
    }

    /// Without a generation nothing can tell one observation of the library from
    /// another, so the restart rule has nothing to stand on.
    func testAPageWithNoGenerationIsUnreadable() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","total":1,"next_cursor":null,
         "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}]}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page is missing generation"))
        }
    }

    func testAPageWithNoTotalIsUnreadable() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"next_cursor":null,
         "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}]}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .unavailable("Bridge's library page is missing total"))
        }
    }

    /// "Not ready yet" keeps its hint. Flattened into an ordinary refusal it
    /// would read as "your library cannot be read", which is how a cold open
    /// showed a library of 0 songs on 2026-09-23.
    func testWarmingKeepsItsRetryHint() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"warming",
         "detail":"preparing your library","retry_after":2.5}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .warming("preparing your library", retryAfter: 2.5))
        }
    }

    /// A reply with no hint still means "ask again", not "give up".
    func testWarmingWithNoHintStillReadsAsWarming() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.librarySongs","error":{"kind":"warming","detail":"preparing"}}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            guard case MusicProviderError.warming(_, let hint) = error else {
                return XCTFail("expected warming, got \(error)")
            }
            XCTAssertEqual(hint, 1.0)
        }
    }

    /// Freshness travels with the page. Neither flag is a reason to refuse it.
    func testAPageCarriesWhetherItIsStaleAndRefreshing() throws {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":7,"total":15697,"stale":true,"refreshing":true,
         "clamped":true,"items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}],
         "next_cursor":null}
        """])
        let page = try provider(wire).librarySongs(cursor: nil, limit: 500)
        XCTAssertTrue(page.stale)
        XCTAssertTrue(page.refreshing)
        XCTAssertEqual(page.rows.map(\.id), ["a"])
        XCTAssertEqual(page.total, 15697)
    }

    /// A page with neither flag is fresh, and says so by omission.
    func testAPageWithNoFreshnessFlagsIsNeitherStaleNorRefreshing() throws {
        let wire = Wire([firstPage])
        let page = try provider(wire).librarySongs(cursor: nil, limit: 100)
        XCTAssertFalse(page.stale)
        XCTAssertFalse(page.refreshing)
    }

    /// An unreadable reply is not an empty library.
    func testAnUnreadablePageIsUnavailableNotEmpty() {
        let wire = Wire(["""
        {"ok":true,"op":"slice.librarySongs","generation":1,"total":0}
        """])
        XCTAssertThrowsError(try provider(wire).librarySongs(cursor: nil, limit: 100)) { error in
            guard case MusicProviderError.unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }
}

/// Playing what you just browsed: the reason the seam exists.
final class BridgeLibraryPlayTests: XCTestCase {

    private final class Wire {
        private(set) var sent: [String] = []
        private var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func transport(_ path: String, _ line: String) throws -> String {
            sent.append(line)
            return replies.isEmpty ? "{}" : replies.removeFirst()
        }
        func request(_ i: Int) -> [String: Any] {
            guard i < sent.count, let data = sent[i].data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return body
        }
    }

    private let queued = """
    {"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"Lotus Flower","artist":"Radiohead",
     "contract":3,"authorization":"authorized","queue":{"phase":"building","requested":2,"present":1,"index":0}}}
    """
    private let status = """
    {"ok":true,"op":"slice.status","status":{"playback":"playing","title":"Lotus Flower","artist":"Radiohead",
     "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2,"present":2,"index":0}}}
    """

    /// The ids go back exactly as Bridge served them, under `library_ids` — not
    /// `ids` (catalogue) and not `rows` (the title/artist/album join this whole
    /// design deletes).
    func testPlaySendsLibraryIdsAndNotAJoin() throws {
        let wire = Wire([queued, status])
        let provider = BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent",
                                                                     transport: wire.transport))
        let queue = try provider.play(ids: ["i.geOG9Cp2Olb6", "i.bbb"])
        let request = wire.request(0)
        XCTAssertEqual(request["op"] as? String, "slice.queue")
        XCTAssertEqual(request["library_ids"] as? [String], ["i.geOG9Cp2Olb6", "i.bbb"])
        XCTAssertNil(request["rows"], "no (title, artist, album) join may be sent")
        XCTAssertNil(request["ids"], "library ids are not catalogue ids")
        XCTAssertEqual(queue, .complete(requested: 2))
    }

    /// A row the app no longer holds refuses the WHOLE queue, and the refusal
    /// keeps Bridge's own sentence.
    func testAMissingRowRefusesTheWholeQueue() {
        let wire = Wire(["""
        {"ok":false,"op":"slice.queue","error":{"kind":"unresolved_library_ids",
         "detail":"1 of 2 tracks are no longer in your library"}}
        """])
        let provider = BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent",
                                                                     transport: wire.transport))
        XCTAssertThrowsError(try provider.play(ids: ["i.a", "i.gone"])) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .refused("1 of 2 tracks are no longer in your library"))
        }
    }
}

/// Which op goes down which socket, and how long each may take.
///
/// The 10s read timeout is shared by every `slice.*` op and is generous for a
/// transport command. It is not generous for a library read: on 2026-09-23 a
/// cold first page paid for Bridge's ~6.4s library drain inline, blew the 10s,
/// and put "Bridge did not answer in time" over an empty Songs list. The library
/// read gets its own longer timeout; nothing else changes.
final class LibraryReadTimeoutTests: XCTestCase {

    private let page = """
    {"ok":true,"op":"slice.librarySongs","generation":1,"total":1,
     "items":[{"id":"a","title":"A","artist":"x","album":"y","kind":"song"}],"next_cursor":null}
    """
    private let status = """
    {"ok":true,"op":"slice.status","status":{"playback":"paused","contract":3,"authorization":"authorized"}}
    """

    /// The values themselves. A regression here is a person watching an empty
    /// library, or a transport key that hangs for half a minute.
    func testTheTwoTimeoutsAreWhatTheyClaimToBe() {
        XCTAssertEqual(SourceAppStationSearch.timeoutSeconds, 10, "the shared transport timeout moved")
        XCTAssertEqual(SourceAppControl.libraryReadTimeoutSeconds, 30, "the library read timeout moved")
    }

    /// And the wiring, which is the part that can be wrong silently: the longer
    /// timeout must reach the library read and NOTHING else.
    func testOnlyTheLibraryReadUsesTheLongerTransport() throws {
        final class Tally {
            var ordinary: [String] = []
            var library: [String] = []
        }
        let tally = Tally()
        let control = SourceAppControl(path: "/nonexistent",
                                       transport: { [self] _, line in
                                           tally.ordinary.append(line); return status
                                       },
                                       libraryTransport: { [self] _, line in
                                           tally.library.append(line); return page
                                       })

        _ = try control.librarySongs(cursor: nil, limit: 100)
        _ = try control.status()
        try control.queue(libraryIDs: ["i.a"])
        try control.pause()

        // The library read and the queue (which may wait on the player
        // preparing its first song) use the long timeout; status and pause do not.
        XCTAssertEqual(tally.library.count, 2, "the library read or the queue did not use the long-timeout transport")
        XCTAssertTrue(tally.library[0].contains("slice.librarySongs"))
        XCTAssertTrue(tally.library[1].contains("slice.queue"))
        XCTAssertEqual(tally.ordinary.count, 2, "an ordinary op was sent down the long-timeout transport")
        XCTAssertTrue(tally.ordinary.allSatisfy { !$0.contains("slice.librarySongs") && !$0.contains("slice.queue") })
    }

    /// The one-transport test seam still serves every op, so no existing test
    /// silently stops exercising the library read.
    func testTheOneTransportSeamStillServesBothPaths() throws {
        var lines: [String] = []
        let control = SourceAppControl(path: "/nonexistent",
                                       transport: { [self] _, line in
                                           lines.append(line)
                                           return line.contains("librarySongs") ? page : status
                                       })
        _ = try control.librarySongs(cursor: nil, limit: 100)
        _ = try control.status()
        XCTAssertEqual(lines.count, 2)
    }
}

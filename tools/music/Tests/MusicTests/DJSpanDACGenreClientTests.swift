// tools/music/Tests/MusicTests/DJSpanDACGenreClientTests.swift
//
// The concrete SpanDAC genre client (`library.genreUnheard`), driven over a
// fake transport: nothing here opens a socket or reaches a real SpanDAC.
import XCTest
@testable import music

final class DJSpanDACGenreClientTests: XCTestCase {

    /// Records every line sent and answers by op.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [[String: Any]] = []
        var capabilities: [String] = ["library.genreUnheard"]
        var genreReplies: [String] = []
        var statusFails = false

        var sent: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _sent }
        var ops: [String] { sent.compactMap { $0["op"] as? String } }

        func transport(_ path: String, _ line: String) throws -> String {
            let body = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            lock.lock()
            _sent.append(body)
            let caps = capabilities
            let isGenre = (body["op"] as? String) == "library.genreUnheard"
            let reply = (isGenre && !genreReplies.isEmpty) ? genreReplies.removeFirst() : ""
            let failStatus = statusFails
            lock.unlock()
            switch body["op"] as? String {
            case "slice.status":
                if failStatus { throw SourceAppError.timedOut }
                let list = caps.map { "\"\($0)\"" }.joined(separator: ",")
                return #"{"ok":true,"op":"slice.status","status":{"playback":"stopped","capabilities":[\#(list)]}}"#
            case "library.genreUnheard":
                return reply
            default:
                return #"{"ok":false,"error":{"kind":"unknown_op","detail":"no"}}"#
            }
        }
    }

    private func make(_ wire: Wire) -> DJSpanDACGenreClient {
        DJSpanDACGenreClient(client: SourceAppClient(path: "/nonexistent", transport: wire.transport))
    }

    private func success(songs: String, total: Int = 2, generation: Int = 7, instance: String = "inst-1") -> String {
        #"{"ok":true,"op":"library.genreUnheard","songs":[\#(songs)],"total":\#(total),"generation":\#(generation),"instance":"\#(instance)"}"#
    }

    private let twoSongs = #"""
    {"id":"i.1","alias":"-123456","title":"One","artist":"A","album":"X","last_played":1700000000},
    {"id":"i.2","title":"Two","artist":"B","album":"Y","last_played":null}
    """#

    private func refusal(_ kind: String, detail: String = "d", extra: String = "") -> String {
        #"{"ok":false,"op":"library.genreUnheard","error":{"kind":"\#(kind)","detail":"\#(detail)"\#(extra)}}"#
    }

    // MARK: success

    func testSuccessMapsRowsAliasAndTheBracket() throws {
        let wire = Wire()
        wire.genreReplies = [success(songs: twoSongs)]
        let pick = try make(wire).genreUnheard(genre: "Jazz", days: 90)
        XCTAssertEqual(pick.rows.map(\.id), ["i.1", "i.2"])
        XCTAssertEqual(pick.rows.map(\.title), ["One", "Two"])
        XCTAssertEqual(pick.rows.map(\.artist), ["A", "B"])
        XCTAssertEqual(pick.rows.map(\.album), ["X", "Y"])
        XCTAssertEqual(pick.rows.map(\.kind), [.song, .song])
        XCTAssertEqual(pick.rows[0].alias, "-123456")
        XCTAssertNil(pick.rows[1].alias, "an omitted alias stays nil")
        XCTAssertEqual(pick.total, 2)
        XCTAssertEqual(pick.generation, 7)
        XCTAssertEqual(pick.instance, "inst-1")
    }

    func testTheRequestIsExactlyTheContract() throws {
        let wire = Wire()
        wire.genreReplies = [success(songs: twoSongs)]
        _ = try make(wire).genreUnheard(genre: "Jazz", days: 90)
        let request = try XCTUnwrap(wire.sent.last)
        XCTAssertEqual(request["op"] as? String, "library.genreUnheard")
        XCTAssertEqual(request["genre"] as? String, "Jazz")
        XCTAssertEqual(request["days"] as? Int, 90)
        XCTAssertEqual(Set(request.keys), ["op", "genre", "days"])
    }

    func testAnEmptyResultIsAPickWithNoRows() throws {
        let wire = Wire()
        wire.genreReplies = [success(songs: "", total: 0)]
        let pick = try make(wire).genreUnheard(genre: "Jazz", days: 90)
        XCTAssertEqual(pick.rows, [])
        XCTAssertEqual(pick.total, 0)
    }

    // MARK: capability

    func testWithoutTheCapabilityNothingIsReadAndItNeedsANewerSpanDAC() {
        let wire = Wire()
        wire.capabilities = ["slice.search"]
        wire.genreReplies = [success(songs: twoSongs)]
        XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .needsNewerSpanDAC)
        }
        XCTAssertEqual(wire.ops, ["slice.status"], "the read went out without the capability")
    }

    func testAnUnreadableStatusReadsNothing() {
        let wire = Wire()
        wire.statusFails = true
        XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .failed(SourceAppError.timedOut.message))
        }
        XCTAssertEqual(wire.ops, ["slice.status"])
    }

    func testAnUnknownOpAnswerIsTheNewerSpanDACSentenceToo() {
        let wire = Wire()
        wire.genreReplies = [refusal("unknown_op")]
        XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .needsNewerSpanDAC)
        }
    }

    // MARK: refusals

    func testEveryRefusalKindSurfacesThroughTheClientsMapping() {
        let cases: [(kind: String, extra: String, expected: DJGenreSourceError)] = [
            ("bad_request", "", .failed(SourceAppError.refused("d").message)),
            ("unauthorized", "", .failed(SourceAppError.notAuthorized.message)),
            ("warming", #","retry_after":2"#, .failed(SourceAppError.warming("d", retryAfter: 2).message)),
            ("stale_generation", "", .libraryChanged),
            ("upstream", "", .failed(SourceAppError.refused("d").message)),
            ("too_large", "", .failed(SourceAppError.refused("d").message)),
            ("unlicensed", "", .failed(SourceAppError.unlicensed("d").message)),
        ]
        for c in cases {
            let wire = Wire()
            wire.genreReplies = [refusal(c.kind, extra: c.extra)]
            XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90), c.kind) {
                XCTAssertEqual($0 as? DJGenreSourceError, c.expected, c.kind)
            }
        }
    }

    // MARK: malformed

    func testAMalformedReplyFailsTheWholeRead() {
        let good = #"{"id":"i.1","title":"One","artist":"A","album":"X","last_played":null}"#
        let replies: [String: String] = [
            "not json": "garbage",
            "no songs": #"{"ok":true,"op":"library.genreUnheard","total":0,"generation":1,"instance":"i"}"#,
            "no total": #"{"ok":true,"op":"library.genreUnheard","songs":[],"generation":1,"instance":"i"}"#,
            "no generation": #"{"ok":true,"op":"library.genreUnheard","songs":[],"total":0,"instance":"i"}"#,
            "no instance": #"{"ok":true,"op":"library.genreUnheard","songs":[],"total":0,"generation":1}"#,
            "blank instance": success(songs: good, total: 1, instance: " "),
            "row without id": success(songs: #"{"title":"One","artist":"A","album":"X","last_played":null}"#, total: 1),
            "row without title": success(songs: #"{"id":"i.1","artist":"A","album":"X","last_played":null}"#, total: 1),
            "row without artist": success(songs: #"{"id":"i.1","title":"One","album":"X","last_played":null}"#, total: 1),
            "row without album": success(songs: #"{"id":"i.1","title":"One","artist":"A","last_played":null}"#, total: 1),
            "row without last_played": success(songs: #"{"id":"i.1","title":"One","artist":"A","album":"X"}"#, total: 1),
            "last_played a string": success(songs: #"{"id":"i.1","title":"One","artist":"A","album":"X","last_played":"x"}"#, total: 1),
            "alias a number": success(songs: #"{"id":"i.1","alias":5,"title":"One","artist":"A","album":"X","last_played":null}"#, total: 1),
            "one bad row among good": success(songs: good + #",{"id":"","title":"T","artist":"A","album":"X","last_played":null}"#, total: 2),
            "total below the rows": success(songs: good, total: 0),
        ]
        for (name, reply) in replies {
            let wire = Wire()
            wire.genreReplies = [reply]
            XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90), name) {
                guard case .failed? = $0 as? DJGenreSourceError else {
                    return XCTFail("\(name): \($0)")
                }
            }
        }
    }

    func testMoreThanFiftySongsIsMalformed() {
        let row = { (n: Int) in #"{"id":"i.\#(n)","title":"T","artist":"A","album":"X","last_played":null}"# }
        let songs = (1...51).map(row).joined(separator: ",")
        let wire = Wire()
        wire.genreReplies = [success(songs: songs, total: 51)]
        XCTAssertThrowsError(try make(wire).genreUnheard(genre: "Jazz", days: 90))
    }

    // MARK: recheck

    private func pickedThenRechecked(second: String) throws -> (Wire, DJSpanDACGenrePick, DJSpanDACGenreClient) {
        let wire = Wire()
        wire.genreReplies = [success(songs: twoSongs), second]
        let client = make(wire)
        let pick = try client.genreUnheard(genre: "Jazz", days: 90)
        return (wire, pick, client)
    }

    func testRecheckPassesWhenInstanceAndGenerationAreTheSame() throws {
        let (wire, pick, client) = try pickedThenRechecked(second: success(songs: twoSongs))
        XCTAssertNoThrow(try client.recheck(pick))
        let request = try XCTUnwrap(wire.sent.last)
        XCTAssertEqual(request["op"] as? String, "library.genreUnheard")
        XCTAssertEqual(request["genre"] as? String, "Jazz")
        XCTAssertEqual(request["days"] as? Int, 90)
    }

    func testRecheckFailsWhenTheInstanceDiffers() throws {
        let (_, pick, client) = try pickedThenRechecked(second: success(songs: twoSongs, instance: "inst-2"))
        XCTAssertThrowsError(try client.recheck(pick)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .libraryChanged)
        }
    }

    func testRecheckFailsWhenTheGenerationDiffers() throws {
        let (_, pick, client) = try pickedThenRechecked(second: success(songs: twoSongs, generation: 8))
        XCTAssertThrowsError(try client.recheck(pick)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .libraryChanged)
        }
    }

    func testRecheckThatCannotReadFailsAndStaleGenerationIsLibraryChanged() throws {
        let (_, pick, client) = try pickedThenRechecked(second: refusal("stale_generation"))
        XCTAssertThrowsError(try client.recheck(pick)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .libraryChanged)
        }
        let (_, pick2, client2) = try pickedThenRechecked(second: "garbage")
        XCTAssertThrowsError(try client2.recheck(pick2)) {
            guard case .failed? = $0 as? DJGenreSourceError else { return XCTFail("\($0)") }
        }
    }

    func testRecheckOfAPickWithNoBracketFailsClosed() {
        let wire = Wire()
        let pick = DJSpanDACGenrePick(rows: [], total: 0, instance: nil, generation: nil)
        XCTAssertThrowsError(try make(wire).recheck(pick)) {
            XCTAssertEqual($0 as? DJGenreSourceError, .libraryChanged)
        }
        XCTAssertEqual(wire.ops, [], "nothing to compare, nothing sent")
    }
}

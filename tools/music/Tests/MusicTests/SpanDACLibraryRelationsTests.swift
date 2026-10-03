// tools/music/Tests/MusicTests/SpanDACLibraryRelationsTests.swift
//
// Album-cleanup score step A1: the client of `slice.libraryRelations` (W1-W4).
// Every transport is a recording closure; nothing opens a socket.
import XCTest
@testable import music

private final class A1RecordingTransport {
    private let lock = NSLock()
    private var lines: [String] = []
    private let answer: (String) throws -> String

    init(_ answer: @escaping (String) throws -> String) { self.answer = answer }

    static func replying(_ reply: String) -> A1RecordingTransport { A1RecordingTransport { _ in reply } }
    static func throwing(_ error: Error) -> A1RecordingTransport { A1RecordingTransport { _ in throw error } }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    var transport: (String, String) throws -> String {
        { [self] _, line in
            lock.lock(); lines.append(line); lock.unlock()
            return try answer(line)
        }
    }
}

final class SpanDACLibraryRelationsTests: XCTestCase {
    private func reader(_ t: A1RecordingTransport) -> SpanDACLibraryRelations {
        SpanDACLibraryRelations(path: "p", transport: t.transport)
    }

    private func ok(_ items: String) -> String {
        #"{"ok":true,"op":"slice.libraryRelations","items":\#(items)}"#
    }

    private func read(_ reply: String, ids: [String] = ["1", "2"]) throws -> [String: [String?]] {
        try reader(.replying(reply)).relations(catalogueIDs: ids)
    }

    private func assertFailed(_ reply: String, ids: [String] = ["1", "2"],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(reply, ids: ids), file: file, line: line) { error in
            guard case SpanDACLibraryOpError.failed = error else {
                return XCTFail("expected .failed, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Parsing

    func testAliasArraysParseIncludingNullElements() throws {
        let got = try read(ok(#"[{"id":"1","aliases":["6006281934004365952"]},{"id":"2","aliases":["-123456789",null]}]"#))
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got["1"]!, ["6006281934004365952"])
        XCTAssertEqual(got["2"]!, ["-123456789", nil])
    }

    func testAnEmptyAliasesArrayIsNoRelationAndKeepsItsRow() throws {
        let got = try read(ok(#"[{"id":"1","aliases":[]},{"id":"2","aliases":[null]}]"#))
        XCTAssertEqual(got["1"]!, [])
        XCTAssertEqual(got["2"]!, [nil])
    }

    func testRowsMayComeInAnyOrderAndExtraKeysAreIgnored() throws {
        let got = try read(ok(#"[{"id":"2","aliases":[],"x":1},{"id":"1","aliases":["5"]}]"#))
        XCTAssertEqual(got["1"]!, ["5"])
        XCTAssertEqual(got["2"]!, [])
    }

    // MARK: W3, unreadable

    func testAMissingIdIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":[]}]"#))
    }

    func testARepeatedIdIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":[]},{"id":"1","aliases":[]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":[]},{"id":"1","aliases":["5"]}]"#))
    }

    func testAnUnrequestedIdIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":[]},{"id":"2","aliases":[]},{"id":"3","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":[]},{"id":"3","aliases":[]}]"#))
    }

    func testANonArrayAliasesIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":"5"},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":null},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":{}},{"id":"2","aliases":[]}]"#))
    }

    func testAMissingAliasesKeyIsUnreadable() {
        assertFailed(ok(#"[{"id":"1"},{"id":"2","aliases":[]}]"#))
    }

    func testANonStringNonNullElementIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":[5]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":[true]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":[["5"]]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":["5",{}]},{"id":"2","aliases":[]}]"#))
    }

    func testAnEmptyStringAliasIsUnreadable() {
        assertFailed(ok(#"[{"id":"1","aliases":[""]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":"1","aliases":["5",""]},{"id":"2","aliases":[]}]"#))
    }

    func testARowWithoutAStringIdOrNotAnObjectIsUnreadable() {
        assertFailed(ok(#"[{"aliases":[]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"[{"id":1,"aliases":[]},{"id":"2","aliases":[]}]"#))
        assertFailed(ok(#"["1",{"id":"2","aliases":[]}]"#))
    }

    func testItemsMissingOrNotAnArrayIsUnreadable() {
        assertFailed(#"{"ok":true,"op":"slice.libraryRelations"}"#)
        assertFailed(#"{"ok":true,"op":"slice.libraryRelations","items":{}}"#)
        assertFailed(#"{"ok":true,"op":"slice.libraryRelations","items":null}"#)
    }

    func testAReplyThatIsNotAnOkObjectIsUnreadable() {
        assertFailed("not json")
        assertFailed("[]")
        assertFailed(#"{"items":[]}"#)
        assertFailed("")
    }

    func testAnUnreadableReplyIsNeverReadAsNoRelation() {
        // The whole point of W3: nothing here may come back as an empty answer.
        for bad in [ok(#"[]"#), ok(#"[{"id":"1","aliases":[]}]"#), #"{"ok":true}"#] {
            XCTAssertThrowsError(try read(bad))
        }
    }

    // MARK: Errors

    func testUnknownOpIsNotOffered() {
        let reply = #"{"ok":false,"op":"slice.libraryRelations","error":{"kind":"unknown_op","detail":"no"}}"#
        XCTAssertThrowsError(try read(reply)) { error in
            XCTAssertEqual(error as? SpanDACLibraryOpError, .notOffered)
        }
    }

    func testUpstreamIsFailedWithItsDetail() {
        let reply = #"{"ok":false,"op":"slice.libraryRelations","error":{"kind":"upstream","detail":"SpanDAC couldn't read your library from Apple Music."}}"#
        XCTAssertThrowsError(try read(reply)) { error in
            XCTAssertEqual(error as? SpanDACLibraryOpError,
                           .failed("SpanDAC couldn't read your library from Apple Music."))
        }
    }

    func testBadRequestAndUnauthorizedAreFailedWithTheirDetail() {
        for kind in ["bad_request", "unauthorized"] {
            let reply = #"{"ok":false,"error":{"kind":"\#(kind)","detail":"d-\#(kind)"}}"#
            XCTAssertThrowsError(try read(reply)) { error in
                XCTAssertEqual(error as? SpanDACLibraryOpError, .failed("d-\(kind)"))
            }
        }
    }

    func testAnErrorWithoutADetailStillFails() {
        XCTAssertThrowsError(try read(#"{"ok":false}"#)) { error in
            XCTAssertEqual(error as? SpanDACLibraryOpError, .failed("SpanDAC refused."))
        }
    }

    func testATransportErrorIsFailedWithItsMessageNeverOutcomeUnknown() {
        for error in [SourceAppError.timedOut, .notRunning] {
            let t = A1RecordingTransport.throwing(error)
            XCTAssertThrowsError(try reader(t).relations(catalogueIDs: ["1"])) { thrown in
                XCTAssertEqual(thrown as? SpanDACLibraryOpError, .failed(error.message))
            }
        }
        struct Other: LocalizedError { var errorDescription: String? { "other" } }
        XCTAssertThrowsError(try reader(.throwing(Other())).relations(catalogueIDs: ["1"])) { thrown in
            XCTAssertEqual(thrown as? SpanDACLibraryOpError, .failed("other"))
        }
    }

    // MARK: The request

    func testTheRequestLineIsExactlyTheSortedKeyForm() throws {
        let t = A1RecordingTransport.replying(ok(#"[{"id":"940618524","aliases":[]},{"id":"940618525","aliases":[]}]"#))
        _ = try reader(t).relations(catalogueIDs: ["940618524", "940618525"])
        XCTAssertEqual(t.sent, [#"{"ids":["940618524","940618525"],"op":"slice.libraryRelations"}"#])
    }

    func testTheOpNameConstantIsTheWireName() {
        XCTAssertEqual(spandacLibraryRelationsOp, "slice.libraryRelations")
    }

    func testAnUnreadableReplySendsExactlyOneRequest() {
        let t = A1RecordingTransport.replying("not json")
        _ = try? reader(t).relations(catalogueIDs: ["1"])
        XCTAssertEqual(t.sent.count, 1)
    }

    // MARK: Capability (CH2)

    private func status(_ capabilities: [String]) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"ok":true,"op":"slice.status","status":{"capabilities":[\#(list)]}}"#
    }

    private let three = ["slice.libraryEnsurePlaylist", "slice.libraryRelations", "library.catalog_playlist"]

    func testOffersAlbumCleanupWhenAllThreeArePresent() throws {
        let t = A1RecordingTransport.replying(status(["slice.libraryAdd"] + three + ["x"]))
        XCTAssertTrue(reader(t).offersAlbumCleanup)
        XCTAssertEqual(t.sent.count, 1)
        let sent = try JSONSerialization.jsonObject(with: Data(t.sent[0].utf8)) as? [String: Any]
        XCTAssertEqual(sent?["op"] as? String, "slice.status")
    }

    func testOffersAlbumCleanupIsFalseWhenAnyOneOfTheThreeIsMissing() {
        for missing in three {
            let present = three.filter { $0 != missing }
            XCTAssertFalse(reader(.replying(status(present))).offersAlbumCleanup, "missing \(missing)")
        }
        XCTAssertFalse(reader(.replying(status([]))).offersAlbumCleanup)
        // The op names of other families are not these strings.
        XCTAssertFalse(reader(.replying(status(["slice.libraryPlaylistCopies", "slice.libraryAddPlaylist"]))).offersAlbumCleanup)
    }

    func testOffersAlbumCleanupIsFalseWhenTheStatusIsUnreadable() {
        XCTAssertFalse(reader(.replying("not json")).offersAlbumCleanup)
        XCTAssertFalse(reader(.replying(#"{"ok":true}"#)).offersAlbumCleanup)
        XCTAssertFalse(reader(.replying(#"{"ok":false,"error":{"kind":"x","detail":"d"}}"#)).offersAlbumCleanup)
        XCTAssertFalse(reader(.replying(#"{"ok":true,"status":{"capabilities":"slice.libraryRelations"}}"#)).offersAlbumCleanup)
        XCTAssertFalse(reader(.throwing(SourceAppError.timedOut)).offersAlbumCleanup)
        XCTAssertFalse(reader(.throwing(SourceAppError.notRunning)).offersAlbumCleanup)
    }

    // MARK: The client plumbing

    func testTheClientSendsOverItsOwnCommandTransport() throws {
        let command = A1RecordingTransport.replying(ok(#"[{"id":"1","aliases":["7"]}]"#))
        let library = A1RecordingTransport.replying(ok(#"[]"#))
        let client = SourceAppClient(path: "p", transport: command.transport, libraryTransport: library.transport)
        let got = try client.libraryRelations().relations(catalogueIDs: ["1"])
        XCTAssertEqual(got["1"]!, ["7"])
        XCTAssertEqual(command.sent.count, 1)
        XCTAssertTrue(library.sent.isEmpty)
    }
}

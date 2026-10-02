// tools/music/Tests/MusicTests/SpanDACCatalogPlaylistTests.swift
//
// Score step C1: the wire client for Discover play-from-here. Decoding
// `duration_ms`, reading the `library.catalog_playlist` capability, and the two
// catalogue-playlist ops with the add's outcomes classified per W4.
//
// Nothing here opens a socket or reaches a real SpanDAC: every transport is a
// recording closure.
import XCTest
@testable import music

/// A transport that records every request line and answers from a script.
private final class RecordingTransport {
    private let lock = NSLock()
    private var lines: [String] = []
    private let answer: (String) throws -> String

    init(_ answer: @escaping (String) throws -> String) { self.answer = answer }

    static func replying(_ reply: String) -> RecordingTransport { RecordingTransport { _ in reply } }
    static func throwing(_ error: Error) -> RecordingTransport { RecordingTransport { _ in throw error } }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    func send(_ path: String, _ line: String) throws -> String {
        lock.lock(); lines.append(line); lock.unlock()
        return try answer(line)
    }

    var transport: (String, String) throws -> String { { [self] in try send($0, $1) } }
}

final class SpanDACCatalogPlaylistTests: XCTestCase {
    private let playlist = "pl.136cbfb46d9b498498b124e8bb816b54"

    // MARK: duration_ms decoding (K1 through the feed)

    private func reply(_ rows: [String]) -> [String: Any] {
        let text = #"{"ok":true,"op":"slice.containerTracks","items":[\#(rows.joined(separator: ","))]}"#
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func lengths(_ rows: [String]) throws -> [RowLength] {
        try BridgeDiscoverFeed.tracks(fromReply: reply(rows)).map(\.length)
    }

    private func song(_ n: Int, _ tail: String) -> String {
        #"{"id":"\#(n)","kind":"song","name":"S\#(n)","subtitle":"A"\#(tail)}"#
    }

    func testRowLengthCasesThroughTheFeed() throws {
        XCTAssertEqual(try lengths([song(1, "")]), [.absent])
        XCTAssertEqual(try lengths([song(1, #","duration_ms":null"#)]), [.null])
        XCTAssertEqual(try lengths([song(1, #","duration_ms":291840"#)]), [.milliseconds(291840)])
        for bad in ["true", "false", #""291840""#, "291840.5", "0", "-5", "[]", "{}"] {
            XCTAssertEqual(try lengths([song(1, #","duration_ms":\#(bad)"#)]), [.malformed], bad)
        }
    }

    func testAMixedReplyKeepsEachRowsOwnCase() throws {
        let got = try lengths([
            song(1, #","duration_ms":1000"#),
            song(2, #","duration_ms":null"#),
            song(3, ""),
            song(4, #","duration_ms":"x""#),
        ])
        XCTAssertEqual(got, [.milliseconds(1000), .null, .absent, .malformed])
    }

    func testRowsThatAreNotSongsStayAbsentEvenWithTheKey() throws {
        let rows = [
            #"{"id":"1","kind":"album","name":"A","duration_ms":5000}"#,
            #"{"id":"2","kind":"playlist","name":"P","duration_ms":5000}"#,
            #"{"id":"3","kind":"station","name":"R","duration_ms":5000}"#,
            song(4, #","duration_ms":5000"#),
        ]
        XCTAssertEqual(try lengths(rows), [.absent, .absent, .absent, .milliseconds(5000)])
    }

    // MARK: Capability

    private func ops(_ transport: RecordingTransport, add: RecordingTransport? = nil) -> SpanDACCatalogPlaylist {
        SpanDACCatalogPlaylist(path: "p", transport: transport.transport,
                               addTransport: (add ?? RecordingTransport.replying("")).transport)
    }

    private func status(_ capabilities: String) -> String {
        #"{"ok":true,"op":"slice.status","status":{"capabilities":[\#(capabilities)]}}"#
    }

    func testCapabilityIsTrueOnlyWhenTheStringIsPresent() {
        let with = RecordingTransport.replying(status(#""slice.libraryAdd","library.catalog_playlist""#))
        XCTAssertTrue(ops(with).offersCatalogPlaylist)
        XCTAssertEqual(with.sent.count, 1)
        XCTAssertEqual(try? parse(with.sent[0])["op"] as? String, "slice.status")

        // The two op names alone are not the capability (the client checks ONE string).
        let opsOnly = RecordingTransport.replying(
            status(#""slice.libraryPlaylistCopies","slice.libraryAddPlaylist""#))
        XCTAssertFalse(ops(opsOnly).offersCatalogPlaylist)
        XCTAssertFalse(ops(.replying(status(""))).offersCatalogPlaylist)
    }

    func testAnUnreadableStatusIsFalse() {
        XCTAssertFalse(ops(.replying("not json")).offersCatalogPlaylist)
        XCTAssertFalse(ops(.replying(#"{"ok":true}"#)).offersCatalogPlaylist)
        XCTAssertFalse(ops(.replying(#"{"ok":false,"error":{"kind":"x","detail":"d"}}"#)).offersCatalogPlaylist)
        XCTAssertFalse(ops(.replying(#"{"ok":true,"status":{"capabilities":"library.catalog_playlist"}}"#)).offersCatalogPlaylist)
        XCTAssertFalse(ops(.throwing(SourceAppError.timedOut)).offersCatalogPlaylist)
        XCTAssertFalse(ops(.throwing(SourceAppError.notRunning)).offersCatalogPlaylist)
    }

    // MARK: Copies (W3)

    private func parse(_ line: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    }

    func testCopiesReadsEachW3Shape() throws {
        let one = RecordingTransport.replying(
            #"{"ok":true,"op":"slice.libraryPlaylistCopies","copies":[{"alias":"7879824511367631203"}]}"#)
        XCTAssertEqual(try ops(one).copies(ofCatalogPlaylist: playlist),
                       [CatalogPlaylistCopy(alias: "7879824511367631203")])
        XCTAssertEqual(one.sent.count, 1)
        let request = try parse(one.sent[0])
        XCTAssertEqual(request["op"] as? String, "slice.libraryPlaylistCopies")
        XCTAssertEqual(request["id"] as? String, playlist)
        XCTAssertEqual(request.count, 2)

        let none = RecordingTransport.replying(#"{"ok":true,"op":"slice.libraryPlaylistCopies","copies":[]}"#)
        XCTAssertEqual(try ops(none).copies(ofCatalogPlaylist: playlist), [])

        let two = RecordingTransport.replying(
            #"{"ok":true,"copies":[{"alias":"7879824511367631203"},{"alias":null}]}"#)
        let got = try ops(two).copies(ofCatalogPlaylist: playlist)
        XCTAssertEqual(got.count, 2)
        XCTAssertNil(got[1].alias)
    }

    func testANullAliasHasNoHexAndTheProbeAliasGivesItsHex() throws {
        XCTAssertNil(CatalogPlaylistCopy(alias: nil).hex)
        XCTAssertNil(CatalogPlaylistCopy(alias: "not a number").hex)
        XCTAssertEqual(CatalogPlaylistCopy(alias: "7879824511367631203").hex, "6D5AC2A4DC7BD163")
    }

    func testCopiesFailuresAreFailedOrNotOffered() {
        func failure(_ transport: RecordingTransport) -> SpanDACLibraryOpError? {
            do { _ = try ops(transport).copies(ofCatalogPlaylist: playlist); return nil }
            catch { return error as? SpanDACLibraryOpError }
        }
        XCTAssertEqual(failure(.replying(
            #"{"ok":false,"op":"slice.libraryPlaylistCopies","error":{"kind":"upstream","detail":"Could not check."}}"#)),
                       .failed("Could not check."))
        XCTAssertEqual(failure(.replying(
            #"{"ok":false,"error":{"kind":"bad_request","detail":"Not a playlist id."}}"#)),
                       .failed("Not a playlist id."))
        XCTAssertEqual(failure(.replying(#"{"ok":false,"error":{"kind":"unknown_op","detail":"no"}}"#)), .notOffered)
        XCTAssertEqual(failure(.replying(#"{"ok":false,"error":{"kind":"unauthorized","detail":"no"}}"#)), .failed("no"))
        for unreadable in ["", "nope", #"{"ok":true}"#, #"{"ok":true,"copies":"x"}"#, #"{"ok":true,"copies":[{}]}"#,
                           #"{"ok":true,"copies":[{"alias":5}]}"#, #"{"ok":true,"copies":[3]}"#] {
            guard case .failed? = failure(.replying(unreadable)) else {
                return XCTFail("\(unreadable) must be a failure, never an empty list")
            }
        }
        // A thrown error is a failure of a read; never outcome-unknown.
        for error in [SourceAppError.timedOut, .notRunning] {
            guard case .failed? = failure(.throwing(error)) else { return XCTFail("\(error)") }
        }
    }

    // MARK: Add (W4)

    private func add(_ answer: RecordingTransport) -> (CatalogPlaylistAddOutcome, RecordingTransport, RecordingTransport) {
        let read = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let outcome = ops(read, add: answer).addCatalogPlaylist(id: playlist)
        return (outcome, read, answer)
    }

    private func classify(_ reply: String) -> CatalogPlaylistAddOutcome { add(.replying(reply)).0 }

    func testAddOkCopiesAreAdded() {
        XCTAssertEqual(classify(#"{"ok":true,"op":"slice.libraryAddPlaylist","copies":[{"alias":"7879824511367631203"}]}"#),
                       .added(copies: [CatalogPlaylistCopy(alias: "7879824511367631203")]))
        XCTAssertEqual(classify(#"{"ok":true,"copies":[]}"#), .added(copies: []))
        XCTAssertEqual(classify(#"{"ok":true,"copies":[{"alias":null}]}"#), .added(copies: [CatalogPlaylistCopy(alias: nil)]))
    }

    func testAddOkWithUnreadableCopiesIsOutcomeUnknown() {
        for reply in [#"{"ok":true}"#, #"{"ok":true,"copies":"x"}"#, #"{"ok":true,"copies":{}}"#,
                      #"{"ok":true,"copies":[{}]}"#, #"{"ok":true,"copies":[{"alias":7}]}"#,
                      #"{"ok":true,"copies":[{"alias":true}]}"#, #"{"ok":true,"copies":["x"]}"#] {
            guard case .outcomeUnknown = classify(reply) else { return XCTFail("\(reply)") }
        }
    }

    func testAddErrorKinds() {
        func err(_ kind: String, outcome: String? = nil) -> String {
            let extra = outcome.map { #","outcome":"\#($0)""# } ?? ""
            return #"{"ok":false,"op":"slice.libraryAddPlaylist"\#(extra),"error":{"kind":"\#(kind)","detail":"D-\#(kind)"}}"#
        }
        XCTAssertEqual(classify(err("copy_appeared")), .copyAppeared)
        XCTAssertEqual(classify(err("refused")), .refused("D-refused"))
        XCTAssertEqual(classify(err("outcome_unknown", outcome: "unknown")), .outcomeUnknown("D-outcome_unknown"))
        XCTAssertEqual(classify(err("write_busy")), .refused("D-write_busy"))
        XCTAssertEqual(classify(err("upstream")), .refused("D-upstream"))
        XCTAssertEqual(classify(err("bad_request")), .refused("D-bad_request"))
        XCTAssertEqual(classify(err("unauthorized")), .refused("D-unauthorized"))
        XCTAssertEqual(classify(err("unknown_op")), .notOffered)
        // `outcome: unknown` is unknown whatever the kind says.
        XCTAssertEqual(classify(err("refused", outcome: "unknown")), .outcomeUnknown("D-refused"))
        // An unlisted kind is a confirmed refusal; a missing detail still has words.
        XCTAssertEqual(classify(err("something_new")), .refused("D-something_new"))
        XCTAssertEqual(classify(#"{"ok":false}"#), .refused("SpanDAC refused."))
    }

    func testAnUnreadableAddReplyIsOutcomeUnknown() {
        for reply in ["", "nope", "[]", #"{"copies":[]}"#, #"{"ok":"yes"}"#] {
            guard case .outcomeUnknown = classify(reply) else { return XCTFail("\(reply)") }
        }
    }

    func testAThrownErrorOnTheAddIsClassifiedByWhetherItCouldHaveBeenSent() {
        guard case .outcomeUnknown = add(.throwing(SourceAppError.timedOut)).0 else { return XCTFail("timedOut") }
        guard case .outcomeUnknown = add(.throwing(SourceAppError.unreadable)).0 else { return XCTFail("unreadable") }
        guard case .outcomeUnknown = add(.throwing(NSError(domain: "x", code: 1))).0 else { return XCTFail("other") }
        guard case .refused = add(.throwing(SourceAppError.notRunning)).0 else { return XCTFail("notRunning") }
        guard case .refused = add(.throwing(SourceAppError.socketUnavailable("perm"))).0 else { return XCTFail("socket") }
    }

    func testTheAddGoesOnAddTransportAndTheReadOnTransportAndNothingIsSentTwice() throws {
        let (outcome, read, addT) = add(.replying(#"{"ok":true,"copies":[{"alias":"1"}]}"#))
        guard case .added = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(addT.sent.count, 1)
        XCTAssertTrue(read.sent.isEmpty, "the add must not touch the read transport")
        let request = try parse(addT.sent[0])
        XCTAssertEqual(request["op"] as? String, "slice.libraryAddPlaylist")
        XCTAssertEqual(request["id"] as? String, playlist)
        XCTAssertEqual(request.count, 2)

        let readOnly = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let addOnly = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let pair = ops(readOnly, add: addOnly)
        _ = try pair.copies(ofCatalogPlaylist: playlist)
        XCTAssertEqual(readOnly.sent.count, 1)
        XCTAssertTrue(addOnly.sent.isEmpty, "a read must not use the long add transport")
    }

    func testNothingIsSentTwiceOnAnyFailure() {
        for answer in [RecordingTransport.throwing(SourceAppError.timedOut),
                       .throwing(SourceAppError.notRunning),
                       .replying(""), .replying(#"{"ok":false,"outcome":"unknown","error":{"kind":"outcome_unknown","detail":"d"}}"#),
                       .replying(#"{"ok":false,"error":{"kind":"upstream","detail":"d"}}"#)] {
            let (_, read, addT) = add(answer)
            XCTAssertEqual(addT.sent.count, 1)
            XCTAssertTrue(read.sent.isEmpty)
        }
    }

    // MARK: The add's own timeout and the client plumbing

    func testTheAddTimeoutIsFiftySeconds() {
        XCTAssertEqual(spandacCatalogPlaylistAddTimeoutSeconds, 50)
    }

    func testTheClientRoutesTheOpsToItsOwnTransports() throws {
        let command = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let library = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let addT = RecordingTransport.replying(#"{"ok":true,"copies":[{"alias":null}]}"#)
        let client = SourceAppClient(path: "p", transport: command.transport,
                                     libraryTransport: library.transport,
                                     catalogPlaylistAddTransport: addT.transport)
        _ = try client.catalogPlaylistOps().copies(ofCatalogPlaylist: playlist)
        _ = client.catalogPlaylistOps().addCatalogPlaylist(id: playlist)
        XCTAssertEqual(command.sent.count, 1)
        XCTAssertEqual(addT.sent.count, 1)
        XCTAssertTrue(library.sent.isEmpty)
    }

    func testTheAddTransportDefaultsToTheLibraryTransportOnTheThreeArgumentInit() {
        let command = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let library = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let client = SourceAppClient(path: "p", transport: command.transport, libraryTransport: library.transport)
        _ = client.catalogPlaylistOps().addCatalogPlaylist(id: playlist)
        XCTAssertEqual(library.sent.count, 1)
        XCTAssertTrue(command.sent.isEmpty)
    }

    func testTheTwoArgumentTestInitUsesTheOneTransportForEverything() {
        let one = RecordingTransport.replying(#"{"ok":true,"copies":[]}"#)
        let client = SourceAppClient(path: "p", transport: one.transport)
        _ = try? client.catalogPlaylistOps().copies(ofCatalogPlaylist: playlist)
        _ = client.catalogPlaylistOps().addCatalogPlaylist(id: playlist)
        XCTAssertEqual(one.sent.count, 2)
    }
}

// tools/music/Tests/MusicTests/SpanDACLibraryRefreshWireTests.swift
import XCTest
@testable import music

/// `slice.libraryRefresh` and the `library_refresh` completion fact on the wire:
/// the request bytes, which transport each goes over, and the fail-closed
/// decoders. A fixture transport only: no socket.
final class SpanDACLibraryRefreshWireTests: XCTestCase {

    private final class Wire {
        var ordinary: [String] = []
        var library: [String] = []
    }

    private func control(_ wire: Wire, library: @escaping () -> String = { "" },
                         ordinary: @escaping () -> String = { "" }) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent",
                         transport: { _, line in wire.ordinary.append(line); return ordinary() },
                         libraryTransport: { _, line in wire.library.append(line); return library() })
    }

    private func refreshReply(_ outcome: String, _ ticket: String, instance: String = #""inst-1""#) -> String {
        #"{"ok":true,"op":"slice.libraryRefresh","outcome":"\#(outcome)","ticket":\#(ticket),"instance":\#(instance)}"#
    }
    private func statusReply(_ fact: String?) -> String {
        let f = fact.map { #","library_refresh":\#($0)"# } ?? ""
        return #"{"ok":true,"op":"slice.status","status":{"playback":"stopped","capabilities":["library.refresh"]\#(f)}}"#
    }

    func testTheNamesAreTheFixedContractNames() {
        XCTAssertEqual(sourceLibraryRefreshOp, "slice.libraryRefresh")
        XCTAssertEqual(sourceLibraryRefreshCapability, "library.refresh")
    }

    func testTheRefreshIsOnlyTheOpAndGoesOverTheLibraryTransport() throws {
        let wire = Wire()
        let outcome = try control(wire, library: { self.refreshReply("started", "7") }).libraryRefresh()
        XCTAssertEqual(outcome, .started(ticket: 7, instance: "inst-1"))
        XCTAssertEqual(wire.ordinary, [], "a refresh is a library op: the longer transport")
        XCTAssertEqual(wire.library.count, 1)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.library[0].utf8)) as? [String: Any])
        XCTAssertEqual(sent as NSDictionary, ["op": "slice.libraryRefresh"] as NSDictionary)
    }

    func testTheCompletionFactIsASliceStatusReadOnTheOrdinaryTransport() throws {
        let wire = Wire()
        let done = try control(wire, ordinary: { self.statusReply(#"{"instance":"inst-1","ticket":7,"result":"installed"}"#) })
            .libraryRefreshCompletion()
        XCTAssertEqual(done, SpanDACLibraryRefreshCompletion(instance: "inst-1", ticket: 7, result: .installed))
        XCTAssertEqual(wire.library, [], "the status read went down the library transport")
        XCTAssertEqual(wire.ordinary.count, 1)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.ordinary[0].utf8)) as? [String: Any])
        XCTAssertEqual(sent as NSDictionary, ["op": "slice.status"] as NSDictionary)
    }

    func testEachOutcomeDecodes() throws {
        XCTAssertEqual(try control(Wire(), library: { self.refreshReply("started", "7") }).libraryRefresh(), .started(ticket: 7, instance: "inst-1"))
        XCTAssertEqual(try control(Wire(), library: { self.refreshReply("joined", "7") }).libraryRefresh(), .joined(ticket: 7, instance: "inst-1"))
        XCTAssertEqual(try control(Wire(), library: { self.refreshReply("deferred", "null") }).libraryRefresh(), .deferred)
        XCTAssertEqual(try control(Wire(), library: { #"{"ok":true,"op":"slice.libraryRefresh","outcome":"deferred","ticket":null}"# })
            .libraryRefresh(), .deferred, "a deferred reply needs no instance")
    }

    func testAnOutcomeThatIsNotOneTheClientCanFollowIsMalformed() {
        let bad = [
            #"{"ok":true,"op":"slice.libraryRefresh"}"#,                                   // the old shape
            #"{"ok":true,"op":"slice.libraryRefresh","started":true}"#,
            refreshReply("started", "null"),                                                // no ticket
            refreshReply("joined", "-1"),
            refreshReply("started", "true"),
            refreshReply("started", "\"7\""),
            refreshReply("started", "7", instance: "null"),                                  // no instance
            refreshReply("joined", "7", instance: #""  ""#),
            refreshReply("rebuilding", "7"),
            refreshReply("", "7"),
        ]
        for reply in bad {
            XCTAssertThrowsError(try control(Wire(), library: { reply }).libraryRefresh(), reply) { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(error) for \(reply)") }
            }
        }
    }

    func testARefusalThrowsLikeAnyOtherOp() {
        let refused = #"{"ok":false,"op":"slice.libraryRefresh","error":{"kind":"unknown_op","detail":"no such op"}}"#
        XCTAssertThrowsError(try control(Wire(), library: { refused }).libraryRefresh())
    }

    func testTheCompletionFactDecodes() throws {
        func fact(_ raw: String?) throws -> SpanDACLibraryRefreshCompletion? {
            try control(Wire(), ordinary: { self.statusReply(raw) }).libraryRefreshCompletion()
        }
        XCTAssertEqual(try fact(#"{"instance":"i","ticket":7,"result":"installed"}"#), .init(instance: "i", ticket: 7, result: .installed))
        XCTAssertEqual(try fact(#"{"instance":"i","ticket":8,"result":"failed"}"#), .init(instance: "i", ticket: 8, result: .failed))
        XCTAssertEqual(try fact(#"{"instance":"i","ticket":9,"result":"cancelled"}"#), .init(instance: "i", ticket: 9, result: .cancelled))
        XCTAssertNil(try fact("null"), "null: no rebuild has ended")
        XCTAssertNil(try fact(nil), "absent: a SpanDAC that does not carry it")
    }

    func testAnUnreadableCompletionFactIsMalformedNotAVerdict() {
        for raw in [#"{"instance":"i","ticket":7}"#, #"{"instance":"i","result":"installed"}"#,
                    #"{"instance":"i","ticket":7,"result":"done"}"#,
                    #"{"instance":"i","ticket":"7","result":"installed"}"#, #"{"instance":"i","ticket":-1,"result":"installed"}"#,
                    #"{"ticket":7,"result":"installed"}"#, #"{"instance":" ","ticket":7,"result":"installed"}"#,
                    #""installed""#] {
            XCTAssertThrowsError(try control(Wire(), ordinary: { self.statusReply(raw) }).libraryRefreshCompletion(), raw) { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(error) for \(raw)") }
            }
        }
    }

    /// A provider whose status cannot be read says "not advertised": the capability
    /// is read from `capabilities`, and only `library.refresh` counts.
    func testTheProviderReadsTheCapabilityFromStatus() {
        func advertises(_ caps: String) -> Bool {
            let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"stopped","capabilities":\#(caps)}}"#
            return BridgeMusicProvider(control: control(Wire(), ordinary: { reply })).supportsLibraryRefresh()
        }
        XCTAssertTrue(advertises(#"["slice.status","library.refresh"]"#))
        XCTAssertFalse(advertises(#"["slice.status","queue.jump"]"#))
        XCTAssertFalse(advertises("[]"))
    }
}

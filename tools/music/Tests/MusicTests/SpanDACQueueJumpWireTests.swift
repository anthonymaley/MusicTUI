// tools/music/Tests/MusicTests/SpanDACQueueJumpWireTests.swift
import XCTest
@testable import music

/// `slice.queueJump` on the wire: the request bytes, the 1-based to 0-based row
/// conversion, the fail-closed reply decoder, and the error envelope. A fixture
/// transport only: no socket, no player.
final class SpanDACQueueJumpWireTests: XCTestCase {

    private func status(token: String? = "tok-1", title: String = "Song 3", playback: String = "playing") -> String {
        let t = token.map { #","queue_token":"\#($0)""# } ?? ""
        return #"{"playback":"\#(playback)","contract":3,"authorization":"authorized","title":"\#(title)","artist":"A","row":2,"next_rows":[3,4],"capabilities":["slice.status","queue.jump"],"queue":{"phase":"complete","requested":5,"present":5,"index":2}\#(t)}"#
    }

    private func ok(top: String? = "tok-1", status: String? = nil) -> String {
        let t = top.map { #","queue_token":"\#($0)""# } ?? ""
        return #"{"ok":true,"op":"slice.queueJump","status":\#(status ?? self.status())\#(t)}"#
    }

    private final class Wire {
        var lines: [String] = []
        var libraryLines: [String] = []
    }

    private func control(_ wire: Wire, reply: @escaping () -> String) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent",
                         transport: { _, line in wire.lines.append(line); return reply() },
                         libraryTransport: { _, line in wire.libraryLines.append(line); return reply() })
    }

    private func sentObject(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: the request

    func testTheOpAndCapabilityAreTheFixedContractNames() {
        XCTAssertEqual(sourceQueueJumpOp, "slice.queueJump")
        XCTAssertEqual(sourceQueueJumpCapability, "queue.jump")
    }

    /// The public entry's `index` is ONE-based (the list the play sent, place
    /// 1 first); the wire's `row` is ZERO-based. Pinned both ways, and the
    /// impossible indexes have no row.
    func testAnEntryIndexIsOneBasedAndTheWireRowIsZeroBased() {
        XCTAssertEqual(SourceAppControl.queueJumpRow(forEntryIndex: 1), 0)
        XCTAssertEqual(SourceAppControl.queueJumpRow(forEntryIndex: 2), 1)
        XCTAssertEqual(SourceAppControl.queueJumpRow(forEntryIndex: 5000), 4999)
        XCTAssertNil(SourceAppControl.queueJumpRow(forEntryIndex: 0))
        XCTAssertNil(SourceAppControl.queueJumpRow(forEntryIndex: -3))
    }

    func testTheRequestCarriesOnlyOpTokenAndZeroBasedRowOnTheLibraryTransport() throws {
        let wire = Wire()
        let result = try control(wire, reply: { self.ok() }).queueJump(token: "tok-1", row: 2)
        XCTAssertEqual(wire.lines, [], "a jump may wait on the player: the longer transport")
        XCTAssertEqual(wire.libraryLines.count, 1)
        let sent = try sentObject(wire.libraryLines[0])
        XCTAssertEqual(Set(sent.keys), ["op", "queue_token", "row"])
        XCTAssertEqual(sent["op"] as? String, "slice.queueJump")
        XCTAssertEqual(sent["queue_token"] as? String, "tok-1")
        XCTAssertEqual(sent["row"] as? Int, 2)
        XCTAssertEqual(result.queueToken, "tok-1", "the token that stood, returned")
        XCTAssertEqual(result.status.title, "Song 3")
        XCTAssertEqual(result.status.row, 2)
    }

    func testABlankTokenOrNegativeRowIsRefusedBeforeAnythingIsSent() {
        let wire = Wire()
        let c = control(wire, reply: { self.ok() })
        XCTAssertThrowsError(try c.queueJump(token: "  ", row: 0))
        XCTAssertThrowsError(try c.queueJump(token: "tok-1", row: -1))
        XCTAssertEqual(wire.lines + wire.libraryLines, [])
    }

    // MARK: the reply

    func testASuccessReplyWithoutAStatusOrATokenIsMalformedNotAJump() {
        let cases: [(String, String)] = [
            ("no status", #"{"ok":true,"op":"slice.queueJump","queue_token":"tok-2"}"#),
            ("no top-level token", ok(top: nil)),
            ("blank token", ok(top: "  ")),
            ("top-level and status tokens differ", ok(top: "tok-9")),
            ("a token other than the one asked for, in both places",
             ok(top: "tok-2", status: status(token: "tok-2"))),
            ("no token in the status", ok(status: status(token: nil))),
            ("paused, not playing", ok(status: status(playback: "paused"))),
            ("loading, not playing", ok(status: status(playback: "loading"))),
            ("stopped, not playing", ok(status: status(playback: "stopped"))),
        ]
        for (label, text) in cases {
            XCTAssertThrowsError(try control(Wire(), reply: { text }).queueJump(token: "tok-1", row: 0), label) {
                guard case SourceAppError.malformedReply = $0 else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    // MARK: the error envelope

    func testEveryRefusalKindReachesThePersonAsSpanDACsOwnWords() {
        func refusal(_ kind: String, _ detail: String) -> String {
            #"{"ok":false,"op":"slice.queueJump","error":{"kind":"\#(kind)","detail":"\#(detail)"}}"#
        }
        let cases: [(String, String, SourceAppError)] = [
            ("stale_token", "The queue changed.", .refused("The queue changed.")),
            ("shuffled", "A shuffled queue has no rows to jump to.", .refused("A shuffled queue has no rows to jump to.")),
            ("unbound_row", "That row is not in the queue.", .refused("That row is not in the queue.")),
            ("ambiguous_row", "That song is in the queue twice.", .refused("That song is in the queue twice.")),
            ("bad_request", "The player could not play that row; playback was paused", .refused("The player could not play that row; playback was paused")),
            (spanDACLicenceRefusalKind, "SpanDAC needs a licence.", .unlicensed("SpanDAC needs a licence.")),
            ("unknown_op", "", .unsupported(sourceQueueJumpOp)),
            ("player_disconnected", "Lost the player.", .playerDisconnected("Lost the player.")),
        ]
        for (kind, detail, expected) in cases {
            XCTAssertThrowsError(try control(Wire(), reply: { refusal(kind, detail) }).queueJump(token: "tok-1", row: 0), kind) {
                XCTAssertEqual($0 as? SourceAppError, expected, kind)
            }
        }
    }

    func testAnOlderSpanDACsDefaultIsUnsupportedNotASilentSuccess() {
        struct Bare: SourceControlling {
            func status() throws -> SourceStatus { throw SourceAppError.unreadable }
            func resume() throws {}; func pause() throws {}; func next() throws {}
            func previous() throws {}; func stop() throws {}
            func seek(toSeconds: Double) throws {}; func seek(byOffset: Double) throws {}
            func queue(rows: [SourceLibraryRow]) throws {}
            func queue(catalogIDs: [String]) throws {}
            func playStation(id: String, named: String) throws {}
            func librarySongs(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
            func queue(libraryIDs: [String], startRequired: Bool) throws -> Int { 0 }
            func libraryAlbums(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
            func libraryArtists(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
            func libraryAlbumTracks(albumID: String) throws -> MusicList { throw SourceAppError.unreadable }
            func libraryArtistAlbums(artistID: String) throws -> MusicList { throw SourceAppError.unreadable }
            func libraryArtistSongs(artistID: String) throws -> MusicList { throw SourceAppError.unreadable }
            func libraryPlaylists(cursor: String?, limit: Int) throws -> MusicPage { throw SourceAppError.unreadable }
            func libraryPlaylistTracks(playlistID: String, cursor: String?, limit: Int, forQueue: Bool) throws -> MusicPage {
                throw SourceAppError.unreadable
            }
        }
        XCTAssertThrowsError(try Bare().queueJump(token: "t", row: 0)) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported(sourceQueueJumpOp))
        }
    }
}

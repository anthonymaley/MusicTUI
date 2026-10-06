// tools/music/Tests/MusicTests/SpanDACPlayLibraryTests.swift
import XCTest
@testable import music

/// `slice.playLibrary` and the queue token, at the wire and the pure window.
/// Fakes only: a canned transport, no socket, no real SpanDAC, no real MusicTUI player.
final class SpanDACPlayLibraryTests: XCTestCase {

    /// Answers every request with one canned reply and records what was sent.
    private final class Canned {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        let reply: String
        init(_ reply: String) { self.reply = reply }
        func transport(_ path: String, _ line: String) throws -> String {
            lock.lock(); lines.append(line); lock.unlock()
            return reply
        }
        var bodies: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
    }

    private func control(_ canned: Canned) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: canned.transport)
    }

    private func playReply(extra: String = "", queued: String = "796", unavailable: String = "4",
                           videos: String = "0", token: String = "qa-1") -> String {
        #"""
        {"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":796,"present":796,"index":41},"queue_token":"\#(token)"},"queued":\#(queued),"skipped_unavailable":\#(unavailable),"skipped_videos":\#(videos),"queue_token":"\#(token)"\#(extra)}
        """#
    }

    // MARK: - the request

    func testAnAlbumPlaySendsKindAndIdAndNoStart() throws {
        let canned = Canned(playReply())
        _ = try control(canned).playLibrary(kind: .album, id: "al1", start: nil, listRev: nil, shuffle: false)
        let body = try XCTUnwrap(canned.bodies.first)
        XCTAssertEqual(body["op"] as? String, "slice.playLibrary")
        XCTAssertEqual(body["kind"] as? String, "album")
        XCTAssertEqual(body["id"] as? String, "al1")
        XCTAssertEqual(SourceAppControl.bool(body["shuffle"]), false, "shuffle is sent explicitly")
        XCTAssertNil(body["start_index"])
        XCTAssertNil(body["start_id"])
    }

    func testAFromRowPlaySendsBothStartFieldsAndASongsPlaySendsNoId() throws {
        let canned = Canned(playReply())
        _ = try control(canned).playLibrary(kind: .songs, id: nil, start: LibraryPlayStart(index: 41, id: "i.x"),
                                            listRev: nil, shuffle: false)
        let body = try XCTUnwrap(canned.bodies.first)
        XCTAssertEqual(body["kind"] as? String, "songs")
        XCTAssertNil(body["id"], "a songs play names no container")
        XCTAssertEqual(body["start_index"] as? Int, 41)
        XCTAssertEqual(body["start_id"] as? String, "i.x")
    }

    func testAShuffledPlayTakesNoStartAndIsRefusedBeforeAnythingIsSent() {
        let canned = Canned(playReply())
        XCTAssertThrowsError(try control(canned).playLibrary(
            kind: .playlist, id: "p1", start: LibraryPlayStart(index: 0, id: "i.a"), listRev: nil, shuffle: true))
        XCTAssertTrue(canned.lines.isEmpty, "a shuffle with a start must not reach SpanDAC")

        let ok = Canned(playReply())
        XCTAssertNoThrow(try control(ok).playLibrary(kind: .playlist, id: "p1", start: nil, listRev: nil, shuffle: true))
        XCTAssertEqual(SourceAppControl.bool(ok.bodies.first?["shuffle"]), true)
    }

    func testAContainerPlayNeedsAnIdAndASongsPlayMustNotCarryOne() {
        let canned = Canned(playReply())
        XCTAssertThrowsError(try control(canned).playLibrary(kind: .artist, id: nil, start: nil, listRev: nil, shuffle: false))
        XCTAssertThrowsError(try control(canned).playLibrary(kind: .songs, id: "x", start: nil, listRev: nil, shuffle: false))
        XCTAssertTrue(canned.lines.isEmpty)
    }

    func testTheListRevTravelsWhenThereIsOneAndOnlyThen() throws {
        let canned = Canned(playReply())
        _ = try control(canned).playLibrary(kind: .playlist, id: "p1", start: LibraryPlayStart(index: 3, id: "i.d"),
                                            listRev: "rev-9", shuffle: false)
        XCTAssertEqual(canned.bodies.first?["list_rev"] as? String, "rev-9")
        let none = Canned(playReply())
        _ = try control(none).playLibrary(kind: .playlist, id: "p1", start: nil, listRev: nil, shuffle: false)
        XCTAssertNil(none.bodies.first?["list_rev"], "no read, no list_rev")
    }

    func testEveryContainerReadCarriesItsListRevAndAnOlderSpanDACsHasNone() throws {
        func page(_ extra: String) -> String {
            #"{"ok":true,"op":"x","generation":3,"total":1,"items":[{"id":"i.a","title":"A","artist":"B","kind":"song"}],"next_cursor":null,"skipped_videos":0\#(extra)}"#
        }
        XCTAssertEqual(try control(Canned(page(#","list_rev":"gen-7""#))).librarySongs(cursor: nil, limit: 100).listRev, "gen-7")
        XCTAssertEqual(try control(Canned(page(#","list_rev":"fp-1""#)))
            .libraryPlaylistTracks(playlistID: "p", cursor: nil, limit: 500).listRev, "fp-1")
        XCTAssertNil(try control(Canned(page(""))).librarySongs(cursor: nil, limit: 100).listRev)
        XCTAssertNil(try control(Canned(page(#","list_rev":"""#))).librarySongs(cursor: nil, limit: 100).listRev)
        func list(_ extra: String) -> String {
            #"{"ok":true,"op":"x","generation":3,"items":[{"id":"i.a","title":"A","artist":"B","kind":"song"}]\#(extra)}"#
        }
        XCTAssertEqual(try control(Canned(list(#","list_rev":"al-1""#))).libraryAlbumTracks(albumID: "a").listRev, "al-1")
        XCTAssertEqual(try control(Canned(list(#","list_rev":"ar-1""#))).libraryArtistSongs(artistID: "a").listRev, "ar-1")
        XCTAssertNil(try control(Canned(list(""))).libraryAlbumTracks(albumID: "a").listRev)
    }

    // MARK: - slice.listRev

    func testTheRevisionReadSendsKindAndIdAndOmitsTheIdForSongs() throws {
        let canned = Canned(#"{"ok":true,"op":"slice.listRev","kind":"artist","list_rev":"fp-9","count":1001}"#)
        _ = try control(canned).listRev(kind: .artist, id: "ar1")
        let body = try XCTUnwrap(canned.bodies.first)
        XCTAssertEqual(body["op"] as? String, "slice.listRev")
        XCTAssertEqual(body["kind"] as? String, "artist")
        XCTAssertEqual(body["id"] as? String, "ar1")
        let songs = Canned(#"{"ok":true,"op":"slice.listRev","kind":"songs","list_rev":"gen-7","count":15646}"#)
        _ = try control(songs).listRev(kind: .songs, id: nil)
        XCTAssertNil(songs.bodies.first?["id"])
        XCTAssertThrowsError(try control(Canned("{}")).listRev(kind: .songs, id: "x"))
        XCTAssertThrowsError(try control(Canned("{}")).listRev(kind: .album, id: nil))
    }

    func testTheRevisionReplyIsReadStrictly() throws {
        let ok = try control(Canned(#"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":"fp-1","count":12}"#))
            .listRev(kind: .album, id: "a")
        XCTAssertEqual(ok.listRev, "fp-1")
        XCTAssertEqual(ok.count, 12)
        for bad in [
            #"{"ok":true,"op":"slice.listRev","kind":"album","count":12}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":"","count":12}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":7,"count":12}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":"fp-1"}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":"fp-1","count":-1}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"album","list_rev":"fp-1","count":true}"#,
            #"{"ok":true,"op":"slice.listRev","kind":"playlist","list_rev":"fp-1","count":3}"#,
        ] {
            XCTAssertThrowsError(try control(Canned(bad)).listRev(kind: .album, id: "a"), bad) { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(bad): \(error)") }
            }
        }
    }

    func testTheRevisionReadKeepsItsRefusalKindsAndAnOlderSpanDACReadsAsUpdate() {
        func attempt(_ reply: String) -> Error? {
            do { _ = try control(Canned(reply)).listRev(kind: .playlist, id: "p"); return nil } catch { return error }
        }
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"warming","detail":"w","retry_after":2.0}}"#)
                        as? SourceAppError, .warming("w", retryAfter: 2.0))
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"not_in_library","detail":"gone"}}"#)
                        as? SourceAppError, .refused("gone"))
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"library_changed","detail":"That list has changed since you saw it; open it again to see the new list."}}"#)
                        as? SourceAppError, .refused("That list has changed since you saw it; open it again to see the new list."))
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"unsupported_item","detail":"That playlist cannot be played."}}"#)
                        as? SourceAppError, .refused("That playlist cannot be played."))
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"busy","detail":"busy"}}"#)
                        as? SourceAppError, .busy)
        XCTAssertEqual(attempt(#"{"ok":false,"op":"slice.listRev","error":{"kind":"unknown_op","detail":"x"}}"#)
                        as? SourceAppError, .unsupported("slice.listRev"))
        let provider = BridgeMusicProvider(control: control(Canned(
            #"{"ok":false,"op":"slice.listRev","error":{"kind":"unknown_op","detail":"x"}}"#)))
        XCTAssertThrowsError(try provider.listRev(kind: .playlist, id: "p")) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This SpanDAC build can't read a list's revision \u{2014} update SpanDAC"))
        }
    }

    // MARK: - the reply

    func testTheReplyCarriesQueuedBothSkipCountsTheTokenAndTheQueue() throws {
        let canned = Canned(playReply(queued: "796", unavailable: "3", videos: "2", token: "qabc-7"))
        let result = try control(canned).playLibrary(kind: .playlist, id: "p1", start: nil, listRev: nil, shuffle: false)
        XCTAssertEqual(result.queued, 796)
        XCTAssertEqual(result.skippedUnavailable, 3)
        XCTAssertEqual(result.skippedVideos, 2)
        XCTAssertEqual(result.requested, 796, "the status's own requested count")
        XCTAssertEqual(result.queueToken, "qabc-7")
        XCTAssertEqual(result.queue, .complete(requested: 796, present: nil))
    }

    func testAReplyWithoutTheCountsItMustCarryIsMalformedNotZero() {
        let missingQueued = #"{"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","contract":3,"authorization":"authorized"},"skipped_unavailable":0,"skipped_videos":0}"#
        XCTAssertThrowsError(try control(Canned(missingQueued))
            .playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false)) { error in
            guard case SourceAppError.malformedReply = error else { return XCTFail("\(error)") }
        }
        for bad in [#""queued":true"#, #""queued":-1"#, #""queued":1.5"#, #""queued":"9""#] {
            let reply = #"{"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","contract":3,"authorization":"authorized"},\#(bad),"skipped_unavailable":0,"skipped_videos":0}"#
            XCTAssertThrowsError(try control(Canned(reply))
                .playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false), bad) { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(bad): \(error)") }
            }
        }
        let noSkips = #"{"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","contract":3,"authorization":"authorized"},"queued":5}"#
        XCTAssertThrowsError(try control(Canned(noSkips))
            .playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false), "a skip is never silent")
    }

    /// `play.library` promises a token on every successful play reply: the
    /// top-level one AND the same one in the reply's own status. A reply without
    /// both, or with two that differ, is a broken peer, and no rows are retained
    /// against it (Codex 116, finding 1).
    func testASuccessfulPlayReplyWithoutItsTokenIsMalformedNotNil() {
        func reply(top: String, embedded: String) -> String {
            #"{"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","contract":3,"authorization":"authorized"\#(embedded)},"queued":5,"skipped_unavailable":0,"skipped_videos":0\#(top)}"#
        }
        let cases: [(String, String, String)] = [
            ("no top-level token", "", #","queue_token":"q-1""#),
            ("blank top-level token", #","queue_token":"""#, #","queue_token":"q-1""#),
            ("no embedded token", #","queue_token":"q-1""#, ""),
            ("blank embedded token", #","queue_token":"q-1""#, #","queue_token":" ""#),
            ("two different tokens", #","queue_token":"q-1""#, #","queue_token":"q-2""#),
            ("no token at all", "", ""),
            ("a top-level token that is not text", #","queue_token":7"#, #","queue_token":"q-1""#),
        ]
        for (label, top, embedded) in cases {
            XCTAssertThrowsError(try control(Canned(reply(top: top, embedded: embedded)))
                .playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false), label) { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(label): \(error)") }
            }
        }
        XCTAssertNoThrow(try control(Canned(reply(top: #","queue_token":"q-1""#, embedded: #","queue_token":"q-1""#)))
            .playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false))
    }

    /// The nil-token compatibility is the LEGACY paths' alone: an older SpanDAC's
    /// `slice.queue` reply carries none, and that stays a success with no token.
    func testALegacyQueueReplyWithoutATokenStaysASuccess() throws {
        let older = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","contract":3,"authorization":"authorized"}}"#
        XCTAssertNil(try control(Canned(older)).queueRetainingToken(libraryIDs: ["a"], startRequired: false).queueToken)
    }

    func testTheRefusalsKeepTheirKinds() {
        func refusal(_ kind: String, _ extra: String = "") -> String {
            #"{"ok":false,"op":"slice.playLibrary","error":{"kind":"\#(kind)","detail":"SpanDAC says \#(kind)"\#(extra)}}"#
        }
        func attempt(_ reply: String) -> Error? {
            do { _ = try control(Canned(reply)).playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false); return nil }
            catch { return error }
        }
        XCTAssertEqual(attempt(refusal("warming", #","retry_after":2.0"#)) as? SourceAppError,
                       .warming("SpanDAC says warming", retryAfter: 2.0))
        XCTAssertEqual(attempt(refusal("library_changed")) as? SourceAppError, .refused("SpanDAC says library_changed"))
        XCTAssertEqual(attempt(refusal("not_in_library")) as? SourceAppError, .refused("SpanDAC says not_in_library"))
        XCTAssertEqual(attempt(refusal("queue_failed")) as? SourceAppError, .refused("SpanDAC says queue_failed"))
        XCTAssertEqual(attempt(refusal("unauthorized")) as? SourceAppError, .notAuthorized)
        XCTAssertEqual(attempt(refusal("unknown_op")) as? SourceAppError, .unsupported("slice.playLibrary"))
        guard case .playerDisconnected(_)? = attempt(refusal("player_disconnected")) as? SourceAppError else {
            return XCTFail("player_disconnected lost its kind")
        }
    }

    func testAnOlderSpanDACsUnknownOpReadsAsUpdateSpanDACThroughTheProvider() {
        let reply = #"{"ok":false,"op":"slice.playLibrary","error":{"kind":"unknown_op","detail":"unknown op"}}"#
        let provider = BridgeMusicProvider(control: control(Canned(reply)))
        XCTAssertThrowsError(try provider.playLibrary(kind: .album, id: "a", start: nil, listRev: nil, shuffle: false)) { error in
            XCTAssertEqual(error as? MusicProviderError,
                           .notImplemented("This SpanDAC build can't play a whole list \u{2014} update SpanDAC"))
        }
    }

    // MARK: - the capability

    private func statusReply(capabilities: String, extra: String = "") -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"T","artist":"A"\#(extra),"capabilities":\#(capabilities)}}"#
    }

    func testTheCapabilityIsReadFromSpanDACsOwnList() throws {
        let capable = try control(Canned(statusReply(capabilities: #"["slice.shuffle","play.library"]"#))).status()
        XCTAssertTrue(capable.offersPlayLibrary)
        let older = try control(Canned(statusReply(capabilities: #"["slice.shuffle"]"#))).status()
        XCTAssertFalse(older.offersPlayLibrary)

        XCTAssertTrue(BridgeMusicProvider(control: control(Canned(statusReply(capabilities: #"["play.library"]"#))))
            .supportsPlayLibrary())
        XCTAssertFalse(BridgeMusicProvider(control: control(Canned(statusReply(capabilities: "[]"))))
            .supportsPlayLibrary())
        let unreadable = Canned(#"{"ok":false,"op":"slice.status","error":{"kind":"bad_request","detail":"no"}}"#)
        XCTAssertFalse(BridgeMusicProvider(control: control(unreadable)).supportsPlayLibrary(),
                       "a status that cannot be read keeps today's path")
    }

    // MARK: - the token on the wire

    func testStatusDecodesTheQueueTokenAndTreatsBlankAsAbsent() throws {
        let with = try control(Canned(statusReply(capabilities: "[]", extra: #","queue_token":"qa-3""#))).status()
        XCTAssertEqual(with.queueToken, "qa-3")
        XCTAssertNil(try control(Canned(statusReply(capabilities: "[]"))).status().queueToken)
        XCTAssertNil(try control(Canned(statusReply(capabilities: "[]", extra: #","queue_token":"""#))).status().queueToken)
        XCTAssertNil(try control(Canned(statusReply(capabilities: "[]", extra: #","queue_token":7"#))).status().queueToken,
                     "a token that is not a string is absent")
    }

    func testALibraryIDQueueReportsTheTokenItsReplyCarried() throws {
        let reply = #"{"ok":true,"op":"slice.queue","skipped_unavailable":1,"status":{"playback":"playing","contract":3,"authorization":"authorized"},"queue_token":"qx-9"}"#
        let canned = Canned(reply)
        let sent = try control(canned).queueRetainingToken(libraryIDs: ["a", "b", "c"], startRequired: true)
        XCTAssertEqual(sent.skippedUnavailable, 1)
        XCTAssertEqual(sent.queueToken, "qx-9")
        XCTAssertEqual(canned.bodies.first?["library_ids"] as? [String], ["a", "b", "c"])
        XCTAssertEqual(SourceAppControl.bool(canned.bodies.first?["start_required"]), true)
        // The old entry point is the same request.
        XCTAssertEqual(try control(Canned(reply)).queue(libraryIDs: ["a", "b", "c"], startRequired: false), 1)
        let older = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","contract":3,"authorization":"authorized"}}"#
        XCTAssertNil(try control(Canned(older)).queueRetainingToken(libraryIDs: ["a"], startRequired: false).queueToken)
    }

    // MARK: - next_rows (SpanDAC stops at 5,000, and so does this)

    func testNextRowsAreKeptUpToExactlyWhatSpanDACSends() throws {
        XCTAssertEqual(SourceAppControl.nextRowsSanityCap, 5000, "SpanDAC's own statusNextRowsMaximum")
        let exactly = (0..<5000).map(String.init).joined(separator: ",")
        let s = try control(Canned(statusReply(capabilities: "[]", extra: #","row":0,"next_rows":[\#(exactly)]"#))).status()
        XCTAssertEqual(s.nextRows?.count, 5000)
        XCTAssertEqual(s.nextRows?.last, 4999)
    }

    // MARK: - the window and the token (Codex 106, finding 6)

    private func song(_ n: Int, alias: String? = nil, album: String = "Album", title: String? = nil) -> MusicRow {
        var r = MusicRow(id: "i\(n)", title: title ?? "Song \(n)", artist: "Artist \(n)", album: album, kind: .song)
        r.alias = alias
        return r
    }

    private func status(title: String, row: Int, next: [Int], token: String?) throws -> SourceStatus {
        let t = token.map { #","queue_token":"\#($0)""# } ?? ""
        let list = next.map(String.init).joined(separator: ",")
        let reply = statusReply(capabilities: "[]", extra: #","row":\#(row),"next_rows":[\#(list)]\#(t)"#)
            .replacingOccurrences(of: #""title":"T""#, with: #""title":"\#(title)""#)
        return try control(Canned(reply)).status()
    }

    /// The Codex 106 S6 reproduction: process A records ["Intro", "A next"];
    /// process B replaces the queue with ["Intro", "B next"]. Status says row 0,
    /// next_rows [1], title Intro, and a token that is B's.
    func testAnotherProcesssQueueDoesNotBorrowThisProcesssRows() throws {
        let aRows = [song(0, alias: "-1", title: "Intro"), song(1, alias: "-2", title: "A next")]
        let fromB = try status(title: "Intro", row: 0, next: [1], token: "qB-2")

        let wrong = spanDACQueueWindow(sent: aRows, token: "qA-1", status: fromB)
        XCTAssertNil(wrong.current, "A's rows must not answer for B's queue: no cover fallback, no album")
        XCTAssertTrue(wrong.entries.isEmpty, "and no Up Next from A's list")

        let fromA = try status(title: "Intro", row: 0, next: [1], token: "qA-1")
        let right = spanDACQueueWindow(sent: aRows, token: "qA-1", status: fromA)
        XCTAssertEqual(right.current?.alias, "-1")
        XCTAssertEqual(right.entries.map(\.name), ["Intro", "A next"])
    }

    func testAStatusWithNoTokenDoesNotVouchForARecordedOne() throws {
        // The player was unloaded (or another client's play is not SpanDAC's own
        // assignment): status carries no token, so nothing retained is shown.
        let rows = [song(0), song(1)]
        let bare = try status(title: "Song 0", row: 0, next: [1], token: nil)
        XCTAssertTrue(spanDACQueueWindow(sent: rows, token: "qA-1", status: bare).entries.isEmpty)
    }

    /// Legacy plays only. An older SpanDAC sends no token in a play reply or a
    /// status, and the title check alone is all there is. A play whose reply had
    /// no token never reaches here from a SpanDAC that has tokens: a whole play
    /// without one is refused, and a legacy reply from a tokened SpanDAC carries it.
    func testWithoutARecordedTokenTheTitleCheckAppliesOnlyToAStatusWithNoTokenEither() throws {
        let rows = [song(0), song(1)]
        let old = try status(title: "Song 0", row: 0, next: [1], token: nil)
        XCTAssertEqual(spanDACQueueWindow(sent: rows, token: nil, status: old).entries.map(\.name), ["Song 0", "Song 1"])
        // A status that carries an assignment's token describes an assignment this
        // play holds no token for: it is not shown these rows, however alike the title.
        let newer = try status(title: "Song 0", row: 0, next: [1], token: "qZ-1")
        XCTAssertTrue(spanDACQueueWindow(sent: rows, token: nil, status: newer).entries.isEmpty)
        XCTAssertNil(spanDACQueueWindow(sent: rows, token: nil, status: newer).current)
    }

    /// SpanDAC may leave `next_rows` out under shuffle. That is "no Up Next list",
    /// never an error and never the container's order passed off as play order.
    func testAShuffledPlayWithNoNextRowsHasNoUpNextList() throws {
        let rows = (0..<4).map { song($0) }
        let reply = statusReply(capabilities: "[]", extra: #","row":2,"queue_token":"qA-1""#)
            .replacingOccurrences(of: #""title":"T""#, with: #""title":"Song 2""#)
        let bare = try control(Canned(reply)).status()
        XCTAssertNil(bare.nextRows)
        let shuffled = spanDACQueueWindow(sent: rows, token: "qA-1", shuffled: true, status: bare)
        XCTAssertEqual(shuffled.current?.id, "i2", "the playing row still gives the cover and album")
        XCTAssertEqual(shuffled.entries.map(\.name), ["Song 2"], "and no list after it")
        // The same status for an unshuffled play keeps today's in-order fallback.
        XCTAssertEqual(spanDACQueueWindow(sent: rows, token: "qA-1", shuffled: false, status: bare).entries.map(\.name),
                       ["Song 2", "Song 3"])
        // SpanDAC's own shuffle state says the same.
        let modeShuffle = try control(Canned(statusReply(capabilities: "[]", extra: #","row":2,"shuffle":true"#)
            .replacingOccurrences(of: #""title":"T""#, with: #""title":"Song 2""#))).status()
        XCTAssertEqual(spanDACQueueWindow(sent: rows, status: modeShuffle).entries.map(\.name), ["Song 2"])
    }

    // MARK: - the coordinator keeps the token with the rows

    private func routing() -> RoutingCoordinator {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.source)
        return RoutingCoordinator(store: modeStore, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in "{}" }) })
    }

    func testTheCoordinatorKeepsTheTokenWithTheRowsAndDropsBothOnALaterPlay() throws {
        let r = routing()
        XCTAssertNil(r.spanDACPlay())
        r.recordSpanDACPlay([song(0)], token: "qA-1")
        XCTAssertEqual(r.spanDACPlay()?.token, "qA-1")
        XCTAssertEqual(r.spanDACPlay()?.rows.map(\.id), ["i0"])
        XCTAssertEqual(r.spanDACPlayedRows()?.map(\.id), ["i0"])
        r.recordSpanDACPlay([song(1)])
        XCTAssertNil(r.spanDACPlay()?.token, "a play with no token records none")
        r.recordSpanDACPlay([song(2)], token: "qB-2", listRev: "rev-3", shuffled: true)
        XCTAssertEqual(r.spanDACPlay()?.listRev, "rev-3", "the list_rev is kept with the rows")
        XCTAssertEqual(r.spanDACPlay()?.shuffled, true)
        try r.perform(.radioStationPlay, expecting: nil, musicApp: { _ in }, source: { _ in }, unaffected: {})
        XCTAssertNil(r.spanDACPlay())
    }

    // MARK: - the poller applies the rule end to end

    func testThePollerShowsNoUpNextWhenStatusEchoesAnotherQueuesToken() throws {
        let aRows = [song(0, alias: "-596357614188841472"), song(1)]
        let fromB = statusReply(capabilities: "[]", extra: #","row":0,"next_rows":[1],"queue_token":"qB-2""#)
            .replacingOccurrences(of: #""title":"T""#, with: #""title":"Song 0""#)
        let r = RoutingCoordinator(store: { () -> PlaybackModeStore in
            let m = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"); m.set(.source); return m
        }(), surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in fromB }) })
        r.recordSpanDACPlay(aRows, token: "qA-1")
        let store = NowPlayingStore()
        let p = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                               appQueue: AppQueueStore(),
                               queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                               routing: r,
                               makeSourceClient: { SourceAppClient(path: "/nonexistent", transport: { _, _ in fromB }) })
        p.tick()
        let snap = store.read()
        XCTAssertTrue(snap.surrounding.isEmpty, "B's queue shows no A rows")
        XCTAssertNil(snap.bridge?.persistentID, "and no persistent-id fallback from A's list")

        // The same play echoed with its own token fills both, as before.
        let fromA = fromB.replacingOccurrences(of: "qB-2", with: "qA-1")
        let r2 = RoutingCoordinator(store: { () -> PlaybackModeStore in
            let m = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"); m.set(.source); return m
        }(), surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in fromA }) })
        r2.recordSpanDACPlay(aRows, token: "qA-1")
        let store2 = NowPlayingStore()
        let p2 = PlaybackPoller(store: store2, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                appQueue: AppQueueStore(),
                                queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                                routing: r2,
                                makeSourceClient: { SourceAppClient(path: "/nonexistent", transport: { _, _ in fromA }) })
        p2.tick()
        let snap2 = store2.read()
        XCTAssertEqual(snap2.surrounding.map(\.name), ["Song 0", "Song 1"])
        XCTAssertEqual(snap2.bridge?.persistentID, "-596357614188841472")
    }
}

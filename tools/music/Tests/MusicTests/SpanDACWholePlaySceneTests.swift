// tools/music/Tests/MusicTests/SpanDACWholePlaySceneTests.swift
import XCTest
@testable import music

/// Album, artist and playlist plays when SpanDAC lists `play.library`: the
/// scene sends ONE `slice.playLibrary` naming the container and the start row,
/// with no page walk and no id list, and keeps the rows it showed with the
/// reply's queue token. Without the capability, today's id-list path is
/// unchanged (the older tests in `BridgeLibraryPlaySceneTests` and
/// `BridgePlaylistsPlaySceneTests` pin it).
///
/// Fakes only. Every SpanDAC answer is canned through the real
/// `SourceAppControl`; the AppleScript backend is `/usr/bin/true`.
final class SpanDACWholePlaySceneTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let twoZone = shellLayout(width: 120, height: 30)   // no automatic playlist preview read
    private let threeZone = shellLayout(width: 160, height: 30) // draws the tracks pane
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - canned replies

    private static let capable = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":3,"authorization":"authorized","capabilities":["slice.shuffle","play.library"]}}"#
    private static let incapable = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":3,"authorization":"authorized","capabilities":["slice.shuffle"]}}"#

    private static func playReply(queued: Int, requested: Int? = nil, unavailable: Int = 0, videos: Int = 0,
                                  token: String = "qa-1") -> String {
        #"""
        {"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":\#(requested ?? queued),"present":\#(queued),"index":0},"queue_token":"\#(token)"},"queued":\#(queued),"skipped_unavailable":\#(unavailable),"skipped_videos":\#(videos),"queue_token":"\#(token)"}
        """#
    }

    /// `slice.listRev`'s answer: the list's revision and count, no rows.
    private static func revReply(_ kind: String, _ rev: String, count: Int = 3) -> String {
        #"{"ok":true,"op":"slice.listRev","kind":"\#(kind)","list_rev":"\#(rev)","count":\#(count)}"#
    }
    /// A listing read over SpanDAC's 1,000-song bound.
    private static let tooLarge = #"{"ok":false,"op":"slice.libraryAlbumTracks","error":{"kind":"too_large","detail":"That has more than 1,000 songs, which is more than SpanDAC will list."}}"#
    private static let unknownOp = #"{"ok":false,"op":"slice.listRev","error":{"kind":"unknown_op","detail":"unknown op"}}"#

    private static func refusal(_ kind: String, _ detail: String) -> String {
        #"{"ok":false,"op":"slice.playLibrary","error":{"kind":"\#(kind)","detail":"\#(detail)"}}"#
    }

    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],
     "next_cursor":null}
    """
    private let artistPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
    """
    private func trackReply(_ ids: [String], listRev: String? = "rev-al1") -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"Radiohead\",\"album\":\"In Rainbows\",\"kind\":\"song\",\"alias\":\"-\($0.dropFirst())\"}" }
            .joined(separator: ",")
        let rev = listRev.map { ",\"list_rev\":\"\($0)\"" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(items)]\(rev)}"
    }
    private let onePlaylistPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"Chill","kind":"playlist"}],"next_cursor":null}
    """
    private func playlistTracks(_ ids: [String], skippedVideos: Int = 0, listRev: String? = "rev-pl1") -> String {
        let rev = listRev.map { ",\"list_rev\":\"\($0)\"" } ?? ""
        let rows = ids.map { "{\"id\":\"\($0)\",\"title\":\"P\($0)\",\"artist\":\"Art\",\"kind\":\"song\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":\(ids.count),
         "items":[\(rows)],"next_cursor":null,"skipped_videos":\(skippedVideos)\(rev)}
        """
    }

    // MARK: - harness

    /// A canned SpanDAC whose `slice.status` keeps answering with its last scripted
    /// reply: a play reads the capabilities before it sends anything.
    private func stickyWire(_ replies: [String: [String]] = [:]) -> BridgeLibraryReadsWire {
        let wire = BridgeLibraryReadsWire(replies)
        wire.stickyStatus = true
        return wire
    }

    private func routing(_ wire: BridgeLibraryReadsWire) -> RoutingCoordinator {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        return RoutingCoordinator(store: store, surface: .tui,
                                  makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
    }

    private func settlePlayed(_ wire: BridgeLibraryReadsWire, seconds: Double = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !wire.sent("slice.playLibrary").isEmpty { return true }
            usleep(5_000)
        }
        return !wire.sent("slice.playLibrary").isEmpty
    }

    /// Lets a play that was NOT supposed to send a queue run to the end.
    private func pause(_ seconds: Double = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { usleep(10_000) }
    }

    private func albumScene(_ wire: BridgeLibraryReadsWire, status: StatusStore = StatusStore(),
                            routing: RoutingCoordinator? = nil,
                            sleep: @escaping (TimeInterval) -> Void = { _ in }) -> LibraryScene {
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 status: status, warmUpSleep: sleep, routing: routing)
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        return s
    }

    // MARK: - albums

    func testPOnAnAlbumSendsOnePlayLibraryWithTheListRevOfItsReadAndNoIdList() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                                           "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
                                           "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 3)]])
        let s = albumScene(wire, status: StatusStore())
        _ = s.handle(.char("p"))
        XCTAssertTrue(settlePlayed(wire), "the album never reached SpanDAC as a container play")
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "album")
        XCTAssertEqual(req["id"] as? String, "al1")
        XCTAssertNil(req["start_index"])
        XCTAssertNil(req["start_id"])
        XCTAssertEqual(req["list_rev"] as? String, "rev-al1", "SpanDAC refuses a container play with no list_rev")
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), false)
        pause()
        XCTAssertTrue(wire.sent("slice.queue").isEmpty, "an id list was sent as well")
        XCTAssertNil(req["library_ids"])
    }

    func testEnterOnAnAlbumTrackSendsTheStartRowByIndexAndIdAndKeepsTheWholeAlbumsRows() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                           "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 3, token: "qalbum-4")]])
        let r = routing(wire)
        let s = albumScene(wire, routing: r)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt2") })
        _ = s.handle(.down)       // the second track
        _ = s.handle(.enter)
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "album")
        XCTAssertEqual(req["id"] as? String, "al1")
        XCTAssertEqual(req["start_index"] as? Int, 1)
        XCTAssertEqual(req["start_id"] as? String, "t2")
        XCTAssertEqual(req["list_rev"] as? String, "rev-al1", "the list_rev of the read the rows on screen came from")
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), false)
        pause()
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)

        // The rows kept are the WHOLE album in the order SpanDAC lists it: its
        // status `row` / `next_rows` index the container, not the song played.
        XCTAssertTrue(settleScene(s) { r.spanDACPlay() != nil })
        XCTAssertEqual(r.spanDACPlay()?.rows.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(r.spanDACPlay()?.token, "qalbum-4")
    }

    func testSOnAnAlbumSendsShuffleAndNoStart() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                                           "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
                                           "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 3)]])
        let s = albumScene(wire)
        _ = s.handle(.char("s"))
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), true)
        XCTAssertNil(req["start_index"])
        XCTAssertNil(req["start_id"])
    }

    func testTheFooterSaysQueuedAndNamesAShortQueue() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                                           "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
                                           "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 790, requested: 796, unavailable: 4)]])
        let status = StatusStore()
        let s = albumScene(wire, status: status)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text.hasPrefix("Playing") == true },
                      "got: \(String(describing: status.current()?.text))")
        XCTAssertEqual(status.current()?.text,
                       "Playing 'In Rainbows' on SpanDAC \u{2014} 790 of 796 queued. 4 songs aren't available to SpanDAC.")
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true,
                       "a short queue stays on screen until something changes")
    }

    func testTheFooterOfAFullQueueJustSaysHowManyAreQueued() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                                           "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
                                           "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 3)]])
        let status = StatusStore()
        let s = albumScene(wire, status: status)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.text.hasPrefix("Playing") == true })
        XCTAssertEqual(status.current()?.text, "Playing 'In Rainbows' on SpanDAC \u{2014} 3 queued.")
        XCTAssertEqual(status.current()?.staysUntilStateChange, false)
    }

    func testARefusalReachesTheFooterInSpanDACsWordsAndKeepsNoRows() {
        let wire = stickyWire([
            "slice.libraryAlbums": [albumPage], "slice.status": [Self.capable],
            "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
            "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
            "slice.playLibrary": [Self.refusal("library_changed",
                "That list has changed since you saw it; open it again to see the new list.")]])
        let status = StatusStore()
        let r = routing(wire)
        let s = albumScene(wire, status: status, routing: r)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.isError == true })
        XCTAssertEqual(status.current()?.text, "That list has changed since you saw it; open it again to see the new list.")
        XCTAssertNil(r.spanDACPlay(), "a refused play recorded rows")
    }

    func testAWarmingPlayWaitsOnItsHintAndIsSentAgain() {
        let wire = stickyWire([
            "slice.libraryAlbums": [albumPage], "slice.status": [Self.capable],
            "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
            "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
            "slice.playLibrary": [Self.refusal("warming", "SpanDAC is still preparing your library."),
                                  Self.playReply(queued: 3)]])
        let status = StatusStore()
        let s = albumScene(wire, status: status)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { wire.sent("slice.playLibrary").count == 2 }, "warming was not retried")
        XCTAssertTrue(settleScene(s) { status.current()?.text == "Playing 'In Rainbows' on SpanDAC \u{2014} 3 queued." },
                      "got: \(String(describing: status.current()?.text))")
    }

    /// Codex 116, finding 2: an album over the listing read's 1,000-song bound has
    /// no rows to read, but a whole play of it needs only its revision.
    func testAnAlbumWhoseListingReadRefusesTooLargeStillPlaysWholeByItsRevision() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                               "slice.libraryAlbumTracks": [Self.tooLarge, Self.tooLarge],
                               "slice.listRev": [Self.revReply("album", "rev-big", count: 1001)],
                               "slice.status": [Self.capable],
                               "slice.playLibrary": [Self.playReply(queued: 1001)]])
        let s = albumScene(wire)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settlePlayed(wire), "an over-bound album never reached slice.playLibrary")
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "album")
        XCTAssertEqual(req["id"] as? String, "al1")
        XCTAssertEqual(req["list_rev"] as? String, "rev-big", "the revision came from slice.listRev")
        let revReads = wire.sent("slice.listRev")
        XCTAssertEqual(revReads.first?["kind"] as? String, "album")
        XCTAssertEqual(revReads.first?["id"] as? String, "al1")
        pause()
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
    }

    /// The album's track list is not read just to play it: with nothing cached the
    /// revision read stands in. (The preview may have cached the rows; then their
    /// own `list_rev` is used and no revision read is sent.)
    func testAFromRowAlbumPlayKeepsTheRevThatCameWithTheRowsOnScreen() {
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                               "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"], listRev: "rev-shown")],
                               "slice.listRev": [Self.revReply("album", "rev-other")],
                               "slice.status": [Self.capable],
                               "slice.playLibrary": [Self.playReply(queued: 3)]])
        let s = albumScene(wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt2") })
        _ = s.handle(.down)
        _ = s.handle(.enter)
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["list_rev"] as? String, "rev-shown")
        XCTAssertEqual(req["start_id"] as? String, "t2")
        XCTAssertTrue(wire.sent("slice.listRev").isEmpty, "a from-row play must not replace the shown list's rev")
    }

    /// A whole play whose reply lacks the token play.library promises keeps no rows.
    func testAWholePlayReplyWithoutItsTokenIsRefusedAndKeepsNoRows() {
        let noToken = #"{"ok":true,"op":"slice.playLibrary","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized"},"queued":3,"skipped_unavailable":0,"skipped_videos":0}"#
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                               "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                               "slice.listRev": [Self.revReply("album", "rev-al1"), Self.revReply("album", "rev-al1")],
                               "slice.status": [Self.capable], "slice.playLibrary": [noToken]])
        let status = StatusStore()
        let r = routing(wire)
        let s = albumScene(wire, status: status, routing: r)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { status.current()?.isError == true })
        XCTAssertNil(r.spanDACPlay(), "rows were kept against a reply with no token")
    }

    func testAnOlderSpanDACKeepsTodaysIdListPath() {
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":3,"present":3,"index":0}}}"#
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"])],
                                           "slice.status": [Self.incapable], "slice.queue": [queued]])
        let s = albumScene(wire)
        _ = s.handle(.char("p"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").isEmpty { usleep(5_000) }
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "t3"])
        XCTAssertTrue(wire.sent("slice.playLibrary").isEmpty, "a SpanDAC without play.library was sent playLibrary")
    }

    func testAlbumRowsReadWithoutAListRevKeepTheIdListEvenFromACapableSpanDAC() {
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2,"present":2,"index":0}}}"#
        let wire = stickyWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"], listRev: nil)],
                                           "slice.status": [Self.capable], "slice.queue": [queued]])
        let s = albumScene(wire)
        _ = s.handle(.enter)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Tt2") })
        _ = s.handle(.down)
        _ = s.handle(.enter)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").isEmpty { usleep(5_000) }
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t2", "t3"])
        XCTAssertTrue(wire.sent("slice.playLibrary").isEmpty,
                      "rows with no list_rev cannot be proven, so no container play was sent")
    }

    /// A network SpanDAC (an iPhone or iPad) does not advertise `play.library`: a
    /// ready network row keeps the id-list path, even though the Mac SpanDAC the
    /// album was read from does advertise it.
    func testANetworkRowWithoutThePlayLibraryCapabilityUsesTheIdListPath() {
        // The Mac's SpanDAC answers a revision read too: the play asks the data
        // SpanDAC before it knows what the network output can take.
        let macWire = stickyWire(["slice.libraryAlbums": [albumPage],
                                  "slice.libraryAlbumTracks": [trackReply(["t1", "t2", "t3"]), trackReply(["t1", "t2", "t3"])],
                                  "slice.listRev": [Self.revReply("album", "rev-al1")],
                                  "slice.status": [Self.capable]])
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":3,"present":3,"index":0}}}"#
        let networkWire = stickyWire(["slice.status": [Self.incapable], "slice.queue": [queued]])
        let id = "0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10"
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.networkSource(id))
        let r = RoutingCoordinator(store: store, surface: .tui, makeSourceFor: { mode in
            SourceAppClient(path: "/nonexistent",
                            transport: (mode.networkSourceID != nil ? networkWire : macWire).transport)
        })
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: macWire, spy: LibraryAppleScriptSpy(),
                                 routing: r)
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && networkWire.sent("slice.queue").isEmpty { usleep(5_000) }
        XCTAssertEqual(networkWire.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "t3"])
        XCTAssertTrue(networkWire.sent("slice.playLibrary").isEmpty)
        XCTAssertTrue(macWire.sent("slice.playLibrary").isEmpty)
        XCTAssertTrue(macWire.sent("slice.queue").isEmpty, "the play went to the Mac instead of the network row")
    }

    // MARK: - artists

    private func artistSongs(_ ids: [String], listRev: String? = "rev-ar1") -> String {
        trackReply(ids, listRev: listRev).replacingOccurrences(of: "libraryAlbumTracks", with: "libraryArtistSongs")
    }

    func testPOnAnArtistOverTheListingBoundStillPlaysWholeByItsRevision() {
        // 1,001 songs: the listing read refuses too_large, and the play does not need it.
        let tooLargeSongs = Self.tooLarge.replacingOccurrences(of: "libraryAlbumTracks", with: "libraryArtistSongs")
        let wire = stickyWire(["slice.libraryArtists": [artistPage], "slice.status": [Self.capable],
                               "slice.libraryArtistSongs": [tooLargeSongs],
                               "slice.listRev": [Self.revReply("artist", "rev-ar1", count: 1001)],
                               "slice.playLibrary": [Self.playReply(queued: 1001)]])
        let status = StatusStore()
        let r = routing(wire)
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(),
                                 status: status, routing: r)
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(settlePlayed(wire), "a 1,001-song artist never reached slice.playLibrary")
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "artist")
        XCTAssertEqual(req["id"] as? String, "ar1")
        XCTAssertNil(req["start_index"])
        XCTAssertEqual(req["list_rev"] as? String, "rev-ar1", "the revision came from slice.listRev")
        XCTAssertEqual(wire.sent("slice.listRev").count, 1)
        XCTAssertEqual(wire.sent("slice.listRev").first?["kind"] as? String, "artist")
        XCTAssertEqual(wire.sent("slice.listRev").first?["id"] as? String, "ar1")
        XCTAssertTrue(wire.sent("slice.libraryArtistSongs").isEmpty, "the artist's songs were read to play them")
        XCTAssertNil(req["library_ids"])
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
        XCTAssertTrue(settleScene(s) { status.current()?.text == "Playing 'Radiohead' on SpanDAC \u{2014} 1,001 queued." },
                      "got: \(String(describing: status.current()?.text))")
        XCTAssertEqual(r.spanDACPlay()?.rows.count, 0, "no rows were read, so none are kept")
        XCTAssertEqual(r.spanDACPlay()?.token, "qa-1", "but the play's token is")
        XCTAssertEqual(r.spanDACPlay()?.listRev, "rev-ar1")
    }

    /// A SpanDAC that cannot read a revision (an older one, or one that does not
    /// advertise play.library) keeps the artist's songs read and the id list.
    func testPOnAnArtistWithoutPlayLibraryReadsTheSongsAndQueuesTheIds() {
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2,"present":2,"index":0}}}"#
        let wire = stickyWire(["slice.libraryArtists": [artistPage], "slice.status": [Self.incapable],
                               "slice.libraryArtistSongs": [artistSongs(["t1", "t2"])], "slice.queue": [queued]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").isEmpty { usleep(5_000) }
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2"])
        XCTAssertTrue(wire.sent("slice.listRev").isEmpty)
        XCTAssertTrue(wire.sent("slice.playLibrary").isEmpty)
    }

    func testSOnAnArtistShufflesTheWholeArtistWithNoStart() {
        let wire = stickyWire(["slice.libraryArtists": [artistPage], "slice.status": [Self.capable],
                               "slice.listRev": [Self.revReply("artist", "rev-ar1")],
                               "slice.playLibrary": [Self.playReply(queued: 14)]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("s"))
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "artist")
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), true)
        XCTAssertNil(req["start_id"])
        XCTAssertEqual(req["list_rev"] as? String, "rev-ar1")
    }

    // MARK: - playlists

    private func playlistScene(_ wire: BridgeLibraryReadsWire, status: StatusStore = StatusStore(),
                               routing: RoutingCoordinator? = nil) -> PlaylistsScene {
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120, routing: routing)
        XCTAssertTrue(settleScene(s) { s.render(frame: twoZone, snapshot: idle).contains("Chill") })
        return s
    }

    func testPOnAPlaylistAsksForItsRevisionAndSendsPlayLibraryWithNoRowRead() {
        let wire = stickyWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.status": [Self.capable],
                               "slice.listRev": [Self.revReply("playlist", "rev-pl1", count: 40)],
                               "slice.playLibrary": [Self.playReply(queued: 40, videos: 2)]])
        let status = StatusStore()
        let s = playlistScene(wire, status: status)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "playlist")
        XCTAssertEqual(req["id"] as? String, "pl1")
        XCTAssertNil(req["start_index"])
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), false)
        XCTAssertEqual(req["list_rev"] as? String, "rev-pl1")
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").isEmpty,
                      "no row was read, not even the one-row probe slice.listRev replaced")
        let revReads = wire.sent("slice.listRev")
        XCTAssertEqual(revReads.count, 1)
        XCTAssertEqual(revReads.first?["kind"] as? String, "playlist")
        XCTAssertEqual(revReads.first?["id"] as? String, "pl1")
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
        XCTAssertTrue(settleScene(s) { status.current()?.text.hasPrefix("Playing") == true })
        XCTAssertEqual(status.current()?.text,
                       "Playing 'Chill' on SpanDAC \u{2014} 40 queued. 2 videos in this playlist skipped.")
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true)
    }

    func testSOnAPlaylistSendsShuffleAndNoStart() {
        let wire = stickyWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.status": [Self.capable],
                               "slice.listRev": [Self.revReply("playlist", "rev-pl1")],
                               "slice.playLibrary": [Self.playReply(queued: 3)]])
        let s = playlistScene(wire)
        _ = s.handle(.char("s"))
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), true)
        XCTAssertNil(req["start_index"])
        XCTAssertEqual(req["list_rev"] as? String, "rev-pl1")
        XCTAssertTrue(wire.sent("slice.libraryPlaylistTracks").isEmpty)
        XCTAssertEqual(wire.sent("slice.listRev").count, 1)
    }

    /// A SpanDAC that cannot answer slice.listRev (it answers unknown_op) is walked
    /// and queued by id, as before: a container play with no `list_rev` would be refused.
    func testAPlaylistWhoseSpanDACCannotReadARevisionKeepsTheIdListPath() {
        let queued = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A","contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":2,"present":2,"index":0}}}"#
        let wire = stickyWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.status": [Self.capable],
                                           "slice.queue": [queued], "slice.listRev": [Self.unknownOp]])
        wire.script("slice.libraryPlaylistTracks", [playlistTracks(["i.a", "i.b"], listRev: nil)])
        let s = playlistScene(wire)
        _ = s.handle(.char("p"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && wire.sent("slice.queue").isEmpty { usleep(5_000) }
        XCTAssertEqual(wire.sent("slice.queue").first?["library_ids"] as? [String], ["i.a", "i.b"])
        XCTAssertTrue(wire.sent("slice.playLibrary").isEmpty)
    }

    func testEnterOnAPlaylistTrackSendsTheRowsIndexAndKeepsTheWholePlaylistsRows() {
        // A repeat: the row is named by index, so the second "i.a" is index 2.
        let wire = stickyWire(["slice.libraryPlaylists": [onePlaylistPage], "slice.status": [Self.capable],
                                           "slice.playLibrary": [Self.playReply(queued: 3, token: "qpl-9")]])
        wire.script("slice.libraryPlaylistTracks", [playlistTracks(["i.a", "i.b", "i.a"])])
        let r = routing(wire)
        let s = playlistScene(wire, routing: r)
        _ = s.handle(.enter)    // drill in
        XCTAssertTrue(settleScene(s) { s.render(frame: threeZone, snapshot: idle).contains("Pi.b") })
        for _ in 0..<20 { _ = s.tick(snapshot: idle); usleep(2_000) }
        _ = s.handle(.down)
        _ = s.handle(.down)     // the repeated third row
        _ = s.handle(.enter)
        XCTAssertTrue(settlePlayed(wire))
        let req = (wire.sent("slice.playLibrary").first ?? [:])
        XCTAssertEqual(req["kind"] as? String, "playlist")
        XCTAssertEqual(req["id"] as? String, "pl1")
        XCTAssertEqual(req["start_index"] as? Int, 2)
        XCTAssertEqual(req["start_id"] as? String, "i.a")
        XCTAssertEqual(req["list_rev"] as? String, "rev-pl1")
        XCTAssertEqual(SourceAppControl.bool(req["shuffle"]), false)
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
        XCTAssertTrue(settleScene(s) { r.spanDACPlay() != nil })
        XCTAssertEqual(r.spanDACPlay()?.rows.map(\.id), ["i.a", "i.b", "i.a"])
        XCTAssertEqual(r.spanDACPlay()?.token, "qpl-9")
    }
}

import XCTest
@testable import music

/// concert/catalogue-play, client side: playing a playlist to an iPhone or iPad
/// SpanDAC that advertises `queue.catalogue_fill` sends the rows' catalogue ids
/// (`catalog_ids`, aligned with `library_ids`) and `fill_from_catalogue: true`,
/// so the songs the phone's library lacks play from Apple's catalogue in their
/// place. A device that does not advertise it gets today's request, byte for
/// byte. No real socket: canned transports only.
final class CatalogueFillClientTests: XCTestCase {

    // MARK: - wire (SourceAppControl)

    private final class Wire {
        private(set) var sentOnLibrary: [String] = []
        private var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func mainTransport(_ path: String, _ line: String) throws -> String { replies.isEmpty ? "{}" : replies.removeFirst() }
        func libraryTransport(_ path: String, _ line: String) throws -> String {
            sentOnLibrary.append(line)
            return replies.isEmpty ? "{}" : replies.removeFirst()
        }
        func decoded(_ line: String?) -> [String: Any] {
            guard let data = line?.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return body
        }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: wire.mainTransport, libraryTransport: wire.libraryTransport)
    }

    private func queueReply(unavailable: Int? = 0, notInLibrary: Int? = nil, repeated: Int? = nil,
                            filled: Int? = nil) -> String {
        let parts = [unavailable.map { "\"skipped_unavailable\":\($0)" },
                     notInLibrary.map { "\"skipped_not_in_library\":\($0)" },
                     repeated.map { "\"skipped_repeated\":\($0)" },
                     filled.map { "\"filled_from_catalogue\":\($0)" }].compactMap { $0 }
        return "{\"ok\":true,\"op\":\"slice.queue\"" + parts.map { "," + $0 }.joined() + "}"
    }

    func testTheBodyCarriesCatalogIdsAlignedWithNullsAndTheFlagOnlyWhenAsked() {
        let ids = ["i.a", "m.1", "m.2"]
        let plain = SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false,
                                                      skipNotInLibrary: true, skipRepeated: true)
        XCTAssertEqual(Set(plain.keys), ["op", "library_ids", "start_required", "skip_not_in_library", "skip_repeated"],
                       "today's request: no new key")
        let filled = SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                       skipRepeated: true, catalogIDs: [nil, "1458871225", nil])
        XCTAssertEqual(filled["fill_from_catalogue"] as? Bool, true)
        let catalog = filled["catalog_ids"] as? [Any]
        XCTAssertEqual(catalog?.count, 3, "parallel to library_ids")
        XCTAssertTrue(catalog?[0] is NSNull)
        XCTAssertEqual(catalog?[1] as? String, "1458871225")
        XCTAssertTrue(catalog?[2] is NSNull)
        XCTAssertEqual(filled["library_ids"] as? [String], ids)
    }

    func testNoCatalogueIdAnywhereOrAMisalignedArrayIsTodaysBody() {
        let ids = ["i.a", "i.b"]
        let today = Set(SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false,
                                                          skipNotInLibrary: true, skipRepeated: true).keys)
        XCTAssertEqual(Set(SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                             skipRepeated: true, catalogIDs: [nil, nil]).keys), today)
        XCTAssertEqual(Set(SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                             skipRepeated: true, catalogIDs: ["1"]).keys), today,
                       "an array that does not line up is never sent: the device would refuse it")
        XCTAssertEqual(Set(SourceAppControl.libraryQueueBody(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                             skipRepeated: true, catalogIDs: nil).keys), today)
    }

    func testAFilledPlayReadsTheCountBackAndAnOlderReplyReadsZero() throws {
        let ids = (0..<53).map { "i.\($0)" }
        let catalog: [String?] = ids.map { _ in "1" }
        let wire = Wire([queueReply(unavailable: 0, notInLibrary: 2, repeated: 1, filled: 28)])
        let sent = try control(wire).queueRetainingToken(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                         skipRepeated: true, catalogIDs: catalog)
        XCTAssertEqual(sent.filledFromCatalogue, 28)
        XCTAssertEqual(sent.skippedNotInLibrary, 2)
        XCTAssertEqual(sent.skippedRepeated, 1)
        let older = Wire([queueReply(unavailable: 0, notInLibrary: 30, repeated: nil, filled: nil)])
        XCTAssertEqual(try control(older).queueRetainingToken(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                              skipRepeated: true, catalogIDs: catalog).filledFromCatalogue, 0)
    }

    func testAMalformedFilledCountIsRefusedLikeEveryOtherCount() {
        let ids = ["i.a", "i.b", "i.c"]
        for bad in ["-1", "4", "7", "1.5", "true", "\"2\""] {
            let wire = Wire(["{\"ok\":true,\"op\":\"slice.queue\",\"skipped_unavailable\":0,\"filled_from_catalogue\":\(bad)}"])
            XCTAssertThrowsError(try control(wire).queueRetainingToken(
                libraryIDs: ids, startRequired: false, skipNotInLibrary: true, skipRepeated: true,
                catalogIDs: ["1", "2", "3"]), "\(bad) of 3 was read") { error in
                guard case SourceAppError.malformedReply = error else { return XCTFail("\(bad): \(error)") }
            }
        }
        // Every song filled is honest (none were in the phone's library); more than the
        // songs that survived the skips cannot be.
        let all = Wire([queueReply(unavailable: 0, notInLibrary: nil, repeated: nil, filled: 3)])
        XCTAssertEqual(try? control(all).queueRetainingToken(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                             skipRepeated: true, catalogIDs: ["1", "2", "3"]).filledFromCatalogue, 3)
        let wire = Wire([queueReply(unavailable: 0, notInLibrary: 2, repeated: nil, filled: 2)])
        XCTAssertThrowsError(try control(wire).queueRetainingToken(
            libraryIDs: ids, startRequired: false, skipNotInLibrary: true, skipRepeated: true,
            catalogIDs: ["1", "2", "3"]))
    }

    func testARequestTooLargeWithCatalogueIdsIsSentWithoutThemSoTodaysPlayStillWorks() throws {
        // 3,000 ids of 14 bytes fit in 64 KiB on their own; the same with catalogue ids does not.
        let ids = (0..<3000).map { "i.\(String(format: "%012d", $0))" }
        let catalog: [String?] = ids.map { _ in "1458871225" }
        XCTAssertLessThanOrEqual(SourceAppControl.libraryQueueRequestBytes(libraryIDs: ids, startRequired: false),
                                 SourceAppControl.maximumRequestBytes)
        let wire = Wire([queueReply(unavailable: 0, notInLibrary: nil, repeated: nil, filled: nil)])
        let sent = try control(wire).queueRetainingToken(libraryIDs: ids, startRequired: false, skipNotInLibrary: true,
                                                         skipRepeated: true, catalogIDs: catalog)
        let body = wire.decoded(wire.sentOnLibrary.first)
        XCTAssertNil(body["catalog_ids"])
        XCTAssertNil(body["fill_from_catalogue"])
        XCTAssertEqual(body["skip_repeated"] as? Bool, true)
        XCTAssertEqual(sent.filledFromCatalogue, 0)
    }

    // MARK: - the provider and the capability

    private let statusWith: (String) -> String = {
        "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"playing\",\"capabilities\":[\($0)]}}"
    }

    func testTheProviderAsksTheDeviceWhetherItCanFillAndSaysNoWhenItCannotRead() {
        let yes = BridgeMusicProvider(control: control(Wire([statusWith("\"slice.queue\",\"queue.catalogue_fill\"")])),
                                      skipsNotInLibrary: true)
        XCTAssertTrue(yes.supportsCatalogueFill())
        let no = BridgeMusicProvider(control: control(Wire([statusWith("\"slice.queue\",\"play.library\"")])),
                                     skipsNotInLibrary: true)
        XCTAssertFalse(no.supportsCatalogueFill())
        let unreadable = BridgeMusicProvider(control: control(Wire(["{\"ok\":false}"])), skipsNotInLibrary: true)
        XCTAssertFalse(unreadable.supportsCatalogueFill(), "a status that cannot be read keeps today's path")
    }

    // MARK: - the scene

    private let frame = shellLayout(width: 120, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let onePlaylistPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"2018","kind":"playlist"}],"next_cursor":null}
    """

    private func tracksPage(_ items: [(id: String, title: String, catalog: String?)]) -> String {
        let rows = items.map { row -> String in
            let catalog = row.catalog.map { ",\"catalog_id\":\"\($0)\"" } ?? ""
            return "{\"id\":\"\(row.id)\",\"title\":\"\(row.title)\",\"artist\":\"A\",\"kind\":\"song\"\(catalog)}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryPlaylistTracks\",\"generation\":3,\"total\":\(items.count),"
            + "\"items\":[\(rows)],\"next_cursor\":null,\"skipped_videos\":0}"
    }

    /// Plays the playlist with `p` against a device whose status lists `capabilities`.
    private func play(rows: [(id: String, title: String, catalog: String?)], capabilities: [String],
                      queue: String, file: StaticString = #filePath, line: UInt = #line)
        -> (request: [String: Any]?, recorded: [String], footer: String?) {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [onePlaylistPage],
                                           "slice.queue": [queue],
                                           "slice.status": [statusWith(caps)]])
        wire.stickyStatus = true
        wire.script("slice.libraryPlaylistTracks", [tracksPage(rows)])
        let status = StatusStore()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   status: status, width: 120, routing: routing)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("2018") }, file: file, line: line)
        _ = s.handle(.char("p"))
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.queue").isEmpty }, file: file, line: line)
        _ = settleScene(s) { status.current()?.text.contains("Playing") == true }
        return (wire.sent("slice.queue").first, routing.spanDACPlay()?.rows.map(\.id) ?? [], status.current()?.text)
    }

    private let rows: [(id: String, title: String, catalog: String?)] = [
        ("i.1", "One", "1001"), ("i.2", "Two", "1002"), ("i.3", "Three", nil), ("i.4", "Four", "1004"),
    ]

    func testADeviceThatAdvertisesTheCapabilityGetsAlignedCatalogIdsAndTheFlag() {
        let r = play(rows: rows, capabilities: ["slice.queue", "queue.catalogue_fill"],
                     queue: queueReply(unavailable: 0, notInLibrary: 1, repeated: nil, filled: 2))
        XCTAssertEqual(r.request?["library_ids"] as? [String], ["i.1", "i.2", "i.3", "i.4"])
        let catalog = r.request?["catalog_ids"] as? [Any]
        XCTAssertEqual(catalog?.count, 4)
        XCTAssertEqual(catalog?[0] as? String, "1001")
        XCTAssertTrue(catalog?[2] is NSNull, "a row with no catalogue id is null, in its own place")
        XCTAssertEqual(r.request?["fill_from_catalogue"] as? Bool, true)
        XCTAssertEqual(r.request?["skip_not_in_library"] as? Bool, true)
        XCTAssertEqual(r.request?["skip_repeated"] as? Bool, true)
        XCTAssertEqual(r.recorded, ["i.1", "i.2", "i.3", "i.4"], "every row is still recorded for Up Next")
        XCTAssertEqual(r.footer, "Skipped 1 not in your library \u{00B7} Playing '2018' on SpanDAC \u{2014} 3 tracks, 2 from Apple Music.")
    }

    func testADeviceWithoutTheCapabilityGetsTodaysRequestAndTodaysFooter() {
        let r = play(rows: rows, capabilities: ["slice.queue"],
                     queue: queueReply(unavailable: 0, notInLibrary: 1, repeated: nil, filled: nil))
        XCTAssertEqual(Set(r.request?.keys.map { $0 } ?? []),
                       ["op", "library_ids", "start_required", "skip_not_in_library", "skip_repeated"])
        XCTAssertEqual(r.footer, "Skipped 1 not in your library \u{00B7} Playing '2018' on SpanDAC \u{2014} 3 tracks.")
    }

    func testACapableDeviceIsSentTodaysRequestWhenNoRowHasACatalogueId() {
        let none: [(id: String, title: String, catalog: String?)] = [("i.1", "One", nil), ("i.2", "Two", nil)]
        let r = play(rows: none, capabilities: ["queue.catalogue_fill"], queue: queueReply())
        XCTAssertEqual(Set(r.request?.keys.map { $0 } ?? []),
                       ["op", "library_ids", "start_required", "skip_not_in_library", "skip_repeated"])
    }

    // MARK: - the footer

    func testTheFooterCountsWhatCameFromAppleMusicAndAbsentIsByteIdentical() {
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "2018", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                      skippedNotInLibrary: 2, skippedByOutput: 2, skippedRepeated: 1,
                                      filledFromCatalogue: 28, startAt: 1, shuffle: false),
            "Skipped 2 not in your library, 1 repeat \u{00B7} Playing '2018' on SpanDAC \u{2014} 50 tracks, 28 from Apple Music.")
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "2018", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, skippedRepeated: 1, startAt: 1, shuffle: false),
            bridgePlaylistPlayMessage(name: "2018", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                      skippedNotInLibrary: 30, skippedByOutput: 30, skippedRepeated: 1,
                                      filledFromCatalogue: 0, startAt: 1, shuffle: false))
        XCTAssertEqual(
            bridgePlaylistPlayMessage(name: "2018", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                      filledFromCatalogue: 1, startAt: 1, shuffle: false),
            "Playing '2018' on SpanDAC \u{2014} 53 tracks, 1 from Apple Music.")
        XCTAssertTrue(bridgePlaylistPlayMessage(name: "X", queued: 40, skippedVideos: 2, skippedUnavailable: 0,
                                                filledFromCatalogue: 5, startAt: 1, shuffle: false)
            .hasSuffix("5 from Apple Music."))
    }

    /// The footer is cut at `width - 4`: the skip lead (ruled) leads and survives at 50, 80
    /// and 120 columns whatever the playlist is called; the new clause is whole only where it fits.
    func testTheSkipLeadSurvivesAtFiftyEightyAndOneTwentyColumnsAndTheFillClauseWhereItFits() {
        let lead = "Skipped 2 not in your library, 1 repeat \u{00B7} "
        let clause = "28 from Apple Music."
        for name in ["2018", String(repeating: "A very long playlist name ", count: 6)] {
            let message = bridgePlaylistPlayMessage(name: name, queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                                    skippedNotInLibrary: 2, skippedByOutput: 2, skippedRepeated: 1,
                                                    filledFromCatalogue: 28, startAt: 1, shuffle: false)
            for width in [50, 80, 120] {
                let cut = max(1, shellLayout(width: width, height: 30).width - 4)
                XCTAssertTrue(truncText(message, to: cut).hasPrefix(lead), "\(name.prefix(6)) at \(width) columns")
            }
        }
        let short = bridgePlaylistPlayMessage(name: "2018", queued: 53, skippedVideos: 0, skippedUnavailable: 0,
                                              skippedNotInLibrary: 2, skippedByOutput: 2, skippedRepeated: 1,
                                              filledFromCatalogue: 28, startAt: 1, shuffle: false)
        let cut120 = max(1, shellLayout(width: 120, height: 30).width - 4)
        XCTAssertTrue(truncText(short, to: cut120).hasSuffix(clause), "whole at 120 columns for a short name")
        let cut80 = max(1, shellLayout(width: 80, height: 30).width - 4)
        XCTAssertFalse(truncText(short, to: cut80).hasSuffix(clause), "cut at 80 columns: the default the owner may change")
    }

    // MARK: - Up Next never claims a wrong row

    func testACatalogueEntryCurrentOrNextShowsNothingRatherThanAWrongRow() {
        let sent = (0..<4).map { MusicRow(id: "i.\($0)", title: "Song \($0)", artist: "A", album: nil, kind: .song) }
        func window(_ status: SourceStatus) -> (current: MusicRow?, entries: [TrackListEntry]) {
            spanDACQueueWindow(sent: sent, token: "T", status: status)
        }
        func status(row: Int?, next: [Int]?, title: String) -> SourceStatus {
            SourceStatus(playback: "playing", title: title, artist: "A", readiness: .ready, queuePhase: "complete",
                         queueRequested: 3, queuePresent: 3, row: row, nextRows: next, queueToken: "T")
        }
        // A library song is playing; the device stopped `next_rows` at the catalogue fill after it.
        let beforeFill = window(status(row: 0, next: [], title: "Song 0"))
        XCTAssertEqual(beforeFill.entries.map(\.index), [1], "no successor is listed, not row 2")
        // A catalogue fill is playing: the device reports no row, and the client does not guess one.
        let onFill = window(status(row: nil, next: [], title: "Apple's Title For Row 1"))
        XCTAssertNil(onFill.current)
        XCTAssertTrue(onFill.entries.isEmpty)
    }
}

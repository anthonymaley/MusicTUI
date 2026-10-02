import XCTest
@testable import music

final class DiscoverFromHereTypesTests: XCTestCase {
    private func wire(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: rowLength

    func testRowLengthKeyAbsent() {
        XCTAssertEqual(rowLength(inWireRow: wire(#"{"id":"1"}"#)), .absent)
    }

    func testRowLengthNullAndNumberAreDistinctFromAbsent() {
        let absent = rowLength(inWireRow: wire(#"{"id":"1"}"#))
        let null = rowLength(inWireRow: wire(#"{"duration_ms":null}"#))
        let ms = rowLength(inWireRow: wire(#"{"duration_ms":215840}"#))
        XCTAssertEqual(null, .null)
        XCTAssertEqual(ms, .milliseconds(215840))
        XCTAssertNotEqual(absent, null)
        XCTAssertNotEqual(absent, ms)
        XCTAssertNotEqual(null, ms)
    }

    func testRowLengthMalformedValues() {
        for json in [#"{"duration_ms":-5}"#, #"{"duration_ms":0}"#, #"{"duration_ms":1.5}"#,
                     #"{"duration_ms":"3"}"#, #"{"duration_ms":true}"#, #"{"duration_ms":false}"#,
                     #"{"duration_ms":[1]}"#] {
            XCTAssertEqual(rowLength(inWireRow: wire(json)), .malformed, json)
        }
    }

    func testRowLengthSwiftNativeValues() {
        XCTAssertEqual(rowLength(inWireRow: ["duration_ms": 7]), .milliseconds(7))
        XCTAssertEqual(rowLength(inWireRow: ["duration_ms": true]), .malformed)
        XCTAssertEqual(rowLength(inWireRow: ["duration_ms": 1.5]), .malformed)
        XCTAssertEqual(rowLength(inWireRow: ["duration_ms": NSNull()]), .null)
    }

    func testDiscoverItemLengthDefaultsToAbsent() {
        let item = DiscoverItem(id: "1", name: "N", subtitle: nil, url: nil, artworkURL: nil, detail: .song)
        XCTAssertEqual(item.length, .absent)
    }

    // MARK: preflight

    private let ok: RowLength = .milliseconds(1000)

    func testPreflightCapabilityFalse() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: false, rows: dfhRows([ok]), selected: 0),
                       .updateSpanDAC)
    }

    func testPreflightAbsentOnEveryRow() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([.absent, .absent]), selected: 0),
                       .updateSpanDAC)
    }

    func testPreflightAbsentOnOneRowOnly() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([ok, ok, .absent]), selected: 0),
                       .updateSpanDAC)
    }

    func testPreflightNullOnSelectedRow() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([ok, .null, ok]), selected: 1),
                       .noLength(title: "Song 2"))
    }

    func testPreflightNullOnARowBeforeSelected() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([ok, .null, ok]), selected: 2),
                       .noLength(title: "Song 2"))
    }

    func testPreflightNullOnlyAfterSelectedPasses() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([ok, ok, .null]), selected: 1),
                       .pass)
    }

    func testPreflightMalformedOnAnyRow() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([ok, ok, .malformed]), selected: 0),
                       .malformedLength)
    }

    func testPreflightOrderMalformedBeforeNull() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([.null, .malformed]), selected: 0),
                       .malformedLength)
    }

    func testPreflightOrderAbsentBeforeMalformed() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([.malformed, .absent]), selected: 0),
                       .updateSpanDAC)
    }

    func testPreflightOrderCapabilityBeforeRange() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: false, rows: dfhRows([ok]), selected: 9),
                       .updateSpanDAC)
    }

    func testPreflightOrderRangeBeforeAbsent() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true,
                                                     rows: dfhRows([.absent]), selected: 5),
                       .selectionOutOfRange)
    }

    func testPreflightSelectionOutOfRange() {
        let rows = dfhRows([ok, ok])
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: rows, selected: -1),
                       .selectionOutOfRange)
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: rows, selected: 2),
                       .selectionOutOfRange)
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: [], selected: 0),
                       .selectionOutOfRange)
    }

    func testPreflightPass() {
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: dfhRows([ok, ok]), selected: 1),
                       .pass)
    }

    func testPreflightNilSubtitleIsNotAPreflightMatter() {
        var rows = dfhRows([ok])
        rows[0] = DiscoverItem(id: "1", name: "N", subtitle: nil, url: nil, artworkURL: nil,
                               detail: .song, length: ok)
        XCTAssertEqual(discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: rows, selected: 0), .pass)
    }

    // MARK: wordings

    func testRefusalTextsNameTheTitleOrPlaylistTheyAreGiven() {
        let refusals: [DiscoverCopyRefusal] = [
            .notReady, .countChanged, .unconfirmed(title: "TTT"), .sourceChanged, .modes,
            .firstPlayUnconfirmed, .landing(title: "TTT"), .wontPlay(title: "TTT"),
        ]
        for refusal in refusals {
            let text = discoverCopyRefusalText(refusal, playlist: "PPP")
            XCTAssertNotNil(text, "\(refusal)")
            if refusal == .sourceChanged {
                XCTAssertEqual(text, sourceChangedNothingPlayed)
            } else if case .wontPlay = refusal {
                XCTAssertTrue(text!.contains("TTT"), "\(refusal)")
            } else if case .unconfirmed = refusal {
                XCTAssertTrue(text!.contains("TTT") && text!.contains("PPP"), "\(refusal)")
            } else if case .landing = refusal {
                XCTAssertTrue(text!.contains("TTT") && text!.contains("PPP"), "\(refusal)")
            } else {
                XCTAssertTrue(text!.contains("PPP"), "\(refusal)")
            }
        }
    }

    func testSupersededHasNoText() {
        XCTAssertNil(discoverCopyRefusalText(.superseded, playlist: "PPP"))
    }

    func testIndividualWordingsNameWhatTheyAreGiven() {
        XCTAssertTrue(discoverNoLengthText(title: "TTT").contains("'TTT'"))
        XCTAssertTrue(discoverSeveralCopiesText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverCopyNoIDText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverJournalUnwritableText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverAddRefusedText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverCopyLeftText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverCopyMaybeAddedText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverCopyChangedText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverCopyBusyText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverAddingText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverWaitingText(playlist: "PPP").contains("'PPP'"))
        XCTAssertTrue(discoverPositioningText(title: "TTT").contains("'TTT'"))
        XCTAssertFalse(discoverMalformedLengthText.isEmpty)
    }

    func testNotReadyIsTheShippedSentence() {
        XCTAssertEqual(discoverCopyRefusalText(.notReady, playlist: "Mix"),
                       "'Mix' is still loading — try again in a moment.")
    }

    // MARK: journal entry coding

    func testDiscoverCopyEntryEncodesSnakeCaseKeysAndRoundTrips() throws {
        let entry = DiscoverCopyEntry(
            txn: "T1", playlistID: "pl.abc", title: "Mix", state: .uncertain, hex: "6D5AC2A4DC7BD163",
            copiesRead: 1, watching: true, copySeen: true, toldAtLaunch: false,
            priorShuffle: true, priorRepeat: "all", createdAt: 100, updatedAt: 200)
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "txn", "playlist_id", "title", "state", "hex", "copies_read", "watching",
            "copy_seen", "told_at_launch", "prior_shuffle", "prior_repeat", "created_at", "updated_at",
        ])
        XCTAssertEqual(object["state"] as? String, "uncertain")
        XCTAssertEqual(try JSONDecoder().decode(DiscoverCopyEntry.self, from: data), entry)
    }

    func testDiscoverCopyEntryRoundTripsWithNilOptionals() throws {
        let entry = DiscoverCopyEntry(
            txn: "T2", playlistID: "pl.x", title: "Mix", state: .intent, hex: nil,
            copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
            priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(DiscoverCopyEntry.self, from: data), entry)
    }

    func testIsDeletable() {
        func entry(_ state: DiscoverCopyState, hex: String?) -> DiscoverCopyEntry {
            DiscoverCopyEntry(txn: "T", playlistID: "pl.x", title: "M", state: state, hex: hex,
                              copiesRead: 1, watching: false, copySeen: false, toldAtLaunch: false,
                              priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
        }
        XCTAssertTrue(entry(.owned, hex: "A").isDeletable)
        XCTAssertTrue(entry(.listening, hex: "A").isDeletable)
        XCTAssertFalse(entry(.owned, hex: nil).isDeletable)
        for state: DiscoverCopyState in [.intent, .uncertain, .closed, .preexisting] {
            XCTAssertFalse(entry(state, hex: "A").isDeletable, "\(state)")
        }
    }

    // MARK: catalogue copy, preamble

    func testCatalogPlaylistCopyHex() {
        XCTAssertEqual(CatalogPlaylistCopy(alias: "7879824511367631203").hex, "6D5AC2A4DC7BD163")
        XCTAssertNil(CatalogPlaylistCopy(alias: nil).hex)
        XCTAssertNil(CatalogPlaylistCopy(alias: "nope").hex)
    }

    func testLookupPreambleShape() {
        let text = discoverCopyLookupPreamble(hex: "6D5AC2A4DC7BD163")
        XCTAssertTrue(text.contains("6D5AC2A4DC7BD163"))
        XCTAssertTrue(text.contains("playlists"))
        XCTAssertFalse(text.contains("user playlist"))
        XCTAssertFalse(text.contains("whose"))
    }

    func testLookupPreambleLeavesPlMissingForBadHex() {
        for bad in ["", "6d5ac2a4dc7bd163", "6D5AC2A4DC7BD16", "6D5AC2A4DC7BD1633", "6D5AC2A4DC7BD16\""] {
            let text = discoverCopyLookupPreamble(hex: bad)
            XCTAssertEqual(text, "set pl to missing value", bad)
            XCTAssertFalse(text.contains("repeat"), bad)
        }
    }

    func testTimingConstants() {
        XCTAssertEqual(DiscoverCopyTiming.readinessBound, 45)
        XCTAssertEqual(DiscoverCopyTiming.scriptTimeout, 5)
        XCTAssertEqual(spandacCatalogPlaylistCapability, "library.catalog_playlist")
    }

    // MARK: the fakes

    func testFakeJournalRecordsOrderAndFailsChosenWrites() throws {
        let store = InMemoryDiscoverCopyJournalStore()
        let entry = DiscoverCopyEntry(txn: "T", playlistID: "pl.x", title: "M", state: .intent, hex: nil,
                                      copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                                      priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
        try store.insert(entry)
        store.failWrites = { $0 == "update:T:owned" }
        XCTAssertThrowsError(try store.update(txn: "T") { $0.state = .owned }) {
            XCTAssertEqual($0 as? DiscoverCopyJournalError, .writeFailed("injected"))
        }
        XCTAssertEqual(try store.entries().first?.state, .intent)
        XCTAssertEqual(store.events, ["insert:T", "update:T!", "entries"])
    }

    func testFakeGateScriptsTheNthCall() {
        let fake = FakeDiscoverCopyGate(scripted: [2: .superseded])
        var ran = 0
        XCTAssertEqual(fake.gate { ran += 1 }, .ran)
        XCTAssertEqual(fake.gate { ran += 1 }, .superseded)
        XCTAssertEqual(fake.gate { ran += 1 }, .ran)
        XCTAssertEqual(ran, 2)
        XCTAssertEqual(fake.calls, [.ran, .superseded, .ran])
    }

    func testFakeOpsQueueAndCalls() throws {
        let ops = FakeCatalogPlaylistOps()
        ops.copiesResults = [.success([]), .success([CatalogPlaylistCopy(alias: "1")])]
        var hooked = false
        ops.onAdd = { hooked = true }
        XCTAssertEqual(try ops.copies(ofCatalogPlaylist: "pl.a"), [])
        XCTAssertEqual(try ops.copies(ofCatalogPlaylist: "pl.a").count, 1)
        XCTAssertEqual(try ops.copies(ofCatalogPlaylist: "pl.a").count, 1)
        _ = ops.addCatalogPlaylist(id: "pl.a")
        XCTAssertTrue(hooked)
        XCTAssertEqual(ops.calls, ["copies:pl.a", "copies:pl.a", "copies:pl.a", "add:pl.a"])
    }
}

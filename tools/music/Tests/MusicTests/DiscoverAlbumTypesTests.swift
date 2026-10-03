import XCTest
@testable import music

/// Album-cleanup shared types (score step A0): the request builder, the
/// journal types' wire shape, the AppleScript name gate and the wordings.
/// Pure: nothing here touches a file, a socket or Music.app.
final class DiscoverAlbumTypesTests: XCTestCase {

    private func item(_ detail: DiscoverItemDetail, id: String = "1440000001", name: String = "Blue") -> DiscoverItem {
        DiscoverItem(id: id, name: name, subtitle: "Someone", url: nil, artworkURL: nil, detail: detail)
    }

    // MARK: K1

    func testPlayKindRawValues() {
        XCTAssertEqual(DiscoverPlayKind.playlistCopy.rawValue, "playlist_copy")
        XCTAssertEqual(DiscoverPlayKind.albumContainer.rawValue, "album_container")
    }

    func testARequestIsAPlaylistCopyUnlessToldOtherwise() {
        let request = DiscoverCopyRequest(playlistID: "pl.x", playlistTitle: "Mix", rows: [], selected: 0)
        XCTAssertEqual(request.kind, .playlistCopy)
    }

    func testAnAlbumGivesAnAlbumRequestWithEverythingHeWasShown() throws {
        let rows = albumTestRows([.milliseconds(1000), .milliseconds(2000), .null])
        let request = try XCTUnwrap(discoverAlbumRequest(container: item(.album(trackCount: 3, year: nil, genre: nil)),
                                                         rows: rows, selected: 1))
        XCTAssertEqual(request.kind, .albumContainer)
        XCTAssertEqual(request.playlistID, "1440000001")
        XCTAssertEqual(request.playlistTitle, "Blue")
        XCTAssertEqual(request.rows, rows)
        XCTAssertEqual(request.selected, 1)
    }

    func testAnythingButAnAlbumGivesNoAlbumRequest() {
        let rows = albumTestRows([.milliseconds(1000)])
        for detail: DiscoverItemDetail in [.playlist(description: nil), .song, .station(isLive: false)] {
            XCTAssertNil(discoverAlbumRequest(container: item(detail, id: "pl.x"), rows: rows, selected: 0), "\(detail)")
        }
    }

    // MARK: K2

    func testTerminalSongStates() {
        let terminal: [DiscoverAlbumSongState] = [.preexisting, .uncertain, .deleted, .kept]
        let open: [DiscoverAlbumSongState] = [.intent, .pending, .owned]
        XCTAssertTrue(terminal.allSatisfy(\.isTerminal))
        XCTAssertFalse(open.contains(where: \.isTerminal))
    }

    private func fullSong(position: Int = 2) -> DiscoverAlbumSong {
        DiscoverAlbumSong(position: position, catalogueID: "940618525", title: "Two", artist: "Band",
                          durationMS: 201_000, relationsBefore: [0, 1], entryHex: "00000000000000AB",
                          alias: "171", cloudStatus: "matched", state: .owned, p4FirstSeenAt: 1_700_000_000.5,
                          uncertainReason: "why", keptReason: "playlist", keptPlaylist: "House",
                          guardStrikes: 2, toldAtLaunch: true, deletedAt: 1_700_000_100.25)
    }

    func testASongRoundTripsWithItsSnakeCaseKeys() throws {
        let song = fullSong()
        let data = try JSONEncoder().encode(song)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "position", "catalogue_id", "title", "artist", "duration_ms", "relations_before", "entry_hex",
            "alias", "cloud_status", "state", "p4_first_seen_at", "uncertain_reason", "kept_reason",
            "kept_playlist", "guard_strikes", "told_at_launch", "deleted_at",
        ])
        XCTAssertEqual(object["state"] as? String, "owned")
        XCTAssertEqual(object["relations_before"] as? [Int], [0, 1])
        XCTAssertEqual(try JSONDecoder().decode(DiscoverAlbumSong.self, from: data), song)
    }

    func testAnEntryWithEveryNewFieldRoundTripsWithSnakeCaseKeys() throws {
        var entry = albumTestEntry(state: .listening, hex: "0000000000001234", songs: [fullSong(position: 1)])
        entry.writeSentAt = 1_700_000_000.125
        entry.listeningEnded = true
        entry.containerGone = false
        entry.endTold = true
        entry.uncertainReason = "outcome_unknown"
        entry.entryIDs = ["00000000000000AB"]
        entry.restorePending = true

        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["kind", "container_name", "write_sent_at", "listening_ended", "container_gone",
                    "end_told", "uncertain_reason", "entry_ids", "before_file", "songs"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(object["kind"] as? String, "album_container")
        XCTAssertEqual(object["write_sent_at"] as? Double, 1_700_000_000.125)
        XCTAssertEqual(object["before_file"] as? String, "before-\(albumTestTxn).json")
        XCTAssertEqual(try JSONDecoder().decode(DiscoverCopyEntry.self, from: data), entry)
    }

    func testACopyEntryEncodesNoneOfTheNewKeys() throws {
        let entry = DiscoverCopyEntry(txn: "T", playlistID: "pl.x", title: "Mix", state: .intent, hex: nil,
                                      copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                                      priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1)
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["txn", "playlist_id", "title", "state", "copies_read", "watching",
                                          "copy_seen", "told_at_launch", "created_at", "updated_at"])
        let decoded = try JSONDecoder().decode(DiscoverCopyEntry.self, from: data)
        XCTAssertNil(decoded.kind)
        XCTAssertNil(decoded.songs)
    }

    // MARK: K4, K8

    func testTheRelationsOpName() {
        XCTAssertEqual(spandacLibraryRelationsOp, "slice.libraryRelations")
    }

    func testTheBounds() {
        XCTAssertEqual(DiscoverAlbumTiming.proofWindow, 180)
        XCTAssertEqual(DiscoverAlbumTiming.collectorCadence, 5)
        XCTAssertEqual(DiscoverAlbumTiming.p4MinGap, 2)
        XCTAssertEqual(DiscoverAlbumTiming.p5LateSlack, 2)
        XCTAssertEqual(DiscoverAlbumTiming.beforeSetBound, 2)
        XCTAssertEqual(DiscoverAlbumTiming.guardScriptTimeout, 10)
        XCTAssertEqual(DiscoverAlbumTiming.proofReadTimeout, DiscoverCopyTiming.scriptTimeout)
        XCTAssertEqual(DiscoverAlbumTiming.retryInterval, 30)
        XCTAssertEqual(DiscoverAlbumTiming.guardStrikes, 3)
        XCTAssertEqual(DiscoverAlbumTiming.recentDeleteBlock, 120)
        XCTAssertEqual(DiscoverAlbumTiming.maxSongs, 100)
    }

    // MARK: K10. The name gate

    func testTheAllowedAndReservedNamesAreDisjoint() {
        XCTAssertTrue(discoverAlbumScriptVariables.isDisjoint(with: discoverAppleScriptReservedNames),
                      "\(discoverAlbumScriptVariables.intersection(discoverAppleScriptReservedNames))")
        XCTAssertTrue(discoverAppleScriptReservedNames.isSuperset(of: ["active", "left"]),
                      "the two measured failures")
    }

    func testAssignedNamesFindsSetAndRepeatWithButNotAppleScriptsProperties() {
        let script = """
        set beforeIDList to persistent ID of every track of library playlist 1
        set AppleScript's text item delimiters to linefeed
        repeat with plRef in userLists
            if plHitCount is not 0 then set liveHolds to true
        end repeat
        repeat with n from 1 to 3
        end repeat
        set   fieldSep   to (ASCII character 31)
        return beforeIDList
        """
        XCTAssertEqual(appleScriptAssignedNames(script), ["beforeIDList", "plRef", "liveHolds", "fieldSep"])
        XCTAssertEqual(appleScriptAssignedNames("return 1"), [])
    }

    func testAssignedNamesCatchesAReservedWord() {
        let names = appleScriptAssignedNames("set active to true\nrepeat with left in items")
        XCTAssertEqual(names, ["active", "left"])
        XCTAssertFalse(names.isDisjoint(with: discoverAppleScriptReservedNames))
    }

    /// The B-script and F-script texts of score 1.5 pass the gate (A2 and A5
    /// own the real scripts and add their own gate tests).
    func testTheScoredScriptShapesPassTheGate() {
        let bScript = """
        set beforeIDList to persistent ID of every track of library playlist 1
        set AppleScript's text item delimiters to linefeed
        set beforeIDText to beforeIDList as text
        set AppleScript's text item delimiters to ""
        return beforeIDText
        """
        let fScript = """
        set foundText to ""
        set userLists to every user playlist
        repeat with plRef in userLists
            set plNameText to ""
            try
                set plNameText to (name of plRef) as text
            end try
        end repeat
        return "ok" & linefeed & foundText
        """
        for script in [bScript, fScript] {
            let names = appleScriptAssignedNames(script)
            XCTAssertFalse(names.isEmpty)
            XCTAssertTrue(names.isSubset(of: discoverAlbumScriptVariables), "\(names)")
            XCTAssertTrue(names.isDisjoint(with: discoverAppleScriptReservedNames))
        }
    }

    // MARK: K9. Wordings

    func testEveryWordingNamesWhatItIsGiven() {
        let album = "Album Zebra"
        let song = "Song Quokka"
        XCTAssertEqual(discoverAlbumPlayingTail(song: song),
                       "from 'Song Quokka'. Songs it adds to your library leave when you stop, unless you love one or add it to a playlist first.")
        XCTAssertEqual(discoverAlbumPlayingOwnedTail(song: song), "from 'Song Quokka'")
        XCTAssertEqual(discoverAlbumRepeatedSongText(album: album),
                       "'Album Zebra' lists the same song twice, so MusicTUI couldn't tell which one it added; nothing played.")
        XCTAssertEqual(discoverAlbumTooManyText, "SpanDAC takes at most 100 songs at once; nothing played.")
        XCTAssertEqual(discoverAlbumRecentlyCleanedText(album: album),
                       "Apple Music hasn't caught up with songs MusicTUI removed from 'Album Zebra' a moment ago; try again in a minute or two. Nothing played.")
        XCTAssertEqual(discoverAlbumRelationsUnreadableText(album: album),
                       "SpanDAC couldn't check which songs from 'Album Zebra' are already in your library; nothing was added and nothing played.")
        XCTAssertEqual(discoverAlbumBeforeSetText(album: album),
                       "MusicTUI couldn't read your library in time to play 'Album Zebra' safely; nothing was added and nothing played.")
        XCTAssertEqual(discoverAlbumMaybeAddedText(album: album),
                       "MusicTUI couldn't confirm whether songs from 'Album Zebra' were added to your library; any it can't prove it added stay there. Nothing played.")
        XCTAssertEqual(discoverAlbumNotOursText(album: album),
                       "MusicTUI left songs from 'Album Zebra' in your library because it couldn't be sure it added them. Nothing played.")
        XCTAssertEqual(discoverAlbumNoIDText(album: album),
                       "Apple Music didn't finish making the temporary playlist for 'Album Zebra' in time; nothing played.")
        XCTAssertEqual(discoverAlbumAllRemovedText(album: album), "Removed the songs 'Album Zebra' added.")
    }

    func testTheRefusalTextNamesTheTemporaryPlaylistAndOtherwiseIsTheShippedOne() {
        XCTAssertEqual(discoverAlbumRefusalText(.unconfirmed(title: "Two"), album: "Blue"),
                       "Couldn't confirm 'Two' in the temporary playlist for 'Blue'; nothing played.")
        XCTAssertNil(discoverAlbumRefusalText(.superseded, album: "Blue"))
        let others: [DiscoverCopyRefusal] = [.notReady, .countChanged, .sourceChanged, .modes,
                                             .firstPlayUnconfirmed, .landing(title: "Two"), .wontPlay(title: "Two")]
        for refusal in others {
            XCTAssertEqual(discoverAlbumRefusalText(refusal, album: "Blue"),
                           discoverCopyRefusalText(refusal, playlist: "Blue"), "\(refusal)")
            XCTAssertNotNil(discoverAlbumRefusalText(refusal, album: "Blue"))
        }
    }

    func testTheKeptLineLabelsEachReasonAndCountsTheRest() {
        let loved = albumTestSong(1, state: .kept, keptReason: "loved")
        let inList = albumTestSong(2, state: .kept, keptReason: "playlist", keptPlaylist: "House")
        let albumLoved = albumTestSong(3, state: .kept, keptReason: "album")
        let unchecked = albumTestSong(4, state: .kept, keptReason: "couldn't check")

        XCTAssertEqual(discoverAlbumKeptText(kept: [loved, inList], album: "Blue", removed: 3),
                       "Kept 'Track 1' (loved) and 'Track 2' (in 'House') from 'Blue'; removed the other 3.")
        XCTAssertEqual(discoverAlbumKeptText(kept: [loved], album: "Blue", removed: 0),
                       "Kept 'Track 1' (loved) from 'Blue'.")
        XCTAssertEqual(discoverAlbumKeptText(kept: [loved, albumLoved, unchecked], album: "Blue", removed: 1),
                       "Kept 'Track 1' (loved), 'Track 3' (album loved) and 'Track 4' (couldn't check) from 'Blue'; removed the other 1.")
    }

    func testTheLeftLineInTheSingularPluralAndThreeItemForms() {
        XCTAssertEqual(discoverAlbumLeftText(titles: ["One"], album: "Blue"),
                       "MusicTUI left 'One' from 'Blue' in your library because it couldn't prove it added it.")
        XCTAssertEqual(discoverAlbumLeftText(titles: ["One", "Two"], album: "Blue"),
                       "MusicTUI left 'One' and 'Two' from 'Blue' in your library because it couldn't prove it added them.")
        XCTAssertEqual(discoverAlbumLeftText(titles: ["One", "Two", "Three"], album: "Blue"),
                       "MusicTUI left 'One', 'Two' and 'Three' from 'Blue' in your library because it couldn't prove it added them.")
    }

    // MARK: The shared fakes behave as documented

    func testFakeLibraryRelationsQueuesAndLogs() throws {
        let fake = FakeLibraryRelations()
        XCTAssertEqual(try fake.relations(catalogueIDs: ["1", "2"]), ["1": [], "2": []])
        fake.results = [.success(["1": ["5"]]), .failure(SpanDACLibraryOpError.failed("x"))]
        XCTAssertEqual(try fake.relations(catalogueIDs: ["1"]), ["1": ["5"]])
        XCTAssertThrowsError(try fake.relations(catalogueIDs: ["1"]))
        XCTAssertThrowsError(try fake.relations(catalogueIDs: ["1"]), "the last result repeats")
        XCTAssertEqual(fake.calls, [["1", "2"], ["1"], ["1"], ["1"]])
        XCTAssertTrue(fake.offersAlbumCleanup)
    }

    func testInMemoryBeforeSetStoreAndFakeAlbumLibrary() throws {
        let store = InMemoryBeforeSetStore()
        let file = try store.writeBeforeSet(txn: albumTestTxn, ids: ["0000000000000001"])
        XCTAssertEqual(file, "before-\(albumTestTxn).json")
        XCTAssertEqual(try store.readBeforeSet(file: file), ["0000000000000001"])
        store.failWrites = true
        XCTAssertThrowsError(try store.writeBeforeSet(txn: "X", ids: []))
        store.deleteBeforeSet(file: file)
        XCTAssertThrowsError(try store.readBeforeSet(file: file))
        XCTAssertEqual(store.calls, ["write:\(albumTestTxn)", "read:\(file)", "write:X!", "delete:\(file)", "read:\(file)"])

        let library = FakeAlbumLibrary(ensureResults: [.success((created: true, id: "p.1", alias: "9"))])
        let ensured = try library.ensurePlaylist(name: "N", catalogueIDs: ["1", "2"])
        XCTAssertEqual(ensured.id, "p.1")
        XCTAssertEqual(library.calls, ["ensure:N:1,2"])
        XCTAssertTrue(discoverCopyEntryHoldsInvariants(albumTestEntry()))
    }
}

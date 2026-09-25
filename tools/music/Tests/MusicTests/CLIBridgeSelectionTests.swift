import XCTest
@testable import music

/// S4: `CLIBridgeSelection.swift`'s name matching and D4 resolvers, against a
/// scripted `BridgeLibraryReadsWire` (shared support in
/// `BridgeLibraryTestSupport.swift`) so these exercise the same
/// `SourceAppControl`/`BridgeMusicProvider` seam production code uses, never a
/// second copy of the wire framing. No command wiring, no scene, no
/// `slice.queue` — only `slice.library*` reads.
final class CLIBridgeSelectionTests: XCTestCase {

    private func provider(_ wire: BridgeLibraryReadsWire) -> BridgeMusicProvider {
        BridgeMusicProvider(control: SourceAppControl(
            path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
    }

    private let noSleep: (TimeInterval) -> Void = { _ in }

    // MARK: - Fixtures

    private func playlistsPage(_ items: [(id: String, title: String)], generation: Int = 1) -> String {
        let itemsJSON = items.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"kind\":\"playlist\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":\(generation),"total":\(items.count),
         "items":[\(itemsJSON)],"next_cursor":null}
        """
    }

    private func albumsPage(_ items: [(id: String, title: String, artist: String)], generation: Int = 1) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"track_count\":1,\"kind\":\"album\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryAlbums","generation":\(generation),"total":\(items.count),
         "items":[\(itemsJSON)],"next_cursor":null}
        """
    }

    private func artistsPage(_ items: [(id: String, title: String)], generation: Int = 1) -> String {
        let itemsJSON = items.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"kind\":\"artist\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryArtists","generation":\(generation),"total":\(items.count),
         "items":[\(itemsJSON)],"next_cursor":null}
        """
    }

    private func songsPage(_ items: [(id: String, title: String, artist: String, album: String)],
                          generation: Int = 1) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\($0.album)\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.librarySongs","generation":\(generation),"total":\(items.count),
         "items":[\(itemsJSON)],"next_cursor":null}
        """
    }

    private func playlistTracksPage(_ items: [(id: String, title: String, artist: String)],
                                    skippedVideos: Int = 0, generation: Int = 1) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":\(generation),"total":\(items.count),
         "items":[\(itemsJSON)],"next_cursor":null,"skipped_videos":\(skippedVideos)}
        """
    }

    private func albumTracksReply(_ items: [(id: String, title: String, artist: String)], generation: Int = 1) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":\(generation),\"items\":[\(itemsJSON)]}"
    }

    private func artistSongsReply(_ items: [(id: String, title: String, artist: String)], generation: Int = 1) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryArtistSongs\",\"generation\":\(generation),\"items\":[\(itemsJSON)]}"
    }

    private func staleReply(op: String) -> String {
        """
        {"ok":false,"op":"\(op)","error":{"kind":"stale_generation","detail":"the library changed while you were reading it; start again"}}
        """
    }

    private func warmingReply(op: String, retryAfter: Double = 0.01) -> String {
        """
        {"ok":false,"op":"\(op)","error":{"kind":"warming","detail":"still preparing your library","retry_after":\(retryAfter)}}
        """
    }

    // MARK: - matchRowsByName (pure)

    func testExactMatchBeatsSubstringMatch() {
        let rows = [MusicRow(id: "1", title: "Rock", artist: "", album: nil, kind: .playlist),
                    MusicRow(id: "2", title: "Rock Anthems", artist: "", album: nil, kind: .playlist)]
        guard case .one(let row) = matchRowsByName(rows, query: "Rock") else {
            return XCTFail("expected the exact match to win")
        }
        XCTAssertEqual(row.id, "1")
    }

    func testTwoExactMatchesAreAmbiguous() {
        // Two rows fold to the same normalised title ("Rock") but differ in
        // case/whitespace, which `normalizeAlbumTitle` treats as identical.
        let rows = [MusicRow(id: "1", title: "Rock", artist: "", album: nil, kind: .playlist),
                    MusicRow(id: "2", title: "  ROCK  ", artist: "", album: nil, kind: .playlist)]
        guard case .ambiguous(let matches) = matchRowsByName(rows, query: "Rock") else {
            return XCTFail("expected two exact matches to be ambiguous")
        }
        XCTAssertEqual(matches.count, 2)
    }

    func testUniqueSubstringMatchPlays() {
        let rows = [MusicRow(id: "1", title: "Awesome Rock Mix", artist: "", album: nil, kind: .playlist),
                    MusicRow(id: "2", title: "Jazz", artist: "", album: nil, kind: .playlist)]
        guard case .one(let row) = matchRowsByName(rows, query: "Rock") else {
            return XCTFail("expected the unique substring match to play")
        }
        XCTAssertEqual(row.id, "1")
    }

    func testNoMatchIsNotFound() {
        let rows = [MusicRow(id: "1", title: "Jazz", artist: "", album: nil, kind: .playlist)]
        XCTAssertEqual(matchRowsByName(rows, query: "Rock"), .notFound)
    }

    // MARK: - filterRowsByArtist (pure)

    func testArtistFilterNarrowsByCredit() {
        let rows = [MusicRow(id: "1", title: "Nude", artist: "Radiohead", album: nil, kind: .song),
                    MusicRow(id: "2", title: "Nude", artist: "Some Other Band", album: nil, kind: .song)]
        let filtered = filterRowsByArtist(rows, artist: "Radiohead")
        XCTAssertEqual(filtered.map(\.id), ["1"])
    }

    func testNilOrEmptyArtistIsNoFilter() {
        let rows = [MusicRow(id: "1", title: "Nude", artist: "Radiohead", album: nil, kind: .song)]
        XCTAssertEqual(filterRowsByArtist(rows, artist: nil), rows)
        XCTAssertEqual(filterRowsByArtist(rows, artist: ""), rows)
    }

    // MARK: - Playlist resolver: temp playlists hidden, ambiguity, not found, no songs

    func testTempPlaylistsAreDroppedBeforeMatching() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [playlistsPage([(id: "pl1", title: "__queue__ Rock")])],
        ])
        let result = try resolveBridgePlaylistSelection(provider: provider(wire), name: "Rock", shuffle: false,
                                                         sleep: noSleep)
        guard case .refused(let msg) = result else { return XCTFail("temp playlist must not match") }
        XCTAssertEqual(msg, "No playlist named 'Rock' in your Bridge library.")
    }

    func testPlaylistNotFound() throws {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage([(id: "pl1", title: "Jazz")])]])
        let result = try resolveBridgePlaylistSelection(provider: provider(wire), name: "Rock", shuffle: false,
                                                         sleep: noSleep)
        XCTAssertEqual(result, .refused("No playlist named 'Rock' in your Bridge library."))
    }

    func testPlaylistAmbiguousListsUpToFiveAndCounts() throws {
        let items = (1...6).map { (id: "pl\($0)", title: "Rock \($0)") }
        // All six share the exact normalised title "rock n" — force ambiguity
        // by giving every row the SAME title instead.
        let sameTitled = items.map { (id: $0.id, title: "Rock") }
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage(sameTitled)]])
        let result = try resolveBridgePlaylistSelection(provider: provider(wire), name: "Rock", shuffle: false,
                                                         sleep: noSleep)
        guard case .refused(let msg) = result else { return XCTFail("6 exact matches must be ambiguous") }
        XCTAssertTrue(msg.hasPrefix("'Rock' matches 6 playlists in your Bridge library: "), msg)
        XCTAssertTrue(msg.contains("; and 1 more"), msg)
        XCTAssertTrue(msg.hasSuffix("Use the exact name."), msg)
        XCTAssertFalse(msg.contains("--artist"), "a playlist ambiguity never suggests --artist")
        XCTAssertFalse(msg.contains(" — "), "playlist rows have no artist, so no dangling dash: \(msg)")
        XCTAssertTrue(msg.contains(": Rock; Rock"), msg)
    }

    func testPlaylistWithNoSongsRefuses() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [playlistsPage([(id: "pl1", title: "Empty")])],
            "slice.libraryPlaylistTracks": [playlistTracksPage([])],
        ])
        let result = try resolveBridgePlaylistSelection(provider: provider(wire), name: "Empty", shuffle: false,
                                                         sleep: noSleep)
        XCTAssertEqual(result, .refused("'Empty' has no songs Bridge can play."))
    }

    func testPlaylistResolvesAndQueuesInOrderWithSkippedVideos() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [playlistsPage([(id: "pl1", title: "Top 25 Most Played")])],
            "slice.libraryPlaylistTracks": [playlistTracksPage(
                [(id: "t1", title: "A", artist: "X"), (id: "t2", title: "B", artist: "Y")], skippedVideos: 2)],
        ])
        let result = try resolveBridgePlaylistSelection(
            provider: provider(wire), name: "Top 25 Most Played", shuffle: false, sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Top 25 Most Played", ids: ["t1", "t2"],
                                     startRequired: false, skippedVideos: 2))
        // Never touches the queue op — S4 resolves, S7 sends.
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
        XCTAssertTrue(wire.requests.allSatisfy { ($0["op"] as? String)?.hasPrefix("slice.library") == true })
    }

    // MARK: - Album resolver: artist filter, ambiguity suggests --artist

    func testAlbumArtistFilterResolvesASameTitledCollision() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryAlbums": [albumsPage([(id: "a1", title: "Greatest Hits", artist: "Queen"),
                                                (id: "a2", title: "Greatest Hits", artist: "Bowie")])],
            "slice.libraryAlbumTracks": [albumTracksReply([(id: "t1", title: "Track", artist: "Bowie")])],
        ])
        let result = try resolveBridgeAlbumSelection(provider: provider(wire), name: "Greatest Hits",
                                                      artist: "Bowie", shuffle: false, sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Greatest Hits", ids: ["t1"], startRequired: false, skippedVideos: 0))
    }

    func testAlbumAmbiguitySuggestsArtist() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryAlbums": [albumsPage([(id: "a1", title: "Greatest Hits", artist: "Queen"),
                                                (id: "a2", title: "Greatest Hits", artist: "Bowie")])],
        ])
        let result = try resolveBridgeAlbumSelection(provider: provider(wire), name: "Greatest Hits",
                                                      artist: nil, shuffle: false, sleep: noSleep)
        guard case .refused(let msg) = result else { return XCTFail("expected ambiguity") }
        XCTAssertTrue(msg.hasSuffix("Use the exact name, or add --artist."), msg)
    }

    // MARK: - Artist resolver: Bridge's own order, no shuffle

    func testArtistResolvesInBridgesOwnOrder() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryArtists": [artistsPage([(id: "ar1", title: "Radiohead")])],
            "slice.libraryArtistSongs": [artistSongsReply([(id: "s2", title: "Nude", artist: "Radiohead"),
                                                            (id: "s1", title: "Bodysnatchers", artist: "Radiohead")])],
        ])
        let result = try resolveBridgeArtistSelection(provider: provider(wire), name: "Radiohead", sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Radiohead", ids: ["s2", "s1"], startRequired: false, skippedVideos: 0))
    }

    func testArtistNotFound() throws {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage([(id: "ar1", title: "Radiohead")])]])
        let result = try resolveBridgeArtistSelection(provider: provider(wire), name: "Bowie", sleep: noSleep)
        XCTAssertEqual(result, .refused("No artist named 'Bowie' in your Bridge library."))
    }

    // MARK: - Song resolver: one id, startRequired true, artist filter, no catalogue fallback

    func testSongPlaysOneIdWithStartRequiredTrue() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([(id: "s1", title: "Nude", artist: "Radiohead", album: "In Rainbows")])],
        ])
        let result = try resolveBridgeSongSelection(provider: provider(wire), title: "Nude", artist: nil, sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Nude", ids: ["s1"], startRequired: true, skippedVideos: 0))
    }

    func testSongArtistFilterResolvesASameTitledCollision() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([(id: "s1", title: "Nude", artist: "Radiohead", album: "In Rainbows"),
                                              (id: "s2", title: "Nude", artist: "Other Band", album: "Other")])],
        ])
        let result = try resolveBridgeSongSelection(provider: provider(wire), title: "Nude", artist: "Radiohead", sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Nude", ids: ["s1"], startRequired: true, skippedVideos: 0))
    }

    func testSongNotFoundNamesTheArtistWhenGiven() throws {
        let wire = BridgeLibraryReadsWire(["slice.librarySongs": [songsPage([])]])
        let result = try resolveBridgeSongSelection(provider: provider(wire), title: "Nude", artist: "Radiohead", sleep: noSleep)
        XCTAssertEqual(result, .refused(
            "No song matching 'Nude' by 'Radiohead' in your Bridge library. From the CLI, Bridge plays your library only; nothing was added or played."))
    }

    func testSongAmbiguitySuggestsArtistAndSearch() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([(id: "s1", title: "Nude", artist: "Radiohead", album: "A"),
                                              (id: "s2", title: "Nude", artist: "Other", album: "B")])],
        ])
        let result = try resolveBridgeSongSelection(provider: provider(wire), title: "Nude", artist: nil, sleep: noSleep)
        guard case .refused(let msg) = result else { return XCTFail("expected ambiguity") }
        XCTAssertTrue(msg.contains("Use the exact name, or add --artist."), msg)
        XCTAssertTrue(msg.hasSuffix("Or: music search --library \"Nude\"  then  music play N"), msg)
    }

    // MARK: - Stale generation: restarts once, twice fails

    func testStaleGenerationRestartsOnceThenSucceeds() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [staleReply(op: "slice.libraryPlaylists"),
                                       playlistsPage([(id: "pl1", title: "Rock")])],
            "slice.libraryPlaylistTracks": [playlistTracksPage([(id: "t1", title: "A", artist: "X")])],
        ])
        let result = try resolveBridgePlaylistSelection(provider: provider(wire), name: "Rock", shuffle: false,
                                                         sleep: noSleep)
        XCTAssertEqual(result, .play(label: "Rock", ids: ["t1"], startRequired: false, skippedVideos: 0))
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2, "expected one restart")
    }

    func testStaleGenerationTwiceThrows() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [staleReply(op: "slice.libraryPlaylists"),
                                       staleReply(op: "slice.libraryPlaylists")],
        ])
        XCTAssertThrowsError(
            try resolveBridgePlaylistSelection(provider: provider(wire), name: "Rock", shuffle: false, sleep: noSleep)
        ) { error in
            guard case MusicProviderError.staleGeneration = error else {
                return XCTFail("expected staleGeneration, got \(error)")
            }
        }
    }

    // MARK: - Warming spends the budget

    func testWarmingRetriesOnTheProvidersHintAndSpendsTheBudget() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [warmingReply(op: "slice.libraryPlaylists", retryAfter: 0.01),
                                       playlistsPage([(id: "pl1", title: "Rock")])],
            "slice.libraryPlaylistTracks": [playlistTracksPage([(id: "t1", title: "A", artist: "X")])],
        ])
        let budget = WarmUpBudget()
        var sleepCalls: [TimeInterval] = []
        var warmedHints: [TimeInterval] = []
        let result = try resolveBridgePlaylistSelection(
            provider: provider(wire), name: "Rock", shuffle: false, budget: budget,
            sleep: { sleepCalls.append($0) }, onWarming: { warmedHints.append($0) })
        XCTAssertEqual(result, .play(label: "Rock", ids: ["t1"], startRequired: false, skippedVideos: 0))
        XCTAssertEqual(sleepCalls.count, 1)
        XCTAssertEqual(warmedHints.count, 1)
        XCTAssertGreaterThan(budget.waited, 0, "the shared budget must record the wait it spent")
    }

    // MARK: - search --library: clauses case by case, blank refuses, Bridge's order, first `limit`

    func testSearchRefusesBlankBeforeAnyRequest() throws {
        let wire = BridgeLibraryReadsWire()
        let result = try bridgeLibrarySearch(provider: provider(wire), term: "", artist: nil, album: nil,
                                             limit: 20, sleep: noSleep)
        XCTAssertEqual(result, .refused("Name something to search for."))
        XCTAssertEqual(wire.requestCount, 0)
    }

    func testSearchTermMatchesTitleArtistOrAlbum() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([
                (id: "s1", title: "Kid A", artist: "Radiohead", album: "Kid A"),      // matches title
                (id: "s2", title: "Nude", artist: "Kid A Fan Club", album: "X"),        // matches artist
                (id: "s3", title: "Track", artist: "Someone", album: "Kid A (Live)"),  // matches album
                (id: "s4", title: "Unrelated", artist: "Other", album: "Nothing"),
            ])],
        ])
        guard case .rows(let rows) = try bridgeLibrarySearch(provider: provider(wire), term: "Kid A", artist: nil,
                                                             album: nil, limit: 20, sleep: noSleep) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.map(\.id), ["s1", "s2", "s3"])
    }

    func testSearchArtistAndAlbumClausesAreAnded() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([
                (id: "s1", title: "Nude", artist: "Radiohead", album: "In Rainbows"),
                (id: "s2", title: "Nude", artist: "Radiohead", album: "Other Album"),
                (id: "s3", title: "Nude", artist: "Someone Else", album: "In Rainbows"),
            ])],
        ])
        guard case .rows(let rows) = try bridgeLibrarySearch(provider: provider(wire), term: "", artist: "Radiohead",
                                                             album: "In Rainbows", limit: 20, sleep: noSleep) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.map(\.id), ["s1"])
    }

    func testSearchKeepsBridgesOrderAndCapsAtLimit() throws {
        let wire = BridgeLibraryReadsWire([
            "slice.librarySongs": [songsPage([
                (id: "s3", title: "Rock C", artist: "X", album: ""),
                (id: "s1", title: "Rock A", artist: "X", album: ""),
                (id: "s2", title: "Rock B", artist: "X", album: ""),
            ])],
        ])
        guard case .rows(let rows) = try bridgeLibrarySearch(provider: provider(wire), term: "Rock", artist: nil,
                                                             album: nil, limit: 2, sleep: noSleep) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.map(\.id), ["s3", "s1"], "Bridge's own order, not re-sorted")
    }

    func testSearchOnlyAsksLibrarySongsNeverQueue() throws {
        let wire = BridgeLibraryReadsWire(["slice.librarySongs": [songsPage([
            (id: "s1", title: "Nude", artist: "Radiohead", album: "In Rainbows"),
        ])]])
        _ = try bridgeLibrarySearch(provider: provider(wire), term: "Nude", artist: nil, album: nil,
                                    limit: 20, sleep: noSleep)
        XCTAssertTrue(wire.sent("slice.queue").isEmpty)
        XCTAssertTrue(wire.requests.allSatisfy { ($0["op"] as? String) == "slice.librarySongs" })
    }
}

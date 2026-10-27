import XCTest
@testable import music

/// `p`/`s` on an Artists-list row plays exactly the albums that row lists
/// (ruling 2026-10-27 15:04). The list groups by credit (album artist, else
/// artist); play used to fetch by TRACK artist, which disagreed for 156 of 740
/// rows on the Studio library. These pin the shapes measured there.
final class ListedArtistPlayTests: XCTestCase {

    private func row(_ index: Int, artist: String, albumArtist: String, album: String,
                     disc: Int = 1, track: Int = 0, status: String = "subscription") -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: "t\(index)", artist: artist, albumArtist: albumArtist,
                        cloudStatus: status, disc: disc, track: track, album: album)
    }

    func testADJMixUnderTheArtistIsListedSoItPlays() {
        // Four Tet's "Live From Lost Village" mix: album artist Four Tet, each track
        // credits the artist mixed in. Track-artist play missed all 26 of them.
        let rows = [
            row(1, artist: "Four Tet", albumArtist: "Four Tet", album: "Rounds"),
            row(2, artist: "Autechre", albumArtist: "Four Tet", album: "Live From Lost Village"),
            row(3, artist: "Four Tet & Burial", albumArtist: "Four Tet", album: "Live From Lost Village"),
        ]
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "Four Tet").map(\.index), [1, 2, 3])
    }

    func testAnAppearanceOnSomeoneElsesAlbumIsNotListedSoItDoesNotPlay() {
        let rows = [
            row(1, artist: "New Order", albumArtist: "New Order", album: "Technique"),
            row(2, artist: "New Order", albumArtist: "Various Artists", album: "Hacienda Classics"),
        ]
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "New Order").map(\.index), [1])
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "Various Artists").map(\.index), [2])
    }

    func testABlankAlbumArtistFallsBackToTheTrackArtist() {
        let rows = [row(1, artist: "Slam", albumArtist: "", album: "Year Zero")]
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "Slam").map(\.index), [1])
    }

    func testACaseVariantCreditIsItsOwnRow() {
        // Music's `is` ignores case, so the fetch returns both spellings; the list
        // shows them as two rows, so each row plays only its own.
        let rows = [
            row(1, artist: "Groove Armada", albumArtist: "Groove Armada", album: "Vertigo"),
            row(2, artist: "groove armada", albumArtist: "", album: "goodbye country (hello nightclub)"),
        ]
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "Groove Armada").map(\.index), [1])
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "groove armada").map(\.index), [2])
    }

    func testATrackWithNoAlbumIsNotListedSoItDoesNotPlay() {
        let rows = [row(1, artist: "Slam", albumArtist: "Slam", album: ""),
                    row(2, artist: "Slam", albumArtist: "Slam", album: "Year Zero")]
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "Slam").map(\.index), [2])
    }

    func testSelectionMatchesTheDrillInRowForRow() {
        // The same tracks through both shapes: what the drill-in counts under each
        // credit is exactly what selection picks for it.
        let tracks: [(artist: String, albumArtist: String, album: String)] = [
            ("Four Tet", "Four Tet", "Rounds"), ("Autechre", "Four Tet", "Mix"),
            ("New Order", "Various Artists", "Comp"), ("New Order", "New Order", "Technique"),
            ("groove armada", "", "Goodbye"), ("Groove Armada", "Groove Armada", "Vertigo"),
            ("Slam", "", ""), ("Slam", "", "Year Zero"),
        ]
        let indexRows = tracks.enumerated().map { i, t in
            LibraryTrackRow(persistentID: "p\(i)", name: "t\(i)", artist: t.artist, album: t.album,
                            albumArtist: t.albumArtist, cloudStatus: "subscription")
        }
        let playRows = tracks.enumerated().map { i, t in
            row(i, artist: t.artist, albumArtist: t.albumArtist, album: t.album)
        }
        // Row for row: the persistent ids of the rows behind each listed album id,
        // in listed album order, against the selected rows' indices, in play order.
        for artist in groupLibraryArtists(indexRows) {
            let listedAlbums = groupLibraryArtistAlbums(indexRows, artistID: artist.id)
            let listed = listedAlbums.flatMap { album in
                indexRows.enumerated().filter {
                    !$0.element.album.isEmpty && libraryAlbumID(forKey: libraryAlbumKey(
                        album: $0.element.album, albumArtist: $0.element.albumArtist,
                        artist: $0.element.artist)) == album.id
                }.map(\.offset)
            }
            let played = sortRowsByListedAlbumOrder(selectListedArtistTracks(playRows, credit: artist.name))
            XCTAssertEqual(played.map(\.index), listed, artist.name)
        }
    }

    func testTheTierOnScreenScopesPlayToTheAlbumsItLists() {
        // Artists' Albums view lists 6+ track albums, 12"/EP lists 2-5: an artist with
        // a 2-track EP and a 6-track LP shows one of them in each, and plays that one.
        let ep = (1...2).map { row($0, artist: "A", albumArtist: "A", album: "EP", track: $0) }
        let lp = (3...8).map { row($0, artist: "A", albumArtist: "A", album: "LP", track: $0 - 2) }
        let rows = ep + lp
        XCTAssertEqual(Set(selectListedArtistTracks(rows, credit: "A", trackRange: 6...Int.max).map(\.album)), ["LP"])
        XCTAssertEqual(Set(selectListedArtistTracks(rows, credit: "A", trackRange: 2...5).map(\.album)), ["EP"])
        XCTAssertEqual(selectListedArtistTracks(rows, credit: "A").count, 8)
    }

    func testATierCountsUnavailableTracksTheWayTheListDoes() {
        // The list counts every row of an album; a 6-track LP with one pre-release
        // track is still in the Albums view, so it still plays (its 5 playable tracks).
        let lp = (1...6).map { row($0, artist: "A", albumArtist: "A", album: "LP", track: $0,
                                   status: $0 == 6 ? "prerelease" : "subscription") }
        XCTAssertEqual(selectListedArtistTracks(lp, credit: "A", trackRange: 6...Int.max).count, 6)
        XCTAssertTrue(selectListedArtistTracks(lp, credit: "A", trackRange: 2...5).isEmpty)
    }

    func testPlayOrderIsTheListedAlbumOrderThenDiscAndTrack() {
        let rows = [
            row(1, artist: "A", albumArtist: "A", album: "zebra", track: 1),
            row(2, artist: "A", albumArtist: "A", album: "Apple", disc: 2, track: 1),
            row(3, artist: "A", albumArtist: "A", album: "Apple", disc: 1, track: 2),
            row(4, artist: "A", albumArtist: "A", album: "Apple", disc: 1, track: 1),
            row(5, artist: "A", albumArtist: "A", album: "mango", track: 1),
        ]
        XCTAssertEqual(sortRowsByListedAlbumOrder(rows).map(\.index), [4, 3, 2, 5, 1])
    }

    func testTheFetchClauseCoversBothCreditShapesAndEscapes() {
        XCTAssertEqual(listedArtistWhereClause(credit: "Four Tet"),
                       "album artist is \"Four Tet\" or (album artist is \"\" and artist is \"Four Tet\")")
        XCTAssertTrue(listedArtistWhereClause(credit: "Say \"Hi\"").contains("\\\"Hi\\\""))
    }

    // MARK: - The scene's default resolver, end to end through a fake interpreter

    /// A fake `osascript`: the album-rows read (the only script carrying
    /// `database ID`) gets `payload`; every other script is logged and succeeds.
    private func fakeInterpreter(payload: String) -> (backend: AppleScriptBackend, log: String) {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let payloadPath = dir.appendingPathComponent("listed-artist-payload-\(id).txt").path
        let logPath = dir.appendingPathComponent("listed-artist-log-\(id).txt").path
        let scriptPath = dir.appendingPathComponent("listed-artist-fake-\(id).sh").path
        try? payload.write(toFile: payloadPath, atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            case "$2" in
              *"database ID"*) cat "\(payloadPath)" ;;
              *) printf '%s\\n' "$2" >> "\(logPath)" ;;
            esac
            exit 0
            """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return (AppleScriptBackend(executable: scriptPath), logPath)
    }

    private func line(_ r: LibraryAlbumRow) -> String {
        [String(r.index), r.name, r.artist, r.albumArtist, r.cloudStatus, String(r.disc), String(r.track), r.album]
            .joined(separator: String(asFieldSep))
    }

    private func defaultScene(backend: AppleScriptBackend, queue: AppQueueStore, status: StatusStore) -> LibraryScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.musicApp)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: { _, _ in "" }) })
        let sources = LibraryDataSources(onAlbums: { _ in true }, onSongs: { _ in true },
                                         onArtists: { _ in true },
                                         onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                                         onAlbumCover: { _ in nil })
        // No resolveArtist: this is the production default.
        return LibraryScene(backend: backend, routing: routing, sources: sources, appQueue: queue,
                            status: status, actions: ActionRunner(status: status),
                            resultCache: temporaryResultCache().cache)
    }

    private func settledQueue(_ queue: AppQueueStore, seconds: Double = 3.0) -> AppQueue? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, queue.read() == nil { usleep(10_000) }
        return queue.read()
    }

    /// The fetch is case-insensitive, so it returns everything below; the queue
    /// must hold exactly the owned mix and LP, listed order, unavailable dropped.
    private var measuredShapes: [LibraryAlbumRow] {
        [
            row(11, artist: "Four Tet", albumArtist: "Various Artists", album: "Comp"),          // appearance
            row(12, artist: "four tet", albumArtist: "", album: "Lower"),                        // case variant
            row(13, artist: "Autechre", albumArtist: "Four Tet", album: "Mix", track: 2),        // owned DJ mix
            row(14, artist: "Bakey", albumArtist: "Four Tet", album: "Mix", track: 1),
            row(15, artist: "Four Tet", albumArtist: "Four Tet", album: "Rounds", track: 1),
            row(16, artist: "Four Tet", albumArtist: "Four Tet", album: "Rounds", track: 2, status: "prerelease"),
        ]
    }

    func testPlayOnAnArtistRowQueuesExactlyItsListedTracks() {
        let fake = fakeInterpreter(payload: measuredShapes.map(line).joined(separator: "\n") + "\n")
        let queue = AppQueueStore()
        let status = StatusStore()
        defaultScene(backend: fake.backend, queue: queue, status: status).playArtist(name: "Four Tet", shuffle: false)
        let q = settledQueue(queue)
        XCTAssertEqual(q?.tracks.map(\.index), [14, 13, 15], "Mix (track 1, 2), then Rounds; no appearance, variant or pre-release")
        // The queue is set just before the first track is asked to play.
        let want = "play track 14 of playlist \"Library\""
        var log = ""
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, !log.contains(want) {
            log = (try? String(contentsOfFile: fake.log, encoding: .utf8)) ?? ""
            usleep(10_000)
        }
        XCTAssertTrue(log.contains(want), log)
    }

    func testShuffleQueuesTheSameSet() {
        let fake = fakeInterpreter(payload: measuredShapes.map(line).joined(separator: "\n") + "\n")
        let queue = AppQueueStore()
        defaultScene(backend: fake.backend, queue: queue, status: StatusStore()).playArtist(name: "Four Tet", shuffle: true)
        XCTAssertEqual(Set(settledQueue(queue)?.tracks.map(\.index) ?? []), [13, 14, 15])
    }

    func testPlayInATierQueuesOnlyThatTiersAlbums() {
        let ep = (1...2).map { row($0, artist: "A", albumArtist: "A", album: "EP", track: $0) }
        let lp = (3...8).map { row($0, artist: "A", albumArtist: "A", album: "LP", track: $0 - 2) }
        for (range, want) in [(6...Int.max, Array(3...8)), (2...5, [1, 2])] {
            let fake = fakeInterpreter(payload: (ep + lp).map(line).joined(separator: "\n") + "\n")
            let queue = AppQueueStore()
            defaultScene(backend: fake.backend, queue: queue, status: StatusStore())
                .playArtist(name: "A", shuffle: false, trackRange: range)
            XCTAssertEqual(settledQueue(queue)?.tracks.map(\.index), want, "\(range)")
        }
    }
}

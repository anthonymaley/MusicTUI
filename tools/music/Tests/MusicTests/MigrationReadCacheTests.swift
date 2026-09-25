// tools/music/Tests/MusicTests/MigrationReadCacheTests.swift
//
// Slice 3 score, S8 [B] (Anthony's Q2 ruling): the read-only CLI lookups keep
// their shipped backends as temporary migration exceptions, and their results
// never feed Bridge `play N`.
//
// A Bridge `search --library` publishes Bridge rows through its real command
// path; then the SHIPPED cache writer a preserved read uses,
// `searchCacheRows(_:origin:)`, overwrites them with catalogue (or Music.app
// library) rows in the same temp cache, standing in for a migration read run
// with Bridge still selected. Bridge `play 1`, through its real command path,
// then refuses in S3's words and sends no `slice.queue`. Temp store, lock and
// cache; the external-call tripwire armed; nothing sleeps.
import ArgumentParser
import XCTest
@testable import music

final class MigrationReadCacheTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias R = CLIBridgeLibraryReplies

    private let ready = CLIBridgeReplies.status()
    private let library = R.songs([("s1", "Angel", "Massive Attack", "Mezzanine"),
                                   ("s2", "Teardrop", "Massive Attack", "Mezzanine")])

    private var neverMusicApp: PlayMusicAppDeps {
        PlayMusicAppDeps(readSongs: { XCTFail("Music.app read the cache"); return [] },
                         resolveIndexed: { _, _ in XCTFail("Music.app re-resolved") })
    }

    private func assertAMigrationReadsRowsNeverFeedBridgePlay(origin: SongOrigin,
                                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let h = H(.source, ["slice.status": [ready, ready], "slice.librarySongs": [library]])

        var searchError: Error?
        var playError: Error?
        let calls = try withTripwire { () -> Void in
            do {
                try runSearch(query: ["massive"], artist: nil, album: nil, types: "songs", library: true,
                              limit: 10, json: false, env: h.env,
                              musicApp: { _, _, _, _, _, _, _ in XCTFail("Music.app search ran") })
            } catch { searchError = error }
        }.calls
        XCTAssertNil(searchError, file: file, line: line)
        XCTAssertEqual(calls, [], file: file, line: line)
        XCTAssertEqual(try h.cache.readSongs().map(\.origin), [.bridgeLibrary, .bridgeLibrary],
                       "Bridge search published Bridge rows", file: file, line: line)

        // The preserved read's shipped writer, same cache, Bridge still selected.
        try h.cache.writeSongs(searchCacheRows([CatalogSong(id: "1440", title: "Angel", artist: "Massive Attack",
                                                            album: "Mezzanine")], origin: origin))
        let row = try h.cache.lookupSong(index: 1)
        XCTAssertEqual(row.origin, origin, file: file, line: line)
        guard case .refuse(let why) = bridgeRef(forCachedRow: row, index: 1) else {
            return XCTFail("a \(origin) row became a Bridge reference", file: file, line: line)
        }
        XCTAssertEqual(why, "Result 1 came from a Music.app or catalogue listing, so Bridge can't play it by its own id. With Bridge selected, run: music search \"Angel\"  then  music play N",
                       file: file, line: line)

        let before = h.io.out.count
        let playCalls = try withTripwire { () -> Void in
            do {
                try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil,
                            json: false, env: h.env, musicAppDeps: neverMusicApp)
            } catch { playError = error }
        }.calls
        XCTAssertEqual(playError as? ExitCode, .failure, file: file, line: line)
        XCTAssertEqual(Array(h.io.out.dropFirst(before)), [why], file: file, line: line)
        XCTAssertEqual(h.wire.sent("slice.queue").count, 0, "no queue from a migration read's row", file: file, line: line)
        XCTAssertEqual(playCalls, [], file: file, line: line)
    }

    func testACatalogueSearchRowNeverFeedsBridgePlay() throws {
        try assertAMigrationReadsRowsNeverFeedBridgePlay(origin: .catalog)
    }

    func testAMusicAppLibraryRowNeverFeedsBridgePlay() throws {
        try assertAMigrationReadsRowsNeverFeedBridgePlay(origin: .library)
    }

    /// The migration reads route as shipped on Bridge (they are exceptions,
    /// not dispatched), so none of them can publish a Bridge row: only the
    /// dispatched `search --library` writes `.bridgeLibrary`, and the
    /// dispatched catalogue search `.bridgeCatalog`. Part 2 P8 retired
    /// discover, the playlist listings, similar, suggest and new-releases
    /// (`testTheP8MigrationExceptionsAreRetired`); `recent` and `rotation`
    /// remain for P9.
    func testTheMigrationReadsAreExceptionsNotDispatched() {
        for action in [MusicTUIAction.recent, .rotation] {
            XCTAssertTrue(cliBridgeExceptions.contains(action), "\(action)")
            XCTAssertFalse(cliDispatchedOnBridge.contains(action), "\(action)")
            XCTAssertEqual(routeAction(action, in: .source, from: .cli),
                           routeAction(action, in: .musicApp, from: .cli), "\(action)")
        }
    }

    /// Part 2, P6 retired the catalogue-search migration exception: with
    /// Bridge selected it is dispatched to Bridge, never run as shipped.
    func testTheCatalogueSearchMigrationExceptionIsRetired() {
        XCTAssertFalse(cliBridgeExceptions.contains(.catalogSearch))
        XCTAssertTrue(cliDispatchedOnBridge.contains(.catalogSearch))
        XCTAssertEqual(routeAction(.catalogSearch, in: .source, from: .cli), .source)
        XCTAssertEqual(routeAction(.catalogSearch, in: .musicApp, from: .cli), .musicApp, "Decision 7: shipped in Music.app mode")
    }

    /// Part 2, P8 retired five: with Bridge selected, discover, the playlist
    /// listings and `similar <title>` dispatch to Bridge (their rows are
    /// `.bridgeLibrary`/`.bridgeCatalog`, written by Bridge ops), and
    /// `suggest`/`new-releases` refuse. None runs its shipped body on Bridge.
    func testTheP8MigrationExceptionsAreRetired() {
        for action in [MusicTUIAction.discoverFeed, .playlistListing, .similar] {
            XCTAssertFalse(cliBridgeExceptions.contains(action), "\(action)")
            XCTAssertEqual(routeAction(action, in: .source, from: .cli), .source, "\(action)")
        }
        for action in [MusicTUIAction.suggest, .newReleases] {
            XCTAssertFalse(cliBridgeExceptions.contains(action), "\(action)")
            guard case .refused = routeAction(action, in: .source, from: .cli) else {
                XCTFail("\(action) must refuse on Bridge"); continue
            }
        }
    }
}

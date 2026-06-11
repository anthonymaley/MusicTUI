import XCTest
@testable import music

final class PlayResolutionTests: XCTestCase {
    func testTwoArgsTryPlaylistAlbumSongBeforeSongArtist() {
        // "kid a" must hit the album lookup before the song+artist heuristic:
        // title contains "kid" + artist contains "a" false-positives on almost
        // any library ("Sinister Kid" — The Black Keys, found live 2026-06-11).
        let plan = PlayResolution.plan(queryArgs: ["kid", "a"])
        XCTAssertEqual(plan, [
            .playlistAlbumSong(query: "kid a"),
            .songArtist(title: "kid", artist: "a"),
        ])
    }

    func testQuotedSongArtistStillReachableAsFallback() {
        let plan = PlayResolution.plan(queryArgs: ["Gypsy Woman", "Tom Misch"])
        XCTAssertEqual(plan, [
            .playlistAlbumSong(query: "Gypsy Woman Tom Misch"),
            .songArtist(title: "Gypsy Woman", artist: "Tom Misch"),
        ])
    }

    func testSingleArgHasNoSongArtistFallback() {
        let plan = PlayResolution.plan(queryArgs: ["mellow"])
        XCTAssertEqual(plan, [.playlistAlbumSong(query: "mellow")])
    }

    func testThreeArgsHaveNoSongArtistFallback() {
        let plan = PlayResolution.plan(queryArgs: ["kid", "a", "radiohead"])
        XCTAssertEqual(plan, [.playlistAlbumSong(query: "kid a radiohead")])
    }

    func testEmptyQueryHasNoStrategies() {
        XCTAssertEqual(PlayResolution.plan(queryArgs: []), [])
    }
}

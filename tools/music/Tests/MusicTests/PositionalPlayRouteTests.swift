import XCTest
@testable import music

final class PositionalPlayRouteTests: XCTestCase {

    /// Precedence is playlist, then album, then song. Unchanged from the old
    /// combined script.
    func testPlaylistWinsAndCreatesNoContainer() {
        XCTAssertEqual(positionalRoute(playlistPlayed: true, albumRowCount: 5),
                       .playlistAlreadyPlaying)
    }

    func testAlbumWhenPlaylistMissedAndRowsExist() {
        XCTAssertEqual(positionalRoute(playlistPlayed: false, albumRowCount: 5),
                       .boundedAlbum)
    }

    func testSongWhenPlaylistMissedAndNoAlbumRows() {
        XCTAssertEqual(positionalRoute(playlistPlayed: false, albumRowCount: 0),
                       .song)
    }

    /// A failed album probe stops the route. Counting it as zero rows would
    /// hand the query to the song branch and could play a same-named song.
    func testFailedAlbumReadStopsTheRouteInsteadOfTryingTheSong() {
        XCTAssertEqual(positionalRoute(playlistPlayed: false, albumRowCount: nil),
                       .albumReadFailed)
    }

    /// A playlist that already played stays terminal even if no album read
    /// happened: audio is running, so there is no failure to report.
    func testPlaylistStillWinsOverAMissingAlbumRead() {
        XCTAssertEqual(positionalRoute(playlistPlayed: true, albumRowCount: nil),
                       .playlistAlreadyPlaying)
    }

    /// A playlist hit has already started audio, so nothing further may play.
    /// This is the no-double-start guarantee.
    func testPlaylistRouteIsTerminal() {
        let route = positionalRoute(playlistPlayed: true, albumRowCount: 0)
        XCTAssertEqual(route, .playlistAlreadyPlaying)
        XCTAssertNotEqual(route, .song)
    }
}

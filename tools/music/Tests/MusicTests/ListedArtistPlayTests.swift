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
        for artist in groupLibraryArtists(indexRows) {
            let listed = groupLibraryArtistAlbums(indexRows, artistID: artist.id).reduce(0) { $0 + $1.trackCount }
            XCTAssertEqual(selectListedArtistTracks(playRows, credit: artist.name).count, listed, artist.name)
        }
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
}

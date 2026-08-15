import XCTest
@testable import music

final class PlaylistTrackParseTests: XCTestCase {
    private func line(_ fields: [String]) -> String {
        fields.joined(separator: String(asFieldSep))
    }

    func testParsesNumberedLines() {
        let raw = [
            line(["1", "Andromeda", "Gorillaz", "Humanz"]),
            line(["2", "Saturnz Barz", "Gorillaz", "Humanz"]),
        ].joined(separator: "\n")
        let tracks = parsePlaylistTrackLines(raw)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].num, 1)
        XCTAssertEqual(tracks[0].title, "Andromeda")
        XCTAssertEqual(tracks[1].num, 2)
        XCTAssertEqual(tracks[1].artist, "Gorillaz")
        XCTAssertEqual(tracks[1].album, "Humanz")
    }

    /// The bug: a "|" in a track title used to shift artist/album, and the
    /// corrupted row was cached for a later `music play N`.
    func testPipeInTitleDoesNotShiftFields() {
        let raw = line(["1", "Rock|Paper", "ArtistX", "AlbumY"])
        let tracks = parsePlaylistTrackLines(raw)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].title, "Rock|Paper")
        XCTAssertEqual(tracks[0].artist, "ArtistX")
        XCTAssertEqual(tracks[0].album, "AlbumY")
    }

    func testMalformedLinesAreSkipped() {
        let raw = [
            "garbage with no separators",
            line(["not-a-number", "T", "A", "B"]),
            line(["3", "Real", "Artist", "Album"]),
        ].joined(separator: "\n")
        let tracks = parsePlaylistTrackLines(raw)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].num, 3)
    }
}

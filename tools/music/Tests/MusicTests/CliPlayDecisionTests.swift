import XCTest
@testable import music

final class CliPlayDecisionTests: XCTestCase {
    private func row(_ index: Int, name: String = "T", cloud: String = "unknown",
                     disc: Int = 0, track: Int = 0) -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: name, artist: "A", albumArtist: "A",
                        cloudStatus: cloud, disc: disc, track: track)
    }

    // MARK: decideAlbumPlay — CLI `play --album` twin of the TUI resolver

    /// The bug: the CLI picked minimum track number ignoring disc, so a
    /// multi-disc album could start on disc 2 (its track 1 enumerates first
    /// in library order).
    func testMultiDiscStartsOnDiscOne() {
        let rows = [
            row(50, name: "D2T1", disc: 2, track: 1),   // library order first
            row(51, name: "D1T2", disc: 1, track: 2),
            row(52, name: "D1T1", disc: 1, track: 1),
        ]
        XCTAssertEqual(decideAlbumPlay(rows), .play(position: 52, playable: 3, matched: 3))
    }

    /// The bug: an unplayable first track (prerelease) made `play` silently
    /// no-op while the CLI reported the still-playing old track as success.
    func testUnplayableFirstTrackIsSkipped() {
        let rows = [
            row(10, name: "T1", cloud: "prerelease", disc: 1, track: 1),
            row(11, name: "T2", disc: 1, track: 2),
        ]
        XCTAssertEqual(decideAlbumPlay(rows), .play(position: 11, playable: 1, matched: 2))
    }

    func testNoMatchesIsNotFound() {
        XCTAssertEqual(decideAlbumPlay([]), .notFound)
    }

    func testAllUnplayableIsNonePlayable() {
        let rows = [
            row(10, cloud: "prerelease", disc: 1, track: 1),
            row(11, cloud: "removed", disc: 1, track: 2),
        ]
        XCTAssertEqual(decideAlbumPlay(rows), .nonePlayable(matched: 2))
    }

    // MARK: firstPlayablePosition — `playLocalSong` twin of the same filter

    func testFirstPlayableSkipsUnplayableInFetchOrder() {
        let rows = [
            row(20, cloud: "prerelease"),
            row(21, cloud: "removed"),
            row(22),
        ]
        XCTAssertEqual(firstPlayablePosition(rows), 22)
    }

    /// Song search keeps fetch order — no album sort (matches span albums).
    func testFirstPlayableKeepsFetchOrder() {
        let rows = [row(30, disc: 2, track: 9), row(31, disc: 1, track: 1)]
        XCTAssertEqual(firstPlayablePosition(rows), 30)
    }

    func testFirstPlayableNilWhenNonePlayable() {
        XCTAssertNil(firstPlayablePosition([row(40, cloud: "prerelease")]))
        XCTAssertNil(firstPlayablePosition([]))
    }
}

import XCTest
@testable import music

final class TitleArtistPairsTests: XCTestCase {

    func testPairsAlternatingItems() {
        XCTAssertEqual(titleArtistPairs(["Song", "Band", "Song2", "Band2"]),
                       [TitleArtist(title: "Song", artist: "Band"),
                        TitleArtist(title: "Song2", artist: "Band2")])
    }

    func testRejectsAnOddNumberOfItems() {
        XCTAssertNil(titleArtistPairs(["Song", "Band", "Orphan"]))
    }

    func testRejectsTooFewItems() {
        XCTAssertNil(titleArtistPairs([]))
        XCTAssertNil(titleArtistPairs(["Song"]))
    }
}

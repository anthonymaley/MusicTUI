import XCTest
@testable import music

final class DiscoverSeedParseTests: XCTestCase {
    func testParsesNameAndArtist() {
        let raw = "Andromeda\u{1F}Gorillaz"
        let seed = parseSeedTrack(raw)
        XCTAssertEqual(seed?.name, "Andromeda")
        XCTAssertEqual(seed?.artist, "Gorillaz")
    }

    /// The bug: "|" was the delimiter, so a pipe in the title split the seed
    /// at the wrong place and the discover search ran on garbage terms.
    func testPipeInTitleStaysInName() {
        let raw = "Intro | Outro\u{1F}AC|DC"
        let seed = parseSeedTrack(raw)
        XCTAssertEqual(seed?.name, "Intro | Outro")
        XCTAssertEqual(seed?.artist, "AC|DC")
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(parseSeedTrack("no separator here"))
        XCTAssertNil(parseSeedTrack(""))
    }
}

import XCTest
@testable import music

final class NowParseTests: XCTestCase {
    func testStopped() {
        XCTAssertEqual(parseNowOutput("STOPPED"), .stopped)
    }

    func testLoading() {
        XCTAssertEqual(parseNowOutput("LOADING"), .loading)
    }

    func testNormalTrack() {
        let raw = "Andromeda|Gorillaz|Humanz|198|12|playing|0|Kitchen:56,Office:40"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Andromeda")
        XCTAssertEqual(i.artist, "Gorillaz")
        XCTAssertEqual(i.album, "Humanz")
        XCTAssertEqual(i.duration, 198)
        XCTAssertEqual(i.position, 12)
        XCTAssertEqual(i.state, "playing")
        XCTAssertFalse(i.isLive)
        XCTAssertEqual(i.speakers, [NowSpeaker(name: "Kitchen", volume: 56),
                                    NowSpeaker(name: "Office", volume: 40)])
    }

    /// The bug that started this: live stations have no duration. "-" means absent.
    func testLiveStationHasNoDurationOrPosition() {
        let raw = "Okayyy (feat. Doja Cat)|Latto|Big Mama|-|-|playing|1|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Okayyy (feat. Doja Cat)")
        XCTAssertTrue(i.isLive)
        XCTAssertNil(i.duration)
        XCTAssertNil(i.position)
    }

    /// BBC Radio 1 reports the station name and an EMPTY artist.
    func testLiveStationWithEmptyArtist() {
        let raw = "BBC Radio 1|||-|-|playing|1|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "BBC Radio 1")
        XCTAssertEqual(i.artist, "")
        XCTAssertEqual(i.album, "")
        XCTAssertTrue(i.isLive)
    }

    func testNoSpeakers() {
        let raw = "Andromeda|Gorillaz|Humanz|198|12|playing|0|"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.speakers, [])
    }

    /// Track titles may contain "|" — only the first 7 separators are structural.
    func testPipeInTrackTitleDoesNotBreakSpeakers() {
        let raw = "A|B|C|10|1|playing|0|Kitchen:56"
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.speakers, [NowSpeaker(name: "Kitchen", volume: 56)])
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(parseNowOutput("nonsense"))
        XCTAssertNil(parseNowOutput(""))
    }
}

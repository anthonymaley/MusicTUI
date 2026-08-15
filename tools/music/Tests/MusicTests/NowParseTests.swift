import XCTest
@testable import music

final class NowParseTests: XCTestCase {
    /// Payloads are asFieldSep-joined, mirroring what the AppleScript emits.
    private func payload(_ fields: [String]) -> String {
        fields.joined(separator: String(asFieldSep))
    }

    func testStopped() {
        XCTAssertEqual(parseNowOutput("STOPPED"), .stopped)
    }

    func testLoading() {
        XCTAssertEqual(parseNowOutput("LOADING"), .loading)
    }

    func testNormalTrack() {
        let raw = payload(["Andromeda", "Gorillaz", "Humanz", "198", "12", "playing", "0", "Kitchen:56,Office:40"])
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
        let raw = payload(["Okayyy (feat. Doja Cat)", "Latto", "Big Mama", "-", "-", "playing", "1", "Kitchen:56"])
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Okayyy (feat. Doja Cat)")
        XCTAssertTrue(i.isLive)
        XCTAssertNil(i.duration)
        XCTAssertNil(i.position)
    }

    /// BBC Radio 1 reports the station name and an EMPTY artist.
    func testLiveStationWithEmptyArtist() {
        let raw = payload(["BBC Radio 1", "", "", "-", "-", "playing", "1", "Kitchen:56"])
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "BBC Radio 1")
        XCTAssertEqual(i.artist, "")
        XCTAssertEqual(i.album, "")
        XCTAssertTrue(i.isLive)
    }

    func testNoSpeakers() {
        let raw = payload(["Andromeda", "Gorillaz", "Humanz", "198", "12", "playing", "0", ""])
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.speakers, [])
    }

    /// Track titles may legally contain "|" ("Intro | Outro"). The payload is
    /// delimited by asFieldSep (ASCII 31), which cannot appear in real names,
    /// so a pipe anywhere in a field must not shift the fields after it.
    func testPipeInsideFieldsDoesNotShiftFields() {
        let fs = String(asFieldSep)
        let raw = ["Intro | Outro", "AC|DC", "Back in Black", "198", "12", "playing", "0", "Kitchen:56"]
            .joined(separator: fs)
        guard case .info(let i)? = parseNowOutput(raw) else { return XCTFail("expected .info") }
        XCTAssertEqual(i.track, "Intro | Outro")
        XCTAssertEqual(i.artist, "AC|DC")
        XCTAssertEqual(i.album, "Back in Black")
        XCTAssertEqual(i.duration, 198)
        XCTAssertEqual(i.state, "playing")
        XCTAssertEqual(i.speakers, [NowSpeaker(name: "Kitchen", volume: 56)])
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(parseNowOutput("nonsense"))
        XCTAssertNil(parseNowOutput(""))
    }
}

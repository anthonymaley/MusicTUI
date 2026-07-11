import XCTest
@testable import music

final class SpeakerParserTests: XCTestCase {
    func testBareNameAdds() {
        let result = SpeakerParser.parse(["kitchen"])
        XCTAssertEqual(result, .add(name: "kitchen"))
    }

    func testNameWithVolumeAddsAndSetsVolume() {
        let result = SpeakerParser.parse(["kitchen", "40"])
        XCTAssertEqual(result, .addWithVolume(name: "kitchen", volume: 40))
    }

    func testNameWithStopRemoves() {
        let result = SpeakerParser.parse(["kitchen", "stop"])
        XCTAssertEqual(result, .remove(name: "kitchen"))
    }

    func testNameWithOnlyExclusiveSelects() {
        let result = SpeakerParser.parse(["airpods", "only"])
        XCTAssertEqual(result, .exclusive(name: "airpods"))
    }

    func testAllIntegersAreIndices() {
        let result = SpeakerParser.parse(["1", "2", "5"])
        XCTAssertEqual(result, .indices([1, 2, 5]))
    }

    func testMultiWordSpeakerName() {
        let result = SpeakerParser.parse(["anthony's", "macbook", "pro"])
        XCTAssertEqual(result, .add(name: "anthony's macbook pro"))
    }

    func testMultiWordNameWithVolume() {
        let result = SpeakerParser.parse(["macbook", "pro", "50"])
        XCTAssertEqual(result, .addWithVolume(name: "macbook pro", volume: 50))
    }

    func testEmptyArgsIsInteractive() {
        let result = SpeakerParser.parse([])
        XCTAssertEqual(result, .interactive)
    }

    func testListKeyword() {
        let result = SpeakerParser.parse(["list"])
        XCTAssertEqual(result, .list)
    }

    func testWakeAllSpeakers() {
        let result = SpeakerParser.parse(["wake"])
        XCTAssertEqual(result, .wake(name: nil))
    }

    func testWakeSpecificSpeaker() {
        let result = SpeakerParser.parse(["wake", "kitchen"])
        XCTAssertEqual(result, .wake(name: "kitchen"))
    }

    func testWakeMultiWordSpeaker() {
        let result = SpeakerParser.parse(["wake", "macbook", "pro"])
        XCTAssertEqual(result, .wake(name: "macbook pro"))
    }

    func testVerifyKeywordParsesBare() {
        XCTAssertEqual(SpeakerParser.parse(["verify"]), .verify(name: nil))
    }

    func testVerifyKeywordParsesWithName() {
        XCTAssertEqual(SpeakerParser.parse(["verify", "Living", "Room"]), .verify(name: "Living Room"))
    }
}

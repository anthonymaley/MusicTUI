import XCTest
@testable import music

final class HistoryAuthMessageTests: XCTestCase {
    func testPlainMessageNamesTheReasonAndTheFix() {
        let message = recentNeedsAuthMessage(json: false)
        XCTAssertTrue(message.contains("account level"))
        XCTAssertTrue(message.contains("Recently Played"))
        XCTAssertTrue(message.contains("this Mac only"))
        XCTAssertTrue(message.contains("zero overlapping rows"))
        XCTAssertTrue(message.contains("music auth setup"))
        XCTAssertFalse(message.contains("\u{2014}"), "message must be dash-free (em dash)")
        XCTAssertFalse(message.contains("\u{2013}"), "message must be dash-free (en dash)")
    }

    func testJSONMessageIsAnObjectWithEmptyRecentAndAnError() throws {
        let json = recentNeedsAuthMessage(json: true)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recent = try XCTUnwrap(obj["recent"] as? [Any])
        XCTAssertTrue(recent.isEmpty)
        let error = try XCTUnwrap(obj["error"] as? String)
        XCTAssertTrue(error.contains("music auth setup"))
    }
}

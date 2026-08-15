import XCTest
@testable import music

final class LoveJSONTests: XCTestCase {
    private func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// The bug: the hand-rolled JSON escaped only double quotes, so a literal
    /// backslash (or control char) in a title emitted invalid JSON per RFC 8259.
    func testBackslashInTitleStaysValidJSON() {
        let out = loveResultJSON(favorited: true, track: #"AC\DC Live"#)
        let obj = parse(out)
        XCTAssertNotNil(obj, "output must parse as strict JSON: \(out)")
        XCTAssertEqual(obj?["track"] as? String, #"AC\DC Live"#)
        XCTAssertEqual(obj?["favorited"] as? Bool, true)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
    }

    func testQuoteAndNewlineInTitleStayValidJSON() {
        let title = "Say \"Hello\"\nGoodbye"
        let obj = parse(loveResultJSON(favorited: false, track: title))
        XCTAssertEqual(obj?["track"] as? String, title)
        XCTAssertEqual(obj?["favorited"] as? Bool, false)
    }
}

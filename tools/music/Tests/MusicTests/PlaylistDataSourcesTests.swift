import XCTest
@testable import music

final class PlaylistDataSourcesTests: XCTestCase {
    func testParseMetaLine() {
        // "idx|count|durationSeconds|smart|specialKind"
        let parsed = parsePlaylistMetaLine("3|42|9000.0|true|none")
        XCTAssertEqual(parsed?.index, 3)
        XCTAssertEqual(parsed?.count, 42)
        XCTAssertEqual(parsed?.durationSec, 9000)
        XCTAssertEqual(parsed?.isSmart, true)
        XCTAssertEqual(parsed?.specialKind, "none")
    }
    func testParseMetaLineRejectsMalformed() {
        XCTAssertNil(parsePlaylistMetaLine("garbage"))
        XCTAssertNil(parsePlaylistMetaLine("x|1|2|true|none"))   // non-int index
    }
    func testParseTracksResultSplitsCountAndLines() {
        let r = parsePlaylistTracksResult("57|Song A — Artist A\nSong B — Artist B")
        XCTAssertEqual(r.count, 57)
        XCTAssertEqual(r.lines, ["Song A — Artist A", "Song B — Artist B"])
    }
    func testParseTracksResultEmptyBody() {
        let r = parsePlaylistTracksResult("0|")
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.lines, [])
    }
}

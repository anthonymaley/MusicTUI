import XCTest
@testable import music

/// `music add --to <playlist>` with no query reads the current track over
/// AppleScript and adds THAT. The old code parsed the two-field payload with
/// `if parts.count >= 2 { ... }` and no else: on a malformed read both fields
/// stayed nil, every downstream branch was skipped, and the command exited 0
/// having printed nothing and added nothing. A silent success on a failure.
final class CurrentTrackFieldsTests: XCTestCase {

    private let fs = String(asFieldSep)

    func testParsesTitleAndArtist() {
        let parsed = parseCurrentTrackFields("Only Love\(fs)Saint Etienne")
        XCTAssertEqual(parsed?.title, "Only Love")
        XCTAssertEqual(parsed?.artist, "Saint Etienne")
    }

    func testTrimsSurroundingWhitespaceFromTheScriptOutput() {
        let parsed = parseCurrentTrackFields("\n  Afterlife\(fs)Ron Trent  \n")
        XCTAssertEqual(parsed?.title, "Afterlife")
        XCTAssertEqual(parsed?.artist, "Ron Trent")
    }

    /// The cases that used to exit 0 in silence. Each must now be refusable by
    /// the caller, which is what returning nil buys.
    func testRefusesAMalformedRead() {
        XCTAssertNil(parseCurrentTrackFields(""), "empty output")
        XCTAssertNil(parseCurrentTrackFields("   \n "), "whitespace only")
        XCTAssertNil(parseCurrentTrackFields("Just A Title"), "no separator: one field")
        XCTAssertNil(parseCurrentTrackFields("Title\(fs)"), "separator but no artist")
        XCTAssertNil(parseCurrentTrackFields("\(fs)Artist Only"), "separator but no title")
    }

    /// A title legitimately containing the separator is impossible (ASCII 31
    /// cannot appear in a real name, which is why it replaced `|`), but extra
    /// fields must not break the read of the first two.
    func testExtraFieldsAreIgnoredRatherThanRejected() {
        let parsed = parseCurrentTrackFields("T\(fs)A\(fs)Album")
        XCTAssertEqual(parsed?.title, "T")
        XCTAssertEqual(parsed?.artist, "A")
    }
}

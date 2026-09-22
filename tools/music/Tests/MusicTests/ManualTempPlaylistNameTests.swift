import XCTest
@testable import music

/// `__temp__` names collided within a second: both creators named by
/// `Int(Date().timeIntervalSince1970)`, so two invocations in the same second
/// produced one name and cleaning up either took both.
final class ManualTempPlaylistNameTests: XCTestCase {

    func testTwoNamesInTheSameSecondDiffer() {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let a = manualTempPlaylistName(now: now)
        let b = manualTempPlaylistName(now: now)
        XCTAssertNotEqual(a, b, "two containers made in one second must not share a name")
    }

    /// The second stays first and readable: it is what a person scanning the
    /// Music.app sidebar reads, and the cleanup paths match on the prefix.
    func testTheNameKeepsItsPrefixAndTimestamp() {
        let name = manualTempPlaylistName(now: Date(timeIntervalSince1970: 1_758_000_000),
                                          uuid: "ABCDEF01-2345-6789-ABCD-EF0123456789")
        XCTAssertEqual(name, "__temp__1758000000-abcdef01")
        XCTAssertTrue(name.hasPrefix(manualTempPlaylistPrefix))
    }

    /// Now Playing's label and the cleanup prefix lists are prefix-based, so the
    /// tail changes nothing they depend on.
    func testTheStableLabelAndSweepStillRecogniseIt() {
        let name = manualTempPlaylistName()
        XCTAssertEqual(cleanContextName(name), temporaryPlaylistLabel)
        XCTAssertTrue(tempPlaylistPrefixes.contains { name.hasPrefix($0) })
    }
}

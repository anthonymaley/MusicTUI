import XCTest
@testable import music

final class LibraryLookupScriptTests: XCTestCase {

    func testIncludesTheArtistClauseWhenAnArtistIsGiven() {
        let s = libraryTrackLookupScript(title: "Song", artist: "Band")
        XCTAssertTrue(s.contains("artist is \"Band\""), s)
        XCTAssertTrue(s.contains("artist contains \"Band\""), s)
    }

    /// Music.app's AppleScript treats `contains ""` as FALSE, not true, so an
    /// empty artist clause matches nothing and the whole lookup fails even when
    /// the title is an exact hit. Measured on a live library: title-only
    /// matched 1, both empty-artist variants matched 0.
    func testOmitsTheArtistClauseEntirelyWhenNoArtistIsGiven() {
        let s = libraryTrackLookupScript(title: "Song", artist: "")
        XCTAssertFalse(s.contains("artist"), "empty artist must not appear as a clause:\n\(s)")
        XCTAssertTrue(s.contains("name is \"Song\""), s)
        XCTAssertTrue(s.contains("name contains \"Song\""), s)
    }
}

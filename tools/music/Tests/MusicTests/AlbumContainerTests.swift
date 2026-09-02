import XCTest
@testable import music

final class AlbumContainerTests: XCTestCase {

    func testNameCarriesPrefixUUIDAndTitle() {
        let name = albumContainerName(title: "Moon Safari", uuid: "ABC-123")
        XCTAssertEqual(name, "__album__ ABC-123 — Moon Safari")
    }

    /// The timestamp scheme used by the two existing `__temp__` creators
    /// collides for two invocations inside one second. A uuid cannot.
    func testTwoNamesInTheSameSecondDiffer() {
        let a = albumContainerName(title: "Moon Safari", uuid: UUID().uuidString)
        let b = albumContainerName(title: "Moon Safari", uuid: UUID().uuidString)
        XCTAssertNotEqual(a, b)
    }

    func testAlbumPrefixIsHiddenFromTheRail() {
        XCTAssertTrue(isTempPlaylistName(albumContainerName(title: "X", uuid: "U")))
    }

    func testCleanContextNameStripsPrefixAndUUID() {
        let name = albumContainerName(title: "Moon Safari", uuid: "ABC-123")
        XCTAssertEqual(cleanContextName(name), "Moon Safari")
    }

    /// A title containing the separator survives: only the FIRST separator
    /// delimits the uuid.
    func testTitleContainingTheSeparatorSurvives() {
        let name = albumContainerName(title: "Songs — Vol 2", uuid: "U")
        XCTAssertEqual(cleanContextName(name), "Songs — Vol 2")
    }

    /// The narrow parsing rule. A user playlist that merely looks uuid-ish must
    /// never be rewritten.
    func testUserPlaylistNamesAreUntouched() {
        XCTAssertEqual(cleanContextName("ABC-123 — My Mix"), "ABC-123 — My Mix")
        XCTAssertEqual(cleanContextName("House"), "House")
        XCTAssertEqual(cleanContextName("__album__x no space prefix"),
                       "__album__x no space prefix")
    }

    /// §17.4: `parseWatcherObservation` trims every field it reads back from
    /// AppleScript, so `name of current playlist` comes back trimmed. A
    /// container built from an UNTRIMMED title (e.g. a user typo,
    /// `--album "Moon Safari "`) would never equal what the watcher observes,
    /// so it would never arm and would always exit on the arm timeout without
    /// deleting — a deterministic, silent leak. Trimming the title here, at
    /// the one place the name is built, closes it.
    func testTitleWhitespaceIsTrimmedFromTheContainerName() {
        XCTAssertEqual(albumContainerName(title: "  Moon Safari  ", uuid: "ABC-123"),
                       "__album__ ABC-123 — Moon Safari")
        XCTAssertEqual(albumContainerName(title: "\tMoon Safari\n", uuid: "ABC-123"),
                       "__album__ ABC-123 — Moon Safari")
    }

    func testDiscoverFormStillWorks() {
        let name = discoverPlaylistPrefix + "U-1" + discoverPlaylistNameSeparator + "Rail Pick"
        XCTAssertEqual(cleanContextName(name), "Rail Pick")
    }
}

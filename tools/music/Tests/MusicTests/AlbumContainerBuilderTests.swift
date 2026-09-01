import XCTest
@testable import music

final class AlbumContainerBuilderTests: XCTestCase {

    private let containerName = "__album__ U — Moon Safari"

    // MARK: - Script shape

    func testBuildScriptCreatesThenDuplicatesEachIndexInOneScript() {
        let s = albumContainerBuildScript(name: containerName, indices: [3, 7, 11])
        XCTAssertTrue(s.contains("make new playlist"))
        XCTAssertTrue(s.contains("duplicate track 3 of playlist \"Library\""))
        XCTAssertTrue(s.contains("duplicate track 7 of playlist \"Library\""))
        XCTAssertTrue(s.contains("duplicate track 11 of playlist \"Library\""))
        XCTAssertTrue(s.contains("count of tracks"))
    }

    func testBuildScriptEscapesTheName() {
        let s = albumContainerBuildScript(name: "__album__ U — He said \"hi\"", indices: [1])
        XCTAssertTrue(s.contains("\\\"hi\\\""))
    }

    func testIDsScriptUsesTheFieldSeparatorNotAPipe() {
        let s = containerTrackIDsScript(name: containerName)
        XCTAssertTrue(s.contains("ASCII character 31"))
        XCTAssertFalse(s.contains("\"|\""))
        XCTAssertTrue(s.contains("persistent ID of every track"))
    }

    func testParseIDs() {
        let raw = "AAA\u{1F}BBB\u{1F}CCC"
        XCTAssertEqual(parseContainerTrackIDs(raw), ["AAA", "BBB", "CCC"])
    }

    func testParseIDsIgnoresBlanksAndWhitespace() {
        XCTAssertEqual(parseContainerTrackIDs("  AAA\u{1F}\u{1F}BBB \n"), ["AAA", "BBB"])
    }

    func testParseEmptyIsEmpty() {
        XCTAssertEqual(parseContainerTrackIDs("   "), [])
    }

    // MARK: - Transactional behaviour

    func testSeededCountEqualToRequestedSucceeds() {
        var calls: [String] = []
        let result = buildAlbumContainer(name: containerName, indices: [1, 2, 3]) { script in
            calls.append(script)
            return "3"
        }
        XCTAssertEqual(result, .built)
        XCTAssertEqual(calls.count, 1, "build must be ONE script, not one per track")
    }

    /// A short seed is a failure, not a partial success. Roll back exactly.
    func testCountMismatchRollsBackWithExactNameDelete() {
        var scripts: [String] = []
        let result = buildAlbumContainer(name: containerName, indices: [1, 2, 3]) { script in
            scripts.append(script)
            return script.contains("make new playlist") ? "2" : ""
        }
        XCTAssertEqual(result, .seedMismatch(expected: 3, got: 2))
        XCTAssertTrue(scripts.count == 2, "must issue the rollback delete")
        XCTAssertTrue(scripts[1].contains("every user playlist whose name is"))
        XCTAssertTrue(scripts[1].contains("Moon Safari"))
    }

    func testRunnerFailureRollsBack() {
        var scripts: [String] = []
        let result = buildAlbumContainer(name: containerName, indices: [1]) { script in
            scripts.append(script)
            return script.contains("make new playlist") ? nil : ""
        }
        XCTAssertEqual(result, .createFailed)
        XCTAssertTrue(scripts.count == 2, "a failed create must still attempt cleanup")
        XCTAssertTrue(scripts[1].contains("every user playlist whose name is"))
    }

    func testEmptyIndicesIsRefusedWithoutTouchingMusic() {
        var called = false
        let result = buildAlbumContainer(name: containerName, indices: []) { _ in
            called = true
            return ""
        }
        XCTAssertEqual(result, .noTracks)
        XCTAssertFalse(called)
    }
}

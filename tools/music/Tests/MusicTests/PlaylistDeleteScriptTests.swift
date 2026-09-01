import XCTest
@testable import music

/// `delete playlist "X"` by name fails with -1708 on a playlist the REST API
/// created (measured 2026-08-28); deleting by object reference works on every
/// playlist regardless of who made it. Both delete sites build their script
/// through these pure functions so the form cannot drift back.
final class PlaylistDeleteScriptTests: XCTestCase {
    func testDeleteScriptUsesObjectReferenceNotName() {
        let script = playlistDeleteScript(name: "Old Mix")
        XCTAssertEqual(script, "delete (every user playlist whose name is \"Old Mix\")")
    }

    func testDeleteScriptEscapesQuotes() {
        let script = playlistDeleteScript(name: "Say \"Hi\"")
        XCTAssertEqual(script, "delete (every user playlist whose name is \"Say \\\"Hi\\\"\")")
    }

    func testCleanupScriptDeletesByReferenceInsideTheLoop() {
        let script = playlistCleanupScript()
        XCTAssertTrue(script.contains("repeat with pp in (every user playlist)"), script)
        XCTAssertTrue(script.contains("delete pp"), script)
        XCTAssertFalse(script.contains("delete playlist p"), script)
    }
}

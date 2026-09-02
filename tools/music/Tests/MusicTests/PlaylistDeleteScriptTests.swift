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

    /// §20: snapshot, then delete. The old shape deleted `pp` from inside the
    /// SAME `repeat with pp in (every user playlist)` loop it was
    /// enumerating — mutating a live AppleScript collection mid-enumeration
    /// skips the element right after the one just deleted, and one cleanup
    /// invocation collected roughly half of N stale containers (measured
    /// live 2026-09-02). The corrected shape enumerates read-only into
    /// `eligibleNames` first, then deletes in a SEPARATE loop over that
    /// captured list, by exact name — never `delete pp` inside the
    /// enumeration loop, and never a bare `delete playlist p` name lookup
    /// either (that form failed with -1708 on a REST-created playlist).
    func testCleanupScriptSnapshotsThenDeletesByExactNameNotInsideTheEnumerationLoop() {
        let script = playlistCleanupScript()
        XCTAssertTrue(script.contains("repeat with pp in (every user playlist)"), script)
        XCTAssertFalse(script.contains("delete pp"), script)
        XCTAssertFalse(script.contains("delete playlist p"), script)
        XCTAssertTrue(script.contains("delete (every user playlist whose name is nm)"), script)

        // The enumeration loop (over the live collection) must contain no
        // delete of any kind — it only ever appends to `eligibleNames`.
        guard let enumStart = script.range(of: "repeat with pp in (every user playlist)")?.lowerBound,
              let enumEnd = script.range(of: "end repeat", range: enumStart..<script.endIndex)?.upperBound else {
            return XCTFail("expected a bounded enumeration loop")
        }
        let enumerationLoop = script[enumStart..<enumEnd]
        XCTAssertFalse(enumerationLoop.contains("delete"), "enumeration loop must never delete: \(enumerationLoop)")

        // The delete-by-name loop must come strictly AFTER the enumeration
        // loop finishes, over the captured names, not the live playlists.
        guard let deleteStart = script.range(of: "repeat with nm in eligibleNames")?.lowerBound else {
            return XCTFail("expected a second loop over the captured eligibleNames")
        }
        XCTAssertLessThan(enumEnd, deleteStart, "delete-by-name loop must start after enumeration ends")
    }
}

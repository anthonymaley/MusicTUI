import XCTest
@testable import music

/// Back out of an opened playlist: the rail cursor is still on the opened row and the
/// rail's scroll offset keeps it on screen, in the same window the person left. Read
/// off the rendered rail (which rows are drawn), not off a private offset. Fakes only:
/// a scripted wire, no AppleScript, no socket, no playback, a temporary metadata cache.
final class PlaylistsBackScrollRestoreTests: XCTestCase {

    private let frame = shellLayout(width: 138, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func id(_ n: Int) -> String { String(format: "%03d", n) }

    private func railPage(_ ids: ClosedRange<Int>) -> String {
        let rows = ids.map { "{\"id\":\"pl\(id($0))\",\"title\":\"Mix\(id($0))\",\"kind\":\"playlist\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":\(ids.count),
         "items":[\(rows)],"next_cursor":null}
        """
    }

    private let tracks = """
    {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":2,
     "items":[{"id":"t1","title":"Song One","artist":"Art","kind":"song"},
              {"id":"t2","title":"Song Two","artist":"Art","kind":"song"}],"next_cursor":null,"skipped_videos":0}
    """

    private func scene() -> PlaylistsScene {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [railPage(1...80)],
                                           "slice.libraryPlaylistTracks": [tracks, tracks, tracks]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(), width: 138)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Mix001") }, "the rail never showed")
        return s
    }

    /// The `Mix###` names the rail draws, in order of appearance.
    private func drawn(_ s: PlaylistsScene) -> [Int] {
        let out = s.render(frame: frame, snapshot: idle)
        var seen: [Int] = []
        var rest = Substring(out)
        while let r = rest.range(of: "Mix") {
            let digits = rest[r.upperBound...].prefix(3)
            if digits.count == 3, let n = Int(digits), !seen.contains(n) { seen.append(n) }
            rest = rest[r.upperBound...]
        }
        return seen
    }

    /// One key, then a paint, as the app does: the rail's scroll follows the cursor at render time.
    private func press(_ s: PlaylistsScene, _ key: KeyPress, _ n: Int = 1) {
        for _ in 0..<n { _ = s.handle(key); _ = s.render(frame: frame, snapshot: idle) }
    }

    private func openAndBack(_ s: PlaylistsScene, opened: String) {
        press(s, .enter)
        XCTAssertTrue(settleScene(s) { s.drilledTrackTitlesForTest == ["Song One", "Song Two"] }, "the tracks never opened")
        XCTAssertEqual(s.drilledPlaylistIDForTest, opened)
        press(s, .escape)
    }

    /// Back is on the rail again when Down moves the rail's cursor, not the tracks'.
    /// Moves the window, so it is asked last.
    private func assertFocusIsOnTheRail(_ s: PlaylistsScene) {
        let at = s.railCursorForTest
        press(s, .down)
        XCTAssertEqual(s.railCursorForTest, at + 1, "Back left the focus in the tracks pane")
        press(s, .up)
        XCTAssertEqual(s.railCursorForTest, at)
    }

    func testBackKeepsTheOpenedPlaylistOnScreenInTheSameWindow() {
        let s = scene()
        press(s, .down, 50)
        press(s, .up, 5)                                    // Mix046, mid-window
        XCTAssertEqual(s.railCursorForTest, 45)
        let before = drawn(s)
        XCTAssertFalse(before.contains(1), "the rail never scrolled: \(before)")
        XCTAssertTrue(before.contains(46) && before.contains(51))

        openAndBack(s, opened: "pl\(id(46))")

        XCTAssertEqual(s.railCursorForTest, 45, "Back moved the rail cursor off the opened playlist")
        XCTAssertEqual(drawn(s), before, "Back moved the rail's scroll window")
        assertFocusIsOnTheRail(s)
    }

    func testBackKeepsTheOpenedPlaylistVisibleAtBothEdgesOfTheWindow() {
        let s = scene()
        press(s, .down, 60)
        let window = drawn(s)
        let top = window.min()!, bottom = window.max()!
        while s.railCursorForTest + 1 > top { press(s, .up) }
        openAndBack(s, opened: "pl\(id(top))")
        XCTAssertEqual(s.railCursorForTest + 1, top)
        XCTAssertEqual(drawn(s), window, "the top-edge playlist's window moved after Back")

        press(s, .down, bottom - top)
        XCTAssertEqual(s.railCursorForTest + 1, bottom)
        openAndBack(s, opened: "pl\(id(bottom))")
        XCTAssertEqual(s.railCursorForTest + 1, bottom)
        XCTAssertEqual(drawn(s), window, "the bottom-edge playlist's window moved after Back")
    }
}

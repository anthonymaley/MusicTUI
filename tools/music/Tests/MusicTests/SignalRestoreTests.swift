import XCTest
@testable import music

/// Closing a terminal sends SIGHUP to the foreground process group, not SIGINT,
/// so until 2026-09-22 it killed the TUI with the terminal still in raw mode and
/// the alternate screen up. The handlers themselves cannot be exercised here —
/// installing them means entering raw mode on the suite's own stdin, and firing
/// one ends the process — so this pins the bytes they write; the behaviour was
/// checked live with `kill -HUP` and `kill -TERM`.
final class SignalRestoreTests: XCTestCase {

    /// Exactly "show the cursor" then "leave the alternate screen", in raw
    /// storage a handler may read: no Array, no Optional, nothing retained.
    func testTheRestoreSequenceIsShowCursorThenAltScreenOff() {
        let expected = Array("\u{1B}[?25h\u{1B}[?1049l".utf8)
        XCTAssertEqual(terminalRestoreBytes.count, expected.count)
        let actual = Array(UnsafeRawBufferPointer(start: terminalRestoreBytes.base,
                                                  count: terminalRestoreBytes.count))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual, Array((ANSICode.showCursor + ANSICode.altScreenOff).utf8))
    }

    /// Nothing entered raw mode here, so the handler would restore nothing —
    /// the flag, not a nil check, is what tells it so.
    func testTheRestoreIsDisarmedOutsideRawMode() {
        XCTAssertEqual(terminalRestoreArmed, 0)
    }
}

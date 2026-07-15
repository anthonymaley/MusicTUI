// tools/music/Tests/MusicTests/TUILayoutTests.swift
import XCTest
@testable import music

final class TUILayoutTests: XCTestCase {

    // MARK: - terminalCellSize

    // The user's actual terminal, measured via TIOCGWINSZ: 214x48 cells,
    // 2996x1632 px -> cell 14.00w x 34.00h (ratio 1:2.429, not the assumed 1:2).
    func testMeasuredCellSizeFromRealTerminalReport() {
        let (w, h) = terminalCellSize(cols: 214, rows: 48, xpixel: 2996, ypixel: 1632)
        XCTAssertEqual(w, 14.0, accuracy: 0.01)
        XCTAssertEqual(h, 34.0, accuracy: 0.01)
    }

    func testZeroXPixelFallsBackToOneByTwo() {
        let (w, h) = terminalCellSize(cols: 214, rows: 48, xpixel: 0, ypixel: 1632)
        XCTAssertEqual(w, 1.0)
        XCTAssertEqual(h, 2.0)
    }

    func testZeroYPixelFallsBackToOneByTwo() {
        let (w, h) = terminalCellSize(cols: 214, rows: 48, xpixel: 2996, ypixel: 0)
        XCTAssertEqual(w, 1.0)
        XCTAssertEqual(h, 2.0)
    }

    func testBothPixelsZeroFallsBackToOneByTwo() {
        let (w, h) = terminalCellSize(cols: 214, rows: 48, xpixel: 0, ypixel: 0)
        XCTAssertEqual(w, 1.0)
        XCTAssertEqual(h, 2.0)
    }

    func testZeroColsOrRowsFallsBackToOneByTwo() {
        XCTAssertEqual(terminalCellSize(cols: 0, rows: 48, xpixel: 2996, ypixel: 1632).w, 1.0)
        XCTAssertEqual(terminalCellSize(cols: 214, rows: 0, xpixel: 2996, ypixel: 1632).h, 2.0)
    }

    func testNegativeInputsFallBackToOneByTwo() {
        let (w, h) = terminalCellSize(cols: -1, rows: -1, xpixel: -1, ypixel: -1)
        XCTAssertEqual(w, 1.0)
        XCTAssertEqual(h, 2.0)
    }
}

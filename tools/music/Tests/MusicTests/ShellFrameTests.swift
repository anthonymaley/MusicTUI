// tools/music/Tests/MusicTests/ShellFrameTests.swift
import XCTest
@testable import music

final class ShellFrameTests: XCTestCase {
    // The persistent now-playing bar was removed, so barHeight is always 0 and
    // the body extends down to just above the footer. Height still drives tabs.
    func testFullTier() {
        let f = shellLayout(width: 120, height: 40)
        XCTAssertEqual(f.barTier, .full)
        XCTAssertEqual(f.barHeight, 0)
        XCTAssertEqual(f.tabStyle, .full)
        XCTAssertEqual(f.footerY, 40)
        XCTAssertEqual(f.barY, 40)                       // footerY - barHeight(0)
        XCTAssertEqual(f.bodyY, 4)                       // label(1) tabs(2) rule(3) body(4)
        XCTAssertEqual(f.bodyHeight, f.footerY - f.bodyY) // 36 — reclaims the old bar band
        XCTAssertGreaterThan(f.bodyHeight, 0)
    }

    func testMidHeightKeepsFullTabs() {
        let f = shellLayout(width: 120, height: 21)
        XCTAssertEqual(f.barTier, .full)
        XCTAssertEqual(f.barHeight, 0)
        XCTAssertEqual(f.tabStyle, .full)
    }

    func testMinimalTierUsesDigitTabs() {
        let f = shellLayout(width: 120, height: 16)
        XCTAssertEqual(f.barTier, .minimal)
        XCTAssertEqual(f.barHeight, 0)
        XCTAssertEqual(f.tabStyle, .digits)
    }

    func testBareTierHidesTabs() {
        let f = shellLayout(width: 120, height: 12)
        XCTAssertEqual(f.barTier, .bare)
        XCTAssertEqual(f.barHeight, 0)
        XCTAssertEqual(f.tabStyle, .hidden)
        XCTAssertEqual(f.bodyY, 3)                        // label(1) rule(2) body(3) — no tab row
    }

    func testBodyHeightNeverNegative() {
        for h in 1...50 {
            XCTAssertGreaterThanOrEqual(shellLayout(width: 80, height: h).bodyHeight, 0)
        }
    }
}

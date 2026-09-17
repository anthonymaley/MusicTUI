// tools/music/Tests/MusicTests/OutputTabTests.swift
//
// The Output tab's row model. Source Mode v1 section 4: Speakers becomes Output,
// gains the playback-mode selection and catalogue-access status, and loses EQ
// and Visualizer.
import XCTest
@testable import music

final class OutputTabTests: XCTestCase {

    /// Section 4. Mode first, because it is the only control that changes
    /// routing; catalogue access is status beneath it; AirPlay last.
    func testModeComesFirstAndAirPlayLast() {
        let rows = outputDisplayRows(speakerCount: 2, mode: .musicApp, sourceReady: .ready)
        XCTAssertEqual(rows.first, .modeHeader)
        XCTAssertEqual(rows[1], .mode(.musicApp))
        XCTAssertEqual(rows[2], .mode(.source))
        XCTAssertTrue(rows.contains(.catalogHeader))
        XCTAssertEqual(rows.last, .speaker(1))
    }

    /// EQ and Visualizer leave the TUI with their polling. Anthony judged them
    /// Music.app-specific and not useful for TUI use; the CLI verbs remain.
    func testEQAndVisualizerAreGone() {
        let rows = outputDisplayRows(speakerCount: 1, mode: .musicApp, sourceReady: .ready)
        for row in rows {
            switch row {
            case .modeHeader, .mode, .catalogHeader, .catalogStatus, .airplayHeader, .speaker:
                continue
            }
        }
        XCTAssertFalse(rows.isEmpty)
    }

    /// Binding rule: AirPlay applies in Music.app mode only. The rows are still
    /// LISTED in Source Mode, because hiding the user's speakers would be a
    /// worse answer than showing them inert with a reason.
    func testAirPlayRowsAreListedInBothModesButOnlyActInMusicApp() {
        let inMusicApp = outputDisplayRows(speakerCount: 3, mode: .musicApp, sourceReady: .ready)
        let inSource = outputDisplayRows(speakerCount: 3, mode: .source, sourceReady: .ready)
        XCTAssertEqual(inMusicApp.filter { if case .speaker = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(inSource.filter { if case .speaker = $0 { return true }; return false }.count, 3)
        XCTAssertFalse(airPlayActs(in: .source))
        XCTAssertTrue(airPlayActs(in: .musicApp))
    }

    /// Ruling 12.13 collapsed four states to two. The property that survives is
    /// the one that mattered: only a Bridge that can actually serve is
    /// selectable, and every refusal says WHY.
    func testOnlyAReadyBridgeIsSelectableAndEveryRefusalSaysWhy() {
        XCTAssertTrue(SourceReadiness.ready.canSelect)
        XCTAssertEqual(SourceReadiness.ready.label, "ready")

        let reasons = ["Bridge is not running",
                       "Bridge was denied Apple Music access",
                       "Apple Music access is restricted on this Mac",
                       "Bridge speaks a different version (2); update one of them"]
        for reason in reasons {
            let state = SourceReadiness.unavailable(reason)
            XCTAssertFalse(state.canSelect, "\(reason) must not be selectable")
            XCTAssertEqual(state.label, reason, "the Output tab must show the reason itself")
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    /// Codex I5: require the incoming source to be READY before the switch
    /// begins, so a failed selection cannot interrupt working playback.
    func testANonReadySourceCannotBeSelected() {
        XCTAssertFalse(outputModeSelectable(.source, readiness: .notRunning))
        XCTAssertTrue(outputModeSelectable(.source, readiness: .ready))
        // Music.app is always selectable: it needs nothing to be reachable.
        XCTAssertTrue(outputModeSelectable(.musicApp, readiness: .notRunning))
    }
}

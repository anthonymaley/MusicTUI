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

    /// Codex M2: connected is not ready. Four states, so a person can tell a
    /// source that is merely reachable from one that can actually serve.
    func testReadinessHasFourDistinctStates() {
        let all: [SourceReadiness] = [.disconnected, .unauthorized, .incompatible, .ready]
        XCTAssertEqual(Set(all.map(\.label)).count, 4, "each state must read differently")
        XCTAssertTrue(SourceReadiness.ready.canSelect)
        XCTAssertFalse(SourceReadiness.disconnected.canSelect)
        XCTAssertFalse(SourceReadiness.unauthorized.canSelect)
        XCTAssertFalse(SourceReadiness.incompatible.canSelect)
    }

    /// Codex I5: require the incoming source to be READY before the switch
    /// begins, so a failed selection cannot interrupt working playback.
    func testANonReadySourceCannotBeSelected() {
        for state: SourceReadiness in [.disconnected, .unauthorized, .incompatible] {
            XCTAssertFalse(outputModeSelectable(.source, readiness: state),
                           "\(state.label) must not be selectable")
        }
        XCTAssertTrue(outputModeSelectable(.source, readiness: .ready))
        // Music.app is always selectable: it needs nothing to be reachable.
        XCTAssertTrue(outputModeSelectable(.musicApp, readiness: .disconnected))
    }
}

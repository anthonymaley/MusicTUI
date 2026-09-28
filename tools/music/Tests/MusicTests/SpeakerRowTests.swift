// tools/music/Tests/MusicTests/SpeakerRowTests.swift
import XCTest
@testable import music

final class SpeakerRowTests: XCTestCase {
    func testMapsDeviceDicts() {
        let devices: [[String: Any]] = [
            ["name": "Kitchen", "selected": true, "volume": 58, "kind": "AirPlay"],
            ["name": "Office", "selected": false, "volume": 30, "kind": "AirPlay"],
        ]
        let rows = speakerRows(from: devices)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Kitchen")
        XCTAssertTrue(rows[0].active)
        XCTAssertEqual(rows[0].volume, 58)
        XCTAssertFalse(rows[1].active)
        XCTAssertEqual(rows[1].volume, 30)
    }
    func testSkipsMalformedEntries() {
        let devices: [[String: Any]] = [
            ["name": "Good", "selected": true, "volume": 50, "kind": "AirPlay"],
            ["selected": true, "volume": 50],            // missing name
            ["name": "NoVol", "selected": false],         // missing volume
        ]
        let rows = speakerRows(from: devices)
        XCTAssertEqual(rows.map { $0.name }, ["Good"])
    }

    func testDisplayRowsCollapsed() {
        let rows = outputTabRows(speakerCount: 2, expanded: false,
                                 presetNames: ["Nightclub", "Manual"])
        XCTAssertEqual(rows, [.spandacMac, .speaker(0), .speaker(1), .eqPower, .eq, .visualizer])
    }

    func testDisplayRowsExpanded() {
        let rows = outputTabRows(speakerCount: 1, expanded: true,
                                 presetNames: ["Nightclub", "Manual"])
        XCTAssertEqual(rows, [.spandacMac, .speaker(0), .eqPower, .eq,
                              .preset("Nightclub"), .preset("Manual"), .visualizer])
    }

    /// Where sound goes is chosen first. There is no separate mode row any
    /// more: the SPANDAC section leads, this Mac as row 1 and the network
    /// SpanDACs after it by sourceID, in the order given; Music.app's
    /// speakers follow, or a stand-in Music.app row when there are none.
    func testOutputModeRowsComeFirst() {
        let rows = outputTabRows(speakerCount: 2, expanded: false,
                                 presetNames: ["Nightclub"], spandacIDs: ["B", "A"])
        XCTAssertEqual(Array(rows.prefix(3)), [.spandacMac, .spandac("B"), .spandac("A")])
        XCTAssertEqual(rows.dropFirst(3).first, .speaker(0))
        XCTAssertFalse(rows.contains(.musicApp), "the stand-in appears only with no speakers")
        XCTAssertEqual(outputTabRows(speakerCount: 0, expanded: false, presetNames: []),
                       [.spandacMac, .musicApp, .eqPower, .eq, .visualizer])
    }

    /// Before the switch to SpanDAC data, network SpanDACs are drawn but are
    /// not rows (Enter never reaches them), and with no SpanDAC on this Mac
    /// its row goes too. "Stop using SpanDAC for music data" ends the SPANDAC
    /// section, or leads the whole tab when it is the way out of trouble.
    func testRowsBeforeTheSwitchAndTheStopUsingRow() {
        XCTAssertEqual(outputTabRows(speakerCount: 1, expanded: false, presetNames: [], spandacIDs: ["A"],
                                     stopUsing: .endOfSection),
                       [.spandacMac, .spandac("A"), .stopUsingSpanDAC, .speaker(0), .eqPower, .eq, .visualizer])
        XCTAssertEqual(outputTabRows(speakerCount: 1, expanded: false, presetNames: [], spandacIDs: ["A"],
                                     stopUsing: .top),
                       [.stopUsingSpanDAC, .spandacMac, .spandac("A"), .speaker(0), .eqPower, .eq, .visualizer])
        XCTAssertEqual(outputTabRows(speakerCount: 0, expanded: false, presetNames: [], spandacIDs: [],
                                     macRow: false),
                       [.musicApp, .eqPower, .eq, .visualizer])
    }
}

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
        let rows = speakersDisplayRows(speakerCount: 2, expanded: false,
                                       presetNames: ["Nightclub", "Manual"],
                                       showModes: false)
        XCTAssertEqual(rows, [.speaker(0), .speaker(1), .eqPower, .eq, .visualizer])
    }

    func testDisplayRowsExpanded() {
        let rows = speakersDisplayRows(speakerCount: 1, expanded: true,
                                       presetNames: ["Nightclub", "Manual"],
                                       showModes: false)
        XCTAssertEqual(rows, [.speaker(0), .eqPower, .eq,
                              .preset("Nightclub"), .preset("Manual"), .visualizer])
    }

    /// Ruling 12.4: mode selection lives on Output, ABOVE the speakers, because
    /// it is the only control that changes where audio goes.
    func testOutputModeRowsComeFirst() {
        let rows = speakersDisplayRows(speakerCount: 2, expanded: false,
                                       presetNames: ["Nightclub"])
        XCTAssertEqual(Array(rows.prefix(2)), [.mode(.musicApp), .mode(.source)])
        XCTAssertEqual(rows.dropFirst(2).first, .speaker(0))
    }
}

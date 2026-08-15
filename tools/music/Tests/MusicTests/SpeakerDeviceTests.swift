// tools/music/Tests/MusicTests/SpeakerDeviceTests.swift
import XCTest
@testable import music

final class SpeakerDeviceTests: XCTestCase {
    // MARK: - Bulk fetch block parsing

    func testParsesFourBlocksIntoDevices() {
        let raw = """
        MacBook
        Kitchen, Left
        =====
        true
        false
        =====
        58
        60
        =====
        computer
        HomePod
        """
        let devices = parseSpeakerDeviceBlocks(raw)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0]["name"] as? String, "MacBook")
        XCTAssertEqual(devices[0]["selected"] as? Bool, true)
        XCTAssertEqual(devices[0]["volume"] as? Int, 58)
        XCTAssertEqual(devices[0]["kind"] as? String, "computer")
        // A comma in a device name must survive (the old comma-split parse broke here).
        XCTAssertEqual(devices[1]["name"] as? String, "Kitchen, Left")
        XCTAssertEqual(devices[1]["selected"] as? Bool, false)
    }

    func testMismatchedBlockLengthsYieldNothing() {
        let raw = "A\nB\n=====\ntrue\n=====\n50\n40\n=====\nHomePod\nHomePod"
        XCTAssertEqual(parseSpeakerDeviceBlocks(raw).count, 0, "torn output must not zip misaligned fields")
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertEqual(parseSpeakerDeviceBlocks("").count, 0)
    }

    // MARK: - Name matching (exact > prefix > contains)

    func testMatchPrecedence() {
        let names = ["Kitchen", "Kitchen Left", "Back Kitchen"]
        XCTAssertEqual(matchSpeakerName("kitchen", in: names), "Kitchen")
        XCTAssertEqual(matchSpeakerName("kitchen l", in: names), "Kitchen Left")
        XCTAssertEqual(matchSpeakerName("back", in: names), "Back Kitchen")
        XCTAssertNil(matchSpeakerName("garage", in: names))
    }

    /// The bug: hasPrefix("") is true for EVERY string, so an empty name
    /// (bare `music speaker stop` / `only`, or a script's unset $NAME)
    /// resolved to an arbitrary device and acted on it.
    func testEmptyInputMatchesNothing() {
        let names = ["Kitchen", "Office"]
        XCTAssertNil(matchSpeakerName("", in: names))
        XCTAssertNil(matchSpeakerName("   ", in: names))
    }

    // MARK: - AppleScript error name extraction

    func testExtractsDeviceNameFromError() {
        let err = "36:41: execution error: Music got an error: Can't get AirPlay device \"Deck\". (-1728)"
        XCTAssertEqual(speakerName(fromAppleScriptError: err), "Deck")
        XCTAssertNil(speakerName(fromAppleScriptError: "some other error"))
    }
}

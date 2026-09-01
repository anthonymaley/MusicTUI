import XCTest
import ArgumentParser
@testable import music

final class WatchContainerTests: XCTestCase {

    func testSubcommandIsHiddenFromHelp() {
        XCTAssertFalse(WatchContainer.configuration.shouldDisplay,
                       "internal plumbing must not appear in normal help")
    }

    func testCommandNameIsTheInternalForm() {
        XCTAssertEqual(WatchContainer.configuration.commandName, "__watch-container")
    }

    /// One read per poll, carrying all three signals, each independently
    /// try-guarded so one failing read does not blank the others.
    func testObservationScriptReadsAllThreeSignalsWithGuards() {
        let s = albumWatcherObservationScript()
        XCTAssertTrue(s.contains("player state"))
        XCTAssertTrue(s.contains("current playlist"))
        XCTAssertTrue(s.contains("persistent ID of current track"))
        XCTAssertTrue(s.contains("ASCII character 31"))
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: "try").count - 1, 3,
                                    "each read needs its own try guard")
    }

    func testParseAllThreeFieldsPresent() {
        let raw = "playing\u{1F}__album__ U — Moon Safari\u{1F}ID2"
        let o = parseWatcherObservation(raw,
                                        containerName: "__album__ U — Moon Safari",
                                        ids: ["ID1", "ID2"])
        XCTAssertEqual(o.playerState, "playing")
        XCTAssertEqual(o.currentPlaylist, "__album__ U — Moon Safari")
        XCTAssertEqual(o.currentTrackID, "ID2")
    }

    /// Empty field means the read threw. It must become nil, not "".
    func testEmptyFieldsBecomeNilNotEmptyString() {
        let raw = "playing\u{1F}\u{1F}"
        let o = parseWatcherObservation(raw, containerName: "C", ids: [])
        XCTAssertEqual(o.playerState, "playing")
        XCTAssertNil(o.currentPlaylist)
        XCTAssertNil(o.currentTrackID)
    }

    func testMalformedPayloadIsAllNilAndThereforeSpares() {
        let o = parseWatcherObservation("garbage", containerName: "C", ids: ["A"])
        XCTAssertNil(o.playerState)
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// The watcher deletes exactly one playlist and can never reach a track.
    func testDeleteScriptNamesOnePlaylistAndNoTrack() {
        let s = playlistDeleteScript(name: "__album__ U — Moon Safari")
        XCTAssertTrue(s.contains("every user playlist whose name is"))
        XCTAssertFalse(s.contains("track"))
        XCTAssertFalse(s.contains("song"))
        XCTAssertFalse(s.contains("starts with"), "must never be prefix wide")
    }
}

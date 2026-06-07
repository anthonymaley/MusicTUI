// tools/music/Tests/MusicTests/QueueEndTests.swift
import XCTest
@testable import music

final class QueueEndTests: XCTestCase {
    func testLibraryNameDetection() {
        XCTAssertTrue(isLibraryContextName("Music"))
        XCTAssertTrue(isLibraryContextName("Library"))
        XCTAssertFalse(isLibraryContextName("Friday Mix"))
        XCTAssertFalse(isLibraryContextName(""))
    }
    func testFiresOnNaturalQueueEnd() {
        XCTAssertTrue(detectQueueEnd(
            prevWasRealPlaylist: true, prevAtLastTrack: true,
            prevNaturalEnd: true, nowIsLibraryAutoplay: true))
    }
    func testNoFireWhenPrevWasLibrary() {
        XCTAssertFalse(detectQueueEnd(
            prevWasRealPlaylist: false, prevAtLastTrack: true,
            prevNaturalEnd: true, nowIsLibraryAutoplay: true))
    }
    func testNoFireMidPlaylist() {
        XCTAssertFalse(detectQueueEnd(
            prevWasRealPlaylist: true, prevAtLastTrack: false,
            prevNaturalEnd: true, nowIsLibraryAutoplay: true))
    }
    func testNoFireOnManualLibraryJump() {
        // prev was last track but not a natural end (user skipped to library)
        XCTAssertFalse(detectQueueEnd(
            prevWasRealPlaylist: true, prevAtLastTrack: true,
            prevNaturalEnd: false, nowIsLibraryAutoplay: true))
    }
    func testNoFireWhenStillInPlaylist() {
        XCTAssertFalse(detectQueueEnd(
            prevWasRealPlaylist: true, prevAtLastTrack: true,
            prevNaturalEnd: true, nowIsLibraryAutoplay: false))
    }
}

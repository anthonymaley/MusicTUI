// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindowMarksCurrentByIndex() {
        // Format: "name\ncurrentIndex\ntotal\nwindowStart\nidx␟title␟artist..."
        // (fields are ASCII unit separator — titles can legally contain "|")
        let fs = String(asFieldSep)
        let raw = "Friday Mix\n3\n42\n2\n2\(fs)Song B\(fs)Artist B\n3\(fs)Song C\(fs)Artist C\n4\(fs)Song C\(fs)Artist C"
        let q = parseContextQueue(raw)
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.currentIndex, 3)
        XCTAssertEqual(q.total, 42)
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)
        XCTAssertFalse(q.tracks[2].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
    /// Now Playing shows the album's real title, not the transaction id.
    func testCleanContextNameStripsTheDiscoverPrefix() {
        XCTAssertEqual(cleanContextName("__discover__ 8B1F"), "8B1F")
        XCTAssertEqual(cleanContextName("__queue__ House"), "House")
        XCTAssertEqual(cleanContextName("My Mix"), "My Mix")
    }
    func testGeniusClearsWhenRealPlaylistTakesOver() {
        // Within the grace window: keep it (post-trigger lag still shows old ctx).
        XCTAssertFalse(geniusShouldClear(elapsedSinceTrigger: 1, hasAppQueue: false, contextName: "Friday Mix"))
        // After grace, a real playlist context means Genius is over.
        XCTAssertTrue(geniusShouldClear(elapsedSinceTrigger: 5, hasAppQueue: false, contextName: "Friday Mix"))
        // Library context after grace = still Genius/library — keep it.
        XCTAssertFalse(geniusShouldClear(elapsedSinceTrigger: 5, hasAppQueue: false, contextName: "Music"))
        // An app-owned queue always wins immediately.
        XCTAssertTrue(geniusShouldClear(elapsedSinceTrigger: 0, hasAppQueue: true, contextName: "Music"))
    }
}

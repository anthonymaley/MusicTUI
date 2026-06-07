// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindow() {
        // Format: "name\ncurrentIndex\nwindowStart\nidx|title|artist\nidx|title|artist..."
        let raw = "Friday Mix\n3\n2\n2|Song B|Artist B\n3|Song C|Artist C\n4|Song D|Artist D"
        let q = parseContextQueue(raw, currentTitle: "Song C", currentArtist: "Artist C")
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[0].index, 2)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)        // Song C is current
        XCTAssertFalse(q.tracks[0].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("", currentTitle: "x", currentArtist: "y")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
}

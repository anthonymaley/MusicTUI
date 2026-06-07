// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindowMarksCurrentByIndex() {
        // Format: "name\ncurrentIndex\nwindowStart\nidx|title|artist..."
        // Index 4 deliberately duplicates the current track's title/artist to
        // prove current is marked by INDEX, not by name (the duplicate bug).
        let raw = "Friday Mix\n3\n2\n2|Song B|Artist B\n3|Song C|Artist C\n4|Song C|Artist C"
        let q = parseContextQueue(raw)
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)         // index 3 == currentIndex
        XCTAssertFalse(q.tracks[2].isCurrent)        // index 4, same name, NOT current
        XCTAssertFalse(q.tracks[0].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
}

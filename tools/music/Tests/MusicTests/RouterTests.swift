// tools/music/Tests/MusicTests/RouterTests.swift
import XCTest
@testable import music

final class RouterTests: XCTestCase {
    func testStartsAtRoot() {
        let r = Router(root: .nowPlaying)
        XCTAssertEqual(r.active, .nowPlaying)
        XCTAssertEqual(r.stack, [.nowPlaying])
    }
    func testPushPop() {
        let r = Router(root: .playlists)
        r.push(.nowPlaying)
        XCTAssertEqual(r.active, .nowPlaying)
        r.pop()
        XCTAssertEqual(r.active, .playlists)
    }
    func testPopAtRootIsNoOp() {
        let r = Router(root: .nowPlaying)
        r.pop()
        XCTAssertEqual(r.active, .nowPlaying)
        XCTAssertEqual(r.stack.count, 1)
    }
    func testSwitchResetsStack() {
        let r = Router(root: .playlists)
        r.push(.nowPlaying)
        r.switchTo(.speakers)
        XCTAssertEqual(r.active, .speakers)
        XCTAssertEqual(r.stack, [.speakers])
    }
}

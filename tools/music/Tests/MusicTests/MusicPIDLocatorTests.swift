import Foundation
import XCTest
@testable import music

/// Finding the running Music.app by executable path. Only lists and injected
/// start times; nothing here talks to Music.app.
final class MusicPIDLocatorTests: XCTestCase {
    func testSystemMusicAppMatches() {
        let list: [(pid: Int32, path: String)] = [
            (pid: 1, path: "/sbin/launchd"),
            (pid: 4413, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
            (pid: 900, path: "/usr/bin/true"),
        ]
        XCTAssertEqual(musicAppPID(list), 4413)
    }

    func testApplicationsMusicAppMatches() {
        XCTAssertEqual(musicAppPID([(pid: 77, path: "/Applications/Music.app/Contents/MacOS/Music")]), 77)
    }

    func testLookalikePathDoesNotMatch() {
        XCTAssertNil(musicAppPID([(pid: 5, path: "/tmp/Music.app.bak/Contents/MacOS/Music2")]))
    }

    func testNoMatchIsNil() {
        XCTAssertNil(musicAppPID([]))
        XCTAssertNil(musicAppPID([(pid: 9, path: "/usr/bin/true")]))
    }

    func testTwoMatchesIsNil() {
        let list: [(pid: Int32, path: String)] = [
            (pid: 4413, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
            (pid: 4414, path: "/Applications/Music.app/Contents/MacOS/Music"),
        ]
        XCTAssertNil(musicAppPID(list))
    }

    func testLocatorBuildsTheProcessFromPidAndStartTime() {
        var asked: [Int32] = []
        let locator = MusicProcessLocator(
            listProcesses: { [(pid: 4413, path: "/System/Applications/Music.app/Contents/MacOS/Music")] },
            startTime: { pid in asked.append(pid); return 1_790_000_000.25 })
        XCTAssertEqual(locator.locate(), MusicProcess(pid: 4413, startedAt: 1_790_000_000.25))
        XCTAssertEqual(asked, [4413])
    }

    func testLocatorWithoutAStartTimeIsNil() {
        let locator = MusicProcessLocator(
            listProcesses: { [(pid: 4413, path: "/System/Applications/Music.app/Contents/MacOS/Music")] },
            startTime: { _ in nil })
        XCTAssertNil(locator.locate())
    }

    func testLocatorLooksAgainOnEveryCall() {
        var calls = 0
        var list: [(pid: Int32, path: String)] = [(pid: 10, path: "/Applications/Music.app/Contents/MacOS/Music")]
        let locator = MusicProcessLocator(listProcesses: { calls += 1; return list },
                                          startTime: { Double($0) })
        XCTAssertEqual(locator.locate()?.pid, 10)
        list = [(pid: 11, path: "/Applications/Music.app/Contents/MacOS/Music")]
        XCTAssertEqual(locator.locate()?.pid, 11)
        list = []
        XCTAssertNil(locator.locate())
        XCTAssertEqual(calls, 3)
    }

    /// The live process table lists this test process with its path. Reading
    /// the table sends nothing to any process.
    func testRunningProcessPathsIncludesThisProcess() {
        let me = getpid()
        let entry = runningProcessPaths().first { $0.pid == me }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.path.isEmpty ?? true)
    }
}

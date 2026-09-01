import XCTest
@testable import music

final class BoundedAlbumPlayTests: XCTestCase {

    private func rows(_ n: Int) -> [LibraryAlbumRow] {
        (1...n).map {
            LibraryAlbumRow(index: $0, name: "T\($0)", artist: "A",
                            albumArtist: "A", cloudStatus: "subscription",
                            disc: 1, track: $0)
        }
    }

    /// Happy path: build, capture ids, play, spawn. No shuffle write anywhere.
    func testPlaysAndSpawnsWatcherWithoutTouchingShuffle() {
        var scripts: [String] = []
        var spawned = false
        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "3" }
                                       if s.contains("persistent ID of every track") {
                                           return "A\u{1F}B\u{1F}C"
                                       }
                                       return ""
                                   },
                                   launch: { _, _ in spawned = true; return true })
        XCTAssertEqual(out, .playing)
        XCTAssertTrue(spawned)
        XCTAssertTrue(scripts.contains { $0.contains("play playlist") })
        XCTAssertFalse(scripts.contains { $0.contains("shuffle enabled") },
                       "the user's shuffle setting must never be written")
    }

    func testNoPlayableTracksPlaysNothing() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: [], uuid: "U",
                                   run: { s in scripts.append(s); return "" },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .notFound)
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    func testMatchedButNonePlayable() {
        let unplayable = [LibraryAlbumRow(index: 1, name: "T1", artist: "A",
                                          albumArtist: "A", cloudStatus: "removed",
                                          disc: 1, track: 1)]
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: unplayable, uuid: "U",
                                   run: { s in scripts.append(s); return "" },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .nonePlayable(matched: 1))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    /// Fail closed: a seed mismatch must not play. The build's own rollback
    /// already deleted the container successfully, so the caller can say so.
    func testSeedMismatchDeletesAndDoesNotPlay() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .buildFailed(containerRemoved: true))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
        XCTAssertTrue(scripts.contains { $0.contains("every user playlist whose name is") })
    }

    /// When the build fails AND its own rollback delete also fails, the caller
    /// must be told the container may still exist, not that it was removed.
    func testBuildFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(3), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .buildFailed(containerRemoved: false))
        XCTAssertFalse(scripts.contains { $0.contains("play playlist") })
    }

    func testPlayFailureDeletesTheContainer() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("persistent ID of every track") { return "A\u{1F}B" }
                                       if s.contains("play playlist") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playFailed(containerRemoved: true))
        XCTAssertTrue(scripts.last!.contains("every user playlist whose name is"))
    }

    /// Play fails, and the rollback delete for that failure ALSO fails: the
    /// caller must be told the container was not removed, not the opposite.
    func testPlayFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("persistent ID of every track") { return "A\u{1F}B" }
                                       if s.contains("play playlist") { return nil }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in true })
        XCTAssertEqual(out, .playFailed(containerRemoved: false))
    }

    /// Playback is ALREADY running when the watcher is spawned, so this rollback
    /// must also stop the audio it started.
    func testWatcherLaunchFailurePausesAndDeletes() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("persistent ID of every track") { return "A\u{1F}B" }
                                       return ""
                                   },
                                   launch: { _, _ in false })
        XCTAssertEqual(out, .watcherFailed(containerRemoved: true))
        XCTAssertTrue(scripts.contains { $0.trimmingCharacters(in: .whitespaces) == "pause" },
                      "must pause the audio it started")
        XCTAssertTrue(scripts.last!.contains("every user playlist whose name is"))
    }

    /// Watcher spawn fails, and the rollback delete for that failure ALSO
    /// fails: playback stays paused (already handled) but the caller must be
    /// told the container was not removed.
    func testWatcherFailureWhoseRollbackAlsoFailsReportsContainerNotRemoved() {
        var scripts: [String] = []
        let out = playBoundedAlbum(title: "X", rows: rows(2), uuid: "U",
                                   run: { s in
                                       scripts.append(s)
                                       if s.contains("count of tracks") { return "2" }
                                       if s.contains("persistent ID of every track") { return "A\u{1F}B" }
                                       if s.contains("every user playlist whose name is") { return nil }
                                       return ""
                                   },
                                   launch: { _, _ in false })
        XCTAssertEqual(out, .watcherFailed(containerRemoved: false))
        XCTAssertTrue(scripts.contains { $0.trimmingCharacters(in: .whitespaces) == "pause" })
    }
}

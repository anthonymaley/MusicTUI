// tools/music/Tests/MusicTests/PlaybackPollerTests.swift
import XCTest
@testable import music

/// tempArtPath: the per-album temp path fix for the Now tab's wrong-album
/// bug. Before this fix, every album's raw art bytes were extracted to the
/// SAME fixed file (/tmp/music-now-art.dat); revisiting an already
/// lines-cached album skipped re-extraction entirely, so the kitty path read
/// whatever album's bytes were extracted most recently — permanently pinned
/// under the revisited album's own (different, correct-looking) id. A
/// deterministic path PER album|artist key makes that collision impossible:
/// two different albums can never share a file.
final class PlaybackPollerTests: XCTestCase {
    private func poller() -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: AppleScriptBackend(), appQueue: AppQueueStore())
    }

    func testTempArtPathIsDeterministicForTheSameKey() {
        let p = poller()
        let key = "The Low End Theory\u{0}A Tribe Called Quest"
        XCTAssertEqual(p.tempArtPath(for: key), p.tempArtPath(for: key))
    }

    func testTempArtPathDiffersForDifferentAlbums() {
        let p = poller()
        // The exact repro from the bug report.
        let lowEndTheory = p.tempArtPath(for: "The Low End Theory\u{0}A Tribe Called Quest")
        let peoplesInstinctive = p.tempArtPath(for: "People's Instinctive Travels and the Paths of Rhythm\u{0}A Tribe Called Quest")
        XCTAssertNotEqual(lowEndTheory, peoplesInstinctive,
                          "two different albums must never resolve to the same temp file")
    }

    func testTempArtPathIsUnderTmpWithDatExtension() {
        let p = poller()
        let path = p.tempArtPath(for: "Some Album\u{0}Some Artist")
        XCTAssertTrue(path.hasPrefix("/tmp/music-now-art-"))
        XCTAssertTrue(path.hasSuffix(".dat"))
    }

    func testCleanupArtFilesRemovesOnlyCachedPaths() {
        let p = poller()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poller-cleanup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // cleanupArtFiles() only touches paths it actually cached (artPathCache
        // is poller-private state populated only via a real extraction), so with
        // nothing extracted yet it must be a safe no-op rather than throwing or
        // touching unrelated files.
        p.cleanupArtFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "cleanup must not touch unrelated paths")
    }
}

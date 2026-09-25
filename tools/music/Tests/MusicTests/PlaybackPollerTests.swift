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
    // Footgun guard (see TODO.md): the default QueueStore() writes the REAL
    // ~/.config/music/queue.json. None of the tests below call tick() (there
    // is no seam to fake AppleScriptBackend's live osascript calls — every
    // poller/context helper takes the concrete struct, not a protocol — so
    // syncQueuePersistence() never runs here regardless), but every
    // PlaybackPoller in this file is still built on a temp-path QueueStore
    // so that stays true if a future test in this file ever does call tick().
    private var queueStoreTmpPath: String!

    override func setUp() {
        super.setUp()
        queueStoreTmpPath = NSTemporaryDirectory() + "poller-tests-queue-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: queueStoreTmpPath)
        super.tearDown()
    }

    private func poller() -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                        queueStore: QueueStore(path: queueStoreTmpPath))
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

    // MARK: - sizedArtKey

    // sizedArtKey: the lines-cache re-key for width-adaptive art (Now-tab art
    // pair, task B). artPathCache stays keyed by album|artist alone (raw
    // bytes don't vary with size) — only the LINES cache needs the size in
    // its key, so a resize doesn't reuse a mismatched size's pre-rendered text.

    func testSizedArtKeyIncludesAlbumArtistAndSize() {
        let p = poller()
        XCTAssertEqual(p.sizedArtKey(album: "Midnight Marauders", artist: "A Tribe Called Quest", cols: 44, rows: 22),
                        "Midnight Marauders\u{0}A Tribe Called Quest\u{0}44x22")
    }

    func testSizedArtKeyDiffersForDifferentSizesOfTheSameAlbum() {
        let p = poller()
        let at44x22 = p.sizedArtKey(album: "Illmatic", artist: "Nas", cols: 44, rows: 22)
        let at54x27 = p.sizedArtKey(album: "Illmatic", artist: "Nas", cols: 54, rows: 27)
        XCTAssertNotEqual(at44x22, at54x27, "a resize must miss the previous size's cached lines")
    }

    func testSizedArtKeyDiffersForDifferentAlbumsAtTheSameSize() {
        let p = poller()
        let lowEndTheory = p.sizedArtKey(album: "The Low End Theory", artist: "A Tribe Called Quest", cols: 44, rows: 22)
        let peoplesInstinctive = p.sizedArtKey(album: "People's Instinctive Travels and the Paths of Rhythm", artist: "A Tribe Called Quest", cols: 44, rows: 22)
        XCTAssertNotEqual(lowEndTheory, peoplesInstinctive)
    }

    // MARK: - clampedArtSize (NowPlayingScene.swift)

    // clampedArtSize: the render-side square-equivalent clamp published to
    // the poller each render — same formula as the kitty rect's own gw-based
    // sizing, so the chafa/mono lines path follows the same proportions
    // kitty already stretches its PNG to.

    func testClampedArtSizeColsIsAlwaysTwiceRows() {
        for artRows in [0, 5, 10, 15, 22, 30, 60, 100] {
            for gw in [0, 10, 20, 44, 54, 108, 200] {
                let size = clampedArtSize(artRows: artRows, gw: gw)
                XCTAssertEqual(size.cols, size.rows * 2,
                                "artRows: \(artRows), gw: \(gw) — cols must stay the square-equivalent double of rows")
            }
        }
    }

    func testClampedArtSizeFloorsAtTwentyByTenWhenInputsAreSmall() {
        let size = clampedArtSize(artRows: 2, gw: 10)
        XCTAssertEqual(size.cols, 20)
        XCTAssertEqual(size.rows, 10)
    }

    func testClampedArtSizeFloorsEvenWithZeroInputs() {
        let size = clampedArtSize(artRows: 0, gw: 0)
        XCTAssertEqual(size.cols, 20)
        XCTAssertEqual(size.rows, 10)
    }

    func testClampedArtSizeUsesArtRowsWhenItIsTheSmallerBound() {
        // gw / 2 = 50, well above artRows — artRows is the binding constraint.
        let size = clampedArtSize(artRows: 15, gw: 100)
        XCTAssertEqual(size.cols, 30)
        XCTAssertEqual(size.rows, 15)
    }

    func testClampedArtSizeUsesHalfGwWhenItIsTheSmallerBound() {
        // artRows = 40 is well above gw / 2 = 22 — gw is the binding constraint.
        // This is also the one-pane case (gw fixed at 44): reproduces the
        // pre-B1 fixed extraction size exactly.
        let size = clampedArtSize(artRows: 40, gw: 44)
        XCTAssertEqual(size.cols, 44)
        XCTAssertEqual(size.rows, 22)
    }
}

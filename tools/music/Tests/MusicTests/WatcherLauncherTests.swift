import XCTest
@testable import music

final class WatcherLauncherTests: XCTestCase {

    func testSmallAlbumPassesIDsInline() throws {
        let args = try watcherArguments(name: "__album__ U — A", uuid: "U",
                                        ids: ["ID1", "ID2"])
        XCTAssertEqual(args[0], "__watch-container")
        XCTAssertEqual(args[1], "__album__ U — A")
        XCTAssertTrue(args.contains("--ids"))
        XCTAssertFalse(args.contains("--manifest"))
        let list = args[args.firstIndex(of: "--ids")! + 1]
        XCTAssertEqual(Set(list.split(separator: ",").map(String.init)), ["ID1", "ID2"])
    }

    func testLargeAlbumUsesAManifest() throws {
        let many = Set((0...(albumWatcherInlineIDLimit + 1)).map { "ID\($0)" })
        let uuid = "TEST-\(UUID().uuidString)"
        let args = try watcherArguments(name: "__album__ \(uuid) — A", uuid: uuid, ids: many)
        XCTAssertTrue(args.contains("--manifest"))
        XCTAssertFalse(args.contains("--ids"))
        let path = args[args.firstIndex(of: "--manifest")! + 1]
        defer { removeAlbumManifest(path: path) }
        XCTAssertEqual(readAlbumManifest(path: path), many)
    }

    func testSpawnReportsSuccess() {
        var launched: [String]?
        let ok = spawnAlbumWatcher(name: "__album__ U — A", uuid: "U", ids: ["ID1"]) { _, args in
            launched = args
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(launched?.first, "__watch-container")
    }

    /// A launch failure must be reported so the caller can roll back. Playback
    /// is already running at this point, so silence here means litter.
    func testSpawnReportsFailure() {
        let ok = spawnAlbumWatcher(name: "__album__ U — A", uuid: "U", ids: ["ID1"]) { _, _ in
            false
        }
        XCTAssertFalse(ok)
    }

    /// A rejected uuid (containing "/") makes `writeAlbumManifest` throw. That
    /// must be reported like any other spawn failure, and MUST NOT reach the
    /// launcher: the child would have no manifest to read.
    func testSpawnReportsFailureOnRejectedUUID() {
        let many = Set((0...(albumWatcherInlineIDLimit + 1)).map { "ID\($0)" })
        var launcherCalled = false
        let ok = spawnAlbumWatcher(name: "__album__ bad — A", uuid: "bad/uuid", ids: many) { _, _ in
            launcherCalled = true
            return true
        }
        XCTAssertFalse(ok)
        XCTAssertFalse(launcherCalled)
    }
}

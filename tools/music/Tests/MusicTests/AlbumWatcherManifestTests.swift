import XCTest
@testable import music

final class AlbumWatcherManifestTests: XCTestCase {

    func testRoundTrip() throws {
        let uuid = "TEST-\(UUID().uuidString)"
        let path = try writeAlbumManifest(uuid: uuid, ids: ["A", "B", "C"])
        defer { removeAlbumManifest(path: path) }
        XCTAssertEqual(readAlbumManifest(path: path), ["A", "B", "C"])
    }

    func testPathIsNamedByTheContainerUUID() {
        XCTAssertTrue(albumManifestPath(uuid: "ABC")?.contains("ABC") ?? false)
    }

    func testOwnerOnlyPermissions() throws {
        let uuid = "TEST-\(UUID().uuidString)"
        let path = try writeAlbumManifest(uuid: uuid, ids: ["A"])
        defer { removeAlbumManifest(path: path) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRemoveIsIdempotent() throws {
        let uuid = "TEST-\(UUID().uuidString)"
        let path = try writeAlbumManifest(uuid: uuid, ids: ["A"])
        removeAlbumManifest(path: path)
        removeAlbumManifest(path: path)
        XCTAssertNil(readAlbumManifest(path: path))
    }

    func testReadMissingFileIsNil() {
        XCTAssertNil(readAlbumManifest(path: "/nonexistent/nope.ids"))
    }

    func testTightensAnAlreadyLooseDirectory() throws {
        let uuid = "TEST-\(UUID().uuidString)"
        let path = try writeAlbumManifest(uuid: uuid, ids: ["A"])
        defer { removeAlbumManifest(path: path) }

        let dir = (path as NSString).deletingLastPathComponent

        // Deliberately loosen the directory
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)

        // Write again; it should tighten the directory even though it already exists
        _ = try writeAlbumManifest(uuid: uuid, ids: ["B"])

        // Verify directory is back to 0700
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700,
                       "directory should be tightened to 0700 even if it already exists")
    }

    func testRejectsUUIDsWithTraversalCharacters() throws {
        XCTAssertNil(albumManifestPath(uuid: "../../evil"))
        XCTAssertNil(albumManifestPath(uuid: "test/evil"))
        XCTAssertNil(albumManifestPath(uuid: ".."))

        XCTAssertThrowsError(try writeAlbumManifest(uuid: "../../evil", ids: []))
        XCTAssertThrowsError(try writeAlbumManifest(uuid: "test/evil", ids: []))
    }

    func testAcceptsValidUUIDs() throws {
        // Valid test and standard UUIDs should be accepted
        XCTAssertNotNil(albumManifestPath(uuid: "00112233-4455-6677-8899-aabbccddeeff"))
        XCTAssertNotNil(albumManifestPath(uuid: "TEST-00112233445566778899"))
        XCTAssertNotNil(albumManifestPath(uuid: "550E8400-E29B-41D4-A716-446655440000"))
    }
}

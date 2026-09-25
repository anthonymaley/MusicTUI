import XCTest
@testable import music

/// `printHistorySongs` fell back to the raw resource `id` whenever
/// `playParams.catalogId` was absent, and built every `SongResult` with no
/// `origin:`, defaulting to `.catalog`. Apple's recent/heavy-rotation
/// endpoints can return `type == "library-songs"` items — a library id, not
/// a catalogue id — exactly when `playParams.catalogId` is absent. Cached as
/// `.catalog`, such a row would route a library id through the REST add path.
final class HistoryCommandsCacheTests: XCTestCase {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "/musictui-history-cache-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func jsonData(type: String, id: String, catalogId: String?) -> Data {
        var attrs: [String: Any] = ["name": "Song Name", "artistName": "Artist", "albumName": "Album"]
        if let catalogId {
            attrs["playParams"] = ["catalogId": catalogId]
        }
        let item: [String: Any] = ["type": type, "id": id, "attributes": attrs]
        let payload: [String: Any] = ["data": [item]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// `type == "library-songs"` with no `playParams.catalogId` is exactly the
    /// mislabel case: it must be tagged `.library`, not the previous default
    /// `.catalog`, and its cached id must be the library id (not empty).
    func testLibrarySongWithNoPlayParamsCatalogIdIsTaggedLibrary() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ResultCache(directory: dir)
        let data = jsonData(type: "library-songs", id: "l.abc123", catalogId: nil)

        try printHistorySongs(data: data, label: "recent", json: false, cache: cache)

        let songs = try cache.readSongs()
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].origin, .library)
        XCTAssertEqual(songs[0].catalogId, "l.abc123")
    }

    /// A catalogue song with a real `playParams.catalogId` stays `.catalog`,
    /// and the id used is the catalog id from playParams, not `item.id`.
    func testCatalogSongWithPlayParamsCatalogIdIsTaggedCatalogAndUsesThatId() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ResultCache(directory: dir)
        let data = jsonData(type: "songs", id: "1234567", catalogId: "999888")

        try printHistorySongs(data: data, label: "recent", json: false, cache: cache)

        let songs = try cache.readSongs()
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].origin, .catalog)
        XCTAssertEqual(songs[0].catalogId, "999888")
    }

    /// Legacy shape: `type == "songs"` with no `playParams` at all must stay
    /// `.catalog` (unchanged behaviour), falling back to the item's own id.
    func testLegacySongWithNoPlayParamsStaysCatalog() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ResultCache(directory: dir)
        let data = jsonData(type: "songs", id: "555444", catalogId: nil)

        try printHistorySongs(data: data, label: "recent", json: false, cache: cache)

        let songs = try cache.readSongs()
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].origin, .catalog)
        XCTAssertEqual(songs[0].catalogId, "555444")
    }
}

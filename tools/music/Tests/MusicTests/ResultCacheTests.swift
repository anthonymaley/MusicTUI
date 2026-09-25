import XCTest
@testable import music

final class ResultCacheTests: XCTestCase {
    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("music-test-\(UUID().uuidString)")

    override func setUp() {
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
    }

    func testWriteAndReadSongs() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs: [SongResult] = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let loaded = try cache.readSongs()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].title, "Alpha")
        XCTAssertEqual(loaded[1].catalogId, "id2")
    }

    func testWriteAndReadSpeakers() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers: [SpeakerResult] = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
            SpeakerResult(index: 2, name: "MacBook Pro", selected: false, volume: 15),
        ]
        try cache.writeSpeakers(speakers)
        let loaded = try cache.readSpeakers()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Kitchen")
        XCTAssertEqual(loaded[1].volume, 15)
    }

    func testLookupSongByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let song = try cache.lookupSong(index: 2)
        XCTAssertEqual(song.title, "Beta")
    }

    func testLookupSongOutOfRange() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.lookupSong(index: 1)) { error in
            XCTAssertTrue(error is CacheError)
        }
    }

    func testLookupSpeakerByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
        ]
        try cache.writeSpeakers(speakers)
        let speaker = try cache.lookupSpeaker(index: 1)
        XCTAssertEqual(speaker.name, "Kitchen")
    }

    func testMissingCacheFileThrows() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.readSongs()) { error in
            XCTAssertTrue(error is CacheError)
        }
    }

    // Batch lookup must separate hits from misses so the caller can report the
    // dropped indices instead of silently building a shorter result.
    func testLookupSongsPartitionsHitsAndDrops() throws {
        let cache = ResultCache(directory: testDir.path)
        try cache.writeSongs([
            SongResult(index: 1, title: "Alpha", artist: "A", album: "AA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "B", album: "BB", catalogId: "id2"),
        ])
        let (resolved, dropped) = cache.lookupSongs(indices: [2, 9])
        XCTAssertEqual(resolved.map { $0.index }, [2])
        XCTAssertEqual(dropped, [9])
    }

    func testLookupSongsAllDroppedWhenCacheMissing() {
        let cache = ResultCache(directory: testDir.path)
        let (resolved, dropped) = cache.lookupSongs(indices: [1, 2])
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertEqual(dropped, [1, 2])
    }

    // MARK: - speaker IP memoization

    func testSpeakerIPRoundTrip() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberSpeakerIP(name: "Kitchen", ip: "192.168.1.112")
        XCTAssertEqual(cache.cachedSpeakerIP(forName: "Kitchen"), "192.168.1.112")
    }

    func testSpeakerIPCaseInsensitiveLookup() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberSpeakerIP(name: "Living Room", ip: "192.168.1.81")
        XCTAssertEqual(cache.cachedSpeakerIP(forName: "living room"), "192.168.1.81")
    }

    func testSpeakerIPMissReturnsNil() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertNil(cache.cachedSpeakerIP(forName: "Nonexistent"))
    }

    func testSpeakerIPExpiresWithZeroTTL() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberSpeakerIP(name: "Kitchen", ip: "192.168.1.112")
        // ttl 0 → the just-written entry is already considered stale.
        XCTAssertNil(cache.cachedSpeakerIP(forName: "Kitchen", ttl: 0))
    }

    func testSpeakerIPRefreshReplacesPriorEntry() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberSpeakerIP(name: "Kitchen", ip: "192.168.1.112")
        cache.rememberSpeakerIP(name: "Kitchen", ip: "192.168.1.200")
        XCTAssertEqual(cache.cachedSpeakerIP(forName: "Kitchen"), "192.168.1.200")
        // No duplicate entries left behind.
        cache.rememberSpeakerIP(name: "Bedroom", ip: "192.168.1.90")
        XCTAssertEqual(cache.cachedSpeakerIP(forName: "Kitchen"), "192.168.1.200")
        XCTAssertEqual(cache.cachedSpeakerIP(forName: "Bedroom"), "192.168.1.90")
    }

    // MARK: - Artist-tier filter cache

    func testArtistTiersRoundTrip() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberArtistTiers(ep: ["burial", "actress"], albums: ["radiohead", "air"])
        let hit = cache.cachedArtistTiers()
        XCTAssertEqual(hit?.ep, ["burial", "actress"])
        XCTAssertEqual(hit?.albums, ["radiohead", "air"])
    }

    func testArtistTiersMissReturnsNil() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertNil(cache.cachedArtistTiers())
    }

    func testArtistTiersExpiresWithZeroTTL() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberArtistTiers(ep: ["burial"], albums: ["radiohead"])
        XCTAssertNil(cache.cachedArtistTiers(ttl: 0))   // just-written entry is already stale
    }

    func testArtistTiersRefreshReplacesPrior() {
        let cache = ResultCache(directory: testDir.path)
        cache.rememberArtistTiers(ep: ["burial"], albums: ["radiohead"])
        cache.rememberArtistTiers(ep: ["actress"], albums: ["air", "boards of canada"])
        let hit = cache.cachedArtistTiers()
        XCTAssertEqual(hit?.ep, ["actress"])
        XCTAssertEqual(hit?.albums, ["air", "boards of canada"])
    }

    // MARK: - Row origin

    func testOriginDefaultsToCatalogWhenAbsentFromFile() throws {
        let json = "[{\"index\":1,\"title\":\"Alpha\",\"artist\":\"A\",\"album\":\"AA\",\"catalogId\":\"id1\"}]"
        try json.data(using: .utf8)!.write(to: testDir.appendingPathComponent("last-songs.json"))
        let loaded = try ResultCache(directory: testDir.path).readSongs()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].origin, .catalog)
        XCTAssertEqual(loaded[0].catalogId, "id1")
    }

    func testOriginRoundTripsThroughTheCache() throws {
        let cache = ResultCache(directory: testDir.path)
        try cache.writeSongs([
            SongResult(index: 1, title: "Alpha", artist: "A", album: "AA", catalogId: "pid1", origin: .library),
            SongResult(index: 2, title: "Beta", artist: "B", album: "BB", catalogId: "id2"),
        ])
        let loaded = try cache.readSongs()
        XCTAssertEqual(loaded[0].origin, .library)
        XCTAssertEqual(loaded[1].origin, .catalog)
        let raw = try String(contentsOf: testDir.appendingPathComponent("last-songs.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"origin\":\"library\""))
    }

    func testMemberwiseInitDefaultsOriginToCatalog() {
        XCTAssertEqual(SongResult(index: 1, title: "t", artist: "a", album: "b", catalogId: "c").origin, .catalog)
    }

    // MARK: - Bridge provenance (score S3, D3)

    /// Rows every shipped writer produces encode exactly as they did before
    /// `bridge_id` existed: the same keys and values, no `bridge_id`, no null.
    /// Compared with sorted keys because the default encoder's key order was
    /// never stable (it differs between processes, measured 2026-09-25 against
    /// the pre-change struct), so unsorted bytes could not be pinned even then.
    func testExistingRowsEncodeToTheSameBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let catalog = SongResult(index: 1, title: "Alpha", artist: "A", album: "AA", catalogId: "id1")
        let library = SongResult(index: 2, title: "Beta", artist: "B", album: "BB", catalogId: "pid2", origin: .library)
        XCTAssertEqual(String(decoding: try encoder.encode(catalog), as: UTF8.self),
                       #"{"album":"AA","artist":"A","catalogId":"id1","index":1,"origin":"catalog","title":"Alpha"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(library), as: UTF8.self),
                       #"{"album":"BB","artist":"B","catalogId":"pid2","index":2,"origin":"library","title":"Beta"}"#)
    }

    func testBridgeRowRoundTripsWithItsBridgeID() throws {
        let cache = ResultCache(directory: testDir.path)
        try cache.writeSongs([
            SongResult(index: 1, title: "Alpha", artist: "A", album: "AA", catalogId: "",
                       origin: .bridgeLibrary, bridgeID: "12345"),
            SongResult(index: 2, title: "Beta", artist: "B", album: "BB", catalogId: "",
                       origin: .bridgeLibrary),
        ])
        let loaded = try cache.readSongs()
        XCTAssertEqual(loaded[0].origin, .bridgeLibrary)
        XCTAssertEqual(loaded[0].bridgeID, "12345")
        XCTAssertEqual(loaded[0].catalogId, "", "Bridge rows keep an empty catalogId")
        XCTAssertEqual(loaded[1].origin, .bridgeLibrary)
        XCTAssertNil(loaded[1].bridgeID)
        let raw = try String(contentsOf: testDir.appendingPathComponent("last-songs.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""origin":"bridge_library""#), raw)
        XCTAssertTrue(raw.contains(#""bridge_id":"12345""#), raw)
        XCTAssertEqual(raw.components(separatedBy: "bridge_id").count - 1, 1,
                       "bridge_id is encoded only when non-nil")
    }

    func testLegacyRowWithBridgeLookingIdStillDecodesAsCatalog() throws {
        let json = #"[{"index":1,"title":"Alpha","artist":"A","album":"AA","catalogId":"i.abc123"}]"#
        try json.data(using: .utf8)!.write(to: testDir.appendingPathComponent("last-songs.json"))
        let loaded = try ResultCache(directory: testDir.path).readSongs()
        XCTAssertEqual(loaded[0].origin, .catalog)
        XCTAssertNil(loaded[0].bridgeID)
    }

    func testRowLookupInAnAlreadyReadList() throws {
        let rows = [SongResult(index: 1, title: "a", artist: "", album: "", catalogId: "x"),
                    SongResult(index: 3, title: "c", artist: "", album: "", catalogId: "z")]
        XCTAssertEqual(try ResultCache.row(index: 3, in: rows).title, "c")
        XCTAssertThrowsError(try ResultCache.row(index: 2, in: rows))
        let split = ResultCache.resolve(indices: [3, 2, 1], in: rows)
        XCTAssertEqual(split.resolved.map(\.index), [3, 1])
        XCTAssertEqual(split.dropped, [2])
    }
}

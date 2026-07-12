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
}

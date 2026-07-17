// tools/music/Tests/MusicTests/QueueResumeTests.swift
//
// Pure foundation for queue resume-across-restart.
// NOTHING here is wired into the app yet — Codable conformance, an on-disk store,
// and a pure staleness-guard function, all exercised in isolation. No live component.
import XCTest
@testable import music

final class QueueResumeTests: XCTestCase {

    private func makeQueue(_ count: Int, at index: Int = 1, displayName: String? = nil) -> AppQueue {
        AppQueue(
            playlistName: "P",
            tracks: (1...count).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) },
            currentIndex: index,
            displayName: displayName
        )
    }

    // MARK: - Codable round trips

    func testAppQueueCodableRoundTrip() throws {
        let q = makeQueue(3, at: 2, displayName: "The Low End Theory")
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(AppQueue.self, from: data)
        XCTAssertEqual(decoded, q)
    }

    func testAppQueueCodableRoundTripWithNilDisplayName() throws {
        let q = makeQueue(2, at: 1)
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(AppQueue.self, from: data)
        XCTAssertEqual(decoded, q)
        XCTAssertNil(decoded.displayName)
    }

    func testTrackListEntryCodableRoundTrip() throws {
        let e = TrackListEntry(index: 12708, name: "Excursions", artist: "A Tribe Called Quest", isCurrent: true)
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(TrackListEntry.self, from: data)
        XCTAssertEqual(decoded, e)
    }

    func testPersistedQueueCodableRoundTrip() throws {
        let q = makeQueue(3, at: 1, displayName: "The Low End Theory")
        let p = PersistedQueue(queue: q, anchorPersistentID: "A1B2C3D4E5F60718",
                                anchorName: "T1", anchorArtist: "A")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersistedQueue.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    func testPersistedQueueCodableRoundTripWithNilAnchorID() throws {
        // The macOS 26 -1728 bug path: persistent ID unreadable at save time.
        let q = makeQueue(2, at: 1)
        let p = PersistedQueue(queue: q, anchorPersistentID: nil, anchorName: "T1", anchorArtist: "A")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersistedQueue.self, from: data)
        XCTAssertEqual(decoded, p)
        XCTAssertNil(decoded.anchorPersistentID)
    }

    // MARK: - QueueStore

    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "queue-store-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func samplePersisted() -> PersistedQueue {
        PersistedQueue(queue: makeQueue(3, at: 2, displayName: "The Low End Theory"),
                        anchorPersistentID: "A1B2C3D4E5F60718", anchorName: "T2", anchorArtist: "A")
    }

    func testQueueStoreLoadMissingReturnsNil() {
        XCTAssertNil(QueueStore(path: tmp).load())
    }

    func testQueueStoreSaveThenLoadRoundTrip() throws {
        let store = QueueStore(path: tmp)
        let p = samplePersisted()
        try store.save(p)
        XCTAssertEqual(QueueStore(path: tmp).load(), p, "a fresh instance must read what a prior instance wrote")
    }

    func testQueueStoreCorruptFileReturnsNil() throws {
        try "not json".write(toFile: tmp, atomically: true, encoding: .utf8)
        XCTAssertNil(QueueStore(path: tmp).load())
    }

    func testQueueStoreClearDeletesFile() throws {
        let store = QueueStore(path: tmp)
        try store.save(samplePersisted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp))
        XCTAssertNil(store.load())
    }

    func testQueueStoreClearIsNoOpWhenAbsent() {
        // Must not throw/crash when there's nothing to delete.
        QueueStore(path: tmp).clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp))
    }

    func testQueueStoreCreatesIntermediateDirectories() throws {
        let dir = NSTemporaryDirectory() + "queue-store-nested-\(UUID().uuidString)"
        let nested = dir + "/sub/queue.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = QueueStore(path: nested)
        try store.save(samplePersisted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
    }

    // MARK: - queueMatches

    private func saved(currentIndex: Int, tracks: [TrackListEntry], anchorID: String?,
                        anchorName: String = "T", anchorArtist: String = "A") -> PersistedQueue {
        PersistedQueue(
            queue: AppQueue(playlistName: "P", tracks: tracks, currentIndex: currentIndex),
            anchorPersistentID: anchorID, anchorName: anchorName, anchorArtist: anchorArtist)
    }

    private func entry(_ name: String, _ artist: String, index: Int = 1) -> TrackListEntry {
        TrackListEntry(index: index, name: name, artist: artist, isCurrent: false)
    }

    func testQueueMatchesBothPersistentIDsEqual() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: "ID-1")
        XCTAssertTrue(queueMatches(playingPersistentID: "ID-1", playingName: "Excursions",
                                    playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesBothPersistentIDsDifferEvenIfNamesMatch() {
        // The mpv lesson: a different occurrence of the same name+artist must not match.
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: "ID-1")
        XCTAssertFalse(queueMatches(playingPersistentID: "ID-2", playingName: "Excursions",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesPlayingIDPresentSavedAnchorNilFallsBackToNameArtist() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertTrue(queueMatches(playingPersistentID: "ID-1", playingName: "Excursions",
                                    playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesSavedAnchorPresentPlayingIDNilFallsBackToNameArtist() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: "ID-1")
        XCTAssertTrue(queueMatches(playingPersistentID: nil, playingName: "Excursions",
                                    playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesNeitherHasIDNameArtistMatch() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertTrue(queueMatches(playingPersistentID: nil, playingName: "Excursions",
                                    playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesNameArtistIsCaseInsensitive() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertTrue(queueMatches(playingPersistentID: nil, playingName: "EXCURSIONS",
                                    playingArtist: "a tribe called quest", saved: s))
    }

    func testQueueMatchesNameArtistIsWhitespaceInsensitive() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertTrue(queueMatches(playingPersistentID: nil, playingName: "  Excursions ",
                                    playingArtist: "A  Tribe Called  Quest", saved: s))
    }

    func testQueueMatchesNameMismatchReturnsFalse() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertFalse(queueMatches(playingPersistentID: nil, playingName: "Buggin' Out",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesArtistMismatchReturnsFalse() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: nil)
        XCTAssertFalse(queueMatches(playingPersistentID: nil, playingName: "Excursions",
                                     playingArtist: "Some Other Artist", saved: s))
    }

    func testQueueMatchesUsesCurrentIndexEntryNotFirstTrack() {
        // currentIndex points at tracks[1] ("Buggin' Out"), not tracks[0].
        let tracks = [entry("Excursions", "A Tribe Called Quest", index: 1),
                      entry("Buggin' Out", "A Tribe Called Quest", index: 2)]
        let s = saved(currentIndex: 2, tracks: tracks, anchorID: nil)
        XCTAssertTrue(queueMatches(playingPersistentID: nil, playingName: "Buggin' Out",
                                    playingArtist: "A Tribe Called Quest", saved: s))
        XCTAssertFalse(queueMatches(playingPersistentID: nil, playingName: "Excursions",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesOutOfRangeCurrentIndexTooLowReturnsFalse() {
        let s = saved(currentIndex: 0, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: "ID-1")
        XCTAssertFalse(queueMatches(playingPersistentID: "ID-1", playingName: "Excursions",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesOutOfRangeCurrentIndexTooHighReturnsFalse() {
        let s = saved(currentIndex: 5, tracks: [entry("Excursions", "A Tribe Called Quest")],
                      anchorID: "ID-1")
        XCTAssertFalse(queueMatches(playingPersistentID: "ID-1", playingName: "Excursions",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    func testQueueMatchesEmptyTracksReturnsFalse() {
        let s = saved(currentIndex: 1, tracks: [], anchorID: "ID-1")
        XCTAssertFalse(queueMatches(playingPersistentID: "ID-1", playingName: "Excursions",
                                     playingArtist: "A Tribe Called Quest", saved: s))
    }

    // MARK: - queueShouldSave / queueShouldClear (poller write-cadence)

    func testQueueShouldSaveFalseWhenNoActiveQueue() {
        XCTAssertFalse(queueShouldSave(active: nil, lastWritten: makeQueue(3)))
    }

    func testQueueShouldSaveTrueOnFirstWrite() {
        // lastWritten nil (fresh poller / just-restored queue) always saves once.
        XCTAssertTrue(queueShouldSave(active: makeQueue(3), lastWritten: nil))
    }

    func testQueueShouldSaveFalseWhenUnchanged() {
        let q = makeQueue(3, at: 2)
        XCTAssertFalse(queueShouldSave(active: q, lastWritten: q))
    }

    func testQueueShouldSaveTrueWhenCurrentIndexAdvanced() {
        XCTAssertTrue(queueShouldSave(active: makeQueue(3, at: 2), lastWritten: makeQueue(3, at: 1)))
    }

    func testQueueShouldSaveTrueOnWholesaleReplacementEvenAtSameIndex() {
        // A brand-new queue (different playlist/tracks) that happens to land
        // on currentIndex 1 again must still be recognized as changed — this
        // is why the comparison is full AppQueue equality, not just the index.
        let old = makeQueue(3, at: 1, displayName: "Old Album")
        let new = AppQueue(playlistName: "Library", tracks: [TrackListEntry(index: 99, name: "New", artist: "A", isCurrent: false)],
                            currentIndex: 1, displayName: "New Album")
        XCTAssertTrue(queueShouldSave(active: new, lastWritten: old))
    }

    func testQueueShouldClearFalseWhenActive() {
        XCTAssertFalse(queueShouldClear(active: makeQueue(3), lastWritten: makeQueue(3)))
    }

    func testQueueShouldClearFalseWhenInactiveAndNothingWasEverWritten() {
        XCTAssertFalse(queueShouldClear(active: nil, lastWritten: nil))
    }

    func testQueueShouldClearTrueWhenQueueWentInactiveAfterWriting() {
        XCTAssertTrue(queueShouldClear(active: nil, lastWritten: makeQueue(3)))
    }

    // MARK: - decideQueueRestore (startup adopt/discard)

    func testDecideQueueRestoreDoNothingWhenNoSavedQueue() {
        XCTAssertEqual(decideQueueRestore(saved: nil, playerStopped: false, playingPersistentID: nil,
                                           playingName: "", playingArtist: ""), .doNothing)
    }

    func testDecideQueueRestoreDiscardsWhenPlayerStopped() {
        // Even a saved queue whose current entry WOULD match must discard —
        // stopped means nothing to resume onto.
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")], anchorID: nil)
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: true, playingPersistentID: nil,
                                           playingName: "Excursions", playingArtist: "A Tribe Called Quest"), .discard)
    }

    func testDecideQueueRestoreAdoptsOnMatch() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")], anchorID: "ID-1")
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: false, playingPersistentID: "ID-1",
                                           playingName: "Excursions", playingArtist: "A Tribe Called Quest"),
                       .adopt(s.queue))
    }

    func testDecideQueueRestoreDiscardsOnMismatch() {
        let s = saved(currentIndex: 1, tracks: [entry("Excursions", "A Tribe Called Quest")], anchorID: "ID-1")
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: false, playingPersistentID: "ID-2",
                                           playingName: "Some Other Track", playingArtist: "Some Other Artist"), .discard)
    }
}

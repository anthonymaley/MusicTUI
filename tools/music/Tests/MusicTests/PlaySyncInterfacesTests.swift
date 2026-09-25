import XCTest
@testable import music

/// The shared play-sync values: their on-disk shape, the live location, and
/// the error case every Bridge surface has to handle.
final class PlaySyncInterfacesTests: XCTestCase {

    private func fullEntry() -> PlaySyncEntry {
        PlaySyncEntry(
            ledgerID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", seq: 1,
            playID: "7D444840-9DC0-11D1-B245-5FFDCE74FAD2",
            alias: "596357614188841472", persistentID: "0846B01728D34A00",
            title: "Are You Awake? - Kevin Shields", artist: "Lost In Translation OST",
            completedAt: 1_790_300_187,
            state: .unresolved, phase: .dateOnly,
            before: TrackPlayState(count: 27, date: 1_790_000_000),
            target: TrackPlayState(count: 28, date: 1_790_300_187),
            attempt: WriteAttempt(phase: .dateOnly,
                                  process: MusicProcess(pid: 60641, startedAt: 1_790_200_000.25),
                                  startedAt: 1_790_300_200),
            observed: TrackPlayState(count: 28, date: nil),
            barrierReplans: 1, reason: "changed", reconciled: false, reported: true)
    }

    func testEntryRoundTripsThroughJSON() throws {
        let entry = fullEntry()
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(PlaySyncEntry.self, from: data), entry)
    }

    func testEntryUsesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(fullEntry())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "ledger_id", "seq", "play_id", "alias", "pid_hex", "title", "artist",
            "completed_at", "state", "phase", "before", "target", "attempt",
            "observed", "barrier_replans", "reason", "reconciled", "reported",
        ])
        XCTAssertEqual(object["pid_hex"] as? String, "0846B01728D34A00")
        XCTAssertEqual(object["state"] as? String, "unresolved")
        XCTAssertEqual(object["phase"] as? String, "date_only")

        let attempt = try XCTUnwrap(object["attempt"] as? [String: Any])
        XCTAssertEqual(Set(attempt.keys), ["phase", "process", "started_at"])
        let process = try XCTUnwrap(attempt["process"] as? [String: Any])
        XCTAssertEqual(Set(process.keys), ["pid", "started_at"])

        let before = try XCTUnwrap(object["before"] as? [String: Any])
        XCTAssertEqual(Set(before.keys), ["count", "date"])
    }

    func testPhaseAndStateWireStrings() {
        XCTAssertEqual(WritePhase.countAndDate.rawValue, "count_and_date")
        XCTAssertEqual(WritePhase.dateOnly.rawValue, "date_only")
        let states: [EntryState] = [.pending, .writing, .unresolved, .done, .unmatched, .conflict]
        XCTAssertEqual(states.map(\.rawValue), ["pending", "writing", "unresolved", "done", "unmatched", "conflict"])
    }

    /// A freshly captured entry has no plan yet; its absent values stay absent
    /// through a round trip rather than turning into zeros.
    func testPendingEntryWithoutPlanRoundTrips() throws {
        let entry = PlaySyncEntry(
            ledgerID: "L", seq: 2, playID: "P", alias: nil, persistentID: nil,
            title: "t", artist: "a", completedAt: 0,
            state: .pending, phase: .countAndDate,
            before: nil, target: nil, attempt: nil, observed: nil,
            barrierReplans: 0, reason: nil, reconciled: false, reported: false)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(PlaySyncEntry.self, from: data), entry)
    }

    func testLivePathsPointAtTheConfigFolder() {
        XCTAssertTrue(PlaySyncPaths.live.journal.path.hasSuffix("/.config/music/playsync/journal.json"),
                      PlaySyncPaths.live.journal.path)
        XCTAssertTrue(PlaySyncPaths.live.lock.path.hasSuffix("/.config/music/playsync/lock"),
                      PlaySyncPaths.live.lock.path)
    }

    func testPathsFollowTheirDirectory() {
        let paths = PlaySyncPaths(directory: URL(fileURLWithPath: "/tmp/somewhere"))
        XCTAssertEqual(paths.journal.path, "/tmp/somewhere/journal.json")
        XCTAssertEqual(paths.lock.path, "/tmp/somewhere/lock")
    }

    func testLedgerChangedReadsAsReplacedRecord() {
        XCTAssertEqual(SourceAppError.ledgerChanged("x").message, "Bridge's play record was replaced")
        XCTAssertEqual(SourceReadiness.from(SourceAppError.ledgerChanged("x")),
                       .unavailable("Bridge's play record was replaced"))
    }
}

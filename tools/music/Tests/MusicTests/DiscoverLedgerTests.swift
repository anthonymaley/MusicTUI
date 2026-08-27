import XCTest
@testable import music

final class DiscoverLedgerTests: XCTestCase {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "discover-ledger-test-\(UUID().uuidString).json"
    }

    private func entry(_ id: String, _ ids: [String]) -> DiscoverTransaction {
        DiscoverTransaction(id: id, playlistName: "__discover__ \(id)",
                            title: "Some Album", createdLibraryIDs: ids,
                            createdAt: "2026-08-26T00:00:00Z")
    }

    func testRoundTripsThroughDisk() throws {
        let path = tempPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = DiscoverLedgerStore(path: path)
        try store.save([entry("a", ["i.1", "i.2"])])
        XCTAssertEqual(store.load(), [entry("a", ["i.1", "i.2"])])
    }

    /// A missing or corrupt ledger must read as empty, never error at the user —
    /// same discipline as QueueStore. The consequence is residue, which is the
    /// safe direction.
    func testAbsentOrCorruptFileReadsAsEmpty() throws {
        let path = tempPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(DiscoverLedgerStore(path: path).load(), [])
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiscoverLedgerStore(path: path).load(), [])
    }

    /// The sweep spares the transaction whose playlist is currently playing:
    /// deleting library rows behind the playhead collapses the queue (measured).
    func testSweepSparesThePlayingTransaction() {
        let all = [entry("a", ["i.1"]), entry("b", ["i.2"]), entry("c", ["i.3"])]
        let plan = discoverSweepPlan(ledger: all, currentPlaylistName: "__discover__ b")
        XCTAssertEqual(plan.sweep.map(\.id), ["a", "c"])
        XCTAssertEqual(plan.spared.map(\.id), ["b"])
    }

    /// Two transactions can claim the same library row when both pre-checked it
    /// before either materialized. Sweeping one must not delete a row the other
    /// still needs — that would collapse the live queue.
    func testRetainedIDsAreSubtractedFromASweep() {
        let a = entry("a", ["i.1", "i.shared"])
        let b = entry("b", ["i.shared", "i.2"])
        let plan = discoverSweepPlan(ledger: [a, b], currentPlaylistName: "__discover__ b")
        XCTAssertEqual(discoverDeletableIDs(sweeping: plan.sweep, retaining: plan.spared),
                       ["i.1"], "i.shared is claimed by the playing transaction")
    }

    func testNothingIsRetainedWhenNothingIsSpared() {
        let a = entry("a", ["i.1", "i.2"])
        XCTAssertEqual(Set(discoverDeletableIDs(sweeping: [a], retaining: [])), ["i.1", "i.2"])
    }

    func testSweepTakesEverythingWhenNothingIsPlaying() {
        let all = [entry("a", ["i.1"]), entry("b", ["i.2"])]
        XCTAssertEqual(discoverSweepPlan(ledger: all, currentPlaylistName: nil).sweep.count, 2)
    }

    /// An orphan playlist — one on disk with no ledger entry, from a crash before
    /// the ledger was written — is swept as a CONTAINER ONLY. Its songs stay.
    /// Guessing at attribution here is what would delete the user's own music.
    func testOrphanPlaylistsAreContainerOnlyDeletions() {
        let plan = discoverOrphanPlan(playlistNames: ["__discover__ x", "__discover__ y", "My Mix"],
                                      ledger: [entry("x", ["i.1"])],
                                      currentPlaylistName: nil)
        XCTAssertEqual(plan, ["__discover__ y"], "only the unledgered Discover playlist, and no song ids")
    }

    func testOrphanPlanSparesThePlayingPlaylist() {
        let plan = discoverOrphanPlan(playlistNames: ["__discover__ y"],
                                      ledger: [], currentPlaylistName: "__discover__ y")
        XCTAssertTrue(plan.isEmpty)
    }
}

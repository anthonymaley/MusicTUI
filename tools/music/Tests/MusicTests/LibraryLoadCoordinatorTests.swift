// tools/music/Tests/MusicTests/LibraryLoadCoordinatorTests.swift
//
// The Library tab's three lists (albums, songs, artists) all come from ONE bulk
// AppleScript read. So the retry budget and the in-flight guard belong to the
// scene, not to each list: three independent budgets would be nine reads of a
// failing Music.app and an attempt budget multiplied by three.
import XCTest
@testable import music

final class LibraryLoadCoordinatorTests: XCTestCase {

    // MARK: - Single flight: one read at a time, whoever asks

    func testSecondCallerIsRefusedWhileAReadIsInFlight() {
        let c = LibraryLoadCoordinator()
        XCTAssertTrue(c.claimRead(), "first caller performs the read")
        XCTAssertFalse(c.claimRead(), "a second list must not start a concurrent bulk read")
        XCTAssertFalse(c.claimRead(), "nor a third")
        c.finishRead(success: true)
        XCTAssertTrue(c.claimRead(), "once finished, a fresh read may be claimed")
    }

    func testConcurrentClaimsElectExactlyOneReader() {
        let c = LibraryLoadCoordinator()
        let winners = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if c.claimRead() { lock.lock(); winners.add(1); lock.unlock() }
        }
        XCTAssertEqual(winners.count, 1, "exactly one of 24 concurrent callers may read")
    }

    // MARK: - One shared budget: three attempts TOTAL, not three per list

    func testThreeListsShareOneAttemptBudget() {
        let c = LibraryLoadCoordinator()
        for _ in 0..<3 {
            XCTAssertTrue(c.claimRead())
            c.finishRead(success: false)
        }
        XCTAssertTrue(c.exhausted, "three failures total exhausts the budget")
        XCTAssertFalse(c.claimRead(), "auto-retry stops after the budget is spent")
    }

    func testBudgetIsNotMultipliedByTheNumberOfLists() {
        let c = LibraryLoadCoordinator()
        var reads = 0
        // Albums, songs and artists each ask repeatedly, as they would on a tick.
        for _ in 0..<9 where c.claimRead() {
            reads += 1
            c.finishRead(success: false)
        }
        XCTAssertEqual(reads, 3, "nine list requests must still cost only three reads")
    }

    func testSuccessClearsTheFailureAndTheBudget() {
        let c = LibraryLoadCoordinator()
        XCTAssertTrue(c.claimRead()); c.finishRead(success: false)
        XCTAssertTrue(c.readFailed)
        XCTAssertTrue(c.claimRead()); c.finishRead(success: true)
        XCTAssertFalse(c.readFailed)
        XCTAssertFalse(c.exhausted)
    }

    // MARK: - Manual retry reopens a stopped controller

    func testManualRetryResetsTheBudgetAfterExhaustion() {
        let c = LibraryLoadCoordinator()
        for _ in 0..<3 { _ = c.claimRead(); c.finishRead(success: false) }
        XCTAssertTrue(c.exhausted)
        XCTAssertFalse(c.claimRead())

        c.manualRetry()

        XCTAssertFalse(c.exhausted, "a manual retry resets the attempt budget")
        XCTAssertTrue(c.claimRead(), "and lets a read be claimed again")
    }

    // MARK: - Empty-state text is earned only by a successful empty read

    func testEmptyTextOnlyAfterASuccessfulEmptyRead() {
        XCTAssertTrue(libraryShowsEmptyText(status: .ready, rowCount: 0))
    }

    func testNoEmptyTextWhenRowsExist() {
        XCTAssertFalse(libraryShowsEmptyText(status: .ready, rowCount: 5))
    }

    func testNoEmptyTextWhileLoading() {
        XCTAssertFalse(libraryShowsEmptyText(status: .loading, rowCount: 0))
    }

    func testNoEmptyTextWhileRetrying() {
        // The defect this whole change exists to remove.
        XCTAssertFalse(libraryShowsEmptyText(status: .unreadableRetrying, rowCount: 0),
                       "a failed read must never render as an empty library")
    }

    func testNoEmptyTextWhenExhausted() {
        XCTAssertFalse(libraryShowsEmptyText(status: .unreadableExhausted, rowCount: 0))
    }

    // MARK: - The status a subview derives from the shared controller

    func testStatusWithNoDataAndFailureIsUnreadable() {
        let c = LibraryLoadCoordinator()
        _ = c.claimRead(); c.finishRead(success: false)
        XCTAssertEqual(c.status(hasData: false), .unreadableRetrying)
    }

    func testStatusWithNoDataAndExhaustedOffersManualRetry() {
        let c = LibraryLoadCoordinator()
        for _ in 0..<3 { _ = c.claimRead(); c.finishRead(success: false) }
        XCTAssertEqual(c.status(hasData: false), .unreadableExhausted)
    }
}

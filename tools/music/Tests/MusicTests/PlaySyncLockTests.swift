import Darwin
import XCTest
@testable import music

/// The play-sync lock excludes every other holder, including another lock
/// object in the same process.
final class PlaySyncLockTests: XCTestCase {

    private var directory: URL!
    private var lockURL: URL { directory.appendingPathComponent("lock") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playsync-lock-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func acquire(wait: TimeInterval = 0) -> Result<PlaySyncLock, PlaySyncLock.Failure> {
        PlaySyncLock.acquire(lockURL, waitingUpTo: wait)
    }

    func testTwoLocksOnOneFileInOneProcessAreExclusive() throws {
        let first = try acquire().get()
        XCTAssertEqual(acquire().failureValue, .busy)
        first.release()
        XCTAssertNotNil(try? acquire().get())
    }

    func testLockFileIsCreatedPrivate() throws {
        let held = try acquire().get()
        defer { held.release() }
        let mode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testReleasingTwiceIsHarmlessAndDeinitReleases() throws {
        let held = try acquire().get()
        held.release()
        held.release()
        do {
            _ = try acquire().get()      // dropped at the end of this scope
        }
        XCTAssertNotNil(try? acquire().get())
    }

    func testWaitingGivesUpAfterItsWait() throws {
        let held = try acquire().get()
        defer { held.release() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(acquire(wait: 0.3).failureValue, .busy)
        let waited = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 3)
    }

    func testWaitingSucceedsWhenTheHolderLetsGo() throws {
        let held = try acquire().get()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { held.release() }
        let start = ProcessInfo.processInfo.systemUptime
        let second = try acquire(wait: 5).get()
        defer { second.release() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
    }

    func testSymlinkInPlaceOfTheLockIsRefused() throws {
        let elsewhere = directory.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: elsewhere.path, contents: nil)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: elsewhere)
        guard case .unavailable = acquire().failureValue else { return XCTFail("a symlinked lock was used") }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

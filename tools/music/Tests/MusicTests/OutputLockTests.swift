// tools/music/Tests/MusicTests/OutputLockTests.swift
//
// The cross-process output lock's primitive (slice 3 score, D6 and S1).
//
// Separate descriptors on one path conflict under flock(2) even inside one
// process, so two `OutputLock` instances on two threads stand in for two
// processes. Waits are barriers (semaphores) and an injected pause and clock;
// nothing here sleeps. The one real second process is the perl child that
// proves a SIGKILLed holder leaves no stale lock.
import XCTest
@testable import music

/// A fake clock that only moves when a pause moves it.
final class OutputLockFakeClock {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ by: TimeInterval) { lock.lock(); current += by; lock.unlock() }
}

/// Opens once and stays open: a waiter's pause blocks on it until the test says
/// the holder has let go. The 10 s bound only stops a broken test hanging the
/// suite; it is never how an ordering is produced.
final class OutputLockLatch {
    private let sem = DispatchSemaphore(value: 0)
    func open() { sem.signal() }
    func wait() {
        if sem.wait(timeout: .now() + 10) == .success { sem.signal() }
    }
}

/// Thread-safe ordered log.
final class OutputLockLog {
    private let lock = NSLock()
    private var entries: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func append(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
}

/// Test helpers shared by both lock test files.
enum OutputLockTestSupport {
    static func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "music-test-outputlock-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when a fresh descriptor can take the lock at once, released again
    /// before returning. This is how a test asks "is anyone holding it?"
    static func isFree(_ path: String) -> Bool {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// A waiter that never really waits: each pause advances the fake clock.
    static func advancingLock(path: String, clock: OutputLockFakeClock,
                              onWaiting: (() -> Void)? = nil) -> OutputLock {
        OutputLock(path: path, pollInterval: 0.5,
                   clock: { clock.now }, pause: { clock.advance($0) },
                   onWaiting: onWaiting)
    }

    /// A waiter whose pause blocks on `latch`; its clock advances per pause so
    /// a latch opened too early still ends in a bounded refusal, not a hang.
    static func latchedLock(path: String, latch: OutputLockLatch,
                            onWaiting: (() -> Void)? = nil) -> OutputLock {
        let clock = OutputLockFakeClock()
        return OutputLock(path: path, pollInterval: 0.001,
                          clock: { clock.now },
                          pause: { latch.wait(); clock.advance($0) },
                          onWaiting: onWaiting)
    }
}

/// Holds `lock` on a background thread until released.
final class BackgroundHolder {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchGroup()
    private(set) var result: Result<String, Error>?

    init(_ lock: OutputLock, timeout: TimeInterval = OutputLock.defaultTimeout) {
        done.enter()
        DispatchQueue.global().async {
            do {
                let value = try lock.withLock(timeout: timeout) { () -> String in
                    self.acquired.signal()
                    self.release.wait()
                    return "holder finished"
                }
                self.result = .success(value)
            } catch {
                self.result = .failure(error)
            }
            self.done.leave()
        }
    }
}

final class OutputLockTests: XCTestCase {

    private typealias S = OutputLockTestSupport

    // MARK: exclusion

    func testTwoInstancesExcludeEachOther() throws {
        let path = S.tempDir() + "/output.lock"
        let holder = BackgroundHolder(OutputLock(path: path))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)

        XCTAssertFalse(S.isFree(path), "a held lock must refuse another descriptor")
        let clock = OutputLockFakeClock()
        var ran = 0
        XCTAssertThrowsError(try S.advancingLock(path: path, clock: clock).withLock(timeout: 1) { ran += 1 }) { error in
            XCTAssertEqual(error as? OutputLockError, .busy)
        }
        XCTAssertEqual(ran, 0, "the second instance's body ran while the first held the lock")

        holder.release.signal()
        XCTAssertEqual(holder.done.wait(timeout: .now() + 5), .success)
        try S.advancingLock(path: path, clock: clock).withLock(timeout: 0) { ran += 1 }
        XCTAssertEqual(ran, 1)
    }

    // MARK: release

    func testReleasedOnNormalReturn() throws {
        let path = S.tempDir() + "/output.lock"
        let value = try OutputLock(path: path).withLock { () -> Int in
            XCTAssertFalse(S.isFree(path), "not held inside the body")
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertTrue(S.isFree(path), "still held after a normal return")
    }

    func testReleasedOnThrow() {
        struct Boom: Error {}
        let path = S.tempDir() + "/output.lock"
        XCTAssertThrowsError(try OutputLock(path: path).withLock { throw Boom() }) { error in
            XCTAssertTrue(error is Boom, "the body's error must pass through untouched")
        }
        XCTAssertTrue(S.isFree(path), "still held after the body threw")
    }

    /// flock belongs to the open file description, so closing the descriptor
    /// is the release: a holder that closes (or dies) frees the lock with no
    /// unlock call, and a waiter gets it at once.
    func testReleasedWhenTheHoldingDescriptorCloses() throws {
        let path = S.tempDir() + "/output.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let clock = OutputLockFakeClock()
        XCTAssertThrowsError(try S.advancingLock(path: path, clock: clock).withLock(timeout: 0) {})
        close(fd)

        var waited = 0
        var ran = false
        try S.advancingLock(path: path, clock: clock, onWaiting: { waited += 1 }).withLock(timeout: 0) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertEqual(waited, 0, "a closed descriptor left the lock held")
    }

    func testTheLockFileIsNeverDeleted() throws {
        let path = S.tempDir() + "/output.lock"
        try OutputLock(path: path).withLock {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCreatesAMissingParentDirectory() throws {
        let path = S.tempDir() + "/not-yet/output.lock"
        var ran = false
        try OutputLock(path: path).withLock { ran = true }
        XCTAssertTrue(ran)
    }

    // MARK: FD_CLOEXEC

    /// A child (`open`, `osascript`, a detached `__watch-container`) must not
    /// inherit the descriptor and prolong the lock past this process's release.
    func testTheDescriptorIsCloseOnExec() throws {
        let path = S.tempDir() + "/output.lock"
        let lock = OutputLock(path: path)
        XCTAssertNil(lock.heldDescriptor)
        try lock.withLock {
            guard let fd = lock.heldDescriptor else { return XCTFail("no descriptor while held") }
            let flags = fcntl(fd, F_GETFD)
            XCTAssertNotEqual(flags, -1)
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "the lock descriptor would leak into child processes")
        }
        XCTAssertNil(lock.heldDescriptor, "the descriptor is still recorded after release")
    }

    // MARK: waiting and the 30 s bound

    func testTheDefaultBoundIsThirtySeconds() {
        XCTAssertEqual(OutputLock.defaultTimeout, 30)
    }

    /// The bound is on the WAITER's attempt, never the holder's run: the
    /// waiter gives up with the refusal sentence and the holder carries on,
    /// still holding, and finishes normally.
    func testAWaiterTimesOutAfterThirtyFakeSecondsAndTheHolderIsUntouched() {
        let path = S.tempDir() + "/output.lock"
        let holder = BackgroundHolder(OutputLock(path: path))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)

        let clock = OutputLockFakeClock()
        let start = clock.now
        var waited = 0
        var ran = 0
        let waiter = S.advancingLock(path: path, clock: clock, onWaiting: { waited += 1 })
        XCTAssertThrowsError(try waiter.withLock { ran += 1 }) { error in
            XCTAssertEqual(error as? OutputLockError, .busy)
            XCTAssertEqual((error as? OutputLockError)?.message(for: .cli),
                           "Output is being switched; nothing was changed. Try again.")
            XCTAssertEqual((error as? OutputLockError)?.message(for: .tui),
                           "A music command is changing playback; nothing was switched.")
        }
        let elapsed = clock.now.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 30, "gave up before the bound")
        XCTAssertLessThan(elapsed, 31, "waited past the bound")
        XCTAssertEqual(waited, 1, "onWaiting fires once, when the wait begins")
        XCTAssertEqual(ran, 0)

        XCTAssertFalse(S.isFree(path), "the waiter's timeout disturbed the holder's lock")
        holder.release.signal()
        XCTAssertEqual(holder.done.wait(timeout: .now() + 5), .success)
        if case .success(let v)? = holder.result {
            XCTAssertEqual(v, "holder finished")
        } else {
            XCTFail("the holder did not finish normally: \(String(describing: holder.result))")
        }
        XCTAssertTrue(S.isFree(path))
    }

    /// Still inside the bound, a waiter that finds the lock released takes it.
    func testAWaiterAcquiresOnceTheHolderReleases() throws {
        let path = S.tempDir() + "/output.lock"
        let holder = BackgroundHolder(OutputLock(path: path))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)

        let latch = OutputLockLatch()
        let waiting = DispatchSemaphore(value: 0)
        let log = OutputLockLog()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            do {
                try S.latchedLock(path: path, latch: latch, onWaiting: { waiting.signal() })
                    .withLock { log.append("waiter ran") }
            } catch {
                log.append("waiter failed: \(error)")
            }
            done.leave()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.all, [])
        holder.release.signal()
        XCTAssertEqual(holder.done.wait(timeout: .now() + 5), .success)
        latch.open()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.all, ["waiter ran"])
    }

    // MARK: fail closed

    func testAnUnopenablePathRefusesNamingThePathAndTheError() {
        let dir = S.tempDir()
        let file = dir + "/a-file"
        FileManager.default.createFile(atPath: file, contents: Data())
        let path = file + "/output.lock"
        var ran = 0
        XCTAssertThrowsError(try OutputLock(path: path).withLock { ran += 1 }) { error in
            guard case .unavailable(let p, let reason)? = error as? OutputLockError else {
                return XCTFail("expected .unavailable, got \(error)")
            }
            XCTAssertEqual(p, path)
            XCTAssertFalse(reason.isEmpty)
            for surface in InvocationSurface.allCases {
                let message = (error as? OutputLockError)?.message(for: surface) ?? ""
                XCTAssertTrue(message.contains(path), "\(surface) refusal does not name the path: \(message)")
                XCTAssertTrue(message.contains(reason), "\(surface) refusal does not name the error: \(message)")
            }
            XCTAssertEqual((error as? OutputLockError)?.message(for: .cli),
                           "Couldn't open the output lock at \(path) (\(reason)); nothing was changed.")
            XCTAssertEqual((error as? OutputLockError)?.message(for: .tui),
                           "Couldn't open the output lock at \(path) (\(reason)); nothing was switched.")
        }
        XCTAssertEqual(ran, 0, "an unopenable lock must fail closed")
    }

    // MARK: re-entry

    static let internalError = "Internal error: a playback action started another inside itself"

    func testSameThreadReentryOnTheSameInstanceThrows() throws {
        let path = S.tempDir() + "/output.lock"
        let lock = OutputLock(path: path)
        var inner = 0
        try lock.withLock {
            XCTAssertThrowsError(try lock.withLock { inner += 1 }) { error in
                XCTAssertEqual((error as? ActionError)?.message, Self.internalError)
            }
            XCTAssertFalse(S.isFree(path), "the failed re-entry released the outer hold")
        }
        XCTAssertEqual(inner, 0)
        XCTAssertTrue(S.isFree(path))
    }

    /// A second instance on the same path, on the same thread, would wait on
    /// its own process for 30 s. It throws instead.
    func testSameThreadReentryThroughAnotherInstanceOnThePathThrows() throws {
        let path = S.tempDir() + "/output.lock"
        var inner = 0
        let clock = OutputLockFakeClock()
        try OutputLock(path: path).withLock {
            XCTAssertThrowsError(try S.advancingLock(path: path, clock: clock).withLock { inner += 1 }) { error in
                XCTAssertEqual((error as? ActionError)?.message, Self.internalError)
            }
        }
        XCTAssertEqual(inner, 0)
        // The marker is cleared on release: the same thread may take it again.
        try OutputLock(path: path).withLock { inner += 1 }
        XCTAssertEqual(inner, 1)
    }

    // MARK: sentences

    func testModeChangedSentences() {
        XCTAssertEqual(OutputLock.cliModeChangedMessage(now: .musicApp),
                       "Output changed to Music.app while this command ran; nothing was changed.")
        XCTAssertEqual(OutputLock.cliModeChangedMessage(now: .source),
                       "Output changed to Bridge while this command ran; nothing was changed.")
        XCTAssertEqual(OutputLock.tuiModeChangedMessage,
                       "Output was changed by another MusicTUI process; nothing was switched.")
    }

    // MARK: process exit

    /// A holder killed with SIGKILL runs no cleanup at all; the kernel closes
    /// its descriptors, and with them the lock. No stale lock survives.
    func testALockHeldByAKilledProcessIsReleased() throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else {
            throw XCTSkip("perl is not available at \(perl)")
        }
        let path = S.tempDir() + "/output.lock"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: perl)
        child.arguments = ["-e", """
            use Fcntl qw(:flock);
            open(my $fh, '>>', $ARGV[0]) or die "open: $!";
            flock($fh, LOCK_EX) or die "flock: $!";
            $| = 1; print "locked\\n";
            sleep 600;
            """, path]
        let out = Pipe()
        child.standardOutput = out
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let line = String(data: out.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        XCTAssertEqual(line.trimmingCharacters(in: .whitespacesAndNewlines), "locked",
                       "the child never reported holding the lock")

        let clock = OutputLockFakeClock()
        var ran = 0
        XCTAssertThrowsError(try S.advancingLock(path: path, clock: clock).withLock(timeout: 0) { ran += 1 }) { error in
            XCTAssertEqual(error as? OutputLockError, .busy, "the child's lock did not conflict with ours")
        }

        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)

        try S.advancingLock(path: path, clock: clock).withLock(timeout: 0) { ran += 1 }
        XCTAssertEqual(ran, 1, "a dead process's lock survived it")
    }
}

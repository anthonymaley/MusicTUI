import XCTest
import Darwin
@testable import music

/// Whether one specific Music.app instance, identified by pid and start time,
/// has verifiably exited. Only the test process itself is inspected here.
final class MusicInstanceInspectionTests: XCTestCase {

    // MARK: - classifyInstance (pure)

    func testSameStartTimeIsAlive() {
        XCTAssertEqual(classifyInstance(.success(1_758_700_000.123456), expectedStart: 1_758_700_000.123456), .alive)
    }

    func testDifferentStartTimeIsExited() {
        // The pid now belongs to a different process.
        XCTAssertEqual(classifyInstance(.success(1_758_700_001.123456), expectedStart: 1_758_700_000.123456), .exited)
    }

    func testNoSuchProcessIsExited() {
        XCTAssertEqual(classifyInstance(.failure(ProcessInspectionErrno(code: ESRCH)), expectedStart: 1_758_700_000.123456), .exited)
    }

    func testOtherFailuresAreUnknown() {
        XCTAssertEqual(classifyInstance(.failure(ProcessInspectionErrno(code: EPERM)), expectedStart: 1_758_700_000.123456), .unknown)
        XCTAssertEqual(classifyInstance(.failure(ProcessInspectionErrno(code: EINVAL)), expectedStart: 1_758_700_000.123456), .unknown)
        XCTAssertEqual(classifyInstance(.failure(ProcessInspectionErrno(code: 0)), expectedStart: 1_758_700_000.123456), .unknown)
    }

    // MARK: - processStartTime (the test process only)

    func testStartTimeOfThisProcessSucceeds() throws {
        let start = try processStartTime(pid: getpid()).get()
        XCTAssertGreaterThan(start, 0)
        XCTAssertLessThanOrEqual(start, Date().timeIntervalSince1970)
    }

    func testStartTimeIsStableAcrossCalls() throws {
        let first = try processStartTime(pid: getpid()).get()
        let second = try processStartTime(pid: getpid()).get()
        XCTAssertEqual(first, second)
    }

    // MARK: - ProcMusicInstanceInspector (the test process only)

    func testInspectorReportsThisProcessAlive() throws {
        let start = try processStartTime(pid: getpid()).get()
        let inspector = ProcMusicInstanceInspector()
        XCTAssertEqual(inspector.state(of: MusicProcess(pid: getpid(), startedAt: start)), .alive)
    }

    func testInspectorReportsMovedStartTimeExited() throws {
        let start = try processStartTime(pid: getpid()).get()
        let inspector = ProcMusicInstanceInspector()
        XCTAssertEqual(inspector.state(of: MusicProcess(pid: getpid(), startedAt: start + 1)), .exited)
        XCTAssertEqual(inspector.state(of: MusicProcess(pid: getpid(), startedAt: start - 1)), .exited)
    }
}

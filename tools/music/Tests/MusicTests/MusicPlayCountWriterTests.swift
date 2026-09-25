import Foundation
import ScriptingBridge
import XCTest
@testable import music

/// The staged read and write, through a fake session. No test here builds a
/// ScriptingBridge application object or sends anything to Music.app.
final class MusicPlayCountWriterTests: XCTestCase {
    private let hex = "D7C69C6A85560CD8"
    private let proc = MusicProcess(pid: 4413, startedAt: 1_790_000_000.5)
    private let before = TrackPlayState(count: 27, date: 1_790_100_000)
    private let target = TrackPlayState(count: 28, date: 1_790_200_000)

    private func writer(_ session: FakeSession?, found: MusicProcess? = nil) -> MusicPlayCountWriter {
        let located = found ?? proc
        return MusicPlayCountWriter(locate: { located }, openSession: { _ in session })
    }

    private func readError(_ w: MusicPlayCountWriter) -> MusicAccessError? {
        do {
            _ = try w.read(proc, persistentID: hex)
            return nil
        } catch let error as MusicAccessError {
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    // MARK: read

    func testReadFoundGivesTheState() throws {
        let s = FakeSession(states: [before])
        XCTAssertEqual(try writer(s).read(proc, persistentID: hex), .found(before))
    }

    func testReadNoMatchGivesTheLibraryTrackCount() throws {
        let s = FakeSession(matchCount: .success(0), libraryTrackCount: .success(8123))
        XCTAssertEqual(try writer(s).read(proc, persistentID: hex), .notFound(libraryTrackCount: 8123))
    }

    func testReadNoMatchInAnEmptyLibraryGivesZero() throws {
        let s = FakeSession(matchCount: .success(0), libraryTrackCount: .success(0))
        XCTAssertEqual(try writer(s).read(proc, persistentID: hex), .notFound(libraryTrackCount: 0))
    }

    func testReadSeveralMatchesIsAmbiguous() throws {
        let s = FakeSession(matchCount: .success(2))
        XCTAssertEqual(try writer(s).read(proc, persistentID: hex), .ambiguous(matches: 2))
        XCTAssertFalse(s.calls.contains("playState"))
    }

    func testReadCodeMappingAtMatchCount() {
        let cases: [(Int, MusicAccessError)] = [
            (-600, .notRunning),
            (-609, .notRunning),
            (-1712, .timedOut),
            (-1743, .failed("Music.app automation is not permitted for this terminal")),
            (-10004, .failed("Music.app error -10004")),
            (-1728, .failed("Music.app error -1728")),
        ]
        for (code, expected) in cases {
            let s = FakeSession(matchCount: .failure(AEFailure(code: code, message: "m")))
            XCTAssertEqual(readError(writer(s)), expected, "code \(code)")
        }
    }

    func testReadCodeMappingAtPlayState() {
        let s = FakeSession(states: [], playStateFailures: [AEFailure(code: -609, message: "gone")])
        XCTAssertEqual(readError(writer(s)), .notRunning)
        let t = FakeSession(states: [], playStateFailures: [AEFailure(code: -1712, message: "slow")])
        XCTAssertEqual(readError(writer(t)), .timedOut)
    }

    func testReadCodeMappingAtLibraryTrackCount() {
        let s = FakeSession(matchCount: .success(0),
                            libraryTrackCount: .failure(AEFailure(code: -600, message: "gone")))
        XCTAssertEqual(readError(writer(s)), .notRunning)
    }

    func testUnexpectedResultIsItsOwnMessage() {
        let s = FakeSession(matchCount: .failure(AEFailure(code: -1, message: "unexpected scripting result")))
        XCTAssertEqual(readError(writer(s)), .failed("unexpected scripting result"))
    }

    func testReadNotRunningWhenNoSessionOpens() {
        XCTAssertEqual(readError(writer(nil)), .notRunning)
    }

    func testReadNotRunningWhenTheProcessChanged() {
        let s = FakeSession(states: [before])
        let restarted = MusicProcess(pid: proc.pid, startedAt: proc.startedAt + 1)
        XCTAssertEqual(readError(writer(s, found: restarted)), .notRunning)
        XCTAssertEqual(s.calls, [])
    }

    func testReadNotRunningWhenMusicIsGone() {
        let s = FakeSession(states: [before])
        let w = MusicPlayCountWriter(locate: { nil }, openSession: { _ in s })
        XCTAssertEqual(readError(w), .notRunning)
        XCTAssertEqual(s.calls, [])
    }

    // MARK: write, before any set

    func testWriteNotRunningWhenNoSessionOpens() {
        XCTAssertEqual(writer(nil).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "not running"))
    }

    func testWriteNotRunningWhenTheProcessChanged() {
        let s = FakeSession(states: [before])
        let other = MusicProcess(pid: proc.pid + 1, startedAt: proc.startedAt)
        XCTAssertEqual(writer(s, found: other).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "not running"))
        XCTAssertEqual(s.calls, [])
    }

    func testWriteNoMatch() {
        let s = FakeSession(matchCount: .success(0))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "no match"))
        XCTAssertTrue(s.sets.isEmpty)
    }

    func testWriteSeveralMatches() {
        let s = FakeSession(matchCount: .success(3))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "matches=3"))
        XCTAssertTrue(s.sets.isEmpty)
    }

    func testWriteFailureAtMatchCountIsNotSent() {
        let s = FakeSession(matchCount: .failure(AEFailure(code: -600, message: "gone")))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "not running"))
        XCTAssertTrue(s.sets.isEmpty)
    }

    func testWriteFailureAtRecheckIsNotSent() {
        let s = FakeSession(states: [], playStateFailures: [AEFailure(code: -1712, message: "slow")])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: nil, reason: "timed out"))
        let t = FakeSession(states: [], playStateFailures: [AEFailure(code: -1743, message: "denied")])
        XCTAssertEqual(writer(t).writeDate(proc, persistentID: hex, expect: before, date: 1_790_200_000),
                       .notSent(current: nil, reason: "Music.app automation is not permitted for this terminal"))
        XCTAssertTrue(s.sets.isEmpty)
        XCTAssertTrue(t.sets.isEmpty)
    }

    func testRecheckMismatchIsNotSentWithTheStateAndNoSetCall() {
        let moved = TrackPlayState(count: 28, date: 1_790_150_000)
        let s = FakeSession(states: [moved])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .notSent(current: moved, reason: "changed"))
        XCTAssertTrue(s.sets.isEmpty)
        let t = FakeSession(states: [moved])
        XCTAssertEqual(writer(t).writeDate(proc, persistentID: hex, expect: before, date: 1_790_200_000),
                       .notSent(current: moved, reason: "changed"))
        XCTAssertTrue(t.sets.isEmpty)
    }

    // MARK: write, after a set

    func testSetPlayedCountFailureIsUnknown() {
        let s = FakeSession(states: [before], countSet: .failure(AEFailure(code: -1712, message: "slow")))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .unknown("timed out"))
        XCTAssertEqual(s.sets, ["count 28"])
    }

    func testSetPlayedCountNotRunningIsStillUnknown() {
        let s = FakeSession(states: [before], countSet: .failure(AEFailure(code: -600, message: "gone")))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .unknown("not running"))
    }

    func testSetPlayedDateFailureAfterACountSetIsCountAppliedDateUnknown() {
        let s = FakeSession(states: [before], dateSet: .failure(AEFailure(code: -1712, message: "slow")))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .countAppliedDateUnknown("timed out"))
        XCTAssertEqual(s.sets, ["count 28", "date 1790200000"])
    }

    func testSetPlayedDateFailureInWriteDateIsUnknown() {
        let expect = TrackPlayState(count: 28, date: 1_790_100_000)
        let s = FakeSession(states: [expect], dateSet: .failure(AEFailure(code: -609, message: "gone")))
        XCTAssertEqual(writer(s).writeDate(proc, persistentID: hex, expect: expect, date: 1_790_200_000),
                       .unknown("not running"))
        XCTAssertEqual(s.sets, ["date 1790200000"])
    }

    func testSetPlayedDateFailureWhenNoCountWasSetIsUnknown() {
        // The count already matches the target, so only the date is set.
        let expect = TrackPlayState(count: 28, date: 1_790_100_000)
        let s = FakeSession(states: [expect], dateSet: .failure(AEFailure(code: -1712, message: "slow")))
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: expect, target: target),
                       .unknown("timed out"))
        XCTAssertEqual(s.sets, ["date 1790200000"])
    }

    func testReadbackFailureIsUnknown() {
        let s = FakeSession(states: [before], playStateFailures: [nil, AEFailure(code: -1712, message: "slow")])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .unknown("timed out"))
        let t = FakeSession(states: [TrackPlayState(count: 28, date: 1_790_100_000)],
                            playStateFailures: [nil, AEFailure(code: -600, message: "gone")])
        XCTAssertEqual(writer(t).writeDate(proc, persistentID: hex,
                                           expect: TrackPlayState(count: 28, date: 1_790_100_000),
                                           date: 1_790_200_000),
                       .unknown("not running"))
    }

    func testReadbackFailureWithNoSetCallIsNotSent() {
        // Nothing differed, so nothing was submitted.
        let s = FakeSession(states: [target], playStateFailures: [nil, AEFailure(code: -1712, message: "slow")])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: target, target: target),
                       .notSent(current: nil, reason: "timed out"))
        XCTAssertTrue(s.sets.isEmpty)
    }

    func testSuccessGivesTheReadback() {
        let s = FakeSession(states: [before])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .applied(target))
        XCTAssertEqual(s.calls, ["matchCount", "playState", "setPlayedCount", "setPlayedDate", "playState"])
    }

    func testSuccessReportsWhateverWasReadBack() {
        let other = TrackPlayState(count: 29, date: 1_790_300_000)
        let s = FakeSession(states: [before], readbackOverride: other)
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: before, target: target),
                       .applied(other))
    }

    func testWriteDateSuccess() {
        let expect = TrackPlayState(count: 28, date: 1_790_100_000)
        let s = FakeSession(states: [expect])
        XCTAssertEqual(writer(s).writeDate(proc, persistentID: hex, expect: expect, date: 1_790_200_000),
                       .applied(target))
    }

    // MARK: set order

    func testCountIsSetBeforeTheDate() {
        let s = FakeSession(states: [before])
        _ = writer(s).write(proc, persistentID: hex, expect: before, target: target)
        XCTAssertEqual(s.sets, ["count 28", "date 1790200000"])
    }

    func testANeverPlayedTrackGetsBothSets() {
        let never = TrackPlayState(count: 0, date: nil)
        let s = FakeSession(states: [never])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: never,
                                       target: TrackPlayState(count: 1, date: 1_790_200_000)),
                       .applied(TrackPlayState(count: 1, date: 1_790_200_000)))
        XCTAssertEqual(s.sets, ["count 1", "date 1790200000"])
    }

    func testAMatchingDateIsNotSet() {
        let sameDate = TrackPlayState(count: 27, date: 1_790_200_000)
        let s = FakeSession(states: [sameDate])
        XCTAssertEqual(writer(s).write(proc, persistentID: hex, expect: sameDate, target: target),
                       .applied(target))
        XCTAssertEqual(s.sets, ["count 28"])
    }

    func testAMatchingCountIsNotSet() {
        let sameCount = TrackPlayState(count: 28, date: 1_790_100_000)
        let s = FakeSession(states: [sameCount])
        _ = writer(s).write(proc, persistentID: hex, expect: sameCount, target: target)
        XCTAssertEqual(s.sets, ["date 1790200000"])
    }

    func testWriteDateNeverSetsTheCount() {
        let expect = TrackPlayState(count: 27, date: 1_790_100_000)
        let s = FakeSession(states: [expect])
        _ = writer(s).writeDate(proc, persistentID: hex, expect: expect, date: 1_790_200_000)
        XCTAssertEqual(s.sets, ["date 1790200000"])
        XCTAssertFalse(s.calls.contains("setPlayedCount"))
    }

    // MARK: validation

    func testInvalidPersistentIDIsRejectedBeforeAnySessionCall() {
        for bad in ["d7c69c6a85560cd8", "D7C69C6A85560CD", "D7C69C6A85560CD8A", "", "D7C69C6A85560CDG",
                    " 7C69C6A85560CD8", "-1"] {
            var opened = false
            let s = FakeSession(states: [before])
            let w = MusicPlayCountWriter(locate: { self.proc }, openSession: { _ in opened = true; return s })
            XCTAssertThrowsError(try w.read(proc, persistentID: bad), bad)
            XCTAssertEqual(w.write(proc, persistentID: bad, expect: before, target: target),
                           .notSent(current: nil, reason: "invalid persistent ID"), bad)
            XCTAssertEqual(w.writeDate(proc, persistentID: bad, expect: before, date: 1),
                           .notSent(current: nil, reason: "invalid persistent ID"), bad)
            XCTAssertFalse(opened, bad)
            XCTAssertEqual(s.calls, [], bad)
        }
        XCTAssertTrue(isPersistentIDHex("0000000000000000"))
        XCTAssertTrue(isPersistentIDHex("FFFFFFFFFFFFFFFF"))
    }

    // MARK: the delegate

    /// Built on its own: capturing a failure needs no application object.
    func testFailureCaptureRecordsTheCodeAndReturnsNil() {
        let capture = AppleEventFailureCapture()
        var event = AppleEvent()
        let returned = withUnsafePointer(to: &event) {
            capture.eventDidFail($0, withError: NSError(domain: NSOSStatusErrorDomain, code: -600))
        }
        XCTAssertNil(returned)
        XCTAssertEqual(capture.failure?.code, -600)
        capture.reset()
        XCTAssertNil(capture.failure)
    }

    func testFailureCaptureKeepsTheFirstFailureOfAStage() {
        let capture = AppleEventFailureCapture()
        var event = AppleEvent()
        withUnsafePointer(to: &event) {
            _ = capture.eventDidFail($0, withError: NSError(domain: NSOSStatusErrorDomain, code: -600))
            _ = capture.eventDidFail($0, withError: NSError(domain: NSOSStatusErrorDomain, code: -1728))
        }
        XCTAssertEqual(capture.failure?.code, -600)
    }
}

/// A scripted Music.app library holding one track. Sets change the track's
/// state, so a readback sees them.
private final class FakeSession: MusicLibrarySession {
    private var matchResult: Result<Int, AEFailure>
    private var libraryResult: Result<Int, AEFailure>
    private var state: TrackPlayState?
    /// Per `playState` call, in order: a failure, or nil for success.
    private var playStateFailures: [AEFailure?]
    private let countSet: Result<Void, AEFailure>
    private let dateSet: Result<Void, AEFailure>
    private let readbackOverride: TrackPlayState?
    private var playStateCalls = 0
    private(set) var calls: [String] = []
    private(set) var sets: [String] = []

    init(matchCount: Result<Int, AEFailure> = .success(1),
         libraryTrackCount: Result<Int, AEFailure> = .success(100),
         states: [TrackPlayState] = [],
         playStateFailures: [AEFailure?] = [],
         countSet: Result<Void, AEFailure> = .success(()),
         dateSet: Result<Void, AEFailure> = .success(()),
         readbackOverride: TrackPlayState? = nil) {
        self.matchResult = matchCount
        self.libraryResult = libraryTrackCount
        self.state = states.first
        self.playStateFailures = playStateFailures
        self.countSet = countSet
        self.dateSet = dateSet
        self.readbackOverride = readbackOverride
    }

    func matchCount(persistentID: String) -> Result<Int, AEFailure> {
        calls.append("matchCount")
        return matchResult
    }

    func libraryTrackCount() -> Result<Int, AEFailure> {
        calls.append("libraryTrackCount")
        return libraryResult
    }

    func playState(persistentID: String) -> Result<TrackPlayState, AEFailure> {
        calls.append("playState")
        defer { playStateCalls += 1 }
        if playStateCalls < playStateFailures.count, let failure = playStateFailures[playStateCalls] {
            return .failure(failure)
        }
        if playStateCalls > 0, let readbackOverride { return .success(readbackOverride) }
        guard let state else { return .failure(AEFailure(code: -1, message: "no state scripted")) }
        return .success(state)
    }

    func setPlayedCount(_ n: Int, persistentID: String) -> Result<Void, AEFailure> {
        calls.append("setPlayedCount")
        sets.append("count \(n)")
        if case .success = countSet, let s = state { state = TrackPlayState(count: n, date: s.date) }
        return countSet
    }

    func setPlayedDate(_ epoch: Int, persistentID: String) -> Result<Void, AEFailure> {
        calls.append("setPlayedDate")
        sets.append("date \(epoch)")
        if case .success = dateSet, let s = state { state = TrackPlayState(count: s.count, date: epoch) }
        return dateSet
    }
}

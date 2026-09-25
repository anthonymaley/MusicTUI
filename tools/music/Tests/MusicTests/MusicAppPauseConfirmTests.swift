import XCTest
@testable import music

/// S1D: the switch away from Music.app needs evidence that Music.app is not
/// playing. Before this, the Output tab's Music.app pause was
/// `_ = try? … "pause"; return true`, so a failed pause still read as paused and
/// a switch to Bridge could commit with Music.app playing.
///
/// Every test here uses a fake session and a fake process probe. Nothing in this
/// file builds a ScriptingBridge object, runs AppleScript or reads the live
/// process table, so Music.app is never touched, let alone launched.
final class MusicAppPauseConfirmTests: XCTestCase {

    // MARK: - Fakes

    private struct FakeFailure: Error {}

    /// A session bound to one process. Its only calls are the two the switch
    /// needs; there is no name-addressed or launching call to make.
    private final class FakeSession: MusicAppPauseSession {
        var calls: [String] = []
        var pauseResult: Result<Void, Error> = .success(())
        var stateResult: Result<MusicAppPlayerState, Error> = .success(.paused)
        /// Runs after `pause`, before the state read: a process that quits here.
        var afterPause: () -> Void = {}

        func pause() throws {
            calls.append("pause")
            defer { afterPause() }
            try pauseResult.get()
        }

        func playerState() throws -> MusicAppPlayerState {
            calls.append("playerState")
            return try stateResult.get()
        }
    }

    /// Answers each `isRunning` call from a script, recording how many were made.
    private final class FakeProbe {
        private var answers: [Bool]
        private(set) var checks = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func isRunning() -> Bool {
            checks += 1
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }

    private func confirm(_ session: FakeSession?, _ probe: FakeProbe,
                         opened: UnsafeMutablePointer<Int>? = nil) throws -> Bool {
        try confirmMusicAppNotPlaying(session: {
            opened?.pointee += 1
            return session
        }, isRunning: probe.isRunning)
    }

    // MARK: - The decision

    func testNoMusicAppProcessIsAbsenceAndSendsNothing() throws {
        let session = FakeSession()
        let probe = FakeProbe([false])
        var opened = 0
        XCTAssertTrue(try confirm(session, probe, opened: &opened))
        XCTAssertEqual(opened, 0, "no session is opened when there is no process")
        XCTAssertEqual(session.calls, [], "no event is sent")
    }

    /// A failed pause is not a verdict: the state read through the same session
    /// decides.
    func testAFailedPauseThenPausedConfirms() throws {
        let session = FakeSession()
        session.pauseResult = .failure(FakeFailure())
        session.stateResult = .success(.paused)
        XCTAssertTrue(try confirm(session, FakeProbe([true])))
        XCTAssertEqual(session.calls, ["pause", "playerState"])
    }

    func testPausedConfirms() throws {
        let session = FakeSession()
        XCTAssertTrue(try confirm(session, FakeProbe([true])))
        XCTAssertEqual(session.calls, ["pause", "playerState"])
    }

    func testStoppedConfirms() throws {
        let session = FakeSession()
        session.stateResult = .success(.stopped)
        XCTAssertTrue(try confirm(session, FakeProbe([true])))
    }

    func testStillPlayingDoesNotConfirm() throws {
        for state in [MusicAppPlayerState.playing, .fastForwarding, .rewinding] {
            let session = FakeSession()
            session.stateResult = .success(state)
            XCTAssertFalse(try confirm(session, FakeProbe([true])), "\(state)")
        }
    }

    /// The process is still there, but its state cannot be read: uncertainty,
    /// which never reads as absence.
    func testAnUnreadableStateThrows() {
        let session = FakeSession()
        session.stateResult = .failure(FakeFailure())
        XCTAssertThrowsError(try confirm(session, FakeProbe([true, true])))
        XCTAssertEqual(session.calls, ["pause", "playerState"])
    }

    /// Music.app quit after the running check, so no session could be bound.
    /// An independent re-check proves it is gone.
    func testExitAfterTheRunningCheckWithAbsenceConfirmedIsTrue() throws {
        let probe = FakeProbe([true, false])
        var opened = 0
        XCTAssertTrue(try confirm(nil, probe, opened: &opened))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(probe.checks, 2, "absence is re-checked, not inferred from the missing session")
    }

    /// No session, and something still answers as Music.app (the same process,
    /// a new one, or a table that could not be read): refuse.
    func testNoSessionWhileAProcessStillAppearsThrows() {
        XCTAssertThrowsError(try confirm(nil, FakeProbe([true, true])))
    }

    /// Music.app quit between the pause and the read. The bound session cannot
    /// relaunch or retarget, so the read fails; the re-check proves absence.
    func testExitBetweenPauseAndReadWithAbsenceConfirmedIsTrue() throws {
        let session = FakeSession()
        let probe = FakeProbe([true, false])
        session.stateResult = .failure(FakeFailure())
        XCTAssertTrue(try confirm(session, probe))
        XCTAssertEqual(session.calls, ["pause", "playerState"])
        XCTAssertEqual(probe.checks, 2)
    }

    /// Music.app quit between the pause and the read, and a process (a new pid
    /// or the same one) is still seen on the re-check: refuse.
    func testExitBetweenPauseAndReadWithAProcessStillSeenThrows() {
        let session = FakeSession()
        session.stateResult = .failure(FakeFailure())
        XCTAssertThrowsError(try confirm(session, FakeProbe([true, true])))
    }

    /// Every call the switch makes goes through the bound session, and that
    /// session has only these two calls: nothing name-addressed, nothing that
    /// launches.
    func testOnlyTheBoundSessionsTwoCallsAreEverMade() throws {
        let scripts: [(FakeSession?, [Bool])] = {
            let failing = FakeSession(); failing.stateResult = .failure(FakeFailure())
            let playing = FakeSession(); playing.stateResult = .success(.playing)
            let refusing = FakeSession(); refusing.pauseResult = .failure(FakeFailure())
            return [(FakeSession(), [true]), (failing, [true, true]), (failing, [true, false]),
                    (playing, [true]), (refusing, [true]), (nil, [true, false]), (nil, [true, true]),
                    (FakeSession(), [false])]
        }()
        for (session, answers) in scripts {
            _ = try? confirm(session, FakeProbe(answers))
            XCTAssertTrue(Set(session?.calls ?? []).isSubset(of: ["pause", "playerState"]))
        }
    }

    // MARK: - Pure pieces of the live session and probe

    func testPlayerStateCodesFromTheMusicDictionary() {
        // com.apple.Music.sdef, enumeration ePlS.
        XCTAssertEqual(musicAppPlayerState(fourCharCode: "kPSS"), .stopped)
        XCTAssertEqual(musicAppPlayerState(fourCharCode: "kPSP"), .playing)
        XCTAssertEqual(musicAppPlayerState(fourCharCode: "kPSp"), .paused)
        XCTAssertEqual(musicAppPlayerState(fourCharCode: "kPSF"), .fastForwarding)
        XCTAssertEqual(musicAppPlayerState(fourCharCode: "kPSR"), .rewinding)
        XCTAssertNil(musicAppPlayerState(fourCharCode: "xxxx"))
        XCTAssertNil(musicAppPlayerState(fourCharCode: "kPS"))
    }

    private let music = "/System/Applications/Music.app/Contents/MacOS/Music"

    func testTheProbeSeesAbsenceOnlyInAFullyReadTable() {
        let other = ProcessTableEntry(pid: 10, path: "/usr/bin/other", name: "other")
        XCTAssertFalse(musicAppMayBeRunning([other]))
        XCTAssertFalse(musicAppMayBeRunning([]))
        XCTAssertTrue(musicAppMayBeRunning(nil), "an unreadable table is not absence")
        XCTAssertTrue(musicAppMayBeRunning([other, ProcessTableEntry(pid: 11, path: music, name: "Music")]))
    }

    /// A process whose path cannot be read is only ruled out by a readable
    /// name that is not Music's (found live: executables replaced on disk
    /// answer ENOENT for their path but still give their name).
    func testAProcessWithNoReadablePathIsRuledOutOnlyByItsName() {
        XCTAssertFalse(musicAppMayBeRunning([ProcessTableEntry(pid: 12, path: nil, name: "2.1.278")]))
        XCTAssertTrue(musicAppMayBeRunning([ProcessTableEntry(pid: 12, path: nil, name: "Music")]))
        XCTAssertTrue(musicAppMayBeRunning([ProcessTableEntry(pid: 12, path: nil, name: nil)]))
    }

    func testTheSessionIsBoundOnlyToTheOneMusicAppPid() {
        let other = ProcessTableEntry(pid: 10, path: "/usr/bin/other", name: "other")
        XCTAssertEqual(musicAppSessionPID([other, ProcessTableEntry(pid: 11, path: music, name: "Music")]), 11)
        XCTAssertNil(musicAppSessionPID([other]))
        XCTAssertNil(musicAppSessionPID(nil))
        XCTAssertNil(musicAppSessionPID([ProcessTableEntry(pid: 11, path: music, name: "Music"),
                                         ProcessTableEntry(pid: 12, path: music, name: "Music")]),
                     "two instances: no guess")
    }

    // MARK: - Structural (source, not execution, evidence)

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// `selectMode`'s `.musicApp` pause case calls the confirmation, and no
    /// longer the unconfirmed name-addressed pause.
    func testSelectModesMusicAppPauseCaseCallsTheConfirmation() throws {
        let source = try String(contentsOf: sources.appendingPathComponent("TUI/Shell/SpeakersScene.swift"),
                                encoding: .utf8)
        guard let select = source.range(of: "private func selectMode("),
              let pause = source.range(of: "pauseOutgoing: { outgoing in", range: select.upperBound..<source.endIndex),
              let caseStart = source.range(of: "case .musicApp:", range: pause.upperBound..<source.endIndex),
              let caseEnd = source.range(of: "case .source:", range: caseStart.upperBound..<source.endIndex)
        else { return XCTFail("selectMode's pauseOutgoing .musicApp case not found") }
        let body = source[caseStart.upperBound..<caseEnd.lowerBound]
        XCTAssertTrue(body.contains("confirmMusicAppNotPlaying("), String(body))
        XCTAssertFalse(body.contains("runMusic"), String(body))
        XCTAssertFalse(body.contains("return true"), String(body))
    }

    /// The live session is addressed by process id with launching disabled, and
    /// the file names no way of reaching Music.app by name.
    func testTheLiveSessionIsProcessBoundAndNonLaunching() throws {
        let source = try String(contentsOf: sources.appendingPathComponent("TUI/MusicAppPauseConfirm.swift"),
                                encoding: .utf8)
        // Code only: the file's comments quote the hazard they avoid.
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("SBApplication(processIdentifier:"))
        XCTAssertTrue(code.contains("launchFlags = []"))
        for forbidden in ["tell application", "runMusic", "osascript", "NSAppleScript", "OSAScript",
                          "bundleIdentifier:", "SBApplication(url", "NSWorkspace", "AppleScriptBackend"] {
            XCTAssertFalse(code.contains(forbidden), forbidden)
        }
    }
}

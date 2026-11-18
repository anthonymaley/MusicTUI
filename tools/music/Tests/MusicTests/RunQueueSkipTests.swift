// tools/music/Tests/MusicTests/RunQueueSkipTests.swift
//
// `music skip` / `music back` and the TUI's next / previous for a queue the Mac DAC
// route's detached runner owns (finding 7, live check 2026-11-18). The runner's end
// is in RunQueueTests; this is the channel's files, the client, and the callers.
// Temp directories only: no process, no socket, no Music, no `~/.config/music`.
import ArgumentParser
import XCTest
@testable import music

final class RunQueueSkipTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "run-queue-skip-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private var files: RunQueueControlFiles { RunQueueControlFiles(directory: dir) }
    private func control(owner: String = "runner-1", pid: Int32 = 4242) -> FileRunQueueControl {
        FileRunQueueControl(files: files, owner: owner, pid: pid)
    }

    // MARK: the files

    func testTheRunnersRecordIsWrittenAndOnlyItsOwnIsRemoved() {
        let mine = control(owner: "a", pid: 1), newer = control(owner: "b", pid: 2)
        mine.register()
        XCTAssertEqual(files.read(files.runnerPath), "1\na\n")
        newer.register()                       // a newer runner replaced the record
        mine.unregister()
        XCTAssertEqual(files.read(files.runnerPath), "2\nb\n", "an ending runner removed a newer runner's record")
        newer.unregister()
        XCTAssertNil(files.read(files.runnerPath))
    }

    func testASkipIsTakenOnceAndGarbageIsIgnored() {
        let c = control()
        XCTAssertNil(c.takeSkip())
        XCTAssertTrue(files.write("1 NONCE", to: files.skipPath))
        XCTAssertEqual(c.takeSkip(), RunQueueSkipRequest(step: 1, nonce: "NONCE"))
        XCTAssertNil(c.takeSkip(), "a skip was taken twice")
        for bad in ["", "2 X", "1", "one X", "-1"] {
            XCTAssertTrue(files.write(bad, to: files.skipPath))
            XCTAssertNil(c.takeSkip(), "\(bad) was taken")
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath), "\(bad) was left behind")
        }
        XCTAssertTrue(files.write("-1 BACK", to: files.skipPath))
        XCTAssertEqual(c.takeSkip(), RunQueueSkipRequest(step: -1, nonce: "BACK"))
    }

    // MARK: the client

    private func client(owner: String = "runner-1", alive: Bool = true, leaseHolds: Bool = true,
                        clock: Clock = Clock(), runner: FileRunQueueControl? = nil,
                        onSleep: @escaping () -> Void = {}) -> RunQueueSkipClient {
        var c = RunQueueSkipClient(files: files, leaseIsOwners: { _ in leaseHolds })
        c.isAlive = { _ in alive }
        c.newNonce = { "NONCE" }
        c.now = { clock.t }
        c.sleep = { clock.t += $0; onSleep() }
        return c
    }
    private final class Clock { var t: TimeInterval = 0 }

    func testNoRecordADeadRunnerOrAnotherLeaseHolderMeansNoRunner() {
        XCTAssertEqual(client().send(step: 1), .noRunner)
        control().register()
        XCTAssertEqual(client(alive: false).send(step: 1), .noRunner, "a dead runner was asked")
        XCTAssertEqual(client(leaseHolds: false).send(step: 1), .noRunner, "a runner that lost the lease was asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath), "a skip was written for nobody")
    }

    func testALiveRunnersSkipIsSentPickedUpAndAcknowledged() {
        let runner = control()
        runner.register()
        var taken: RunQueueSkipRequest?
        let c = client(onSleep: {
            if taken == nil { taken = runner.takeSkip() }
            else if let taken { runner.acknowledge(nonce: taken.nonce) }
        })
        XCTAssertEqual(c.send(step: -1), .done)
        XCTAssertEqual(taken, RunQueueSkipRequest(step: -1, nonce: "NONCE"))
    }

    func testARunnerThatNeverPicksItUpIsWithdrawnAndNothingFiresLater() {
        control().register()
        XCTAssertEqual(client().send(step: 1), .notPickedUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath), "a withdrawn skip is still there")
    }

    func testARunnerThatTookItButNeverAnswersIsReported() {
        let runner = control()
        runner.register()
        let c = client(onSleep: { _ = runner.takeSkip() })
        XCTAssertEqual(c.send(step: 1), .notAcknowledged)
    }

    // MARK: the CLI

    func testSkipThroughTheRunnerShowsWhatPlaysOnlyOnceItStarted() throws {
        let runner = control()
        runner.register()
        var shown = 0
        var taken: RunQueueSkipRequest?
        let c = client(onSleep: {
            if taken == nil { taken = runner.takeSkip() } else if let taken { runner.acknowledge(nonce: taken.nonce) }
        })
        XCTAssertTrue(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: c,
                                            show: { _ in shown += 1 }, fail: { _ in XCTFail("failed") }))
        XCTAssertEqual(shown, 1)
    }

    func testOffTheRouteOrWithNoRunnerTheCallerDoesWhatItAlwaysDid() throws {
        var shown = 0
        XCTAssertFalse(try skipThroughRunner(step: 1, json: false, routeIsOn: { false }, client: client(),
                                             show: { _ in shown += 1 }))
        XCTAssertFalse(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: client(),
                                             show: { _ in shown += 1 }), "no runner is asked")
        XCTAssertEqual(shown, 0)
    }

    func testARunnerThatDoesNotAnswerFailsTheCommandInsteadOfRestartingTheSong() {
        control().register()
        var said: String?
        XCTAssertThrowsError(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: client(),
                                                   show: { _ in XCTFail("shown") }, fail: { said = $0 })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(said, macRouteSkipNotDoneMessage)
    }

    /// `skip` and `back` ask the runner FIRST, and never send Music's own next or
    /// previous track when the runner took it (that restarts the song).
    func testSkipAndBackGoThroughTheRunnerBeforeMusicsOwnTrackStep() throws {
        for (name, step) in [("skip", 1), ("back", -1)] {
            var asked: [Int] = [], musicStepped = 0, shown = 0
            let runner: (Int, Bool) throws -> Bool = { s, _ in asked.append(s); return true }
            if step > 0 {
                try skipViaMusicApp(json: false, runner: runner, nextTrack: { musicStepped += 1 }, show: { _ in shown += 1 })
            } else {
                try backViaMusicApp(json: false, runner: runner, previousTrack: { musicStepped += 1 }, show: { _ in shown += 1 })
            }
            XCTAssertEqual(asked, [step], name)
            XCTAssertEqual(musicStepped, 0, "\(name): Music's own track step restarted the song")
            XCTAssertEqual(shown, 0, "\(name): the runner's own line was doubled")
        }
        // No runner: exactly the shipped body.
        var musicStepped = 0, shown = 0
        try skipViaMusicApp(json: false, runner: { _, _ in false }, nextTrack: { musicStepped += 1 }, show: { _ in shown += 1 })
        try backViaMusicApp(json: false, runner: { _, _ in false }, previousTrack: { musicStepped += 1 }, show: { _ in shown += 1 })
        XCTAssertEqual(musicStepped, 2)
        XCTAssertEqual(shown, 2)
    }

    // MARK: the TUI

    /// The TUI's own queue goes through the transition already (MacRouteWiringTests).
    /// With NO queue of its own (the runner owns it) its next and previous used to
    /// send Music "next track" too; they ask the runner first.
    func testTheTUIsNextAndPreviousWithNoQueueOfItsOwnAskTheRunner() throws {
        let log = dir + "/scripts.txt"
        let fake = dir + "/osascript"
        try "#!/bin/sh\nprintf '%s\\n' \"$2\" >> '\(log)'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        let backend = AppleScriptBackend(executable: fake)
        var asked: [Int] = []
        for step in [1, -1] {
            try musicTUISkip(step, backend: backend, appQueue: AppQueueStore(), runner: { asked.append($0); return true })
        }
        XCTAssertEqual(asked, [1, -1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log), "Music's own track step ran after the runner took it")
        try musicTUISkip(1, backend: backend, appQueue: AppQueueStore(), runner: { _ in false })
        XCTAssertTrue((try? String(contentsOfFile: log, encoding: .utf8))?.contains("next track") == true,
                      "with no runner the shipped step is unchanged")
    }
}

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

    func testTheRunnersRecordHasItsPhaseAndOnlyItsOwnIsRemoved() {
        let mine = control(owner: "a", pid: 1), newer = control(owner: "b", pid: 2)
        mine.register()
        XCTAssertEqual(files.read(files.runnerPath), "1\na\nstarting\n")
        mine.markReady()
        XCTAssertEqual(files.read(files.runnerPath), "1\na\nready\n")
        newer.register()                       // a newer runner replaced the record
        mine.unregister()
        XCTAssertEqual(files.read(files.runnerPath), "2\nb\nstarting\n", "an ending runner removed a newer runner's record")
        // The same pid under another owner is not this runner either.
        FileRunQueueControl(files: files, owner: "other", pid: 2).unregister()
        XCTAssertEqual(files.read(files.runnerPath), "2\nb\nstarting\n", "a record of another owner was removed by pid alone")
        newer.markReady()
        newer.unregister()
        XCTAssertNil(files.read(files.runnerPath))
    }

    func testASkipIsTakenOnceAndGarbageIsIgnored() {
        let c = control()
        XCTAssertNil(c.takeSkip())
        XCTAssertTrue(files.write("1 NONCE", to: files.skipPath(owner: "runner-1")))
        XCTAssertEqual(c.takeSkip(), RunQueueSkipRequest(step: 1, nonce: "NONCE"))
        XCTAssertNil(c.takeSkip(), "a skip was taken twice")
        for bad in ["", "2 X", "1", "one X", "-1"] {
            XCTAssertTrue(files.write(bad, to: files.skipPath(owner: "runner-1")))
            XCTAssertNil(c.takeSkip(), "\(bad) was taken")
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath(owner: "runner-1")), "\(bad) was left behind")
        }
        XCTAssertTrue(files.write("-1 BACK", to: files.skipPath(owner: "runner-1")))
        XCTAssertEqual(c.takeSkip(), RunQueueSkipRequest(step: -1, nonce: "BACK"))
    }

    /// A request is addressed to a runner by its owner: another runner (the lease
    /// moved after the client looked) never reads it.
    func testASkipAddressedToOneRunnerIsNeverTakenByAnother() {
        let a = control(owner: "runner-a", pid: 1), b = control(owner: "runner-b", pid: 2)
        XCTAssertTrue(files.write("1 FORA", to: files.skipPath(owner: "runner-a")))
        XCTAssertNil(b.takeSkip(), "a runner took a skip addressed to another")
        XCTAssertEqual(a.takeSkip(), RunQueueSkipRequest(step: 1, nonce: "FORA"))
    }

    func testTheAckIsPerRunnerAndCarriesTheOutcome() {
        let a = control(owner: "runner-a", pid: 1)
        a.acknowledge(nonce: "N", outcome: .failed)
        XCTAssertEqual(files.read(files.ackPath(owner: "runner-a")), "N failed")
        XCTAssertNil(files.read(files.ackPath(owner: "runner-b")))
    }

    // MARK: the client

    private func client(owner: String = "runner-1", alive: Bool = true, leaseHolds: Bool = true,
                        lease: RateFence.LeaseStatus? = nil,
                        clock: Clock = Clock(), nonce: String = "NONCE",
                        onSleep: @escaping () -> Void = {}) -> RunQueueSkipClient {
        var c = RunQueueSkipClient(files: files, leaseStatus: { _ in lease ?? (leaseHolds ? .ours : .another) })
        c.isAlive = { _ in alive }
        c.newNonce = { nonce }
        c.now = { clock.t }
        c.sleep = { clock.t += $0; onSleep() }
        return c
    }
    private final class Clock { var t: TimeInterval = 0 }

    func testNoRecordADeadRunnerOrAnotherLeaseHolderMeansNoRunner() {
        XCTAssertEqual(client().send(step: 1), .noRunner)
        let up = control()
        up.register(); up.markReady()
        XCTAssertEqual(client(alive: false).send(step: 1), .noRunner, "a dead runner was asked")
        XCTAssertEqual(client(leaseHolds: false).send(step: 1), .noRunner, "a runner that lost the lease was asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath(owner: "runner-1")), "a skip was written for nobody")
    }

    func testALiveRunnersSkipIsSentPickedUpAndAcknowledged() {
        let runner = control()
        runner.register(); runner.markReady()
        var taken: RunQueueSkipRequest?
        let c = client(onSleep: {
            if taken == nil { taken = runner.takeSkip() }
            else if let taken { runner.acknowledge(nonce: taken.nonce, outcome: .played) }
        })
        XCTAssertEqual(c.send(step: -1), .done)
        XCTAssertEqual(taken, RunQueueSkipRequest(step: -1, nonce: "NONCE"))
    }

    func testARunnerThatNeverPicksItUpIsWithdrawnAndNothingFiresLater() {
        let up = control()
        up.register(); up.markReady()
        XCTAssertEqual(client().send(step: 1), .notPickedUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.skipPath(owner: "runner-1")), "a withdrawn skip is still there")
    }

    /// Two clients at once: the second overwrites the first, the runner takes the
    /// second. The first is told it was not heard (its nonce is never acknowledged);
    /// a client that times out withdraws only its OWN request.
    func testTwoClientsAtOnceEachReportTheTruthFromTheAcksNonce() {
        let runner = control()
        runner.register(); runner.markReady()
        // Client A writes; before it looks again, client B's request replaces it.
        var replaced = false
        let a = client(nonce: "A", onSleep: {
            if !replaced {
                replaced = true
                _ = self.files.write("1 B", to: self.files.skipPath(owner: "runner-1"))
                _ = runner.takeSkip()                     // the runner hears B
                runner.acknowledge(nonce: "B", outcome: .played)
            }
        })
        XCTAssertEqual(a.send(step: 1), .notAcknowledged, "a client whose request was overwritten was told it was heard")
    }

    func testATimedOutClientNeverWithdrawsAnotherClientsRequest() {
        let up = control()
        up.register(); up.markReady()
        var swapped = false
        let a = client(nonce: "A", onSleep: {
            if !swapped { swapped = true; _ = self.files.write("1 B", to: self.files.skipPath(owner: "runner-1")) }
        })
        XCTAssertEqual(a.send(step: 1), .notPickedUp)
        XCTAssertEqual(files.read(files.skipPath(owner: "runner-1")), "1 B", "A's timeout removed B's request")
    }

    /// What the runner says it did is what the client reports.
    func testTheClientReportsTheRunnersOutcome() {
        for (outcome, expected) in [(RunQueueSkipOutcome.played, RunQueueSkipClient.Outcome.done),
                                    (.end, .done), (.failed, .notStarted), (.notStarted, .notStarted),
                                    (.superseded, .superseded)] {
            let runner = control()
            runner.register(); runner.markReady()
            var taken: RunQueueSkipRequest?
            let c = client(nonce: "N-\(outcome.rawValue)", onSleep: {
                if taken == nil { taken = runner.takeSkip() } else if let taken { runner.acknowledge(nonce: taken.nonce, outcome: outcome) }
            })
            XCTAssertEqual(c.send(step: 1), expected, "\(outcome)")
        }
    }

    func testARunnerThatTookItButNeverAnswersIsReported() {
        let runner = control()
        runner.register(); runner.markReady()
        let c = client(onSleep: { _ = runner.takeSkip() })
        XCTAssertEqual(c.send(step: 1), .notAcknowledged)
    }

    // MARK: the CLI

    func testSkipThroughTheRunnerShowsWhatPlaysOnlyOnceItStarted() throws {
        let runner = control()
        runner.register(); runner.markReady()
        var shown = 0
        var taken: RunQueueSkipRequest?
        let c = client(onSleep: {
            if taken == nil { taken = runner.takeSkip() } else if let taken { runner.acknowledge(nonce: taken.nonce, outcome: .played) }
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
        let up = control()
        up.register(); up.markReady()
        var said: String?
        XCTAssertThrowsError(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: client(),
                                                   show: { _ in XCTFail("shown") }, fail: { said = $0 })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(said, macRouteSkipNotDoneMessage)
    }

    // MARK: a runner that is starting, or whose lease is not readable now

    /// A live runner that has not finished starting is waited for; if it becomes ready the
    /// skip goes through, if not the client says so, and Music's own next track (which
    /// restarts the song) is never the answer.
    func testAStartingRunnerIsWaitedForAndNeverReplacedByMusicsOwnNextTrack() {
        let runner = control()
        runner.register()
        var taken: RunQueueSkipRequest?
        var sleeps = 0
        let c = client(onSleep: {
            sleeps += 1
            if sleeps == 3 { runner.markReady() }             // the start finishes while the client waits
            else if sleeps > 3 {
                if taken == nil { taken = runner.takeSkip() } else if let taken { runner.acknowledge(nonce: taken.nonce, outcome: .played) }
            }
        })
        XCTAssertEqual(c.send(step: 1), .done, "a runner that was only starting was given up on")

        let stuck = control(owner: "stuck", pid: 7)
        stuck.register()
        XCTAssertEqual(client().send(step: 1), .stillStarting)
        var said: String?
        XCTAssertThrowsError(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: client(),
                                                   show: { _ in XCTFail("shown") }, fail: { said = $0 })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(said, macRouteSkipStartingMessage)
    }

    func testABusyLeaseIsWaitedForNotReadAsNoRunnerAndAMovedLeaseIsNoRunner() {
        let up = control()
        up.register(); up.markReady()
        XCTAssertEqual(client(lease: .busy).send(step: 1), .stillStarting, "a busy lock was read as no runner")
        XCTAssertEqual(client(lease: .another).send(step: 1), .noRunner)
        XCTAssertEqual(client(lease: RateFence.LeaseStatus.none).send(step: 1), .noRunner)
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

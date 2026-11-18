// tools/music/Tests/MusicTests/CLISkipWiringTests.swift
//
// `music skip` / `music back` through the REAL `runSkip` / `runBack` -> `cliDispatch` ->
// output lock wiring (live check 2026-11-18: the runner was asked from inside the lock the
// dispatcher holds, where the lease could not be read, so Music's own next track ran and
// restarted the song). The runner is simulated by the client's own sleep; the lease is
// read through a REAL `RateFence` on the same lock file the dispatcher takes. Temp
// directories only: no process, no Music, no `~/.config/music`.
import ArgumentParser
import XCTest
@testable import music

final class CLISkipWiringTests: XCTestCase {

    private struct Rig {
        let env: CLIBridgeEnv
        let lockPath: String
        let files: RunQueueControlFiles
        let fence: RateFence
        let runner: FileRunQueueControl
    }

    private func rig() throws -> Rig {
        let dir = NSTemporaryDirectory() + "music-skip-wiring-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PlaybackModeStore(path: dir + "/mode.json")
        precondition(store.set(.musicApp))
        precondition(isUnderTemporaryDirectory(store.lockPath))
        let routing = RoutingCoordinator(
            store: store, surface: .cli,
            makeSource: { SourceAppClient(path: "/nonexistent/s.sock", transport: { _, _ in throw SourceAppError.timedOut }) },
            outputLock: OutputLock(path: store.lockPath))
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv(routing: routing, modeStore: store, cache: ResultCache(directory: dir + "/cache"),
                               out: io.writeOut, err: io.writeErr, sleep: io.sleep)
        let fence = RateFence(lock: OutputLock(path: store.lockPath, pollInterval: 0.001))
        _ = try fence.begin(.play, owner: "owner-X")          // the runner's lease
        let files = RunQueueControlFiles(directory: dir)
        let runner = FileRunQueueControl(files: files, owner: "owner-X")
        runner.register(); runner.markReady()
        return Rig(env: env, lockPath: store.lockPath, files: files, fence: fence, runner: runner)
    }

    /// The client, with the lease read through the real fence and the runner simulated by
    /// its sleep: it takes the request and answers it. `lockFreeWhileWaiting` records that
    /// the CLI was NOT holding the output lock while it waited (the runner needs it).
    private func client(_ r: Rig, lockFreeWhileWaiting: @escaping (Bool) -> Void) -> RunQueueSkipClient {
        var c = RunQueueSkipClient(files: r.files, leaseStatus: { r.fence.leaseStatus(owner: $0, timeout: 0.2) })
        var taken: RunQueueSkipRequest?
        c.sleep = { _ in
            lockFreeWhileWaiting(OutputLockTestSupport.isFree(r.lockPath))
            if taken == nil { taken = r.runner.takeSkip() }
            else if let taken { r.runner.acknowledge(nonce: taken.nonce, outcome: .played) }
        }
        return c
    }

    func testSkipAndBackReachTheRunnerThroughTheRealDispatcherAndNeverRestartTheSong() throws {
        for (name, step) in [("skip", 1), ("back", -1)] {
            let r = try rig()
            var musicStepped = 0, shown = 0
            var lockFree: [Bool] = []
            var asked: [Int] = []
            let c = client(r, lockFreeWhileWaiting: { lockFree.append($0) })
            let runner: (Int, Bool) throws -> Bool = { s, j in
                asked.append(s)
                return try skipThroughRunner(step: s, json: j, routeIsOn: { true }, client: c, show: { _ in shown += 1 },
                                             fail: { XCTFail("\(name) failed: \($0)") })
            }
            if step > 0 {
                try runSkip(json: false, env: r.env, musicApp: { _ in musicStepped += 1 }, runner: runner)
            } else {
                try runBack(json: false, env: r.env, musicApp: { _ in musicStepped += 1 }, runner: runner)
            }
            XCTAssertEqual(asked, [step], name)
            XCTAssertEqual(musicStepped, 0, "\(name): Music's own track step ran (it restarts the song)")
            XCTAssertEqual(shown, 1, name)
            XCTAssertFalse(lockFree.isEmpty, name)
            XCTAssertTrue(lockFree.allSatisfy { $0 }, "\(name): the CLI held the output lock while waiting for the runner")
            XCTAssertTrue(OutputLockTestSupport.isFree(r.lockPath), name)
        }
    }

    /// Off the route, or with no runner at all, the dispatcher runs the shipped body.
    func testWithNoRunnerTheShippedBodyRunsUnderTheLockAsBefore() throws {
        let r = try rig()
        try? FileManager.default.removeItem(atPath: r.files.runnerPath)
        var musicStepped = 0
        try runSkip(json: false, env: r.env, musicApp: { _ in musicStepped += 1 },
                    runner: { s, j in try skipThroughRunner(step: s, json: j, routeIsOn: { true },
                                                            client: RunQueueSkipClient(files: r.files, leaseStatus: { _ in .none })) })
        XCTAssertEqual(musicStepped, 1)
        var off = 0
        try runBack(json: false, env: r.env, musicApp: { _ in off += 1 },
                    runner: { s, j in try skipThroughRunner(step: s, json: j, routeIsOn: { false }) })
        XCTAssertEqual(off, 1)
    }

    /// A runner that is still starting: the command fails with the starting line and the
    /// shipped body (Music's own next track) is never run.
    func testARunnerStillStartingFailsTheCommandInsteadOfRestartingTheSong() throws {
        let r = try rig()
        r.runner.register()                                      // back to `starting`
        var c = RunQueueSkipClient(files: r.files, leaseStatus: { r.fence.leaseStatus(owner: $0) })
        var clock = 0.0
        c.now = { clock }
        c.sleep = { clock += $0 }
        var said: String?
        var musicStepped = 0
        XCTAssertThrowsError(try runSkip(json: false, env: r.env, musicApp: { _ in musicStepped += 1 }, runner: { s, j in
            try skipThroughRunner(step: s, json: j, routeIsOn: { true }, client: c, show: { _ in }, fail: { said = $0 })
        })) { XCTAssertEqual($0 as? ExitCode, .failure) }
        XCTAssertEqual(said, macRouteSkipStartingMessage)
        XCTAssertEqual(musicStepped, 0)
    }
}

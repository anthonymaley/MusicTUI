// tools/music/Tests/MusicTests/CLIBridgeDispatchTests.swift
//
// The CLI dispatch seam (slice 3 score, S5; decisions D1, D5, D6). Every
// ordering is produced by barriers (the switch's own callbacks, the lock's
// `onWaiting` hook, S1's latched lock), never by sleeping. No test reaches
// Music.app, AppleScript, REST, the real Bridge socket or ~/.config/music:
// the wire is scripted, the store, lock and cache are temp, and the external
// call tripwire is armed where a branch could conceivably reach a funnel.
import ArgumentParser
import XCTest
@testable import music

final class CLIBridgeDispatchTests: XCTestCase {

    private typealias S = OutputLockTestSupport

    // MARK: requiresOutputLock

    func testRequiresOutputLockIsTouchesPlaybackPlusTheHealingSpeakerActions() {
        for action in MusicTUIAction.allCases {
            XCTAssertEqual(requiresOutputLock(action), action.touchesPlayback || action == .airplayRoute,
                           "\(action)")
        }
        XCTAssertTrue(requiresOutputLock(.airplayRoute))
        XCTAssertFalse(MusicTUIAction.airplayRoute.touchesPlayback, "touchesPlayback must not change")
        XCTAssertFalse(requiresOutputLock(.catalogSearch))
    }

    // MARK: Music.app mode

    func testMusicAppModeRunsTheBodyOnceUnderTheLockForAPlaybackAction() throws {
        let wire = BridgeLibraryReadsWire()
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, wire: wire, io: io)
        let lockPath = env.routing.outputLock!.path
        var runs = 0
        var heldDuringBody: Bool?
        let (_, calls) = try withTripwire {
            try cliDispatch(.next, json: false, env: env,
                            musicApp: { runs += 1; heldDuringBody = !S.isFree(lockPath) },
                            bridge: { _ in XCTFail("the Bridge branch ran in Music.app mode") })
        }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(heldDuringBody, true, "a playback action's Music.app body must run inside the lock")
        XCTAssertTrue(S.isFree(lockPath), "the lock is released after the body")
        XCTAssertEqual(wire.requestCount, 0)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(io.out, [])
        XCTAssertEqual(io.err, [])
    }

    func testMusicAppModeTakesTheLockForAHealingSpeakerAction() throws {
        let env = CLIBridgeEnv.test(mode: .musicApp)
        let lockPath = env.routing.outputLock!.path
        var held: Bool?
        try cliDispatch(.airplayRoute, json: false, env: env,
                        musicApp: { held = !S.isFree(lockPath) }, bridge: { _ in XCTFail() })
        XCTAssertEqual(held, true)
    }

    func testMusicAppModeTakesNoLockForARead() throws {
        let wire = BridgeLibraryReadsWire()
        let env = CLIBridgeEnv.test(mode: .musicApp, wire: wire)
        let lockPath = env.routing.outputLock!.path
        var runs = 0
        var freeDuringBody: Bool?
        try cliDispatch(.catalogSearch, json: false, env: env,
                        musicApp: { runs += 1; freeDuringBody = S.isFree(lockPath) },
                        bridge: { _ in XCTFail() })
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(freeDuringBody, true, "a read must not take the output lock")
        XCTAssertEqual(wire.requestCount, 0)
    }

    func testAnUnaffectedRouteRunsTheShippedBody() throws {
        let env = CLIBridgeEnv.test(mode: .musicApp)
        var runs = 0
        try cliDispatch(.auth, json: false, env: env, musicApp: { runs += 1 }, bridge: { _ in XCTFail() })
        XCTAssertEqual(runs, 1)
    }

    func testAMusicAppExitCodePropagatesSilently() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env,
                                             musicApp: { throw ExitCode.failure },
                                             bridge: { _ in })) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
        XCTAssertEqual(io.out, [])
        XCTAssertEqual(io.err, [])
        XCTAssertTrue(S.isFree(env.routing.outputLock!.path))
    }

    func testAMusicAppErrorPassesThroughUntouchedAndUnprinted() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        XCTAssertThrowsError(try cliDispatch(.catalogSearch, json: true, env: env,
                                             musicApp: { throw ActionError(message: "boom") },
                                             bridge: { _ in })) { error in
            XCTAssertEqual((error as? ActionError)?.message, "boom")
        }
        XCTAssertEqual(io.out, [])
    }

    // MARK: refused routes

    private func assertRefusalBytesMatchRefuseInBridge(json: Bool) throws {
        let wire = BridgeLibraryReadsWire()
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io)
        var ran = false
        let (_, calls) = try withTripwire { () throws -> Void in
            XCTAssertThrowsError(try cliDispatch(.playPause, json: json, env: env,
                                                 musicApp: { ran = true }, bridge: { _ in ran = true })) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
        }
        let shipped = captureStdout { try refuseInBridge(.playPause, json: json, mode: .source) }
        XCTAssertEqual(shipped.error as? ExitCode, .failure)
        XCTAssertFalse(shipped.output.isEmpty)
        XCTAssertEqual(io.stdoutBytes, shipped.output, "json: \(json)")
        XCTAssertFalse(ran)
        XCTAssertEqual(wire.requestCount, 0)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(io.err, [])
    }

    func testARefusedRoutePrintsExactlyWhatRefuseInBridgePrints() throws {
        try assertRefusalBytesMatchRefuseInBridge(json: false)
    }

    func testARefusedRoutePrintsExactlyWhatRefuseInBridgePrintsAsJSON() throws {
        try assertRefusalBytesMatchRefuseInBridge(json: true)
    }

    // MARK: Bridge branch (driven through the real perform; see CLIBridgeEnv.test)

    func testMutateInsidePerformDoesNotTripTheReentryGuard() throws {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()],
                                           "slice.next": [CLIBridgeReplies.ok]])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        let lockPath = env.routing.outputLock!.path
        var held: Bool?
        try cliDispatch(.next, json: false, env: env, musicApp: { XCTFail("Music.app ran on Bridge") },
                        bridge: { session in
                            try session.mutate { control in
                                held = !S.isFree(lockPath)
                                try control.next()
                            }
                        })
        XCTAssertEqual(held, true, "the Bridge mutation runs inside the output lock")
        XCTAssertEqual(wire.sent("slice.next").count, 1)
        XCTAssertTrue(S.isFree(lockPath))
        XCTAssertEqual(io.out, [])
    }

    func testReadinessNotReadyPrintsTheSentenceAndSendsNothingFurther() {
        for json in [false, true] {
            let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status(authorization: "denied")]])
            let io = CLIBridgeTestIO()
            let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
            var bridgeRan = false
            XCTAssertThrowsError(try cliDispatch(.next, json: json, env: env, musicApp: {},
                                                 bridge: { _ in bridgeRan = true })) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
            let sentence = "Bridge was denied Apple Music access. Switch Output to Music.app to use Music.app instead."
            if json {
                XCTAssertEqual(io.out.count, 1)
                let doc = try? JSONSerialization.jsonObject(with: Data(io.out[0].utf8)) as? [String: Any]
                XCTAssertEqual(doc?["ok"] as? Bool, false)
                XCTAssertEqual(doc?["error"] as? String, sentence)
            } else {
                XCTAssertEqual(io.out, [sentence])
            }
            XCTAssertFalse(bridgeRan)
            XCTAssertEqual(wire.requests.map { $0["op"] as? String }, ["slice.status"])
        }
    }

    func testReadinessWhenBridgeIsNotRunningReadsAsASentence() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv(test: .source, io: io, transport: { _, _ in throw SourceAppError.notRunning })
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env, musicApp: {}, bridge: { _ in XCTFail() }))
        XCTAssertEqual(io.out, ["Bridge is not running. Switch Output to Music.app to use Music.app instead."])
    }

    func testABridgeErrorIsPrintedInItsOwnWords() {
        for json in [false, true] {
            let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()],
                                               "slice.next": [CLIBridgeReplies.refused("Nothing is queued")]])
            let io = CLIBridgeTestIO()
            let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
            XCTAssertThrowsError(try cliDispatch(.next, json: json, env: env, musicApp: {},
                                                 bridge: { try $0.mutate { try $0.next() } })) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
            let message = SourceAppError.refused("Nothing is queued").message
            if json {
                let doc = try? JSONSerialization.jsonObject(with: Data(io.out.first?.utf8 ?? "".utf8)) as? [String: Any]
                XCTAssertEqual(doc?["error"] as? String, message)
                XCTAssertEqual(doc?["ok"] as? Bool, false)
            } else {
                XCTAssertEqual(io.out, [message])
            }
            XCTAssertEqual(wire.sent("slice.next").count, 1, "a refused mutation is not re-sent")
        }
    }

    func testAnExitCodeFromTheBridgeBodyPassesThroughUnprinted() {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()]])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        XCTAssertThrowsError(try cliDispatch(.playPause, json: false, env: env, musicApp: {},
                                             bridge: { _ in env.out("Bridge is still playing."); throw ExitCode.failure })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(io.out, ["Bridge is still playing."])
    }

    // MARK: warming (D5)

    func testWarmingBeforeTheMutationRetriesOutsideTheLockAndRevalidates() throws {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()],
                                           "slice.next": [CLIBridgeReplies.warming(retryAfter: 2), CLIBridgeReplies.ok]])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        let lockPath = env.routing.outputLock!.path
        var freeWhileSleeping: [Bool] = []
        io.onSleep = { _ in freeWhileSleeping.append(S.isFree(lockPath)) }
        var attempts = 0
        try cliDispatch(.next, json: false, env: env, musicApp: {},
                        bridge: { try $0.mutate { attempts += 1; try $0.next() } })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(wire.sent("slice.next").count, 2)
        XCTAssertEqual(io.sleeps, [2])
        XCTAssertEqual(freeWhileSleeping, [true], "the warm-up wait must be outside the output lock")
        XCTAssertEqual(io.err.count, 1, "warm-up progress goes to stderr")
        XCTAssertEqual(io.out, [])
    }

    func testAWarmingRetryRevalidatesTheModeAndRefusesAfterASwitch() {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()],
                                           "slice.next": [CLIBridgeReplies.warming(retryAfter: 1), CLIBridgeReplies.ok]])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        // Another process switches Output while this command waits out the warm-up.
        io.onSleep = { _ in PlaybackModeStore(path: env.testDirectory + "/mode.json").set(.musicApp) }
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env, musicApp: {},
                                             bridge: { try $0.mutate { try $0.next() } })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(wire.sent("slice.next").count, 1, "the retry must not reach Bridge after a switch")
        XCTAssertEqual(io.out, [OutputLock.cliModeChangedMessage(now: .musicApp)])
        XCTAssertTrue(S.isFree(env.routing.outputLock!.path))
    }

    func testWarmingSpendsTheSessionsOneBudget() {
        // 60 s of waiting at the 5 s clamp: 12 waits, then the give-up sentence.
        let warm = Array(repeating: CLIBridgeReplies.warming(retryAfter: 30), count: 20)
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()], "slice.next": warm])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env, musicApp: {},
                                             bridge: { try $0.mutate { try $0.next() } }))
        XCTAssertEqual(io.sleeps.reduce(0, +), LibraryWarmUp.maxTotalWait, accuracy: 0.0001)
        XCTAssertEqual(io.out, [LibraryWarmUp.gaveUp])
        XCTAssertEqual(wire.sent("slice.next").count, io.sleeps.count + 1)
    }

    func testAMutationFollowedByAFailingStatusReadIsNotResent() {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status(),
                                                            CLIBridgeReplies.warming(retryAfter: 1)],
                                           "slice.queue": [#"{"ok":true,"skipped_unavailable":0}"#]])
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, io: io, surface: .tui)
        var statusError: Error?
        XCTAssertNoThrow(try cliDispatch(.cliPlaySong, json: false, env: env, musicApp: {}, bridge: { session in
            _ = try session.mutate { try $0.queue(libraryIDs: ["i.1"], startRequired: true) }
            do { _ = try session.status() } catch { statusError = error }
        }))
        XCTAssertNotNil(statusError)
        XCTAssertEqual(wire.sent("slice.queue").count, 1, "the observation failing must never re-send the mutation")
        XCTAssertEqual(wire.sent("slice.status").count, 2)
        XCTAssertEqual(io.sleeps, [], "a status read is an observation, not a warming-retried mutation")
    }

    // MARK: a concurrent switch (S1's barrier pattern, real RoutingCoordinator)

    private struct Race {
        let env: CLIBridgeEnv
        let io: CLIBridgeTestIO
        let wire: BridgeLibraryReadsWire
        let latch: OutputLockLatch
        let cliWaiting: DispatchSemaphore
    }

    private func race(from: PlaybackMode) -> Race {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()],
                                           "slice.next": [CLIBridgeReplies.ok]])
        let io = CLIBridgeTestIO()
        let latch = OutputLockLatch()
        let cliWaiting = DispatchSemaphore(value: 0)
        let env = CLIBridgeEnv.test(mode: from, wire: wire, io: io, surface: from == .source ? .tui : .cli,
                                    outputLock: { S.latchedLock(path: $0, latch: latch, onWaiting: { cliWaiting.signal() }) })
        return Race(env: env, io: io, wire: wire, latch: latch, cliWaiting: cliWaiting)
    }

    /// The switch holds the lock inside `pauseOutgoing`; the CLI command reaches
    /// the wait; the switch commits; the CLI acquires, revalidates, and refuses
    /// with its mutation run 0 times.
    private func assertNoMutationAfterASwitch(from: PlaybackMode, to: PlaybackMode,
                                              dispatch: @escaping (CLIBridgeEnv, @escaping () -> Void) throws -> Void) {
        let r = race(from: from)
        let tui = RoutingCoordinator(store: PlaybackModeStore(path: r.env.testDirectory + "/mode.json"),
                                     surface: .tui,
                                     makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning }) },
                                     outputLock: OutputLock(path: r.env.routing.outputLock!.path))
        let log = OutputLockLog()
        let inPause = DispatchSemaphore(value: 0)
        let switchDone = DispatchGroup()
        var switchResult: Result<RoutingCoordinator.SwitchResult, Error>?
        switchDone.enter()
        DispatchQueue.global().async {
            switchResult = Result {
                try tui.switchMode(to: to, readiness: { .ready },
                                   pauseOutgoing: { _ in
                                       log.append("switch-pause")
                                       inPause.signal()
                                       _ = r.cliWaiting.wait(timeout: .now() + 10)
                                       log.append("cli-waiting")
                                       return true
                                   },
                                   dropQueue: { _ in log.append("switch-drop") })
            }
            log.append("switch-committed")
            switchDone.leave()
        }
        XCTAssertEqual(inPause.wait(timeout: .now() + 5), .success)

        var mutations = 0
        var cliError: Error?
        let cliDone = DispatchGroup()
        cliDone.enter()
        DispatchQueue.global().async {
            do { try dispatch(r.env) { log.append("cli-mutation"); mutations += 1 } } catch { cliError = error }
            cliDone.leave()
        }
        XCTAssertEqual(switchDone.wait(timeout: .now() + 5), .success)
        r.latch.open()
        XCTAssertEqual(cliDone.wait(timeout: .now() + 5), .success)

        guard case .success(.switched(to))? = switchResult else {
            return XCTFail("the switch did not commit: \(String(describing: switchResult))")
        }
        XCTAssertEqual(mutations, 0, "the CLI mutated after the switch committed")
        XCTAssertEqual(r.wire.sent("slice.next").count, 0)
        XCTAssertEqual(cliError as? ExitCode, .failure)
        XCTAssertEqual(r.io.out, [OutputLock.cliModeChangedMessage(now: to)])
        XCTAssertEqual(log.all, ["switch-pause", "cli-waiting", "switch-drop", "switch-committed"])
        XCTAssertTrue(S.isFree(r.env.routing.outputLock!.path))
    }

    func testABridgeMutationWaitingOnASwitchToMusicAppNeverRuns() {
        assertNoMutationAfterASwitch(from: .source, to: .musicApp) { env, count in
            try cliDispatch(.next, json: false, env: env, musicApp: { XCTFail() },
                            bridge: { try $0.mutate { count(); try $0.next() } })
        }
    }

    func testAMusicAppBodyWaitingOnASwitchToBridgeNeverRuns() {
        assertNoMutationAfterASwitch(from: .musicApp, to: .source) { env, count in
            try cliDispatch(.next, json: false, env: env, musicApp: { count() }, bridge: { _ in XCTFail() })
        }
    }

    func testWithCLIOutputLockWaitingOnASwitchNeverRuns() {
        assertNoMutationAfterASwitch(from: .musicApp, to: .source) { env, count in
            try withCLIOutputLock(expecting: .musicApp, env: env) { count() }
        }
    }

    // MARK: withCLIOutputLock

    func testWithCLIOutputLockRunsTheBodyUnderTheLock() throws {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        let lockPath = env.routing.outputLock!.path
        let held = try withCLIOutputLock(expecting: .musicApp, env: env) { !S.isFree(lockPath) }
        XCTAssertTrue(held)
        XCTAssertTrue(S.isFree(lockPath))
        XCTAssertEqual(io.out, [])
    }

    func testWithCLIOutputLockRefusesAModeItDidNotExpect() {
        for json in [false, true] {
            let io = CLIBridgeTestIO()
            let env = CLIBridgeEnv.test(mode: .source, io: io)
            var ran = false
            XCTAssertThrowsError(try withCLIOutputLock(expecting: .musicApp, json: json, env: env) { ran = true }) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
            XCTAssertFalse(ran)
            let message = OutputLock.cliModeChangedMessage(now: .source)
            if json {
                let doc = try? JSONSerialization.jsonObject(with: Data(io.out.first?.utf8 ?? "".utf8)) as? [String: Any]
                XCTAssertEqual(doc?["error"] as? String, message)
            } else {
                XCTAssertEqual(io.out, [message])
            }
        }
    }

    func testABusyLockRefusesInTheCLIsWords() throws {
        let io = CLIBridgeTestIO()
        let clock = OutputLockFakeClock()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io,
                                    outputLock: { S.advancingLock(path: $0, clock: clock) })
        let holder = BackgroundHolder(OutputLock(path: env.routing.outputLock!.path))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)
        defer { holder.release.signal(); _ = holder.done.wait(timeout: .now() + 5) }
        var ran = false
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env, musicApp: { ran = true }, bridge: { _ in })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertFalse(ran)
        XCTAssertEqual(io.out, [OutputLockError.busy.message(for: .cli)])
    }

    // MARK: every exit path releases the lock

    func testABodyThatThrowsInsideMutateLeavesTheLockFree() {
        let wire = BridgeLibraryReadsWire(["slice.status": [CLIBridgeReplies.status()]])
        let env = CLIBridgeEnv.test(mode: .source, wire: wire, surface: .tui)
        XCTAssertThrowsError(try cliDispatch(.next, json: false, env: env, musicApp: {},
                                             bridge: { try $0.mutate { _ in throw ActionError(message: "thrown inside") } }))
        XCTAssertTrue(S.isFree(env.routing.outputLock!.path))
    }

    func testABodyThatThrowsInsideWithCLIOutputLockLeavesTheLockFreeAndPassesThrough() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        XCTAssertThrowsError(try withCLIOutputLock(expecting: .musicApp, env: env) { throw ActionError(message: "speaker failed") }) {
            XCTAssertEqual(($0 as? ActionError)?.message, "speaker failed")
        }
        XCTAssertEqual(io.out, [], "a body's own error is not printed by the lock")
        XCTAssertTrue(S.isFree(env.routing.outputLock!.path))
    }

    // MARK: composition

    func testTheTestEnvKeepsEveryPathUnderTheTemporaryDirectory() {
        let a = CLIBridgeEnv.test(mode: .musicApp)
        let b = CLIBridgeEnv.test(mode: .musicApp)
        XCTAssertTrue(isUnderTemporaryDirectory(a.routing.outputLock!.path))
        XCTAssertTrue(isUnderTemporaryDirectory(a.cache.directory))
        XCTAssertNotEqual(a.routing.outputLock!.path, b.routing.outputLock!.path, "each env has its own lock")
        XCTAssertNotEqual(a.routing.outputLock!.path, NSTemporaryDirectory() + "output.lock")
    }

    func testDispatchSourceNamesNoMusicAppOrRESTBackend() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands/CLIBridgeDispatch.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["AppleScriptBackend", "runMusic", "osascript", "RESTAPIBackend", "AuthManager", "exclusively"] {
            XCTAssertFalse(text.contains(forbidden), "CLIBridgeDispatch.swift names \(forbidden)")
        }
    }
}

extension CLIBridgeEnv {
    /// A Bridge-mode env on an arbitrary transport, for failures the scripted
    /// wire cannot produce (the socket not answering at all).
    init(test mode: PlaybackMode, io: CLIBridgeTestIO,
         transport: @escaping (String, String) throws -> String) {
        let dir = NSTemporaryDirectory() + "music-test-clibridge-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PlaybackModeStore(path: dir + "/mode.json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: transport) },
                                         outputLock: OutputLock(path: store.lockPath))
        self.init(routing: routing, modeStore: store, cache: ResultCache(directory: dir + "/cache"),
                  out: io.writeOut, err: io.writeErr, sleep: io.sleep)
    }
}

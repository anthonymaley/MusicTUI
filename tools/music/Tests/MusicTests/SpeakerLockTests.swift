// tools/music/Tests/MusicTests/SpeakerLockTests.swift
//
// Slice 3 score, S8 (R1): a speaker action that can reach route healing runs
// its whole shipped body inside the output lock, with the mode revalidated, so
// a heal's pause→play cannot straddle a TUI Output switch. `list`, `verify` and
// the interactive picker take no lock.
//
// Executed through the command-owned path, `runSpeakerSmart(args:json:guard:
// execute:)`, with the REAL `withCLIOutputLock` on a temp store and lock and a
// fake `execute` standing in for the shipped body beneath the parse (the
// healer). The switch is a real `RoutingCoordinator.switchMode` on another
// thread (S1's barrier pattern). Orderings come from semaphores and latched
// locks, never from sleeping. No test reaches Music.app, AppleScript, REST, the
// real Bridge socket or ~/.config/music.
import ArgumentParser
import XCTest
@testable import music

final class SpeakerLockTests: XCTestCase {

    private typealias S = OutputLockTestSupport

    /// The live guard, on a test env: the real `withCLIOutputLock`.
    private func realGuard(_ env: CLIBridgeEnv, json: Bool = false) -> (() throws -> Void) throws -> Void {
        { body in try withCLIOutputLock(expecting: .musicApp, json: json, env: env, body) }
    }

    /// A TUI process's coordinator on the same temp store and lock path.
    private func tuiCoordinator(_ env: CLIBridgeEnv, lock: OutputLock) -> RoutingCoordinator {
        RoutingCoordinator(store: PlaybackModeStore(path: env.testDirectory + "/mode.json"),
                           surface: .tui,
                           makeSource: { SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning }) },
                           outputLock: lock)
    }

    // MARK: - Classification

    func testHealingActionsTakeTheLockAndReadsDoNot() throws {
        let cases: [(args: [String], action: SpeakerAction, locked: Bool)] = [
            (["Kitchen"], .add(name: "Kitchen"), true),
            (["Kitchen", "40"], .addWithVolume(name: "Kitchen", volume: 40), true),
            (["Kitchen", "stop"], .remove(name: "Kitchen"), true),
            (["Kitchen", "only"], .exclusive(name: "Kitchen"), true),
            (["1", "2"], .indices([1, 2]), true),
            (["wake"], .wake(name: nil), true),
            (["wake", "Kitchen"], .wake(name: "Kitchen"), true),
            (["list"], .list, false),
            (["verify"], .verify(name: nil), false),
            (["verify", "Kitchen"], .verify(name: "Kitchen"), false),
            ([], .interactive, false),
        ]
        for c in cases {
            XCTAssertEqual(speakerActionRequiresOutputLock(c.action), c.locked, "\(c.args)")
            var guardCalls = 0
            var insideGuard = false
            var executed: [(SpeakerAction, Bool, Bool)] = []
            try runSpeakerSmart(args: c.args, json: true,
                                guard: { body in guardCalls += 1; insideGuard = true; defer { insideGuard = false }; try body() },
                                execute: { action, json in executed.append((action, json, insideGuard)) })
            XCTAssertEqual(guardCalls, c.locked ? 1 : 0, "\(c.args)")
            XCTAssertEqual(executed.count, 1, "\(c.args)")
            XCTAssertEqual(executed.first?.0, c.action, "\(c.args)")
            XCTAssertEqual(executed.first?.1, true, "\(c.args): json passes through")
            XCTAssertEqual(executed.first?.2, c.locked, "\(c.args): the body runs inside the guard iff it locks")
        }
    }

    // MARK: - The executed ordering (R1), both orderings

    /// The speaker action holds the lock while its heal runs; a concurrent
    /// switch to Bridge waits for it. The recorded order is heal-start, play,
    /// switch-pause, switch-commit: the switch can never commit between the
    /// heal's pause and its play. Removing the guard call from
    /// `runSpeakerSmart` lets the switch run straight through and fails this.
    func testASwitchWaitsForAHealThatHoldsTheLock() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        let lockPath = env.routing.outputLock!.path
        let log = OutputLockLog()
        let latch = OutputLockLatch()
        // Signalled when the switch starts waiting on the lock, or, if it never
        // has to wait, when it finishes: so a missing guard shows as a wrong
        // order, not as a hang.
        let switchWaitingOrDone = DispatchSemaphore(value: 0)
        let tui = tuiCoordinator(env, lock: S.latchedLock(path: lockPath, latch: latch,
                                                          onWaiting: { switchWaitingOrDone.signal() }))

        let inHeal = DispatchSemaphore(value: 0)
        let barrier = DispatchSemaphore(value: 0)
        var executed: SpeakerAction?
        var speakerError: Error?
        let speakerDone = DispatchGroup()
        speakerDone.enter()
        DispatchQueue.global().async {
            do {
                try runSpeakerSmart(args: ["Kitchen"], json: false, guard: self.realGuard(env),
                                    execute: { action, _ in
                                        executed = action
                                        log.append("heal-start")
                                        inHeal.signal()
                                        _ = barrier.wait(timeout: .now() + 10)
                                        log.append("play")
                                    })
            } catch { speakerError = error }
            speakerDone.leave()
        }
        XCTAssertEqual(inHeal.wait(timeout: .now() + 5), .success)

        var switchResult: Result<RoutingCoordinator.SwitchResult, Error>?
        let switchDone = DispatchGroup()
        switchDone.enter()
        DispatchQueue.global().async {
            switchResult = Result {
                try tui.switchMode(to: .source, readiness: { .ready },
                                   pauseOutgoing: { _ in log.append("switch-pause"); return true },
                                   dropQueue: { _ in })
            }
            log.append("switch-commit")
            switchWaitingOrDone.signal()
            switchDone.leave()
        }
        XCTAssertEqual(switchWaitingOrDone.wait(timeout: .now() + 5), .success)
        barrier.signal()
        XCTAssertEqual(speakerDone.wait(timeout: .now() + 5), .success)
        latch.open()
        XCTAssertEqual(switchDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(log.all, ["heal-start", "play", "switch-pause", "switch-commit"])
        XCTAssertNil(speakerError)
        XCTAssertEqual(executed, .add(name: "Kitchen"))
        guard case .success(.switched(to: .source))? = switchResult else {
            return XCTFail("the switch did not commit after the heal: \(String(describing: switchResult))")
        }
        XCTAssertEqual(io.out, [])
        XCTAssertTrue(S.isFree(lockPath))
    }

    /// The other ordering: the switch holds the lock first and commits to
    /// Bridge while the speaker action waits. The speaker action then acquires,
    /// revalidates, and refuses in the CLI's words with its body run 0 times:
    /// no `play` is recorded. Removing the guard call fails this too.
    func testASpeakerActionWaitingOnASwitchRefusesOnRevalidationAndNeverPlays() {
        let io = CLIBridgeTestIO()
        let latch = OutputLockLatch()
        let cliWaiting = DispatchSemaphore(value: 0)
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io,
                                    outputLock: { S.latchedLock(path: $0, latch: latch, onWaiting: { cliWaiting.signal() }) })
        let lockPath = env.routing.outputLock!.path
        let tui = tuiCoordinator(env, lock: OutputLock(path: lockPath))
        let log = OutputLockLog()

        let inPause = DispatchSemaphore(value: 0)
        var switchResult: Result<RoutingCoordinator.SwitchResult, Error>?
        let switchDone = DispatchGroup()
        switchDone.enter()
        DispatchQueue.global().async {
            switchResult = Result {
                try tui.switchMode(to: .source, readiness: { .ready },
                                   pauseOutgoing: { _ in
                                       log.append("switch-pause")
                                       inPause.signal()
                                       _ = cliWaiting.wait(timeout: .now() + 10)
                                       return true
                                   },
                                   dropQueue: { _ in })
            }
            log.append("switch-commit")
            switchDone.leave()
        }
        XCTAssertEqual(inPause.wait(timeout: .now() + 5), .success)

        var speakerError: Error?
        let speakerDone = DispatchGroup()
        speakerDone.enter()
        DispatchQueue.global().async {
            do {
                try runSpeakerSmart(args: ["Kitchen", "only"], json: false, guard: self.realGuard(env),
                                    execute: { _, _ in log.append("heal-start"); log.append("play") })
            } catch { speakerError = error }
            speakerDone.leave()
        }
        XCTAssertEqual(switchDone.wait(timeout: .now() + 5), .success)
        latch.open()
        XCTAssertEqual(speakerDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(log.all, ["switch-pause", "switch-commit"], "the speaker action ran after the switch committed")
        XCTAssertEqual(speakerError as? ExitCode, .failure)
        XCTAssertEqual(io.out, [OutputLock.cliModeChangedMessage(now: .source)])
        guard case .success(.switched(to: .source))? = switchResult else {
            return XCTFail("the switch did not commit: \(String(describing: switchResult))")
        }
        XCTAssertTrue(S.isFree(lockPath))
    }

    // MARK: - Reads take no lock

    /// `list`, `verify` and the picker run while another process holds the
    /// lock, at once, with nothing printed. If any of them took the lock, the
    /// advancing (never-sleeping) waiter would give up and refuse instead.
    func testListVerifyAndThePickerAreNotDelayedByAHeldLock() throws {
        for args in [["list"], ["verify"], ["verify", "Kitchen"], []] {
            let io = CLIBridgeTestIO()
            let clock = OutputLockFakeClock()
            let env = CLIBridgeEnv.test(mode: .musicApp, io: io,
                                        outputLock: { S.advancingLock(path: $0, clock: clock) })
            let holder = BackgroundHolder(OutputLock(path: env.routing.outputLock!.path))
            XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)
            var ran = 0
            XCTAssertNoThrow(try runSpeakerSmart(args: args, json: false, guard: realGuard(env),
                                                 execute: { _, _ in ran += 1 }), "\(args)")
            holder.release.signal()
            _ = holder.done.wait(timeout: .now() + 5)
            XCTAssertEqual(ran, 1, "\(args)")
            XCTAssertEqual(io.out, [], "\(args)")
            XCTAssertEqual(io.err, [], "\(args): it never waited")
        }
    }

    /// A healing action under a held lock refuses in the CLI's busy words and
    /// runs nothing (the advancing clock stands in for the 30 s bound).
    func testAHealingActionUnderAHeldLockRefusesBusyAndRunsNothing() {
        let io = CLIBridgeTestIO()
        let clock = OutputLockFakeClock()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io,
                                    outputLock: { S.advancingLock(path: $0, clock: clock) })
        let holder = BackgroundHolder(OutputLock(path: env.routing.outputLock!.path))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)
        defer { holder.release.signal(); _ = holder.done.wait(timeout: .now() + 5) }
        var ran = 0
        XCTAssertThrowsError(try runSpeakerSmart(args: ["wake"], json: false, guard: realGuard(env),
                                                 execute: { _, _ in ran += 1 })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(io.out, [OutputLockError.busy.message(for: .cli)])
    }

    /// The shipped body's own error passes through untouched and unprinted, and
    /// the lock is free afterwards.
    func testTheShippedBodysErrorPassesThroughAndReleasesTheLock() {
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv.test(mode: .musicApp, io: io)
        XCTAssertThrowsError(try runSpeakerSmart(args: ["Kitchen"], json: false, guard: realGuard(env),
                                                 execute: { _, _ in throw AppleScriptBackend.ScriptError.speakerUnavailable("Kitchen") })) {
            guard case AppleScriptBackend.ScriptError.speakerUnavailable("Kitchen")? = $0 as? AppleScriptBackend.ScriptError else {
                return XCTFail("the body's error was replaced: \($0)")
            }
        }
        XCTAssertEqual(io.out, [])
        XCTAssertTrue(S.isFree(env.routing.outputLock!.path))
    }

    // MARK: - Bridge mode

    /// Backstop, executed: were a healing action to get past the entry gate
    /// with Bridge selected, the guard's revalidation refuses it before the
    /// body. The entry gate itself is checked structurally below and in
    /// CLIInventoryTests.
    func testWithBridgeSelectedAHealingActionNeverReachesItsBody() {
        for json in [false, true] {
            let io = CLIBridgeTestIO()
            let env = CLIBridgeEnv.test(mode: .source, io: io)
            var ran = 0
            XCTAssertThrowsError(try runSpeakerSmart(args: ["Kitchen", "40"], json: json, guard: realGuard(env, json: json),
                                                     execute: { _, _ in ran += 1 }))
            XCTAssertEqual(ran, 0)
            XCTAssertEqual(io.out, [cliFailureText(OutputLock.cliModeChangedMessage(now: .source), json: json)])
        }
    }

    /// Every speaker entry and `volume` refuse with Bridge selected, in their
    /// TUI-table words, through the real gate function (the mode is passed in:
    /// the command's own read is `~/.config/music`, which tests never touch).
    func testTheGateRefusesSpeakersAndVolumeOnBridge() {
        for action in [MusicTUIAction.airplayRoute, .volume] {
            guard case .refused(let why) = routeAction(action, in: .source, from: .tui) else {
                return XCTFail("\(action)")
            }
            for json in [false, true] {
                let printed = captureStdout { try refuseInBridge(action, json: json, mode: .source) }
                XCTAssertEqual(printed.output, cliFailureText(why, json: json) + "\n", "\(action)")
            }
            XCTAssertNoThrow(try refuseInBridge(action, mode: .musicApp))
        }
    }

    // MARK: - The live wiring (STRUCTURAL: source text, not execution evidence)

    /// The two-argument `runSpeakerSmart` every command calls passes the live
    /// values: the real `withCLIOutputLock`, expecting Music.app, and
    /// `executeSpeakerAction`. And every speaker subcommand's `run()` starts
    /// with the Bridge gate for `.airplayRoute`.
    func testTheLiveEntryPointsWireTheGateTheLockAndTheShippedBody() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands/SpeakerCommands.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        guard let decl = source.range(of: "\nfunc runSpeakerSmart(args: [String], json: Bool) throws {\n"),
              let end = source.range(of: "\n}\n", range: decl.upperBound..<source.endIndex)
        else { return XCTFail("the two-argument runSpeakerSmart is missing") }
        let body = String(source[decl.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("withCLIOutputLock(expecting: .musicApp"), body)
        XCTAssertTrue(body.contains("execute: executeSpeakerAction"), body)

        for command in ["SpeakerSmart", "SpeakerList", "SpeakerSet", "SpeakerAdd", "SpeakerRemove", "SpeakerStop"] {
            guard let d = source.range(of: "struct \(command): ParsableCommand"),
                  let run = source.range(of: "func run() throws {\n", range: d.upperBound..<source.endIndex)
            else { XCTFail("\(command) not found"); continue }
            let first = source[run.upperBound...].prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(first.hasPrefix("try refuseInBridge(.airplayRoute"), "\(command).run() starts with: \(first)")
        }
    }
}

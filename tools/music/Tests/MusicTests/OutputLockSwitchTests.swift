// tools/music/Tests/MusicTests/OutputLockSwitchTests.swift
//
// The TUI's switch transaction under the cross-process output lock (slice 3
// score, D6 and S1). A second `OutputLock` on the same temp path, on another
// thread, stands in for a CLI command: it takes the lock, revalidates the
// persisted mode against the mode it read at start, and runs a counting
// mutation only if they still agree. That is the protocol S5's `mutate`
// implements; here it is spelled out so the switch side can be proven alone.
//
// Orderings are produced by barriers (the switch's own callbacks and the
// lock's `onWaiting` hook), never by sleeping.
import XCTest
@testable import music

final class OutputLockSwitchTests: XCTestCase {

    private typealias S = OutputLockTestSupport

    private func fakeClient() -> SourceAppClient {
        SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning })
    }

    /// A temp store in its own directory, so its `output.lock` is its own.
    /// `path` is kept so a test can open a second store on the same file, the
    /// way another process would.
    private struct TempStore {
        let path: String
        let store: PlaybackModeStore
        var lockPath: String { store.lockPath }
        func mode() -> PlaybackMode { store.mode() }
    }

    private func store(_ mode: PlaybackMode) -> TempStore {
        let path = S.tempDir() + "/mode.json"
        let s = PlaybackModeStore(path: path)
        s.set(mode)
        return TempStore(path: path, store: s)
    }

    private func coordinator(_ temp: TempStore, lock: OutputLock? = nil) -> RoutingCoordinator {
        RoutingCoordinator(store: temp.store, surface: .tui, makeSource: { self.fakeClient() },
                           outputLock: lock ?? OutputLock(path: temp.lockPath))
    }

    /// The CLI's side of D6, reduced to its protocol: lock, revalidate, mutate.
    private func cliMutation(lock: OutputLock, store: PlaybackModeStore,
                             expecting: PlaybackMode, log: OutputLockLog,
                             mutation: () -> Void) throws {
        try lock.withLock {
            log.append("cli-acquired")
            let now = store.mode()
            guard now == expecting else {
                throw ActionError(message: OutputLock.cliModeChangedMessage(now: now))
            }
            mutation()
        }
    }

    // MARK: lockPath

    func testTheLockSitsBesideModeJSON() {
        let dir = S.tempDir()
        XCTAssertEqual(PlaybackModeStore(path: dir + "/mode.json").lockPath, dir + "/output.lock")
        XCTAssertEqual(PlaybackModeStore().lockPath,
                       NSString(string: "~/.config/music/output.lock").expandingTildeInPath)
    }

    func testTheCoordinatorExposesItsLock() {
        let s = store(.musicApp)
        let lock = OutputLock(path: s.lockPath)
        XCTAssertTrue(coordinator(s, lock: lock).outputLock === lock)
        XCTAssertNil(RoutingCoordinator(store: s.store, surface: .tui, makeSource: { self.fakeClient() }).outputLock)
    }

    // MARK: Codex's schedule

    /// The switch holds the lock inside `pauseOutgoing`; a CLI command reaches
    /// the wait; the switch saves and commits; the CLI then acquires, finds the
    /// output changed, and its mutation runs 0 times.
    private func assertCLIWaitingOnASwitchNeverMutates(from: PlaybackMode, to: PlaybackMode) throws {
        let s = store(from)
        let c = coordinator(s)
        let log = OutputLockLog()
        let inPause = DispatchSemaphore(value: 0)
        let cliWaiting = DispatchSemaphore(value: 0)
        let switchDone = DispatchGroup()
        let cliDone = DispatchGroup()
        var switchResult: Result<RoutingCoordinator.SwitchResult, Error>?
        var cliError: Error?
        var mutations = 0

        // The CLI read the mode at its start, before the switch.
        let cliExpects = s.mode()
        XCTAssertEqual(cliExpects, from)

        switchDone.enter()
        DispatchQueue.global().async {
            switchResult = Result {
                try c.switchMode(to: to, readiness: { .ready },
                                 pauseOutgoing: { _ in
                                     log.append("switch-pause")
                                     inPause.signal()
                                     _ = cliWaiting.wait(timeout: .now() + 10)
                                     return true
                                 },
                                 dropQueue: { _ in log.append("switch-drop") })
            }
            log.append("switch-returned")
            switchDone.leave()
        }
        XCTAssertEqual(inPause.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(S.isFree(s.lockPath), "the switch does not hold the lock inside pauseOutgoing")

        let latch = OutputLockLatch()
        let cliLock = S.latchedLock(path: s.lockPath, latch: latch, onWaiting: {
            log.append("cli-waiting")
            cliWaiting.signal()
        })
        cliDone.enter()
        DispatchQueue.global().async {
            do {
                try self.cliMutation(lock: cliLock, store: PlaybackModeStore(path: s.path),
                                     expecting: cliExpects, log: log) {
                    log.append("cli-mutation"); mutations += 1
                }
            } catch {
                cliError = error
            }
            cliDone.leave()
        }

        XCTAssertEqual(switchDone.wait(timeout: .now() + 5), .success)
        latch.open()
        XCTAssertEqual(cliDone.wait(timeout: .now() + 5), .success)

        guard case .success(.switched(let mode))? = switchResult else {
            return XCTFail("the switch did not commit: \(String(describing: switchResult))")
        }
        XCTAssertEqual(mode, to)
        XCTAssertEqual(c.mode, to)
        XCTAssertEqual(s.mode(), to)
        XCTAssertEqual(mutations, 0, "the CLI mutated after the switch committed")
        XCTAssertEqual((cliError as? ActionError)?.message, OutputLock.cliModeChangedMessage(now: to))
        XCTAssertEqual(log.all, ["switch-pause", "cli-waiting", "switch-drop", "switch-returned", "cli-acquired"])
        XCTAssertTrue(S.isFree(s.lockPath))
    }

    func testACLICommandWaitingOnABridgeToMusicAppSwitchNeverMutates() throws {
        try assertCLIWaitingOnASwitchNeverMutates(from: .source, to: .musicApp)
    }

    func testACLICommandWaitingOnAMusicAppToBridgeSwitchNeverMutates() throws {
        try assertCLIWaitingOnASwitchNeverMutates(from: .musicApp, to: .source)
    }

    // MARK: a holder delays the switch

    /// A CLI mutation in flight delays the switch: the switch's pause runs only
    /// after the mutation has finished and released the lock.
    func testAHolderMidMutationDelaysTheSwitch() throws {
        let s = store(.musicApp)
        let log = OutputLockLog()
        let latch = OutputLockLatch()
        let switchWaiting = DispatchSemaphore(value: 0)
        let c = coordinator(s, lock: S.latchedLock(path: s.lockPath, latch: latch, onWaiting: {
            log.append("switch-waiting")
            switchWaiting.signal()
        }))

        let inMutation = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let cliDone = DispatchGroup()
        var mutations = 0
        cliDone.enter()
        DispatchQueue.global().async {
            try? self.cliMutation(lock: OutputLock(path: s.lockPath), store: PlaybackModeStore(path: s.path),
                                  expecting: .musicApp, log: log) {
                log.append("cli-mutation-start")
                inMutation.signal()
                _ = proceed.wait(timeout: .now() + 10)
                log.append("cli-mutation-end")
                mutations += 1
            }
            cliDone.leave()
        }
        XCTAssertEqual(inMutation.wait(timeout: .now() + 5), .success)

        let switchDone = DispatchGroup()
        var switchResult: Result<RoutingCoordinator.SwitchResult, Error>?
        switchDone.enter()
        DispatchQueue.global().async {
            switchResult = Result {
                try c.switchMode(to: .source, readiness: { log.append("switch-readiness"); return .ready },
                                 pauseOutgoing: { _ in log.append("switch-pause"); return true },
                                 dropQueue: { _ in log.append("switch-drop") })
            }
            switchDone.leave()
        }
        XCTAssertEqual(switchWaiting.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(log.all, ["cli-acquired", "cli-mutation-start", "switch-waiting"],
                       "the switch ran a step while the CLI held the lock")

        proceed.signal()
        XCTAssertEqual(cliDone.wait(timeout: .now() + 5), .success)
        latch.open()
        XCTAssertEqual(switchDone.wait(timeout: .now() + 5), .success)

        guard case .success(.switched(.source))? = switchResult else {
            return XCTFail("the switch did not commit: \(String(describing: switchResult))")
        }
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(log.all, ["cli-acquired", "cli-mutation-start", "switch-waiting", "cli-mutation-end",
                                 "switch-readiness", "switch-pause", "switch-drop"])
        XCTAssertEqual(c.mode, .source)
    }

    // MARK: the whole transaction is under the lock

    func testEveryStepRunsUnderTheLockAndItIsReleasedAfterACommit() throws {
        let s = store(.musicApp)
        let c = coordinator(s)
        var held: [String: Bool] = [:]
        let result = try c.switchMode(to: .source,
                                      readiness: { held["readiness"] = !S.isFree(s.lockPath); return .ready },
                                      pauseOutgoing: { _ in held["pause"] = !S.isFree(s.lockPath); return true },
                                      dropQueue: { _ in held["drop"] = !S.isFree(s.lockPath) })
        XCTAssertEqual(result, .switched(to: .source))
        XCTAssertEqual(held, ["readiness": true, "pause": true, "drop": true])
        XCTAssertTrue(S.isFree(s.lockPath), "a committed switch kept the lock")
    }

    // MARK: failure paths

    func testASwitchFailingAtDropQueueReleasesTheLockAndLeavesTheModeUnchanged() {
        let s = store(.musicApp)
        let c = coordinator(s)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true },
                                              dropQueue: { _ in throw SourceAppError.notRunning })) { error in
            XCTAssertEqual((error as? ActionError)?.message, "Couldn't clear Music.app's queue; still using it",
                           "the shipped message changed")
        }
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(s.mode(), .musicApp)
        XCTAssertTrue(S.isFree(s.lockPath), "a failed switch kept the lock")
    }

    func testAnUnconfirmedPauseReleasesTheLockWithTheShippedMessage() {
        let s = store(.source)
        let c = coordinator(s)
        XCTAssertThrowsError(try c.switchMode(to: .musicApp, readiness: { .ready },
                                              pauseOutgoing: { _ in false }, dropQueue: { _ in })) { error in
            XCTAssertEqual((error as? ActionError)?.message, "Couldn't confirm Bridge paused; still using it")
        }
        XCTAssertEqual(c.mode, .source)
        XCTAssertTrue(S.isFree(s.lockPath))
    }

    /// Another process (a second TUI, or anything that wrote mode.json) moved
    /// the selection: this TUI's in-memory mode is stale, and switching from it
    /// could pause the wrong player. It refuses and touches nothing.
    func testAModeChangedByAnotherProcessMakesTheSwitchRefuse() {
        let s = store(.musicApp)
        let c = coordinator(s)
        PlaybackModeStore(path: s.path).set(.source)
        let log = OutputLockLog()
        XCTAssertThrowsError(try c.switchMode(to: .source,
                                              readiness: { log.append("readiness"); return .ready },
                                              pauseOutgoing: { _ in log.append("pause"); return true },
                                              dropQueue: { _ in log.append("drop") })) { error in
            XCTAssertEqual((error as? ActionError)?.message,
                           "Output was changed by another MusicTUI process; nothing was switched.")
        }
        XCTAssertEqual(log.all, [], "a stale switch ran a step")
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(s.mode(), .source, "the refusal wrote the store")
        XCTAssertTrue(S.isFree(s.lockPath))
    }

    /// A long CLI holder makes the switch give up after the bound with the TUI
    /// sentence; nothing is paused, dropped or saved, and the holder is left alone.
    func testASwitchWaitingPastTheBoundRefusesAndTouchesNothing() {
        let s = store(.musicApp)
        let holder = BackgroundHolder(OutputLock(path: s.lockPath))
        XCTAssertEqual(holder.acquired.wait(timeout: .now() + 5), .success)

        let clock = OutputLockFakeClock()
        let c = coordinator(s, lock: S.advancingLock(path: s.lockPath, clock: clock))
        let log = OutputLockLog()
        XCTAssertThrowsError(try c.switchMode(to: .source,
                                              readiness: { log.append("readiness"); return .ready },
                                              pauseOutgoing: { _ in log.append("pause"); return true },
                                              dropQueue: { _ in log.append("drop") })) { error in
            XCTAssertEqual((error as? ActionError)?.message,
                           "A music command is changing playback; nothing was switched.")
        }
        XCTAssertEqual(log.all, [])
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(s.mode(), .musicApp)
        XCTAssertFalse(S.isFree(s.lockPath), "the waiting switch disturbed the holder")
        holder.release.signal()
        XCTAssertEqual(holder.done.wait(timeout: .now() + 5), .success)
    }

    func testAnUnopenableLockRefusesTheSwitchNamingThePath() {
        let dir = S.tempDir()
        let file = dir + "/a-file"
        FileManager.default.createFile(atPath: file, contents: Data())
        let s = TempStore(path: file + "/mode.json", store: PlaybackModeStore(path: file + "/mode.json"))
        let c = coordinator(s)
        let log = OutputLockLog()
        XCTAssertThrowsError(try c.switchMode(to: .source,
                                              readiness: { log.append("readiness"); return .ready },
                                              pauseOutgoing: { _ in log.append("pause"); return true },
                                              dropQueue: { _ in log.append("drop") })) { error in
            let message = (error as? ActionError)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("Couldn't open the output lock at \(s.lockPath) ("), message)
            XCTAssertTrue(message.hasSuffix("); nothing was switched."), message)
        }
        XCTAssertEqual(log.all, [], "an unopenable lock must fail closed")
        XCTAssertEqual(c.mode, .musicApp)
    }

    /// The TUI never nests a switch in a switch, but if a branch ever did, the
    /// in-process boundary's own guard answers first, with the same sentence.
    func testASwitchInsideASwitchThrowsTheInternalError() throws {
        let s = store(.musicApp)
        let c = coordinator(s)
        var inner: Error?
        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in
                                 do { _ = try c.switchMode(to: .source, readiness: { .ready },
                                                           pauseOutgoing: { _ in true }, dropQueue: { _ in }) }
                                 catch { inner = error }
                                 return true
                             },
                             dropQueue: { _ in })
        XCTAssertEqual((inner as? ActionError)?.message, OutputLockTests.internalError)
    }

    // MARK: composition, read from the source

    private func sourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Production builds the coordinator only through `live`, and `live` always
    /// hands it the lock beside the store's mode.json. Read from the source: a
    /// call site that builds its own coordinator compiles and passes every
    /// behavioural test while silently skipping the lock.
    func testProductionConstructsTheCoordinatorOnlyThroughLiveWithTheLock() throws {
        let root = sourcesDir()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no sources under \(root.path)")

        var constructions: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("RoutingCoordinator(") {
                    constructions.append("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(constructions.count, 1, "more than one production construction: \(constructions)")
        XCTAssertTrue(constructions.first?.hasPrefix("RoutingCoordinator.swift:") ?? false, "\(constructions)")
        XCTAssertTrue(constructions.first?.contains("outputLock: OutputLock(path: store.lockPath)") ?? false,
                      "live does not pass the store's lock: \(constructions)")

        let coordinator = try String(contentsOf: root.appendingPathComponent("TUI/RoutingCoordinator.swift"), encoding: .utf8)
        guard let liveRange = coordinator.range(of: "static func live(") else {
            return XCTFail("no live composition")
        }
        let liveBody = coordinator[liveRange.lowerBound...].prefix(400)
        XCTAssertTrue(liveBody.contains("outputLock: OutputLock(path: store.lockPath)"),
                      "the construction is not inside live")
    }

    /// D6: the coordinator exposes the lock, never a way into its in-process
    /// boundary, so the CLI's `mutate` (already inside `perform`) takes the
    /// file lock directly rather than re-entering `exclusively`.
    func testTheInProcessBoundaryStaysPrivate() throws {
        let text = try String(contentsOf: sourcesDir().appendingPathComponent("TUI/RoutingCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("private func exclusively<"), "exclusively is no longer private")
        XCTAssertTrue(text.contains("let outputLock: OutputLock?"), "the lock is not exposed read-only")
    }
}

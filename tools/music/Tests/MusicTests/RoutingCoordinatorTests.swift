// tools/music/Tests/MusicTests/RoutingCoordinatorTests.swift
//
// The execution half of the routing seam (docs/plans/2026-09-13-routing-seam-design.md).
// routeAction decides WHERE an action goes; RoutingCoordinator makes that
// decision at the moment the action runs, against the mode in memory, in one
// order shared with mode switching.
//
// The tests are Codex's list from the design review, numbered as there:
//   1. Music.app mode never invokes the source execution factory (DoD 7)
//   2. Source Mode reaches Music.app only for the named rows (rule 3, rule 9)
//   3. A refusal runs neither backend and keeps its reason
//   4. A switch changes the next action without restarting or rereading
//   5. An action overlapping a switch never runs on the outgoing backend
// plus the composition point the CLI will use (B2).
import XCTest
@testable import music

final class RoutingCoordinatorTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "music-test-routing-\(UUID().uuidString).json"
    }

    /// Counts factory calls and records which branch each action ran.
    private final class Recorder {
        private let lock = NSLock()
        private(set) var factoryCalls = 0
        private var _log: [String] = []
        var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
        func append(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }
        func madeSource() { lock.lock(); factoryCalls += 1; lock.unlock() }
    }

    private func fakeClient() -> SourceAppClient {
        SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning })
    }

    private func coordinator(mode: PlaybackMode, recorder: Recorder,
                             path: String? = nil) -> RoutingCoordinator {
        let store = PlaybackModeStore(path: path ?? tempPath())
        store.set(mode)
        return RoutingCoordinator(store: store, makeSource: {
            recorder.madeSource()
            return self.fakeClient()
        })
    }

    private func run(_ c: RoutingCoordinator, _ action: MusicTUIAction, _ r: Recorder) throws {
        try c.perform(action,
                      musicApp: { r.append("musicApp") },
                      source: { _ in r.append("source") },
                      unaffected: { r.append("unaffected") })
    }

    // MARK: 1

    func testMusicAppModeNeverInvokesTheSourceFactory() throws {
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r)
        for action in MusicTUIAction.allCases {
            try run(c, action, r)
        }
        XCTAssertEqual(r.factoryCalls, 0, "Music.app mode constructed a source client")
        XCTAssertFalse(r.log.contains("source"))
        XCTAssertEqual(r.log.count, MusicTUIAction.allCases.count,
                       "every action should run a branch; nothing is refused in Music.app mode")
    }

    // MARK: 2

    /// The complete set of rows allowed to reach Music.app in Source Mode, named
    /// rather than derived. Listing reads stay on AppleScript by rule 9; EQ, the
    /// visualizer and playlist share are rows the spec leaves as they are.
    private let musicAppInSourceMode: Set<MusicTUIAction> = [
        .libraryListing, .playlistListing, .searchLibrary, .libraryRetry,
        .eq, .visualizer, .playlistShare,
    ]

    func testSourceModeReachesMusicAppOnlyForTheNamedRows() {
        var reached: Set<MusicTUIAction> = []
        for action in MusicTUIAction.allCases {
            let r = Recorder()
            let c = coordinator(mode: .source, recorder: r)
            try? run(c, action, r)
            if r.log.contains("musicApp") { reached.insert(action) }
        }
        XCTAssertEqual(reached, musicAppInSourceMode)
        XCTAssertTrue(reached.allSatisfy { !$0.touchesPlayback },
                      "a playback action reached Music.app in Source Mode")
    }

    // MARK: 3

    func testRefusalRunsNeitherBackendAndKeepsItsReason() {
        let r = Recorder()
        let c = coordinator(mode: .source, recorder: r)
        guard case .refused(let reason) = routeAction(.volume, in: .source) else {
            return XCTFail("volume should be refused in Source Mode")
        }
        XCTAssertThrowsError(try run(c, .volume, r)) { error in
            XCTAssertEqual((error as? ActionError)?.message, reason)
        }
        XCTAssertEqual(r.log, [])
        XCTAssertEqual(r.factoryCalls, 0)
    }

    // MARK: 4

    func testSwitchChangesTheNextActionWithoutRereadingTheFile() throws {
        let path = tempPath()
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r, path: path)

        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        try run(c, .playPause, r)
        XCTAssertEqual(r.log, ["source"])

        // Behind the coordinator's back, the file says Music.app. The mode in
        // memory is the truth for the life of the process.
        PlaybackModeStore(path: path).set(.musicApp)
        try run(c, .playPause, r)
        XCTAssertEqual(r.log, ["source", "source"])
        XCTAssertEqual(c.mode, .source)
    }

    func testSwitchPersistsSoARestartKeepsIt() throws {
        let path = tempPath()
        let c = coordinator(mode: .musicApp, recorder: Recorder(), path: path)
        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .source)
    }

    // MARK: 5

    /// The Blocking shape from B1: a route decided when the key is pressed can
    /// run after a switch commits. Here the action provably reaches the boundary
    /// while the switch is mid-transaction (its pause is held open), so a route
    /// read before the boundary sees Music.app and would run there.
    func testActionOverlappingASwitchRunsOnTheIncomingBackend() throws {
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r)
        let pausing = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        let done = DispatchGroup()

        done.enter()
        DispatchQueue.global().async {
            _ = try? c.switchMode(to: .source, readiness: { .ready },
                                  pauseOutgoing: { _ in
                                      pausing.signal()
                                      releasePause.wait()
                                      r.append("paused")
                                      return true
                                  },
                                  dropQueue: { _ in r.append("dropped") })
            done.leave()
        }
        XCTAssertEqual(pausing.wait(timeout: .now() + 5), .success, "the switch never began pausing")

        let reached = DispatchSemaphore(value: 0)
        c.onReachingBoundary { reached.signal() }
        done.enter()
        DispatchQueue.global().async {
            try? self.run(c, .playPause, r)
            done.leave()
        }
        // Positive handshake, not a sleep: the action has reached the boundary
        // while the switch still holds its pause open.
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success, "the action never reached the boundary")
        releasePause.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(r.log, ["paused", "dropped", "source"])
    }

    // MARK: the switch transaction (rule 4)

    func testSwitchRefusedWhenTheSourceIsNotReady() {
        let path = tempPath()
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r, path: path)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .disconnected },
                                              pauseOutgoing: { _ in r.append("paused"); return true },
                                              dropQueue: { _ in r.append("dropped") }))
        XCTAssertEqual(r.log, [], "readiness is checked before anything is touched")
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    func testModeUnchangedWhenPauseCannotBeConfirmed() {
        let path = tempPath()
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r, path: path)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in false },
                                              dropQueue: { _ in r.append("dropped") }))
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in throw SourceAppError.notRunning },
                                              dropQueue: { _ in r.append("dropped") }))
        XCTAssertEqual(r.log, [], "the queue is not dropped for a switch that did not happen")
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    /// A switch that cannot be saved does not happen: otherwise the session and
    /// the next launch disagree about which player MusicTUI drives. The queue is
    /// already gone by then, and ruling 12.3 only confirms that loss while
    /// playback is active, so the failure must SAY the queue was cleared rather
    /// than implying nothing changed (Codex, 12:40).
    func testModeUnchangedWhenTheSelectionCannotBeSaved() {
        let r = Recorder()
        let store = PlaybackModeStore(path: "/dev/null/cannot/mode.json")
        let c = RoutingCoordinator(store: store, makeSource: { r.madeSource(); return self.fakeClient() })
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true },
                                              dropQueue: { _ in r.append("dropped") })) { error in
            let message = (error as? ActionError)?.message ?? ""
            XCTAssertTrue(message.contains("queue was cleared"), "the partial outcome is hidden: \(message)")
        }
        XCTAssertEqual(r.log, ["dropped"])
        XCTAssertEqual(c.mode, .musicApp)
    }

    /// Ruling 12.3: the queue is dropped at a switch. A switch whose queue
    /// could not be dropped does not happen, and nothing is saved.
    func testModeUnchangedWhenTheQueueCannotBeDropped() {
        let path = tempPath()
        let c = coordinator(mode: .musicApp, recorder: Recorder(), path: path)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true },
                                              dropQueue: { _ in throw SourceAppError.notRunning }))
        XCTAssertEqual(c.mode, .musicApp)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    /// A switch can wait behind a slow action, so readiness is read when the
    /// switch actually runs, not when it was requested.
    func testReadinessIsEvaluatedInsideTheBoundary() throws {
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r)
        let inAction = DispatchSemaphore(value: 0)
        let releaseAction = DispatchSemaphore(value: 0)
        let done = DispatchGroup()

        done.enter()
        DispatchQueue.global().async {
            try? c.perform(.playPause,
                           musicApp: { inAction.signal(); releaseAction.wait(); r.append("action") },
                           source: { _ in }, unaffected: {})
            done.leave()
        }
        XCTAssertEqual(inAction.wait(timeout: .now() + 5), .success)

        let reached = DispatchSemaphore(value: 0)
        c.onReachingBoundary { reached.signal() }
        done.enter()
        DispatchQueue.global().async {
            _ = try? c.switchMode(to: .source,
                                  readiness: { r.append("readiness"); return .ready },
                                  pauseOutgoing: { _ in true }, dropQueue: { _ in })
            done.leave()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        releaseAction.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(r.log, ["action", "readiness"])
    }

    /// A factory that reads `mode` must not deadlock against the coordinator's
    /// own state lock.
    func testSourceFactoryMayReadTheMode() {
        let path = tempPath()
        PlaybackModeStore(path: path).set(.source)
        var c: RoutingCoordinator!
        c = RoutingCoordinator(store: PlaybackModeStore(path: path),
                               makeSource: { _ = c.mode; return self.fakeClient() })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? c.perform(.playPause, musicApp: {}, source: { _ in }, unaffected: {})
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the source factory deadlocked")
    }

    /// The pause and queue drop address the OUTGOING mode, never the incoming.
    func testTransactionAddressesTheOutgoingMode() throws {
        let r = Recorder()
        let c = coordinator(mode: .musicApp, recorder: r)
        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { m in r.append("pause \(m)"); return true },
                             dropQueue: { m in r.append("drop \(m)") })
        XCTAssertEqual(r.log, ["pause musicApp", "drop musicApp"])
    }

    func testSwitchingToTheCurrentModeTouchesNothing() throws {
        let r = Recorder()
        let c = coordinator(mode: .source, recorder: r)
        let result = try c.switchMode(to: .source, readiness: { .disconnected },
                                      pauseOutgoing: { _ in r.append("paused"); return true },
                                      dropQueue: { _ in r.append("dropped") })
        XCTAssertEqual(result, .alreadyInMode)
        XCTAssertEqual(r.log, [])
    }

    /// Music.app needs nothing to be reachable, so leaving the source never
    /// waits on its readiness.
    func testSwitchToMusicAppIgnoresSourceReadiness() throws {
        let c = coordinator(mode: .source, recorder: Recorder())
        _ = try c.switchMode(to: .musicApp, readiness: { .disconnected },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: ordering boundary

    /// A branch calling back into the coordinator would wait on itself forever
    /// and silently wedge the shell's action queue. It fails visibly instead.
    func testReentrantCallFailsInsteadOfDeadlocking() {
        let c = coordinator(mode: .musicApp, recorder: Recorder())
        var inner: Error?
        XCTAssertNoThrow(try c.perform(.playPause,
                                       musicApp: {
                                           do { try c.perform(.next, musicApp: {}, source: { _ in }, unaffected: {}) }
                                           catch { inner = error }
                                       },
                                       source: { _ in }, unaffected: {}))
        XCTAssertNotNil(inner, "a nested perform must throw rather than block")
    }

    // MARK: the CLI's view of a refusal (Codex, 11:47)

    /// A CLI command that lets a refusal escape prints the matrix's reason, not
    /// `ActionError(message: ...)`, because ArgumentParser renders a
    /// `LocalizedError` by its description.
    func testCLIPrintsARefusalsReason() {
        let c = coordinator(mode: .source, recorder: Recorder())
        guard case .refused(let reason) = routeAction(.volume, in: .source) else {
            return XCTFail("volume should be refused in Source Mode")
        }
        do {
            try c.perform(.volume, musicApp: {}, source: { _ in }, unaffected: {})
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(Music.message(for: error), reason)
        }
    }

    // MARK: composition (B2)

    /// The one composition both processes use: the TUI once at launch, each CLI
    /// command once per invocation. It reads the persisted selection.
    func testLiveCompositionReadsThePersistedSelection() {
        let path = tempPath()
        PlaybackModeStore(path: path).set(.source)
        XCTAssertEqual(RoutingCoordinator.live(store: PlaybackModeStore(path: path)).mode, .source)
        XCTAssertEqual(RoutingCoordinator.live(store: PlaybackModeStore(path: tempPath())).mode, .musicApp)
    }
}

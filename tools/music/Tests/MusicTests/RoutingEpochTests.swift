// tools/music/Tests/MusicTests/RoutingEpochTests.swift
//
// Slice 3 Part 2, score P2, decision D3: "choice inside the lock, round trip
// outside, result carries an epoch." `RoutingCoordinator.epoch` starts at 0
// and increments exactly once per COMMITTED switch, so a caller (Radio, P5)
// can stamp an async result with the epoch its provider was chosen under and
// drop it at drain time if the epoch has since moved on.
//
// Patterns reused from RoutingCoordinatorTests (S1) and OutputLockSwitchTests:
// barriers and hooks, never sleeps, for every concurrency claim.
import XCTest
@testable import music

final class RoutingEpochTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "music-test-epoch-\(UUID().uuidString).json"
    }

    private func fakeClient() -> SourceAppClient {
        SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning })
    }

    private func coordinator(mode: PlaybackMode, path: String? = nil,
                             outputLock: OutputLock? = nil) -> RoutingCoordinator {
        let store = PlaybackModeStore(path: path ?? tempPath())
        store.set(mode)
        return RoutingCoordinator(store: store, surface: .tui, makeSource: { self.fakeClient() },
                                  outputLock: outputLock)
    }

    // MARK: epoch 0 at init

    func testEpochStartsAtZero() {
        XCTAssertEqual(coordinator(mode: .musicApp).epoch, 0)
        XCTAssertEqual(coordinator(mode: .source).epoch, 0)
    }

    // MARK: +1 per committed switch, each way

    func testEpochIncrementsByOnePerCommittedSwitchEachWay() throws {
        let c = coordinator(mode: .musicApp)
        XCTAssertEqual(c.epoch, 0)

        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(c.epoch, 1)

        _ = try c.switchMode(to: .musicApp, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(c.epoch, 2)

        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(c.epoch, 3)
    }

    // MARK: unchanged on alreadyInMode

    func testEpochUnchangedOnAlreadyInMode() throws {
        let c = coordinator(mode: .source)
        let result = try c.switchMode(to: .source, readiness: { .notRunning },
                                      pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(result, .alreadyInMode)
        XCTAssertEqual(c.epoch, 0)
    }

    // MARK: unchanged on a refused switch — readiness

    func testEpochUnchangedOnReadinessRefusal() {
        let c = coordinator(mode: .musicApp)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .notRunning },
                                              pauseOutgoing: { _ in true }, dropQueue: { _ in }))
        XCTAssertEqual(c.epoch, 0)
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: unchanged on a refused switch — unconfirmed pause

    func testEpochUnchangedOnUnconfirmedPause() {
        let c = coordinator(mode: .musicApp)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in false }, dropQueue: { _ in }))
        XCTAssertEqual(c.epoch, 0)
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: unchanged on a refused switch — dropQueue failure

    func testEpochUnchangedOnDropQueueFailure() {
        let c = coordinator(mode: .musicApp)
        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true },
                                              dropQueue: { _ in throw SourceAppError.notRunning }))
        XCTAssertEqual(c.epoch, 0)
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: unchanged on a foreign-process refusal

    /// Another process (a second TUI, or anything that wrote mode.json) moved
    /// the persisted selection after this coordinator read it; `underOutputLock`
    /// catches the mismatch and refuses before any of the switch's steps run,
    /// so the epoch — which only ever moves at the commit line — cannot have
    /// moved either.
    func testEpochUnchangedOnForeignProcessRefusal() throws {
        let path = tempPath()
        let store = PlaybackModeStore(path: path)
        store.set(.musicApp)
        let lockPath = (path as NSString).deletingLastPathComponent + "/epoch-test-\(UUID().uuidString).lock"
        let c = RoutingCoordinator(store: store, surface: .tui, makeSource: { self.fakeClient() },
                                   outputLock: OutputLock(path: lockPath))
        XCTAssertEqual(c.epoch, 0)

        // Another process changes the persisted mode behind this coordinator's
        // back; its in-memory `mode` is still `.musicApp`.
        PlaybackModeStore(path: path).set(.source)

        XCTAssertThrowsError(try c.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true }, dropQueue: { _ in })) { error in
            XCTAssertEqual((error as? ActionError)?.message, OutputLock.tuiModeChangedMessage)
        }
        XCTAssertEqual(c.epoch, 0)
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: choose

    func testChooseReadsModeAndEpochTogetherWithTheRoute() throws {
        let c = coordinator(mode: .musicApp)
        let choice = try c.choose(.radioCatalogueBrowse,
                                  musicApp: { "musicApp-provider" },
                                  source: { _ in "source-provider" })
        XCTAssertEqual(choice.provider, "musicApp-provider")
        XCTAssertEqual(choice.epoch, 0)
        XCTAssertEqual(choice.mode, .musicApp)
    }

    func testChooseBuildsTheSourceProviderInSourceMode() throws {
        let c = coordinator(mode: .source)
        let choice = try c.choose(.radioCatalogueBrowse,
                                  musicApp: { "musicApp-provider" },
                                  source: { _ in "source-provider" })
        XCTAssertEqual(choice.provider, "source-provider")
        XCTAssertEqual(choice.mode, .source)
    }

    func testChooseThrowsForARefusedRoute() {
        let c = coordinator(mode: .source)
        guard case .refused(let reason) = routeAction(.volume, in: .source, from: .tui) else {
            return XCTFail("volume should be refused in Source Mode")
        }
        XCTAssertThrowsError(try c.choose(.volume, musicApp: { 1 }, source: { _ in 2 })) { error in
            XCTAssertEqual((error as? ActionError)?.message, reason)
        }
    }

    /// Two `choose` calls straddling a committed switch differ by exactly one
    /// epoch and one mode — the shape Radio's Live/Personal refetch (P5) and
    /// its stale-result drop both depend on.
    func testTwoChooseCallsStraddlingACommitDifferByOneEpochAndOneMode() throws {
        let c = coordinator(mode: .musicApp)
        let before = try c.choose(.radioCatalogueBrowse, musicApp: { 1 }, source: { _ in 2 })
        XCTAssertEqual(before.epoch, 0)
        XCTAssertEqual(before.mode, .musicApp)

        _ = try c.switchMode(to: .source, readiness: { .ready },
                             pauseOutgoing: { _ in true }, dropQueue: { _ in })

        let after = try c.choose(.radioCatalogueBrowse, musicApp: { 1 }, source: { _ in 2 })
        XCTAssertEqual(after.epoch, before.epoch + 1)
        XCTAssertEqual(after.mode, .source)
        XCTAssertNotEqual(after.mode, before.mode)
    }

    /// A `choose` call that reaches the ordering boundary WHILE a switch is
    /// mid-transaction waits behind it (both take `order`) and then reads
    /// whatever the switch committed: mode and epoch always come from the SAME
    /// side of a commit, never mode from one and epoch from the other. Mirrors
    /// `RoutingCoordinatorTests.testActionOverlappingASwitchRunsOnTheIncomingBackend`.
    func testChooseOverlappingASwitchSeesTheCommittedModeAndEpochTogether() throws {
        let c = coordinator(mode: .musicApp)
        let pausing = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        let done = DispatchGroup()

        done.enter()
        DispatchQueue.global().async {
            _ = try? c.switchMode(to: .source, readiness: { .ready },
                                  pauseOutgoing: { _ in
                                      pausing.signal()
                                      releasePause.wait()
                                      return true
                                  },
                                  dropQueue: { _ in })
            done.leave()
        }
        XCTAssertEqual(pausing.wait(timeout: .now() + 5), .success, "the switch never began pausing")

        let reached = DispatchSemaphore(value: 0)
        c.onReachingBoundary { reached.signal() }
        var choice: ProviderChoice<Int>?
        done.enter()
        DispatchQueue.global().async {
            choice = try? c.choose(.radioCatalogueBrowse, musicApp: { 1 }, source: { _ in 2 })
            done.leave()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success, "choose never reached the boundary")
        releasePause.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        // `choose` waited behind the switch (both take `order`), so by the
        // time it ran, the switch had already committed: it sees the NEW mode
        // and epoch, consistently with each other — never the old mode paired
        // with the new epoch or vice versa.
        XCTAssertEqual(choice?.mode, .source)
        XCTAssertEqual(choice?.provider, 2)
        XCTAssertEqual(choice?.epoch, 1)
        XCTAssertEqual(choice?.epoch, c.epoch)
    }

    /// D3: the round trip runs OUTSIDE the boundary. A slow read performed on
    /// the provider `choose` already returned must not delay a concurrent
    /// switch — because by design `choose`'s closures only construct the
    /// provider and have already returned by the time any such read starts.
    func testASlowReadOnTheReturnedProviderDoesNotDelayASwitch() throws {
        let c = coordinator(mode: .musicApp)
        let choice = try c.choose(.radioCatalogueBrowse,
                                  musicApp: { "musicApp-provider" },
                                  source: { _ in "source-provider" })
        XCTAssertEqual(choice.provider, "musicApp-provider")

        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var readFinished = false

        // Stands in for the caller's own round trip on the chosen provider —
        // deliberately outside any call into the coordinator.
        DispatchQueue.global().async {
            readStarted.signal()
            releaseRead.wait()
            lock.lock(); readFinished = true; lock.unlock()
            readDone.signal()
        }
        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)

        let result = try c.switchMode(to: .source, readiness: { .ready },
                                      pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(result, .switched(to: .source))

        lock.lock(); let finishedBeforeSwitchReturned = readFinished; lock.unlock()
        XCTAssertFalse(finishedBeforeSwitchReturned, "the switch waited behind the outstanding read")

        releaseRead.signal()
        XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success)
    }

    // MARK: the TUI literal gains exactly the two rows

    /// `ActionRoutingTests`'s independent spec table pins the outcome; this
    /// checks it against `routeAction` directly, so a regression in either
    /// place is caught from this file too.
    func testTheTwoNewActionsAreTuiOnlyAndServedOnBridge() {
        for action in [MusicTUIAction.radioCatalogueBrowse, .radioStationLookup] {
            XCTAssertEqual(action.surfaces, [.tui], "\(action)")
            XCTAssertFalse(action.touchesPlayback, "\(action)")
            XCTAssertFalse(action.readsMusicAppCurrentTrack, "\(action)")
            XCTAssertEqual(routeAction(action, in: .musicApp, from: .tui), .musicApp, "\(action)")
            XCTAssertEqual(routeAction(action, in: .source, from: .tui), .source, "\(action)")
            // No CLI invoker exists yet: the closed CLI clause refuses, naming
            // what is not yet available, exactly as D7 requires for every
            // undispatched action.
            guard case .refused(let reason) = routeAction(action, in: .source, from: .cli) else {
                return XCTFail("\(action) must refuse from the CLI: no invoker exists yet")
            }
            XCTAssertEqual(reason, cliBridgeNotServedReason(action), "\(action)")
        }
    }
}

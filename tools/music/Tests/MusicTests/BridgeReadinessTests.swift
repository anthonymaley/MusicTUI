import XCTest
@testable import music

/// The Output tab's Bridge readiness, after the 2026-09-16 gate found it
/// reporting "Bridge is not running" while Bridge was running and answering.
///
/// The defect was not protocol drift: a direct `slice.status` returned
/// `authorization:"authorized"`, `contract:2`. `refreshBridgeReadiness()` was
/// declared and never called, so the field never left its initialiser — and the
/// initialiser was a diagnosis rather than "not asked yet", which is what made
/// an unfilled field look like a finding.
final class BridgeReadinessTests: XCTestCase {

    /// Counts calls to the injected speaker/EQ/visualizer refresh closures, so a
    /// test can prove `tick()` reaches ONLY these — never the real
    /// `fetchSpeakerDevices()`/`fetchEQSnapshot`/`visualizerStatus`, which shell
    /// out to real AppleScript and, for speakers, write through to the real
    /// `~/.config/music` cache.
    private final class RefreshCallCounter {
        private let lock = NSLock()
        private(set) var speakerCalls = 0
        private(set) var eqCalls = 0
        private(set) var visualizerCalls = 0

        func bumpSpeakers() { lock.lock(); speakerCalls += 1; lock.unlock() }
        func bumpEQ() { lock.lock(); eqCalls += 1; lock.unlock() }
        func bumpVisualizer() { lock.lock(); visualizerCalls += 1; lock.unlock() }
    }

    /// `refreshCounter` is nil for every existing test — they don't care about
    /// the speaker/EQ/visualizer refresh, only that it never reaches real
    /// AppleScript. The inert closures always stand in for the production
    /// defaults; the counter is opt-in instrumentation for the one test that
    /// asserts on it.
    private func scene(reply: @escaping (String, String) throws -> String,
                        refreshCounter: RefreshCallCounter? = nil) -> SpeakersScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        return SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                             status: StatusStore(),
                             actions: ActionRunner(status: StatusStore()),
                             routing: RoutingCoordinator(store: store, surface: .tui,
                                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                                       transport: reply) }),
                             makeSourceClient: { SourceAppClient(path: "/nonexistent", transport: reply) },
                             fetchSpeakers: {
                                 refreshCounter?.bumpSpeakers()
                                 return []
                             },
                             fetchEQ: { _ in
                                 refreshCounter?.bumpEQ()
                                 return EQSnapshot(enabled: false, current: nil, presets: [])
                             },
                             fetchVisualizer: { _ in
                                 refreshCounter?.bumpVisualizer()
                                 return false
                             })
    }

    private func settle(_ s: SpeakersScene, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
            if s.bridgeReadinessForTest != .checking { return }
            usleep(20_000)
        }
    }

    private let authorized = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":3,"authorization":"authorized"}}"#

    /// The initial state is "not asked", and it is not selectable. This is the
    /// state whose absence caused the gate failure.
    func testInitialStateIsCheckingAndUnselectable() {
        let s = scene(reply: { _, _ in self.authorized })
        XCTAssertEqual(s.bridgeReadinessForTest, .checking)
        XCTAssertFalse(SourceReadiness.checking.canSelect)
        XCTAssertFalse(outputModeSelectable(.source, readiness: .checking))
    }

    /// The probe actually runs, and its result reaches the field. This is the
    /// exact assertion that would have failed before the fix: the method existed
    /// and nothing called it.
    func testEnteringTheTabProbesOnceAndDeliversTheResult() {
        let s = scene(reply: { _, _ in self.authorized })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        XCTAssertGreaterThan(s.readinessProbeCount, 0, "entering the tab never asked Bridge anything")
        settle(s)
        XCTAssertEqual(s.bridgeReadinessForTest, .ready)
    }

    /// A result delivered off-thread must land through tick(), so the main loop
    /// is the only writer — and tick must report the change so the row redraws.
    func testTheResultArrivesThroughTickAndRequestsARedraw() {
        let s = scene(reply: { _, _ in self.authorized })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        var redrew = false
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])) { redrew = true; break }
            usleep(20_000)
        }
        XCTAssertTrue(redrew, "readiness changed without tick reporting a redraw")
        XCTAssertEqual(s.bridgeReadinessForTest, .ready)
    }

    /// It asks on entry, not on a timer. A tab left open must not keep hitting
    /// the socket.
    func testItDoesNotPollWhileTheTabStaysOpen() {
        let s = scene(reply: { _, _ in self.authorized })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        settle(s)
        let afterEntry = s.readinessProbeCount
        for _ in 0..<40 { _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])) }   // same sitting, no gap
        XCTAssertEqual(s.readinessProbeCount, afterEntry,
                       "readiness is polling: it must be asked on entry, not on a heartbeat")
    }

    /// `tick()`'s speaker/EQ/visualizer refresh must go through the injected
    /// closures only. Before this seam, `fetchSpeakerDevices()` built its own
    /// real `AppleScriptBackend()` — bypassing the scene's injected (inert)
    /// backend entirely — and wrote through to the real `~/.config/music`
    /// speaker cache on every tick. A count of zero default calls is the
    /// isolation proof; an empty `reply` transport keeps Bridge itself out of
    /// it too.
    func testTickReachesOnlyTheInjectedSpeakerEQAndVisualizerClosures() {
        let counter = RefreshCallCounter()
        let s = scene(reply: { _, _ in self.authorized }, refreshCounter: counter)
        for _ in 0..<5 {
            _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        }
        // The fetch is kicked off on a background queue; give it a bounded
        // window to land rather than asserting on the same thread as the kick.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && counter.speakerCalls == 0 { usleep(20_000) }
        XCTAssertGreaterThan(counter.speakerCalls, 0, "tick() never called the injected fetchSpeakers")
        XCTAssertGreaterThan(counter.eqCalls, 0, "tick() never called the injected fetchEQ")
        XCTAssertGreaterThan(counter.visualizerCalls, 0, "tick() never called the injected fetchVisualizer")
    }

    /// Every failure keeps its own words. Collapsing them is what let a client
    /// bug and a missing app print the same sentence.
    func testEachFailureKeepsItsOwnReason() {
        let cases: [(SourceAppError, String)] = [
            (.notRunning, "Bridge is not running"),
            (.notAuthorized, "Bridge has no Apple Music access"),
            (.refused("queue_invalid"), "Bridge refused: queue_invalid"),
            (.timedOut, "Bridge did not answer in time"),
            (.socketUnavailable("permission denied"), "Bridge's control socket is unusable: permission denied"),
            (.unreadable, "Bridge sent a reply this build could not read"),
        ]
        var seen = Set<String>()
        for (error, expected) in cases {
            let readiness = SourceReadiness.from(error)
            XCTAssertEqual(readiness, .unavailable(expected))
            XCTAssertFalse(readiness.canSelect)
            XCTAssertTrue(seen.insert(readiness.label).inserted,
                          "\(error) reuses another failure's wording: \(readiness.label)")
        }
    }

    /// The pairing Codex B1 named: this build against the contract-1 app that
    /// reads every container as an album. It must read as incompatible, never as
    /// ready - ready is what let a playlist be answered as a missing album.
    func testTheContractOneAppIsIncompatibleWithThisBuild() {
        let old = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":1,"authorization":"authorized"}}"#
        let s = scene(reply: { _, _ in old })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        settle(s)
        guard case .unavailable(let reason) = s.bridgeReadinessForTest else {
            return XCTFail("a contract-1 app must not read as ready")
        }
        XCTAssertTrue(reason.contains("(1)"), "the reason must name the version it saw: \(reason)")
    }

    /// A contract mismatch is not an error path — the app answers fine, it just
    /// answers a version this build does not know.
    func testAContractMismatchIsReportedAsIncompatibleNotAsAFailure() {
        let mismatched = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":99,"authorization":"authorized"}}"#
        let s = scene(reply: { _, _ in mismatched })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        settle(s)
        guard case .unavailable(let reason) = s.bridgeReadinessForTest else {
            return XCTFail("a version mismatch must not read as ready")
        }
        XCTAssertTrue(reason.contains("99"), "the reason must name the version it saw: \(reason)")
    }

    /// An unauthorised Bridge is reachable but cannot serve, and says so.
    func testAnUnauthorizedBridgeIsNotReady() {
        let denied = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":3,"authorization":"denied"}}"#
        let s = scene(reply: { _, _ in denied })
        _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        settle(s)
        XCTAssertEqual(s.bridgeReadinessForTest, .unavailable("Bridge was denied Apple Music access"))
    }

    // MARK: - The real client path, not just the mapping function

    /// `SourceReadiness.from(_:)` being right proves nothing if the client never
    /// calls it. This drives `SourceAppClient.readiness()` itself — the code the
    /// Output tab actually runs — with a transport that throws each error in
    /// turn. Before this fix every row here returned "Bridge is not running".
    func testTheClientPathClassifiesEveryThrownError() {
        let cases: [(SourceAppError, String)] = [
            (.notRunning, "Bridge is not running"),
            (.notAuthorized, "Bridge has no Apple Music access"),
            (.refused("queue_invalid"), "Bridge refused: queue_invalid"),
            (.timedOut, "Bridge did not answer in time"),
            (.socketUnavailable("permission denied"), "Bridge's control socket is unusable: permission denied"),
            (.unreadable, "Bridge sent a reply this build could not read"),
        ]
        var seen = Set<String>()
        for (thrown, expected) in cases {
            let client = SourceAppClient(path: "/nonexistent", transport: { _, _ in throw thrown })
            let readiness = client.readiness()
            XCTAssertEqual(readiness, .unavailable(expected),
                           "\(thrown) was collapsed by the client path")
            XCTAssertFalse(readiness.canSelect)
            XCTAssertTrue(seen.insert(readiness.label).inserted,
                          "\(thrown) reuses another failure's wording through the client")
        }
    }

    /// A reply the app could never send: `ok` present but no status. The client
    /// must call this unreadable rather than guess.
    func testTheClientPathReportsAMalformedReplyAsUnreadable() {
        let client = SourceAppClient(path: "/nonexistent",
                                     transport: { _, _ in #"{"ok":true,"op":"slice.status"}"# })
        XCTAssertEqual(client.readiness(),
                       .unavailable("Bridge sent a reply this build could not read"))
    }

    // MARK: - A completed switch publishes, it does not assign

    /// Enter on a mode row runs the switch on a background queue. Its readiness
    /// result must reach `bridgeReadiness` through the inbox like every other
    /// background result — otherwise the race the inbox removed is back on the
    /// one path a person actually triggers.
    ///
    /// Switching OUT of Bridge rather than into it keeps the test off AppleScript
    /// entirely: pausing and dropping the outgoing source both go through the
    /// stubbed transport.
    func testACompletedSwitchChangesReadinessOnlyWhenTickDrainsIt() throws {
        let path = NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"
        let store = PlaybackModeStore(path: path)
        store.set(.source)
        let client = { SourceAppClient(path: "/nonexistent", transport: { _, _ in
            #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":3,"authorization":"denied"}}"#
        }) }
        // Inert closures (P6's seam): this test builds its SpeakersScene
        // directly rather than through scene(reply:), and the trailing tick()
        // below would otherwise kick the real fetchSpeakerDevices()/
        // fetchEQSnapshot()/visualizerStatus() — real AppleScript, and a real
        // ~/.config/music write — on every run of this file.
        let scene = SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                  status: StatusStore(),
                                  actions: ActionRunner(status: StatusStore()),
                                  routing: RoutingCoordinator(store: store, surface: .tui,
                                                              makeSource: { client() }),
                                  makeSourceClient: client,
                                  fetchSpeakers: { [] },
                                  fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                                  fetchVisualizer: { _ in false })

        // Cursor starts on the Music.app row, which is the switch TARGET here.
        let before = scene.bridgeReadinessForTest
        // A fixed wall-clock poll here raced under full-suite load (P7):
        // GCD scheduling of selectMode's action body competes with every
        // other test's background work, so a real 3.0s budget could be
        // exceeded without the work itself stalling. The completion hook is
        // a synchronization primitive; the poll was not.
        let done = DispatchSemaphore(value: 0)
        scene.selectModeFinishedForTest = { done.signal() }
        _ = scene.handle(.enter)

        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "selectMode's action never finished")
        XCTAssertTrue(scene.hasPendingReadinessForTest, "the switch never published its readiness")
        XCTAssertEqual(scene.bridgeReadinessForTest, before,
                       "the switch wrote bridgeReadiness directly instead of publishing it")

        _ = scene.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        XCTAssertEqual(scene.bridgeReadinessForTest,
                       .unavailable("Bridge was denied Apple Music access"),
                       "tick did not apply the switch's published readiness")
        XCTAssertFalse(scene.hasPendingReadinessForTest, "tick left the inbox undrained")
    }
}

import XCTest
@testable import music

/// The Output tab's Bridge readiness, after the 2026-09-16 gate found it
/// reporting "Bridge is not running" while Bridge was running and answering.
///
/// The defect was not protocol drift: a direct `slice.status` returned
/// `authorization:"authorized"`, `contract:1`. `refreshBridgeReadiness()` was
/// declared and never called, so the field never left its initialiser — and the
/// initialiser was a diagnosis rather than "not asked yet", which is what made
/// an unfilled field look like a finding.
final class BridgeReadinessTests: XCTestCase {

    private func scene(reply: @escaping (String, String) throws -> String) -> SpeakersScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        return SpeakersScene(backend: AppleScriptBackend(),
                             status: StatusStore(),
                             actions: ActionRunner(status: StatusStore()),
                             routing: RoutingCoordinator(store: store, surface: .tui,
                                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                                       transport: reply) }),
                             makeSourceClient: { SourceAppClient(path: "/nonexistent", transport: reply) })
    }

    private func settle(_ s: SpeakersScene, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
            if s.bridgeReadinessForTest != .checking { return }
            usleep(20_000)
        }
    }

    private let authorized = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":1,"authorization":"authorized"}}"#

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
        let denied = #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":1,"authorization":"denied"}}"#
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
            #"{"ok":true,"op":"slice.status","status":{"playback":"idle","contract":1,"authorization":"denied"}}"#
        }) }
        let scene = SpeakersScene(backend: AppleScriptBackend(),
                                  status: StatusStore(),
                                  actions: ActionRunner(status: StatusStore()),
                                  routing: RoutingCoordinator(store: store, surface: .tui,
                                                              makeSource: { client() }),
                                  makeSourceClient: client)

        // Cursor starts on the Music.app row, which is the switch TARGET here.
        let before = scene.bridgeReadinessForTest
        _ = scene.handle(.enter)

        // Wait for the switch's result to LAND in the inbox, still unapplied.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && !scene.hasPendingReadinessForTest { usleep(10_000) }
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

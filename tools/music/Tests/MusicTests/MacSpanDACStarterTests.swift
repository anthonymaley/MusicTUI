// tools/music/Tests/MusicTests/MacSpanDACStarterTests.swift
//
// Starting SpanDAC on this Mac (score: data route and output, C-START).
// Proves: a not-installed starter never launches; a launch happens at most
// once per attempt even under concurrent callers; polling stops on ready,
// not-authorized, a failure, or the 15 s bound; a non-ready outcome is sticky
// until newAttempt(); the live launch is a third tripwire funnel beside
// AppleScript and REST; bringForward only activates, never the hidden start;
// isRunning reads only its own probe; and the data client's one retry fires
// only after a start that reaches ready.
//
// Every starter here is `LiveMacSpanDACStarter` built with fakes for its
// launcher, locator, probe and clock: none of these tests launches the real
// SpanDAC app, polls a real socket, or waits out a real 15 s bound.
import XCTest
@testable import music

final class MacSpanDACStarterTests: XCTestCase {

    private let testBundleID = "com.example.not-a-real-app"

    /// A clock a test drives by hand: `wait(_:)` advances `now` instead of
    /// sleeping, so a 15 s bound resolves instantly and a test can assert
    /// exactly how many pauses happened.
    private final class FakeClock {
        private(set) var now: Date
        private(set) var waits: [TimeInterval] = []
        init(start: Date = Date(timeIntervalSince1970: 0)) { now = start }
        var asClock: MacSpanDACClock {
            MacSpanDACClock(
                now: { self.now },
                wait: { interval in
                    self.waits.append(interval)
                    self.now = self.now.addingTimeInterval(interval)
                })
        }
    }

    /// A spy `MacSpanDACStarting` for the data-client tests: counts
    /// `ensureStarted()` calls and returns a fixed outcome. Never launches or
    /// polls anything real.
    private final class SpyStarter: MacSpanDACStarting {
        var outcome: MacSpanDACStartOutcome = .ready
        private(set) var ensureStartedCalls = 0
        var isInstalled: Bool { true }
        var isRunning: Bool { true }
        var isStarting: Bool { false }
        func ensureStarted() -> MacSpanDACStartOutcome {
            ensureStartedCalls += 1
            return outcome
        }
        func bringForward() {}
        func newAttempt() {}
    }

    private func makeStarter(
        installed: Bool = true,
        running: Bool = false,
        launch: @escaping (String) throws -> Void = { _ in },
        activate: @escaping (String) throws -> Void = { _ in },
        probe: @escaping () -> MacSpanDACProbe = { .ready },
        clock: MacSpanDACClock = MacSpanDACClock(now: { Date() }, wait: { _ in }),
        pollInterval: TimeInterval = 0.25,
        bound: TimeInterval = 15
    ) -> LiveMacSpanDACStarter {
        LiveMacSpanDACStarter(
            bundleID: testBundleID,
            checkInstalled: { installed },
            checkRunning: { running },
            launch: launch,
            activate: activate,
            probe: probe,
            clock: clock,
            pollInterval: pollInterval,
            bound: bound)
    }

    // MARK: - Installed gate

    func testNotInstalledNeverLaunches() {
        var launchCount = 0
        let starter = makeStarter(installed: false, launch: { _ in launchCount += 1 })
        XCTAssertEqual(starter.ensureStarted(), .notInstalled)
        XCTAssertEqual(launchCount, 0)
    }

    // MARK: - At most one launch per attempt

    func testLaunchesAtMostOncePerAttempt() {
        let lock = NSLock()
        var launchCount = 0
        let starter = makeStarter(
            launch: { _ in lock.lock(); launchCount += 1; lock.unlock() },
            probe: { .ready })
        let group = DispatchGroup()
        let outcomesLock = NSLock()
        var outcomes: [MacSpanDACStartOutcome] = []
        for _ in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                let outcome = starter.ensureStarted()
                outcomesLock.lock(); outcomes.append(outcome); outcomesLock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(outcomes.count, 10)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .ready })
    }

    // MARK: - Polling

    func testPollsUntilReadyWithinTheBound() {
        var results: [MacSpanDACProbe] = [.notYetReady, .notYetReady, .ready]
        let clock = FakeClock()
        let starter = makeStarter(
            probe: { results.isEmpty ? .ready : results.removeFirst() },
            clock: clock.asClock)
        XCTAssertEqual(starter.ensureStarted(), .ready)
        // Two "not yet" probes, each followed by one 250ms pause, then ready.
        XCTAssertEqual(clock.waits, [0.25, 0.25])
    }

    func testTimesOutAtFifteenSecondsWithTheSentence() {
        let clock = FakeClock()
        let starter = makeStarter(probe: { .notYetReady }, clock: clock.asClock)
        let outcome = starter.ensureStarted()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(outcome.sentence,
                       "SpanDAC on this Mac didn't start. Open it from your Applications folder.")
        // 15s bound at a 250ms cadence: exactly 60 pauses land on the deadline.
        XCTAssertEqual(clock.waits.count, 60)
        XCTAssertTrue(clock.waits.allSatisfy { $0 == 0.25 })
    }

    // MARK: - Stickiness

    func testAFailedAttemptIsStickyUntilANewAttempt() {
        var launchCount = 0
        var probeCount = 0
        let starter = makeStarter(
            launch: { _ in launchCount += 1 },
            probe: { probeCount += 1; return .failed("SpanDAC on this Mac said no.") })

        XCTAssertEqual(starter.ensureStarted(), .failed("SpanDAC on this Mac said no."))
        XCTAssertEqual(launchCount, 1)
        let probeCountAfterFirstAttempt = probeCount

        // Sticky: a second call returns the same outcome without launching or
        // polling again.
        XCTAssertEqual(starter.ensureStarted(), .failed("SpanDAC on this Mac said no."))
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(probeCount, probeCountAfterFirstAttempt)

        // A new attempt tries again.
        starter.newAttempt()
        XCTAssertEqual(starter.ensureStarted(), .failed("SpanDAC on this Mac said no."))
        XCTAssertEqual(launchCount, 2)
    }

    // MARK: - Data readiness never depends on a DAC

    /// Starting SpanDAC on this Mac is for music DATA: once it answers with
    /// Apple Music access, a Mac with no DAC (or one it is still checking
    /// for) is ready at the first probe, not after the 15 s bound. Access
    /// still matters.
    func testAStartOnAMacWithoutADACIsReady() {
        func client(dac: String, authorization: String = "authorized") -> SourceAppClient {
            let reply = #"{"ok":true,"status":{"playback":"idle","authorization":"\#(authorization)","contract":\#(sourceContractVersion),"output":{"dac":"\#(dac)"}}}"#
            return SourceAppClient(path: "/nonexistent/starter-probe.sock", transport: { _, _ in reply })
        }
        for dac in ["not_connected", "unknown"] {
            XCTAssertEqual(liveMacSpanDACProbe(client: client(dac: dac)), .ready, dac)
            let clock = FakeClock()
            let starter = makeStarter(probe: { liveMacSpanDACProbe(client: client(dac: dac)) }, clock: clock.asClock)
            XCTAssertEqual(starter.ensureStarted(), .ready, dac)
            XCTAssertEqual(clock.waits, [], "\(dac): ready at the first probe, no polling")
        }
        XCTAssertEqual(liveMacSpanDACProbe(client: client(dac: "not_connected", authorization: "denied")),
                       .notAuthorized)
    }

    // MARK: - Contract mismatch

    /// SpanDAC on this Mac answers, but speaks a contract this build does not
    /// know. Waiting cannot fix that, so the start stops at the first probe
    /// with a sentence that says what to do, never polling to the 15 s bound
    /// and never reading as "didn't start". It is sticky like any failure.
    func testAContractMismatchIsATerminalNotCompatibleResult() {
        let reply = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion + 1),"output":{"dac":"connected"}}}"#
        let client = SourceAppClient(path: "/nonexistent/starter-probe.sock", transport: { _, _ in reply })
        let expected = "SpanDAC on this Mac is a different version from MusicTUI. Update SpanDAC, then try again."
        XCTAssertEqual(liveMacSpanDACProbe(client: client), .failed(expected))

        let clock = FakeClock()
        var probes = 0
        var launches = 0
        let starter = makeStarter(launch: { _ in launches += 1 },
                                  probe: { probes += 1; return liveMacSpanDACProbe(client: client) },
                                  clock: clock.asClock)
        let outcome = starter.ensureStarted()
        XCTAssertEqual(outcome, .failed(expected))
        XCTAssertEqual(outcome.sentence, expected)
        XCTAssertEqual(clock.waits, [], "no polling")
        XCTAssertEqual(probes, 1)
        // Sticky: no second launch or probe until a person asks again.
        XCTAssertEqual(starter.ensureStarted(), .failed(expected))
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(probes, 1)
    }

    // MARK: - Authorization

    func testNotAuthorizedIsReportedAndNeverPrompts() {
        var activateCount = 0
        var probeCount = 0
        let starter = makeStarter(
            activate: { _ in activateCount += 1 },
            probe: { probeCount += 1; return .notAuthorized })

        let outcome = starter.ensureStarted()
        XCTAssertEqual(outcome, .notAuthorized)
        XCTAssertEqual(outcome.sentence,
                       "SpanDAC needs Apple Music access. Open SpanDAC on this Mac and allow it.")
        // Never brings the app forward by itself; only a person's Enter does.
        XCTAssertEqual(activateCount, 0)

        // Sticky, so a second call neither launches again nor prompts.
        let probeCountAfterFirst = probeCount
        XCTAssertEqual(starter.ensureStarted(), .notAuthorized)
        XCTAssertEqual(probeCount, probeCountAfterFirst)
        XCTAssertEqual(activateCount, 0)
    }

    // MARK: - The data client's one retry

    func testMacDataClientRetriesOnceAfterAStart() {
        let starter = SpyStarter()
        starter.outcome = .ready
        var sendCalls = 0
        let send: (String, String) throws -> String = { _, _ in
            sendCalls += 1
            if sendCalls == 1 { throw SourceAppError.notRunning }
            return "{\"ok\":true}"
        }
        let wrapped = retryingOnceAfterAStart(send, starter: starter)
        XCTAssertNoThrow(try {
            let reply = try wrapped("socket-path", "{}")
            XCTAssertEqual(reply, "{\"ok\":true}")
        }())
        XCTAssertEqual(sendCalls, 2)
        XCTAssertEqual(starter.ensureStartedCalls, 1)
    }

    func testMacDataClientDoesNotLaunchForOtherErrors() {
        let starter = SpyStarter()
        var sendCalls = 0
        let send: (String, String) throws -> String = { _, _ in
            sendCalls += 1
            throw SourceAppError.timedOut
        }
        let wrapped = retryingOnceAfterAStart(send, starter: starter)
        XCTAssertThrowsError(try wrapped("socket-path", "{}")) { error in
            XCTAssertEqual(error as? SourceAppError, .timedOut)
        }
        XCTAssertEqual(sendCalls, 1)
        XCTAssertEqual(starter.ensureStartedCalls, 0)
    }

    // MARK: - The live launch is a tripwire funnel

    func testTheLiveLaunchGoesThroughTheTripwire() {
        let (result, calls) = withTripwire {
            Result { try liveLaunchMacSpanDAC(bundleID: testBundleID, hidden: true) }
        }
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is ExternalCallBlocked)
        }
        XCTAssertEqual(calls, [.launchApp(bundleID: testBundleID)])
    }

    // MARK: - bringForward only activates

    func testBringForwardOnlyActivates() {
        var launchCalls: [String] = []
        var activateCalls: [String] = []
        let starter = makeStarter(
            launch: { id in launchCalls.append(id) },
            activate: { id in activateCalls.append(id) })
        starter.bringForward()
        XCTAssertEqual(activateCalls, [testBundleID])
        XCTAssertEqual(launchCalls, [])
    }

    // MARK: - isRunning

    func testIsRunningReadsLaunchServicesOnly() {
        let runningStarter = makeStarter(installed: false, running: true)
        XCTAssertTrue(runningStarter.isRunning)
        XCTAssertFalse(runningStarter.isInstalled)

        let notRunningStarter = makeStarter(installed: true, running: false)
        XCTAssertFalse(notRunningStarter.isRunning)
        XCTAssertTrue(notRunningStarter.isInstalled)
    }

    func testResolvePrefersFirstIDWhenBothKnown() {
        let ids = ["first.example", "second.example"]
        XCTAssertEqual(resolveMacSpanDACBundleID(ids) { _ in true }, "first.example")
    }

    func testResolveFallsBackToSecondWhenOnlyItIsKnown() {
        let ids = ["first.example", "second.example"]
        XCTAssertEqual(resolveMacSpanDACBundleID(ids) { $0 == "second.example" }, "second.example")
    }

    func testResolveReturnsFirstWhenNeitherIsKnown() {
        let ids = ["first.example", "second.example"]
        XCTAssertEqual(resolveMacSpanDACBundleID(ids) { _ in false }, "first.example")
    }

    func testResolveReturnsNilForAnEmptyList() {
        XCTAssertNil(resolveMacSpanDACBundleID([]) { _ in true })
    }

    func testProductIDIsListedBeforeTheTemporaryDevID() {
        XCTAssertEqual(macSpanDACBundleIDs.first, "io.vouch.spandac")
    }
}

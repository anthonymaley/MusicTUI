import XCTest
@testable import music

/// Discover lifecycle design §6: barriers and ownership, never a race.
///
/// No test here sleeps to "let the race happen", none calls `syncRun` (it
/// deadlocks inside the XCTest runner), and the test thread never waits for
/// work it has itself blocked. Concurrent actors run on explicit `Thread`s
/// with expectations; every seam is a synchronous closure a test can hold at
/// a gate; every deadline and delay comes from the scheduler seam, so time is
/// an instant the test supplies. The condition waits themselves are the
/// PRODUCTION `NSCondition`: B16 and B7a would pass vacuously against a fake
/// wait that returns, which is exactly why the real one is required.
final class DiscoverLifecycleTests: XCTestCase {

    // MARK: - Harness

    /// A lock-protected, append-only event log, asserted in order.
    final class Recorder {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    /// Holds a seam at a barrier. The seam calls `pass()`; the test learns it
    /// arrived with `awaitArrival`, and lets it through with `open()`.
    final class Gate {
        private let arrived = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        func pass() { arrived.signal(); release.wait() }
        @discardableResult
        func awaitArrival(_ timeout: TimeInterval = 2) -> Bool {
            arrived.wait(timeout: .now() + timeout) == .success
        }
        func open() { release.signal() }
    }

    /// Virtual time for readiness and confirmation polling; the sleeps between
    /// reads advance it. The two condition-wait deadlines are REAL instants,
    /// defaulting to ten real seconds out, so a regression fails on an
    /// expectation rather than hanging.
    final class TestClock {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)
        var admissionToastDeadline: () -> Date = { Date().addingTimeInterval(10) }
        var exitLaunchSweepDeadline: () -> Date = { Date().addingTimeInterval(10) }
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(to d: Date) { lock.lock(); if d > current { current = d }; lock.unlock() }
        var scheduler: DiscoverScheduler {
            DiscoverScheduler(
                now: { self.now },
                deadline: { wait in
                    switch wait {
                    case .admissionToast: return self.admissionToastDeadline()
                    case .exitLaunchSweep: return self.exitLaunchSweepDeadline()
                    case .readiness, .confirmation:
                        return self.now.addingTimeInterval(DiscoverScheduler.interval(for: wait))
                    }
                },
                delay: { self.advance(to: $0) })
        }
    }

    struct SeamError: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    final class Fixture {
        let rec = Recorder()
        let clock = TestClock()
        var launchGate: Gate?
        var createGate: Gate?
        var readCountGate: Gate?
        var playGate: Gate?
        var confirmGate: Gate?
        var launchSweepThrows: Error?
        var createThrows: Error?
        var playThrows: Error?
        var readCountValue = 1
        var confirmResponder: (String) -> String = { _ in discoverConfirmedToken }
        var onToast: ((DiscoverToast) -> Void)?
        var onAdmissionWait: (() -> Void)?

        private let lock = NSLock()
        private(set) var exitScripts: [String] = []
        private(set) var toasts: [DiscoverToast] = []
        private(set) var mintedNames: [String] = []

        private(set) var coordinator: DiscoverLifecycleCoordinator!

        init() {
            let seams = DiscoverLifecycleCoordinator.Seams(
                runSweep: { [self] script in
                    if self.coordinator.launchSweep.isRunning {
                        self.rec.add("launchSweep")
                        self.launchGate?.pass()
                        if let e = self.launchSweepThrows { throw e }
                    } else {
                        self.rec.add("exitSweep")
                        self.lock.lock(); self.exitScripts.append(script); self.lock.unlock()
                    }
                },
                create: { [self] _, _ in
                    self.rec.add("create")
                    self.createGate?.pass()
                    if let e = self.createThrows { throw e }
                },
                readCount: { [self] _ in
                    self.rec.add("readCount")
                    self.readCountGate?.pass()
                    return self.readCountValue
                },
                play: { [self] _ in
                    self.rec.add("play")
                    self.playGate?.pass()
                    if let e = self.playThrows { throw e }
                },
                confirmRead: { [self] name in
                    self.rec.add("confirmRead")
                    self.confirmGate?.pass()
                    return self.confirmResponder(name)
                },
                post: { [self] toast in
                    self.rec.add("toast:\(Fixture.label(toast))")
                    self.lock.lock(); self.toasts.append(toast); self.lock.unlock()
                    self.onToast?(toast)
                },
                scheduler: clock.scheduler,
                onTransition: { [self] _, state in
                    self.rec.add(Fixture.label(state))
                    if case .minted(let n) = state {
                        self.lock.lock(); self.mintedNames.append(n); self.lock.unlock()
                    }
                },
                onAdmissionWait: { [self] in self.onAdmissionWait?() },
                launchExecutor: { body in Thread(block: body).start() })
            coordinator = DiscoverLifecycleCoordinator(seams: seams)
        }

        static func label(_ s: DiscoverTransactionState) -> String {
            switch s {
            case .minted: return "minted"
            case .created: return "created"
            case .ready: return "ready"
            case .playIssued: return "playIssued"
            case .unconfirmed: return "unconfirmed"
            case .playAmbiguous: return "playAmbiguous"
            case .confirmedPlaying: return "confirmedPlaying"
            case .failedBeforePlay(_, let stage): return "failedBeforePlay(\(stage))"
            }
        }

        static func label(_ t: DiscoverToast) -> String {
            switch t {
            case .startupCleanup: return "startupCleanup"
            case .outcome(let o, _):
                switch o {
                case .playing: return "playing"
                case .needsSignIn: return "needsSignIn"
                case .createFailed: return "createFailed"
                case .notReady: return "notReady"
                case .playFailed: return "playFailed"
                }
            }
        }

        var singleMintedName: String? { lock.lock(); defer { lock.unlock() }; return mintedNames.count == 1 ? mintedNames[0] : nil }
        var exitSweepCount: Int { lock.lock(); defer { lock.unlock() }; return exitScripts.count }
        var lastExitScript: String? { lock.lock(); defer { lock.unlock() }; return exitScripts.last }
        var startupToastCount: Int { lock.lock(); defer { lock.unlock() }; return toasts.filter { $0 == .startupCleanup }.count }

        /// The production exit sequence, both phases, nothing between.
        @discardableResult
        func beginExit() -> DiscoverExitOutcome {
            coordinator.closeAdmission()
            return coordinator.finishExit()
        }

        func requestPlay(title: String = "Album", ids: [String] = ["1"], disableShuffle: Bool = false) -> DiscoverPlayRequestOutcome {
            coordinator.requestPlay(title: title, catalogIDs: ids, disableShuffle: disableShuffle)
        }
    }

    /// Runs `body` on its own thread; the returned expectation is fulfilled
    /// when it finishes. The result is read after waiting on it.
    final class Async<T> {
        private let lock = NSLock()
        private var value: T?
        let done: XCTestExpectation
        init(_ name: String, _ body: @escaping () -> T) {
            done = XCTestExpectation(description: name)
            let exp = done
            Thread { [self] in
                let v = body()
                lock.lock(); value = v; lock.unlock()
                exp.fulfill()
            }.start()
        }
        var result: T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func protectedClause(_ name: String) -> String {
        "set protectedNames to {\"\(escapeAppleScriptString(name))\"}"
    }

    // MARK: - §6.1 pure and structural

    func testProtectedSetIsExactlyTheSixProtectedStates() {
        let n = "x"
        let protected: [DiscoverTransactionState] = [.minted(n), .created(n), .ready(n), .playIssued(n), .unconfirmed(n), .playAmbiguous(n)]
        let unprotected: [DiscoverTransactionState] = [.confirmedPlaying(n), .failedBeforePlay(n, .create), .failedBeforePlay(n, .readiness)]
        for s in protected { XCTAssertTrue(s.isProtected, "\(s) must protect") }
        for s in unprotected { XCTAssertFalse(s.isProtected, "\(s) must not protect") }
    }

    func testTerminalStatesAreTerminalAndHaveNoSuccessor() {
        let n = "x"
        let all: [DiscoverTransactionState] = [.minted(n), .created(n), .ready(n), .playIssued(n), .unconfirmed(n), .playAmbiguous(n), .confirmedPlaying(n), .failedBeforePlay(n, .create), .failedBeforePlay(n, .readiness)]
        for from in all where from.isTerminal {
            for to in all {
                XCTAssertFalse(discoverTransitionIsLegal(from: from, to: to), "\(from) -> \(to) must be illegal")
            }
        }
        XCTAssertFalse(DiscoverTransactionState.minted(n).isTerminal)
        XCTAssertFalse(DiscoverTransactionState.playIssued(n).isTerminal)
    }

    func testOnlyTheStageSuccessorsAreLegal() {
        let n = "x"
        let legal: [(DiscoverTransactionState, DiscoverTransactionState)] = [
            (.minted(n), .created(n)), (.minted(n), .failedBeforePlay(n, .create)),
            (.created(n), .ready(n)), (.created(n), .failedBeforePlay(n, .readiness)),
            (.ready(n), .playIssued(n)), (.ready(n), .playAmbiguous(n)),
            (.playIssued(n), .confirmedPlaying(n)), (.playIssued(n), .unconfirmed(n)),
        ]
        for (f, t) in legal { XCTAssertTrue(discoverTransitionIsLegal(from: f, to: t), "\(f) -> \(t)") }
        XCTAssertFalse(discoverTransitionIsLegal(from: .minted(n), to: .ready(n)), "no stage may be skipped")
        XCTAssertFalse(discoverTransitionIsLegal(from: .created(n), to: .playAmbiguous(n)))
        XCTAssertFalse(discoverTransitionIsLegal(from: .minted(n), to: .created("other")), "a transition never renames")
    }

    func testLaunchSweepFinishesExactlyOnce() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.coordinator.completeLaunchSweep(.failed("later"))
        XCTAssertEqual(f.coordinator.launchSweep, .finished(.swept), "the first completion wins; finished is entered once")
    }

    func testStartLaunchSweepRunsTheSweepOnceHoweverOftenItIsCalled() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        XCTAssertEqual(f.coordinator.launchSweep, .running)
        f.launchGate!.open()
        let finished = expectation(description: "finished")
        Thread { while !f.coordinator.launchSweep.isFinished { Thread.sleep(forTimeInterval: 0.01) }; finished.fulfill() }.start()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(f.rec.all.filter { $0 == "launchSweep" }.count, 1)
    }

    // MARK: - §6.2 barrier tests

    /// B1, the lemma: no transaction exists while the launch sweep runs.
    func testB1_RequestWaitsForTheLaunchSweepBeforeMinting() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        // The sweep is held; nothing may have been minted or created. A spin
        // on the recorder would be a sleep in disguise, so the assertion is
        // on state that cannot regress: the table and the create event.
        XCTAssertTrue(f.coordinator.transactions.isEmpty)
        XCTAssertFalse(f.rec.all.contains("create"))
        XCTAssertFalse(f.rec.all.contains("minted"))
        f.launchGate!.open()
        wait(for: [t1.done], timeout: 2)
        let events = f.rec.all
        let mintedAt = events.firstIndex(of: "minted"), createAt = events.firstIndex(of: "create"), sweepAt = events.firstIndex(of: "launchSweep")
        XCTAssertNotNil(mintedAt); XCTAssertNotNil(createAt)
        XCTAssertLessThan(sweepAt!, mintedAt!, "the sweep was entered before anything was minted")
        XCTAssertLessThan(mintedAt!, createAt!, "minted, then create, same name")
        guard case .completed(.confirmedPlaying(let n))? = t1.result else { return XCTFail("\(String(describing: t1.result))") }
        XCTAssertEqual(n, f.singleMintedName)
    }

    /// B2, fast quit, timeout branch: the launch sweep outlives the deadline,
    /// so the exit sweep is skipped. Nothing of ours existed to protect.
    func testB2_FastQuitSkipsTheExitSweepWhenTheLaunchSweepOutlivesTheDeadline() {
        let f = Fixture()
        f.launchGate = Gate()
        f.clock.exitLaunchSweepDeadline = { .distantPast }
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        XCTAssertEqual(f.beginExit(), .skippedLaunchSweepStillRunning)
        XCTAssertEqual(f.coordinator.admission, .closed)
        XCTAssertEqual(f.exitSweepCount, 0)
        XCTAssertTrue(f.coordinator.transactions.isEmpty)
        f.launchGate!.open()
    }

    /// B16, fast quit, success branch (Codex I1): the exit WAITS on the
    /// production condition and is WOKEN by the launch sweep's completion
    /// broadcast well before its ten-second deadline. Removing that broadcast
    /// makes this fail on the two-second expectation. This is the test that
    /// would have caught the deadlocking protocol.
    func testB16_FastQuitIsWokenByTheLaunchSweepCompletingAndRunsOneExitSweep() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        f.coordinator.closeAdmission()
        let t1 = Async("exit") { f.coordinator.finishExit() }
        f.launchGate!.open()
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(t1.result, .swept(protected: []))
        XCTAssertEqual(f.exitSweepCount, 1)
        XCTAssertEqual(f.lastExitScript, discoverSweepScript(protectedNames: []))
    }

    /// B3, exit during create: the minted name is protected and travels in
    /// the exit script.
    func testB3_ExitDuringCreateProtectsTheMintedName() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.createGate = Gate()
        let t1 = Async("play") { f.requestPlay() }
        XCTAssertTrue(f.createGate!.awaitArrival())
        let name = f.singleMintedName!
        XCTAssertEqual(f.coordinator.protectedNames, [name])
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertEqual(f.exitSweepCount, 1)
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
        f.createGate!.open()
        wait(for: [t1.done], timeout: 2)
    }

    /// B10, exit at `created` (readiness held).
    func testB10_ExitAtCreatedProtectsTheName() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.readCountGate = Gate()
        let t1 = Async("play") { f.requestPlay() }
        XCTAssertTrue(f.readCountGate!.awaitArrival())
        let name = f.singleMintedName!
        XCTAssertEqual(f.coordinator.transactions.values.first, .created(name))
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
        f.readCountGate!.open()
        wait(for: [t1.done], timeout: 2)
    }

    /// B11, exit at `ready` (play held).
    func testB11_ExitAtReadyProtectsTheName() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.playGate = Gate()
        let t1 = Async("play") { f.requestPlay() }
        XCTAssertTrue(f.playGate!.awaitArrival())
        let name = f.singleMintedName!
        XCTAssertEqual(f.coordinator.transactions.values.first, .ready(name))
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
        f.playGate!.open()
        wait(for: [t1.done], timeout: 2)
    }

    /// B4, exit during confirmation: `playIssued` is protected even though a
    /// state read at this moment could say stopped or paused. The "Playing"
    /// toast has already been posted, before the first confirmation read.
    func testB4_ExitDuringConfirmationProtectsThePlayIssuedName() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.confirmGate = Gate()
        let t1 = Async("play") { f.requestPlay() }
        XCTAssertTrue(f.confirmGate!.awaitArrival())
        let name = f.singleMintedName!
        XCTAssertEqual(f.coordinator.transactions.values.first, .playIssued(name))
        let events = f.rec.all
        XCTAssertLessThan(events.firstIndex(of: "toast:playing")!, events.firstIndex(of: "confirmRead")!,
                          "the toast is posted as soon as the play returns, before confirmation")
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
        f.confirmGate!.open()
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(t1.result, .completed(.confirmedPlaying(name)))
    }

    /// B5, exit after confirmation: nothing protected, today's script.
    func testB5_ExitAfterConfirmationEmitsTheOrdinaryScript() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        let r = f.requestPlay()
        guard case .completed(.confirmedPlaying(let name)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f.coordinator.protectedNames, [])
        XCTAssertEqual(f.beginExit(), .swept(protected: []))
        XCTAssertEqual(f.lastExitScript, discoverSweepScript(protectedNames: []))
        XCTAssertFalse(f.lastExitScript!.contains(name))
        XCTAssertEqual(f.rec.all, ["minted", "create", "created", "readCount", "ready", "play", "playIssued",
                                   "toast:playing", "confirmRead", "confirmedPlaying", "exitSweep"])
    }

    /// B5a, the first-round Blocking as a test: `playing` for the OLD context
    /// is not confirmation. The read never returns `confirmed`, the bound
    /// elapses, the transaction ends `unconfirmed`, and the name is protected
    /// at exit. Same with an unreadable context (also `notyet`).
    func testB5a_PlayingForTheOldContextNeverConfirms() {
        for label in ["old-context", "unreadable-context"] {
            let f = Fixture()
            f.coordinator.completeLaunchSweep(.swept)
            f.confirmResponder = { _ in discoverNotYetToken }
            let r = f.requestPlay()
            guard case .completed(.unconfirmed(let name)) = r else { return XCTFail("\(label): \(r)") }
            XCTAssertEqual(f.coordinator.protectedNames, [name], label)
            XCTAssertEqual(f.beginExit(), .swept(protected: [name]), label)
            XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)), label)
        }
    }

    /// B6, late request: refused at its first check, no seam touched.
    func testB6_RequestAfterExitIsRefusedWithoutTouchingAnySeam() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.beginExit()
        XCTAssertEqual(f.requestPlay(), .refused(.exiting))
        XCTAssertEqual(f.rec.all, ["exitSweep"])
        XCTAssertTrue(f.coordinator.transactions.isEmpty)
    }

    /// B7, queued request woken by exit, on three threads: T1 waits for
    /// admission, T2 exits (waiting on the sweep), T3 releases the sweep.
    /// T1 is refused, nothing minted, T2 sweeps once.
    ///
    /// Admission is closed on the test thread BEFORE T2 and T3 start: phase 1
    /// is synchronous and its return is the only observable that orders it
    /// ahead of the release. The first cut started all three together and the
    /// release sometimes beat the close, admitting T1 legitimately, which was
    /// a race in the test and not in the coordinator.
    func testB7_QueuedRequestIsRefusedWhenExitClosesAdmission() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        f.coordinator.closeAdmission()
        let t2 = Async("exit") { f.coordinator.finishExit() }
        let t3 = Async("release") { f.launchGate!.open() }
        wait(for: [t1.done, t2.done, t3.done], timeout: 2)
        XCTAssertEqual(t1.result, .refused(.exiting))
        XCTAssertNil(f.singleMintedName)
        XCTAssertFalse(f.rec.all.contains("create"))
        XCTAssertEqual(t2.result, .swept(protected: []))
        XCTAssertEqual(f.exitSweepCount, 1)
    }

    /// B7a: the admission-closure broadcast is load-bearing on its own. The
    /// launch sweep stays HELD while the waiting request is observed to be
    /// refused, so only `closeAdmission()`'s broadcast can have woken it.
    /// (B7 and B18 release the sweep, whose completion broadcast would wake
    /// the waiter anyway, so they do not prove this; Anthony's point at the
    /// plan gate.)
    ///
    /// The ordering is forced, not hoped for: `onAdmissionWait` fires UNDER
    /// the lock just before T1 waits, and `closeAdmission()` needs that lock,
    /// so it cannot run until T1 is inside the wait. The first cut of this
    /// test had no such ordering and passed with the broadcast deleted: the
    /// close won the thread start-up race and T1 was refused at its first
    /// check, never woken at all.
    func testB7a_ClosingAdmissionWakesAWaitingRequestWhileTheSweepIsStillHeld() {
        let f = Fixture()
        f.launchGate = Gate()
        let waiting = expectation(description: "T1 is about to wait, holding the lock")
        waiting.assertForOverFulfill = false
        f.onAdmissionWait = { waiting.fulfill() }
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        wait(for: [waiting], timeout: 2)
        f.coordinator.closeAdmission()   // blocks until T1 has released the lock into its wait
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(t1.result, .refused(.exiting))
        XCTAssertEqual(f.coordinator.launchSweep, .running, "the sweep was never released before the refusal was observed")
        XCTAssertNil(f.singleMintedName)
        f.launchGate!.open()
        XCTAssertEqual(f.coordinator.finishExit(), .swept(protected: []))
    }

    /// B8, confirmation bound: `notyet` until the virtual clock passes the
    /// deadline. `unconfirmed`, protected, and the exit script carries it.
    func testB8_ConfirmationBoundLeavesTheNameProtected() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.confirmResponder = { _ in discoverNotYetToken }
        let r = f.requestPlay()
        guard case .completed(.unconfirmed(let name)) = r else { return XCTFail("\(r)") }
        let reads = f.rec.all.filter { $0 == "confirmRead" }.count
        // Absolute deadline of 3s at a 0.3s cadence: reads at t = 0, 0.3, …,
        // 3.0 and never one scheduled past the deadline, so eleven exactly
        // on the virtual clock. The first cut of the loop read twelve times:
        // it checked the deadline AFTER each read and floating-point drift on
        // the cadence put the eleventh read just under 3.0.
        XCTAssertEqual(reads, 11)
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
    }

    /// B12, play throws: ambiguous, protected, the existing "Couldn't play"
    /// outcome, and the exit script carries the name.
    func testB12_ThrownPlayIsAmbiguousAndProtected() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.playThrows = SeamError(text: "AppleEvent timed out")
        let r = f.requestPlay(title: "Kid A")
        guard case .completed(.playAmbiguous(let name)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f.toasts, [.outcome(.playFailed("AppleEvent timed out"), title: "Kid A")])
        XCTAssertEqual(f.coordinator.protectedNames, [name])
        XCTAssertEqual(f.beginExit(), .swept(protected: [name]))
        XCTAssertTrue(f.lastExitScript!.contains(protectedClause(name)))
        XCTAssertFalse(f.rec.all.contains("confirmRead"), "no confirmation after a thrown play")
    }

    /// B13, create throws: unprotected (no play follows), the ordinary script
    /// runs. The test does NOT assert nothing exists in Music: the harness
    /// cannot know that, and a create can throw after a 2xx.
    func testB13_ThrownCreateIsUnprotectedAndTheOrdinarySweepRuns() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.createThrows = SeamError(text: "503")
        let r = f.requestPlay(title: "Kid A")
        guard case .completed(.failedBeforePlay(_, .create)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f.toasts, [.outcome(.createFailed("503"), title: "Kid A")])
        XCTAssertEqual(f.coordinator.protectedNames, [])
        XCTAssertEqual(f.beginExit(), .swept(protected: []))
        XCTAssertEqual(f.lastExitScript, discoverSweepScript(protectedNames: []))
    }

    /// An expired user token on the create is the sign-in toast, as before.
    func testB13a_ExpiredTokenOnCreateAsksForSignIn() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.createThrows = AuthError.userTokenExpired(401)
        _ = f.requestPlay(title: "Kid A")
        XCTAssertEqual(f.toasts, [.outcome(.needsSignIn, title: "Kid A")])
    }

    /// B14, readiness timeout: unprotected, the "still loading" outcome, the
    /// ordinary script.
    func testB14_ReadinessTimeoutIsUnprotectedAndTheOrdinarySweepRuns() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        f.readCountValue = 0
        let r = f.requestPlay(title: "Kid A")
        guard case .completed(.failedBeforePlay(_, .readiness)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f.toasts, [.outcome(.notReady, title: "Kid A")])
        XCTAssertEqual(f.coordinator.protectedNames, [])
        XCTAssertFalse(f.rec.all.contains("play"))
        XCTAssertEqual(f.beginExit(), .swept(protected: []))
        XCTAssertEqual(f.lastExitScript, discoverSweepScript(protectedNames: []))
    }

    /// B15, launch sweep fails: `finished(failed)`, a waiting request proceeds
    /// to mint, and exit does not wait.
    func testB15_FailedLaunchSweepStillReleasesRequestsAndExit() {
        let f = Fixture()
        f.launchGate = Gate()
        f.launchSweepThrows = SeamError(text: "osascript timed out")
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        f.launchGate!.open()
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(f.coordinator.launchSweep, .finished(.failed("osascript timed out")))
        guard case .completed(.confirmedPlaying)? = t1.result else { return XCTFail("\(String(describing: t1.result))") }
        f.clock.exitLaunchSweepDeadline = { .distantPast }
        XCTAssertEqual(f.beginExit(), .swept(protected: []), "a finished sweep never makes exit wait, whatever its outcome")
    }

    /// B17, exit across every terminal state, one parameterised drive. The
    /// protected SET and its USE in the emitted script are asserted together,
    /// because a correct set discarded by its caller is the seam this repo
    /// has shipped bugs through.
    func testB17_ExitScriptMatchesTheProtectionOfEveryTerminalState() {
        struct Arm { let label: String; let configure: (Fixture) -> Void; let protects: Bool }
        let arms: [Arm] = [
            Arm(label: "confirmedPlaying", configure: { _ in }, protects: false),
            Arm(label: "unconfirmed", configure: { $0.confirmResponder = { _ in discoverNotYetToken } }, protects: true),
            Arm(label: "playAmbiguous", configure: { $0.playThrows = SeamError(text: "x") }, protects: true),
            Arm(label: "failedBeforePlay(create)", configure: { $0.createThrows = SeamError(text: "x") }, protects: false),
            Arm(label: "failedBeforePlay(readiness)", configure: { $0.readCountValue = 0 }, protects: false),
        ]
        for arm in arms {
            let f = Fixture()
            f.coordinator.completeLaunchSweep(.swept)
            arm.configure(f)
            guard case .completed(let state) = f.requestPlay() else { return XCTFail(arm.label) }
            XCTAssertEqual(Fixture.label(state), arm.label)
            XCTAssertTrue(state.isTerminal, arm.label)
            let expected: [String] = arm.protects ? [state.name] : []
            XCTAssertEqual(f.beginExit(), .swept(protected: expected), arm.label)
            let script = f.lastExitScript!
            if arm.protects {
                XCTAssertTrue(script.contains(protectedClause(state.name)), arm.label)
                XCTAssertTrue(script.contains(" and (protectedNames does not contain nm)"), arm.label)
            } else {
                XCTAssertEqual(script, discoverSweepScript(protectedNames: []), arm.label)
            }
        }
    }

    /// B18 arm 1, nothing is admitted after `q` (Codex, third round): the
    /// poller wait is modelled as the gap between `closeAdmission()` and
    /// `finishExit()`, and the launch sweep finishes INSIDE that gap. The
    /// request that was waiting on it is still refused.
    func testB18_LaunchSweepFinishingBetweenTheTwoExitPhasesAdmitsNothing() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        f.coordinator.closeAdmission()                       // phase 1 (T2)
        let t3 = Async("release") { f.launchGate!.open() }   // sweep finishes in the gap
        wait(for: [t1.done, t3.done], timeout: 2)
        XCTAssertEqual(t1.result, .refused(.exiting))
        XCTAssertNil(f.singleMintedName)
        XCTAssertFalse(f.rec.all.contains("create"))
        XCTAssertEqual(f.coordinator.finishExit(), .swept(protected: []))   // phase 2 (T2)
        XCTAssertTrue(f.coordinator.transactions.isEmpty)
    }

    /// B18 arm 2: the launch sweep already finished; a request is queued on a
    /// serial queue behind a held action when admission closes. When the
    /// held action releases, the request is refused at its first check.
    func testB18_RequestQueuedBehindAHeldActionIsRefusedAfterClose() {
        let f = Fixture()
        f.coordinator.completeLaunchSweep(.swept)
        let queue = DispatchQueue(label: "test.actions")
        let held = Gate()
        queue.async { held.pass() }
        let done = expectation(description: "queued request ran")
        var result: DiscoverPlayRequestOutcome?
        queue.async { result = f.requestPlay(); done.fulfill() }
        XCTAssertTrue(held.awaitArrival())
        f.coordinator.closeAdmission()
        held.open()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, .refused(.exiting))
        XCTAssertNil(f.singleMintedName)
        XCTAssertEqual(f.coordinator.finishExit(), .swept(protected: []))
    }

    /// B9, toast threshold: the first timed wait expires with the sweep still
    /// running, so exactly one "Finishing startup cleanup…" is posted; the
    /// request then waits untimed and proceeds when the sweep completes.
    func testB9_OneStartupToastWhenTheSweepOutlivesTheThreshold() {
        let f = Fixture()
        f.launchGate = Gate()
        f.clock.admissionToastDeadline = { .distantPast }
        let toasted = expectation(description: "toast")
        f.onToast = { if $0 == .startupCleanup { toasted.fulfill() } }
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        wait(for: [toasted], timeout: 2)
        XCTAssertEqual(f.coordinator.launchSweep, .running, "the toast was posted while the sweep was still running")
        f.launchGate!.open()
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(f.startupToastCount, 1, "exactly one, however long the untimed wait")
        guard case .completed(.confirmedPlaying)? = t1.result else { return XCTFail("\(String(describing: t1.result))") }
    }

    /// B9, second arm: released before the threshold, no toast.
    func testB9_NoStartupToastWhenTheSweepFinishesBeforeTheThreshold() {
        let f = Fixture()
        f.launchGate = Gate()
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.launchGate!.awaitArrival())
        let t1 = Async("play") { f.requestPlay() }
        f.launchGate!.open()
        wait(for: [t1.done], timeout: 2)
        XCTAssertEqual(f.startupToastCount, 0)
    }

    // MARK: - The confirmation script

    func testConfirmationScriptKeysOnTheSharedReadyStateAndTheEscapedName() {
        let name = "\(discoverPlaylistPrefix)X — He said \"hi\""
        let s = discoverConfirmationScript(playlistName: name)
        XCTAssertTrue(s.contains("stateText is \"\(nowPlayingReadyState)\""))
        XCTAssertTrue(s.contains("ctxName is \"\(escapeAppleScriptString(name))\""))
        XCTAssertTrue(s.contains("return \"\(discoverConfirmedToken)\""))
        XCTAssertTrue(s.contains("return \"\(discoverNotYetToken)\""))
        XCTAssertFalse(s.contains("track")); XCTAssertFalse(s.contains("song"))
    }

    /// The comparison happens INSIDE AppleScript, so it is executed here with
    /// the two application reads substituted. `playing` for the OLD context is
    /// `notyet`; an unreadable context is `notyet`; only state AND name confirm.
    func testConfirmationScriptExecutedComparesStateAndName() {
        let name = "\(discoverPlaylistPrefix)N — Kid \"A\""
        let base = discoverConfirmationScript(playlistName: name)
        func run(state: String, context: String?) -> String? {
            var s = base
            s = s.replacingOccurrences(of: "player state as text", with: "\"\(state)\"")
            if let context {
                s = s.replacingOccurrences(of: "name of current playlist", with: "\"\(escapeAppleScriptString(context))\"")
            } else {
                s = s.replacingOccurrences(of: "set ctxName to name of current playlist", with: "error \"unreadable\" number -1728")
            }
            XCTAssertFalse(s.contains("player state"), "substitution applied")
            XCTAssertFalse(s.contains("current playlist"), "substitution applied")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on runScript()\n\(s)\nend runScript\nreturn my runScript()"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { XCTFail("\(error)"); return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { XCTFail("osascript exit \(p.terminationStatus)"); return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(run(state: "playing", context: name), discoverConfirmedToken)
        XCTAssertEqual(run(state: "playing", context: "\(discoverPlaylistPrefix)OLD"), discoverNotYetToken, "playing for the OLD context is not confirmation")
        XCTAssertEqual(run(state: "playing", context: nil), discoverNotYetToken, "an unreadable context is not confirmation")
        XCTAssertEqual(run(state: "stopped", context: name), discoverNotYetToken, "the right context in the wrong state is not confirmation")
        XCTAssertEqual(run(state: "paused", context: name), discoverNotYetToken)
    }
}

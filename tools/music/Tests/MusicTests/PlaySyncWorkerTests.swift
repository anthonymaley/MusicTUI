import XCTest
@testable import music

/// A runner that records every call and returns a canned result. It is the
/// worker's only dependency, so anything the worker does to play sync shows up
/// here and nowhere else.
private final class FakeRunner: PlaySyncRunning {
    private let lock = NSLock()
    private var _calls: [PlaySyncTrigger] = []
    private var _threads: [Thread] = []
    var result: PlaySyncResult
    /// When set, `pass` waits on it before returning.
    var gate: DispatchSemaphore?
    /// Signalled as each pass begins.
    let entered = DispatchSemaphore(value: 0)

    init(result: PlaySyncResult = FakeRunner.quiet) { self.result = result }

    func pass(_ trigger: PlaySyncTrigger) -> PlaySyncResult {
        lock.lock(); _calls.append(trigger); _threads.append(Thread.current); lock.unlock()
        entered.signal()
        gate?.wait()
        return result
    }

    var calls: [PlaySyncTrigger] { lock.lock(); defer { lock.unlock() }; return _calls }
    var threads: [Thread] { lock.lock(); defer { lock.unlock() }; return _threads }

    static let quiet = PlaySyncResult(blocked: nil, fetch: .ok(newPlays: 0), musicRunning: true,
                                      recorded: [], newProblems: [], outstanding: [],
                                      unconfirmed: [], waiting: 0)
}

private struct Posted: Equatable {
    let text: String
    let error: Bool
    let ttl: TimeInterval
}

private final class PostLog {
    private let lock = NSLock()
    private var _items: [Posted] = []
    func add(_ text: String, _ error: Bool, _ ttl: TimeInterval) {
        lock.lock(); _items.append(Posted(text: text, error: error, ttl: ttl)); lock.unlock()
    }
    var items: [Posted] { lock.lock(); defer { lock.unlock() }; return _items }
}

private func entry(_ seq: Int, _ state: EntryState, reported: Bool = false) -> PlaySyncEntry {
    PlaySyncEntry(ledgerID: "L1", seq: seq, playID: "play-\(seq)", alias: "596357614188841472",
                  persistentID: "0846B01728D34A00", title: "Are You Awake?", artist: "Artist",
                  completedAt: 1_790_000_000 + seq, state: state, phase: .countAndDate,
                  before: nil, target: nil, attempt: nil, observed: nil, barrierReplans: 0,
                  reason: nil, reconciled: false, reported: reported)
}

final class PlaySyncWorkerTests: XCTestCase {

    private func makeWorker(bridge: Bool, runner: FakeRunner, log: PostLog,
                            interval: TimeInterval = 30, firstDelay: TimeInterval = 5) -> PlaySyncWorker {
        PlaySyncWorker(isBridgeSelected: { bridge }, runner: runner,
                       post: { log.add($0, $1, $2) },
                       intervalSeconds: interval, firstDelaySeconds: firstDelay)
    }

    // MARK: - Music.app mode

    func testMusicAppModeRunsNoPassAndPostsNothingEvenWithWorkPending() {
        var pending = FakeRunner.quiet
        pending.waiting = 3
        pending.recorded = [entry(1, .done)]
        pending.newProblems = [entry(2, .unmatched, reported: true)]
        let runner = FakeRunner(result: pending)
        let log = PostLog()
        let worker = makeWorker(bridge: false, runner: runner, log: log)
        worker.tickOnce()
        worker.tickOnce()
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(log.items, [])
    }

    func testSwitchingBackToMusicAppStopsPasses() {
        let runner = FakeRunner()
        let log = PostLog()
        var bridge = true
        let worker = PlaySyncWorker(isBridgeSelected: { bridge }, runner: runner,
                                    post: { log.add($0, $1, $2) })
        worker.tickOnce()
        bridge = false
        worker.tickOnce()
        XCTAssertEqual(runner.calls, [.background])
    }

    // MARK: - Bridge mode: news only

    func testTwoRecordedPostsThePluralSentence() {
        var result = FakeRunner.quiet
        result.recorded = [entry(1, .done), entry(2, .done)]
        let runner = FakeRunner(result: result)
        let log = PostLog()
        makeWorker(bridge: true, runner: runner, log: log).tickOnce()
        XCTAssertEqual(runner.calls, [.background])
        XCTAssertEqual(log.items, [Posted(text: "Recorded 2 library plays in Music.app", error: false, ttl: 4)])
    }

    func testOneRecordedPostsTheSingularSentence() {
        var result = FakeRunner.quiet
        result.recorded = [entry(1, .done)]
        let log = PostLog()
        makeWorker(bridge: true, runner: FakeRunner(result: result), log: log).tickOnce()
        XCTAssertEqual(log.items, [Posted(text: "Recorded 1 library play in Music.app", error: false, ttl: 4)])
    }

    func testOneNewProblemPostsTheSingularErrorSentence() {
        var result = FakeRunner.quiet
        result.newProblems = [entry(3, .unmatched, reported: true)]
        result.outstanding = result.newProblems
        let log = PostLog()
        makeWorker(bridge: true, runner: FakeRunner(result: result), log: log).tickOnce()
        XCTAssertEqual(log.items, [Posted(text: "1 play not recorded yet \u{2014} run music sync-plays",
                                          error: true, ttl: 6)])
    }

    func testSeveralNewProblemsPostThePluralErrorSentence() {
        var result = FakeRunner.quiet
        result.newProblems = [entry(3, .unmatched, reported: true), entry(4, .conflict, reported: true),
                              entry(5, .unresolved, reported: true)]
        let log = PostLog()
        makeWorker(bridge: true, runner: FakeRunner(result: result), log: log).tickOnce()
        XCTAssertEqual(log.items, [Posted(text: "3 plays not recorded yet \u{2014} run music sync-plays",
                                          error: true, ttl: 6)])
    }

    /// Problems already reported stay in `outstanding` and `unconfirmed` on
    /// every later pass; only `newProblems` is news, and the worker keeps no
    /// memory of its own that could repeat or suppress it.
    func testOutstandingProblemsWithNoNewOnesPostNothingOnEveryTick() {
        var result = FakeRunner.quiet
        result.outstanding = [entry(3, .unmatched, reported: true)]
        result.unconfirmed = [entry(4, .unresolved, reported: true)]
        result.waiting = 2
        let runner = FakeRunner(result: result)
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log)
        worker.tickOnce()
        worker.tickOnce()
        XCTAssertEqual(runner.calls, [.background, .background])
        XCTAssertEqual(log.items, [])
    }

    func testTheSameNewProblemsReturnedTwiceArePostedTwice() {
        var result = FakeRunner.quiet
        result.newProblems = [entry(3, .conflict, reported: true)]
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: FakeRunner(result: result), log: log)
        worker.tickOnce()
        worker.tickOnce()
        XCTAssertEqual(log.items.count, 2, "whether a problem is new is the pass's decision")
    }

    func testRecordedAndNewProblemsBothPostWithTheProblemLast() {
        var result = FakeRunner.quiet
        result.recorded = [entry(1, .done)]
        result.newProblems = [entry(2, .unmatched, reported: true)]
        let log = PostLog()
        makeWorker(bridge: true, runner: FakeRunner(result: result), log: log).tickOnce()
        XCTAssertEqual(log.items, [
            Posted(text: "Recorded 1 library play in Music.app", error: false, ttl: 4),
            Posted(text: "1 play not recorded yet \u{2014} run music sync-plays", error: true, ttl: 6),
        ])
    }

    // MARK: - Quiet cases

    func testQuietCasesPostNothing() {
        var noop = FakeRunner.quiet
        var busy = FakeRunner.quiet
        busy.blocked = .lockBusy
        busy.fetch = .skipped
        var unreadable = FakeRunner.quiet
        unreadable.blocked = .journalUnreadable(path: "/tmp/x/journal.json")
        unreadable.fetch = .skipped
        var tooNew = FakeRunner.quiet
        tooNew.blocked = .journalTooNew
        var unsafe = FakeRunner.quiet
        unsafe.blocked = .directoryUnsafe(path: "/tmp/x")
        var musicQuit = FakeRunner.quiet
        musicQuit.musicRunning = false
        musicQuit.waiting = 4
        var bridgeDown = FakeRunner.quiet
        bridgeDown.fetch = .bridgeNotRunning
        var bridgeOld = FakeRunner.quiet
        bridgeOld.fetch = .bridgeTooOld
        var fetchFailed = FakeRunner.quiet
        fetchFailed.fetch = .failed("timed out")
        noop.fetch = .ok(newPlays: 0)

        for (name, result) in [("no-op", noop), ("lock busy", busy), ("unreadable", unreadable),
                               ("too new", tooNew), ("unsafe", unsafe), ("Music.app quit", musicQuit),
                               ("Bridge not running", bridgeDown), ("Bridge too old", bridgeOld),
                               ("fetch failed", fetchFailed)] {
            let runner = FakeRunner(result: result)
            let log = PostLog()
            makeWorker(bridge: true, runner: runner, log: log).tickOnce()
            XCTAssertEqual(runner.calls, [.background], name)
            XCTAssertEqual(log.items, [], name)
        }
    }

    // MARK: - Structure

    /// The worker's only play-sync dependency is the runner, and its only call
    /// is one background pass per tick. It is built here with no paths, no
    /// journal and no writer, so it has no other way in.
    func testTheOnlyCallIsOneBackgroundPassPerTick() {
        let runner = FakeRunner()
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log)
        for _ in 0..<3 { worker.tickOnce() }
        XCTAssertEqual(runner.calls, [.background, .background, .background])
    }

    // MARK: - Thread, cadence and stop

    func testPassesRunOnTheWorkersOwnThread() {
        let runner = FakeRunner()
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log, interval: 0.05, firstDelay: 0.01)
        worker.start()
        XCTAssertEqual(runner.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(runner.entered.wait(timeout: .now() + 2), .success, "a second pass follows at the interval")
        worker.stop()
        let threads = runner.threads
        XCTAssertFalse(threads.isEmpty)
        for t in threads {
            XCTAssertFalse(t === Thread.current)
            XCTAssertFalse(t.isMainThread)
        }
    }

    func testNoPassBeforeTheFirstDelay() {
        let runner = FakeRunner()
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log, interval: 30, firstDelay: 30)
        worker.start()
        XCTAssertEqual(runner.entered.wait(timeout: .now() + 0.3), .timedOut)
        worker.stop()
        XCTAssertEqual(runner.calls, [])
    }

    func testStopDuringTheWaitReturnsPromptlyAndRunsNoMorePasses() {
        let runner = FakeRunner()
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log, interval: 30, firstDelay: 0.01)
        worker.start()
        XCTAssertEqual(runner.entered.wait(timeout: .now() + 2), .success)
        let began = Date()
        worker.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
        let count = runner.calls.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(runner.calls.count, count)
    }

    func testStopReturnsWithinTwoAndAHalfSecondsWhilePassIsBlocked() {
        var result = FakeRunner.quiet
        result.recorded = [entry(1, .done)]
        let runner = FakeRunner(result: result)
        let gate = DispatchSemaphore(value: 0)
        runner.gate = gate
        let log = PostLog()
        let worker = makeWorker(bridge: true, runner: runner, log: log, interval: 30, firstDelay: 0.01)
        worker.start()
        XCTAssertEqual(runner.entered.wait(timeout: .now() + 2), .success)
        let began = Date()
        worker.stop()
        let took = Date().timeIntervalSince(began)
        XCTAssertLessThan(took, 2.5)
        XCTAssertGreaterThanOrEqual(took, 1.5, "stop waits for a pass in progress, up to its bound")
        // The pass is left to finish on its own; it posts nothing after stop.
        gate.signal()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(log.items, [])
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testStopWithoutStartReturnsImmediately() {
        let worker = makeWorker(bridge: true, runner: FakeRunner(), log: PostLog())
        let began = Date()
        worker.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    }

    // MARK: - Status line wiring

    func testPostsReachTheStatusStore() {
        var result = FakeRunner.quiet
        result.recorded = [entry(1, .done), entry(2, .done)]
        let status = StatusStore()
        let worker = PlaySyncWorker(isBridgeSelected: { true }, runner: FakeRunner(result: result),
                                    post: { status.post($0, error: $1, ttl: $2) })
        worker.tickOnce()
        let toast = status.current()
        XCTAssertEqual(toast?.text, "Recorded 2 library plays in Music.app")
        XCTAssertEqual(toast?.isError, false)
    }
}

import XCTest
@testable import music

/// `BridgeListFeed<Row>` in isolation, against a fake `fetch` closure — no
/// scene, no wire. C2's shared walk-and-inbox discipline for Albums and
/// Artists (Songs kept its own hand-rolled version, from before this slice).
final class BridgeListFeedTests: XCTestCase {

    private struct Row: Equatable { let id: String }

    private func page(_ ids: [String], generation: Int?, next: String?, total: Int? = nil,
                      instance: String? = nil) -> MusicPage {
        MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                  nextCursor: next, total: total ?? ids.count, generation: generation, libraryInstance: instance)
    }

    /// A scripted fetch, one page per call, with an optional gate per index so
    /// a test can observe "page 1 landed, page 2 has not yet" rather than
    /// racing the feed's own background thread.
    fileprivate final class ScriptedFetch {
        private let lock = NSLock()
        private var script: [MusicPage]
        private var calls = 0
        private var gates: [Int: DispatchSemaphore] = [:]
        private var threads: [Int: Thread] = [:]

        init(_ script: [MusicPage]) { self.script = script }

        func gate(at n: Int) { lock.lock(); gates[n] = DispatchSemaphore(value: 0); lock.unlock() }
        func release(at n: Int) { lock.lock(); let g = gates[n]; lock.unlock(); g?.signal() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        /// True once the thread that made call `n` has ENDED, which is later than
        /// the call returning: the walk's page post, its epoch check and its
        /// ending have all run by then. The signal for "the abandoned work has
        /// finished", so a test asserts after it instead of after a sleep.
        func threadEnded(at n: Int) -> Bool {
            lock.lock(); let t = threads[n]; lock.unlock()
            return t?.isFinished ?? false
        }

        func fetch(_ cursor: String?, _ limit: Int) throws -> MusicPage {
            lock.lock()
            let n = calls
            calls += 1
            guard n < script.count else { lock.unlock(); throw MusicProviderError.unavailable("unscripted call \(n)") }
            let result = script[n]
            let gate = gates[n]
            threads[n] = Thread.current
            lock.unlock()
            _ = gate?.wait(timeout: .now() + 5)
            return result
        }
    }

    private func feed(_ fetch: @escaping (String?, Int) throws -> MusicPage) -> BridgeListFeed<Row> {
        BridgeListFeed<Row>(fetch: fetch, map: { Row(id: $0.id) }, sleep: { _ in })
    }

    private func settleUntil(_ seconds: Double = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }

    func testTheFirstPageIsVisibleWhileTheSecondIsGated() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 1, next: nil)])
        script.gate(at: 1)
        let f = feed(script.fetch)
        f.start()

        // Drain repeatedly until the first page's replace shows up (start()
        // runs on a detached thread, so this may need a couple of ticks).
        // `drain()` CLEARS `replace` once read, so there must be exactly one
        // loop capturing it — an earlier probe-then-drain would discard it.
        var seenFirst: [Row] = []
        XCTAssertTrue(settleUntil {
            let d = f.drain()
            if let r = d.replace { seenFirst = r }
            return !seenFirst.isEmpty
        })
        XCTAssertEqual(seenFirst, [Row(id: "a")], "the first page was not visible before the second landed")
        script.release(at: 1)
        var seenSecond: [Row] = []
        XCTAssertTrue(settleUntil {
            let d = f.drain()
            seenSecond += d.append
            return !seenSecond.isEmpty
        })
        XCTAssertEqual(seenSecond, [Row(id: "b")])
    }

    func testAGenerationChangeKeepsOldRowsUntilTheNewPage1ThenReplaces() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 2, next: "c2"),
                                    page(["z"], generation: 3, next: nil)])
        let f = feed(script.fetch)
        f.start()

        var replaced: [Row] = []
        var appended: [Row] = []
        XCTAssertTrue(settleUntil(3.0) {
            let d = f.drain()
            if let r = d.replace { replaced = r; appended = [] }
            appended += d.append
            return d.done
        })
        // The restart discards the first attempt's rows wholesale; only the
        // SECOND attempt's page is ever the final `replace`.
        XCTAssertEqual(replaced, [Row(id: "z")])
        XCTAssertTrue(appended.isEmpty)
    }

    func testASecondRestartEndsWithTheReason() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 2, next: "c2")])
        // Only two pages scripted: the third call (the restarted attempt's
        // first page) hits the unscripted throw, which is itself a
        // `.unavailable`, not a `.staleGeneration` — close enough to prove the
        // feed reports SOME failure rather than looping forever. The
        // `walkLibraryPages`-level "second stale generation" property is
        // already pinned directly in `BridgeLibraryReadsTests`.
        let f = feed(script.fetch)
        f.start()
        XCTAssertTrue(settleUntil(3.0) { f.drain().failure != nil })
    }

    func testWarmingSetsWarmingAndTheWalkAsksAgainOnTheHint() {
        // Gates the retry itself (via `sleep`), so the test can observe
        // `pendingWarming == true` deterministically before letting the walk
        // proceed to the successful second page — without this, an
        // essentially-instant fake fetch could set warming and clear it again
        // (the success page lands) before any drain ever ran.
        let releaseRetry = DispatchSemaphore(value: 0)
        var calls = 0
        let lock = NSLock()
        let f = BridgeListFeed<Row>(fetch: { _, _ in
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if n == 1 { throw MusicProviderError.warming("hold on", retryAfter: 0.01) }
            return self.page(["a"], generation: 1, next: nil)
        }, map: { Row(id: $0.id) }, sleep: { _ in releaseRetry.wait(timeout: .now() + 5) })
        f.start()

        var sawWarming = false
        XCTAssertTrue(settleUntil(3.0) {
            let d = f.drain()
            if d.warming { sawWarming = true }
            return sawWarming
        }, "warming was never surfaced before the retry was released")
        releaseRetry.signal()
        XCTAssertTrue(settleUntil(3.0) { f.drain().done })
        lock.lock(); let finalCalls = calls; lock.unlock()
        XCTAssertGreaterThanOrEqual(finalCalls, 2, "the walk did not ask again after warming")
    }

    func testResetDuringAWalkDropsEveryLaterPostFromThatWalk() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 1, next: nil)])
        script.gate(at: 1)
        let f = feed(script.fetch)
        f.start()
        XCTAssertTrue(settleUntil { script.reachedGateAt1() })
        f.reset()
        script.release(at: 1)
        // Wait for the (now-abandoned) walk to END, so it has had its chance to
        // post; it must not land anything after the reset. The feed's worker
        // group covers every walk thread it started.
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "the abandoned walk never ended")
        let d = f.drain()
        XCTAssertNil(d.replace)
        XCTAssertTrue(d.append.isEmpty)
        XCTAssertFalse(d.done)
    }

    func testStartWhileInFlightDoesNothing() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil)])
        script.gate(at: 0)
        let f = feed(script.fetch)
        f.start()
        XCTAssertTrue(settleUntil { script.reachedGateAt0() })
        f.start()   // second start while the first is still in flight
        script.release(at: 0)
        XCTAssertTrue(settleUntil(3.0) { f.drain().done })
        XCTAssertEqual(script.callCount, 1, "a second start() re-issued the fetch instead of no-op'ing")
    }

    /// The single-flight race Codex's review caught: `reset()` while a walk
    /// is blocked mid-fetch lets `start()` launch a second walk under the new
    /// epoch; the FIRST (abandoned) walk then unblocks and reaches its own
    /// ending. Before the fix, that ending cleared `walking` unconditionally,
    /// which is the SECOND walk's flag, not its own — so a THIRD `start()`
    /// call (while the second walk is still legitimately blocked) launched a
    /// third, concurrent walk instead of correctly no-op'ing. Fixed by
    /// checking the epoch BEFORE touching `walking` in the walk's ending.
    ///
    /// Detected here by exhausting the script at exactly 2 entries: a rogue
    /// third walk's first fetch call lands on index 2, which is unscripted
    /// and throws — so `script.callCount` climbing past 2 is the tell.
    func testResetWhileBlockedThenStartAgainNeverLaunchesAThirdConcurrentWalk() {
        let script = ScriptedFetch([
            page(["a"], generation: 1, next: nil),   // index 0: walk A's page, gated
            page(["b"], generation: 2, next: nil),   // index 1: walk B's page, gated — finishes B
        ])
        script.gate(at: 0)
        script.gate(at: 1)
        let f = feed(script.fetch)

        f.start()                                              // walk A: blocks fetching index 0
        XCTAssertTrue(settleUntil { script.reachedGateAt0() })

        f.reset()                                              // abandon walk A: bump epoch, clear walking
        f.start()                                              // walk B: fresh epoch, should be allowed
        XCTAssertTrue(settleUntil { script.callCount > 1 }, "walk B never reached its own (gated) first page")

        script.release(at: 0)                                  // let walk A's blocked fetch return
        // A's thread has ended, so its (should-be-no-op) ending has run. The
        // group can't say this: B is still blocked, so it holds the group open.
        XCTAssertTrue(settleUntil { script.threadEnded(at: 0) }, "walk A never ended")

        // The race: if A's ending wrongly cleared `walking`, THIS call
        // launches a rogue walk C while B is still blocked at index 1.
        f.start()

        script.release(at: 1)                                  // let walk B finish
        // Every walk thread, B and a rogue C alike, has ended once the group
        // drains, so the count below is final rather than a snapshot. C's
        // fetch (index 2) is not gated: it would already have been made.
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "a walk never ended")
        XCTAssertEqual(script.callCount, 2,
                      "a third walk started while the second was still legitimately in flight")
        let drained = settleUntil(3.0) { let d = f.drain(); return d.done || d.failure != nil }
        XCTAssertTrue(drained, "walk B never finished")
        XCTAssertNil(f.drain().failure, "an unscripted (rogue walk) call was recorded as a failure")
    }

    /// Gates the SECOND page so the walk is blocked mid-attempt, drops the
    /// only strong reference to the feed while it waits, then releases the
    /// gate. `onPage`'s `[weak self]` must find the feed gone and return
    /// false, so the walk stops THERE rather than asking for a third page —
    /// an exact count, not a timing-dependent approximation.
    func testTheWalkEndsWhenTheFeedIsReleased() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 1, next: "c2"),
                                    page(["c"], generation: 1, next: nil)])
        script.gate(at: 1)
        var f: BridgeListFeed<Row>? = feed(script.fetch)
        f?.start()
        XCTAssertTrue(settleUntil { script.callCount > 1 }, "never reached the gated second page")
        f = nil   // drop the only strong reference while blocked mid-page
        script.release(at: 1)
        // The feed is gone, so its worker group is out of reach: wait on the
        // thread that made the gated call instead. It has ended once the walk
        // has either stopped or gone on to fetch a third page.
        XCTAssertTrue(settleUntil { script.threadEnded(at: 1) }, "the walk never ended")
        XCTAssertEqual(script.callCount, 2, "the walk fetched a THIRD page after the feed was released")
    }

    // MARK: - Re-asking a stale snapshot
    //
    // SpanDAC serves a snapshot older than 600 s marked `stale`, starts one
    // background refresh and never pushes the result, so a feed that asked once
    // keeps the old list for the rest of the run. These pin the re-ask: keep the
    // stale rows, probe again every `LibraryReask.interval`, replace with the
    // first unflagged read, stop at `maxTotalWait`.

    private func flagged(_ ids: [String], stale: Bool = true, refreshing: Bool = false) -> MusicPage {
        MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                  nextCursor: nil, total: ids.count, generation: 1, stale: stale, refreshing: refreshing)
    }

    /// An injected `sleep` that records what it was asked for and can hold the
    /// FIRST call until the test lets it go.
    fileprivate final class SleepRecorder {
        private let lock = NSLock()
        private var values: [TimeInterval] = []
        let firstGate = DispatchSemaphore(value: 0)
        private let gateFirst: Bool
        init(gateFirst: Bool = false) { self.gateFirst = gateFirst }
        var calls: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
        func sleep(_ s: TimeInterval) {
            lock.lock(); values.append(s); let first = values.count == 1; lock.unlock()
            if gateFirst && first { _ = firstGate.wait(timeout: .now() + 5) }
        }
    }

    private func reaskFeed(_ fetch: @escaping (String?, Int) throws -> MusicPage,
                           _ sleeper: SleepRecorder) -> BridgeListFeed<Row> {
        BridgeListFeed<Row>(fetch: fetch, map: { Row(id: $0.id) }, sleep: sleeper.sleep, reasksStale: true)
    }

    func testAStaleReplyIsKeptThenReplacedByTheFirstFreshReadAfterTheInterval() {
        let script = ScriptedFetch([flagged(["old"]),                 // initial walk: stale
                                    flagged(["old"]),                 // probe 1: still stale
                                    flagged(["new"], stale: false),   // probe 2: fresh
                                    flagged(["new"], stale: false)])  // the re-walk
        let sleeper = SleepRecorder(gateFirst: true)   // hold the wait so the stale list is observable
        let f = reaskFeed(script.fetch, sleeper)
        f.start()

        var replaces: [[Row]] = []
        var done = false
        XCTAssertTrue(settleUntil {
            let d = f.drain()
            if let r = d.replace { replaces.append(r) }
            if d.done { done = true }
            return !replaces.isEmpty
        }, "the stale list was not shown")
        sleeper.firstGate.signal()
        XCTAssertTrue(settleUntil {
            let d = f.drain()
            if let r = d.replace { replaces.append(r) }
            if d.done { done = true }
            return replaces.count >= 2
        }, "the fresh list never replaced the stale one: \(replaces)")
        XCTAssertEqual(replaces, [[Row(id: "old")], [Row(id: "new")]])
        XCTAssertTrue(done, "the first walk's done must still be reported")
        XCTAssertEqual(sleeper.calls, [LibraryReask.interval, LibraryReask.interval])
        XCTAssertEqual(script.callCount, 4)
    }

    /// The drill-in tracks feed is built without the opt-in: a flagged tracks
    /// read is shown as it is and never swapped under the tracks cursor.
    func testAFeedThatDidNotOptInNeverReAsksAFlaggedReply() {
        let script = ScriptedFetch([flagged(["t1"]), flagged(["t2"], stale: false), flagged(["t2"], stale: false)])
        let sleeper = SleepRecorder()
        let f = BridgeListFeed<Row>(fetch: script.fetch, map: { Row(id: $0.id) }, sleep: sleeper.sleep)
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        usleep(80_000)
        XCTAssertEqual(script.callCount, 1)
        XCTAssertTrue(sleeper.calls.isEmpty)
    }

    func testARefreshingReplyIsAlsoReAsked() {
        let script = ScriptedFetch([flagged(["old"], stale: false, refreshing: true),
                                    flagged(["new"], stale: false),
                                    flagged(["new"], stale: false)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        var last: [Row]? = nil
        XCTAssertTrue(settleUntil {
            if let r = f.drain().replace { last = r }
            return last == [Row(id: "new")]
        })
    }

    /// A `reset()` that lands while the probe is in flight must not cost a
    /// first-page read: the probe's unflagged reply earns a re-walk only if the
    /// feed is still current.
    func testAResetDuringTheProbeSpendsNoFurtherRead() {
        let script = ScriptedFetch([flagged(["old"]),                 // initial walk: stale
                                    flagged(["new"], stale: false),   // the probe: fresh, but gated
                                    flagged(["new"], stale: false)])  // the re-walk's first page: must never be read
        script.gate(at: 1)
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.callCount == 2 }, "the probe never started")
        f.reset()
        script.release(at: 1)
        // The worker has ended, so a re-walk it was going to make has been made.
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "the re-ask worker never ended")
        XCTAssertEqual(script.callCount, 2, "a reset during the probe still cost a first-page read")
    }

    // MARK: - A person-asked refresh

    /// One buffered, `reasked` replacement; nothing before it, so the list on
    /// screen is never shrunk to a first page.
    func testARefreshPostsOneReaskedReplacementAndRunsTheHookFirst() {
        let script = ScriptedFetch([page(["a", "b"], generation: 1, next: nil),
                                    page(["n", "a", "b"], generation: 1, next: nil)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        var order: [String] = []
        XCTAssertEqual(f.refresh(begin: { order.append("begin\(script.callCount)"); return nil },
                                 end: { order.append("end:\($0)") }), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "the refresh worker never ended")
        XCTAssertEqual(order, ["begin1", "end:listOnly"], "begin must run before the re-walk's first read")
        let d = f.drain()
        XCTAssertEqual(d.replace, [Row(id: "n"), Row(id: "a"), Row(id: "b")])
        XCTAssertTrue(d.reasked)
        XCTAssertTrue(d.append.isEmpty)
    }

    func testARefreshStartsNothingWhileAWalkOrAnEarlierRefreshIsInFlight() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil),
                                    page(["a", "b"], generation: 1, next: nil)])
        script.gate(at: 0)
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.reachedGateAt0() })
        XCTAssertEqual(f.refresh(), .busy, "a refresh started beside a walk")
        script.release(at: 0)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        _ = f.drain()
        script.gate(at: 1)
        XCTAssertEqual(f.refresh(), .started)
        XCTAssertTrue(settleUntil { script.reachedGateAt1() })
        XCTAssertEqual(f.refresh(), .alreadyRefreshing, "a second refresh started beside the first")
        script.release(at: 1)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(script.callCount, 2)
    }

    /// With a completion check the list is read after a verdict is seen, and the
    /// loop spends `LibraryReask`'s interval, not its own.
    func testARefreshWithACheckReadsAgainAfterTheVerdictAndEndsSettled() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil),
                                    page(["a"], generation: 1, next: nil),     // first re-read: before the install
                                    page(["n", "a"], generation: 1, next: nil)])  // the re-read after the verdict
        let sleeper = SleepRecorder()
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        var verdicts: [BridgeListFeed<Row>.RefreshProgress] = [.pending, .pending, .installed]
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        var readsAtCheck: [Int] = []
        XCTAssertEqual(f.refresh(begin: { { readsAtCheck.append(script.callCount); return verdicts.removeFirst() } },
                                 end: { ends.append($0) }), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(ends, [.settled(.installed)])
        XCTAssertEqual(readsAtCheck, [1, 2, 2], "each check must come before the read it vouches for")
        XCTAssertEqual(sleeper.calls, [LibraryReask.interval, LibraryReask.interval], "one interval per wait")
        XCTAssertEqual(f.drain().replace, [Row(id: "n"), Row(id: "a")])
        XCTAssertEqual(script.callCount, 3)
    }

    func testARefreshWithACheckThatNeverSettlesEndsAtTheBound() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil), page(["a"], generation: 1, next: nil)])
        let sleeper = SleepRecorder()
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        XCTAssertEqual(f.refresh(begin: { { .pending } }, end: { ends.append($0) }), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(ends, [.boundSpent])
        XCTAssertEqual(sleeper.calls.reduce(0, +), LibraryReask.maxTotalWait)
        XCTAssertEqual(script.callCount, 2, "an unflagged list was re-read while only the check was pending")
    }

    func testARefreshWhoseReadFailsEndsReadFailedAndPostsNothing() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil)])   // the re-read is unscripted: it throws
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        XCTAssertEqual(f.refresh(end: { ends.append($0) }), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(ends, [.readFailed])
        XCTAssertNil(f.drain().replace)
    }

    /// A `reset()` between the claim and the worker starting revokes the refresh
    /// before it does anything: no `begin`, no read, no `end`.
    /// A plain stale re-ask is waiting on a drain that predates the ask: a refresh
    /// takes over, and the old worker posts nothing after it.
    func testARefreshTakesOverAPlainReAskAndTheOldWorkerPostsNothing() {
        let script = ScriptedFetch([flagged(["old"]),                    // the walk: stale, so a re-ask begins
                                    page(["new"], generation: 1, next: nil)])   // the refresh's read
        let sleeper = SleepRecorder(gateFirst: true)
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { !sleeper.calls.isEmpty }, "the plain re-ask never began waiting")
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        XCTAssertEqual(f.refresh(end: { ends.append($0) }), .tookOver)
        var replaces: [[Row]] = []
        XCTAssertTrue(settleUntil {
            let d = f.drain()
            if let r = d.replace { replaces.append(r) }
            return replaces.last == [Row(id: "new")] && !ends.isEmpty
        }, "the refresh never landed: \(replaces)")
        sleeper.firstGate.signal()   // the old re-ask wakes up
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "a worker never ended")
        XCTAssertEqual(script.callCount, 2, "the old re-ask read after it was taken over")
        XCTAssertNil(f.drain().replace, "the old re-ask posted rows after the takeover")
        XCTAssertEqual(ends, [.listOnly])
        XCTAssertEqual(f.refresh(), .started, "the takeover left the feed claimed")
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
    }

    /// A scene reading the list again by itself (`joinReask`) finds the plain re-ask
    /// waiting on the drain: it starts nothing, and the re-ask's own read after the
    /// drain is the only one.
    func testAnAutomaticRereadJoinsAPlainReAskAndStartsNoWalk() {
        let script = ScriptedFetch([flagged(["old"]),                        // the walk: stale, so a re-ask begins
                                    flagged(["mid"], stale: false),          // its probe: the drain is over
                                    flagged(["new"], stale: false)])         // its re-walk
        let sleeper = SleepRecorder(gateFirst: true)
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { !sleeper.calls.isEmpty }, "the plain re-ask never began waiting")
        XCTAssertEqual(f.refresh(joinReask: true), .joined)
        XCTAssertEqual(f.refresh(joinReask: true), .joined, "asked again on the next tick")
        XCTAssertEqual(script.callCount, 1, "the join read the list")
        sleeper.firstGate.signal()
        XCTAssertTrue(settleUntil { f.drain().replace == [Row(id: "new")] }, "the re-ask's own rows never landed")
        XCTAssertEqual(script.callCount, 3, "one walk for the first read, a probe and ONE walk after the drain")
    }

    /// The re-ask has posted and ended, but the scene has not drained its rows: they
    /// are newer than the list the caller found behind, so the ask joins them. Once
    /// drained, the feed is idle and the same ask reads the list.
    func testAnAutomaticRereadJoinsAReAskThatPostedAndIsNotDrainedYet() {
        let script = ScriptedFetch([flagged(["old"]),
                                    flagged(["mid"], stale: false),
                                    flagged(["new"], stale: false),
                                    flagged(["newer"], stale: false)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.callCount == 3 && script.threadEnded(at: 2) }, "the re-ask never finished")
        XCTAssertEqual(f.refresh(joinReask: true), .joined, "the posted rows are not drained yet")
        XCTAssertEqual(script.callCount, 3)
        XCTAssertEqual(f.drain().replace, [Row(id: "new")])
        XCTAssertEqual(f.refresh(joinReask: true), .started, "nothing left to join")
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(f.drain().replace, [Row(id: "newer")])
    }

    /// The scene's own re-read (`joinReask`) read a list that still said it was
    /// refreshing and is waiting out the rest of the bound. A person's refresh is not
    /// told "already refreshing" behind it: it takes the wait over, the automatic
    /// worker is told at once (`displaced`, not after its bound), and nothing it
    /// does later posts or ends.
    func testAPersonsRefreshTakesOverAnAutomaticRereadWaitingOnAFlaggedList() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil),     // the walk: fresh, idle
                                    flagged(["mid"]),                          // the automatic read: still stale
                                    page(["new"], generation: 1, next: nil)])  // the person's read
        let sleeper = SleepRecorder(gateFirst: true)
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { script.callCount == 1 && script.threadEnded(at: 0) })
        _ = f.drain()
        var autoEnds: [BridgeListFeed<Row>.RefreshEnd] = [], displaced = 0
        XCTAssertEqual(f.refresh(end: { autoEnds.append($0) }, displaced: { displaced += 1 }, joinReask: true), .started)
        XCTAssertTrue(settleUntil { !sleeper.calls.isEmpty }, "the automatic re-read never began waiting")
        XCTAssertEqual(f.refresh(joinReask: true), .alreadyRefreshing, "an automatic ask never takes over, and says nothing")
        XCTAssertEqual(displaced, 0)

        var asked = 0, said = 0
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        let claim = f.refresh(begin: { asked += 1; return nil }, end: { ends.append($0) },
                              alreadyRefreshing: { said += 1 })
        XCTAssertEqual(claim, .tookOver)
        XCTAssertEqual(displaced, 1, "the displaced read was not told at once")
        XCTAssertEqual(said, 0)
        var replaces: [[Row]] = []
        XCTAssertTrue(settleUntil {
            if let r = f.drain().replace { replaces.append(r) }
            return replaces.last == [Row(id: "new")] && !ends.isEmpty
        }, "the person's refresh never landed: \(replaces)")
        XCTAssertEqual(asked, 1, "the person's begin never ran")
        sleeper.firstGate.signal()   // the automatic worker wakes up and finds it was taken over
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5), "a worker never ended")
        XCTAssertEqual(script.callCount, 3, "the displaced worker read after it was taken over")
        XCTAssertNil(f.drain().replace, "the displaced worker posted rows after the takeover")
        XCTAssertTrue(autoEnds.isEmpty, "the displaced worker's ending was delivered")
        XCTAssertEqual(ends, [.listOnly])
        XCTAssertEqual(displaced, 1)
    }

    /// Once a person's refresh has taken it over, a second one is single-flight
    /// again, and an automatic ask is turned away as before.
    func testASecondPersonsRefreshDuringTheirTakeoverIsSingleFlight() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil),
                                    flagged(["mid"]),
                                    page(["new"], generation: 1, next: nil)])   // the person's read, held
        script.gate(at: 2)
        let sleeper = SleepRecorder(gateFirst: true)
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { script.callCount == 1 && script.threadEnded(at: 0) })
        _ = f.drain()
        XCTAssertEqual(f.refresh(joinReask: true), .started)
        XCTAssertTrue(settleUntil { !sleeper.calls.isEmpty })
        XCTAssertEqual(f.refresh(), .tookOver)
        XCTAssertTrue(settleUntil { script.callCount == 3 }, "the person's read never went out")
        var said = 0, began = 0
        XCTAssertEqual(f.refresh(begin: { began += 1; return nil }, alreadyRefreshing: { said += 1 }), .alreadyRefreshing)
        XCTAssertEqual(f.refresh(joinReask: true), .alreadyRefreshing)
        XCTAssertEqual(said, 1)
        XCTAssertEqual(began, 0)
        script.release(at: 2)
        sleeper.firstGate.signal()
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(f.drain().replace, [Row(id: "new")])
        XCTAssertEqual(script.callCount, 3)
    }

    /// With no re-ask to join, the scene's own re-read reads the list as it always did
    /// (a person's `r` never joins at all: `testARefreshTakesOverAPlainReAsk...`).
    func testAnAutomaticRereadStartsAWalkWhenThereIsNoReAsk() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil), page(["a", "b"], generation: 1, next: nil)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.callCount == 1 && script.threadEnded(at: 0) })
        _ = f.drain()
        XCTAssertEqual(f.refresh(joinReask: true), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(f.drain().replace, [Row(id: "a"), Row(id: "b")])
    }

    func testAResetBeforeTheRefreshWorkerStartsRunsNothing() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil), page(["a", "b"], generation: 1, next: nil)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        var began = false
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        f.afterClaimForTest = { f.reset() }
        XCTAssertEqual(f.refresh(begin: { began = true; return nil }, end: { ends.append($0) }), .started)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertFalse(began, "begin ran for a revoked refresh")
        XCTAssertTrue(ends.isEmpty)
        XCTAssertEqual(script.callCount, 1, "a revoked refresh read the list")
        XCTAssertNil(f.drain().replace)
        f.afterClaimForTest = nil
        XCTAssertEqual(f.refresh(), .started, "the revoked refresh left the feed claimed")
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
    }

    func testAResetDuringARefreshDropsItsResult() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: nil),
                                    page(["a", "b"], generation: 1, next: nil)])
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        script.gate(at: 1)
        var ends: [BridgeListFeed<Row>.RefreshEnd] = []
        XCTAssertEqual(f.refresh(end: { ends.append($0) }), .started)
        XCTAssertTrue(settleUntil { script.reachedGateAt1() })
        f.reset()
        script.release(at: 1)
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertNil(f.drain().replace, "a refresh that outlived a reset landed")
        XCTAssertTrue(ends.isEmpty, "a refresh that outlived a reset still spoke: \(ends)")
    }

    func testAFreshReplyIsNeverReAsked() {
        let script = ScriptedFetch([flagged(["a"], stale: false)])
        let sleeper = SleepRecorder()
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done })
        usleep(80_000)   // long enough for a re-ask to have started if one were going to
        XCTAssertEqual(script.callCount, 1)
        XCTAssertTrue(sleeper.calls.isEmpty)
    }

    func testTheReAskStopsAtTheBound() {
        let lock = NSLock()
        var fetches = 0
        let sleeper = SleepRecorder()
        let bounded = reaskFeed({ _, _ in
            lock.lock(); fetches += 1; lock.unlock()
            return self.flagged(["old"])
        }, sleeper)
        let expected = Int(LibraryReask.maxTotalWait / LibraryReask.interval)
        bounded.start()
        XCTAssertTrue(settleUntil(5) { sleeper.calls.count == expected })
        usleep(80_000)
        XCTAssertEqual(sleeper.calls.count, expected, "asked past the bound")
        XCTAssertEqual(sleeper.calls.reduce(0, +), LibraryReask.maxTotalWait)
        lock.lock(); let n = fetches; lock.unlock()
        XCTAssertEqual(n, 1 + expected, "one walk, then one probe per interval")
        XCTAssertGreaterThan(LibraryReask.maxTotalWait, 150 * 2, "must comfortably exceed a ~150 s live refresh")
    }

    func testAResetWhileWaitingDropsTheReAsk() {
        let script = ScriptedFetch([flagged(["old"]), flagged(["new"], stale: false), flagged(["new"], stale: false)])
        let sleeper = SleepRecorder(gateFirst: true)
        let f = reaskFeed(script.fetch, sleeper)
        f.start()
        XCTAssertTrue(settleUntil { !sleeper.calls.isEmpty }, "never reached the re-ask wait")
        f.reset()                          // the provenance switched while it waited
        sleeper.firstGate.signal()
        usleep(80_000)
        XCTAssertEqual(script.callCount, 1, "a re-ask went out after a provenance switch")
        let d = f.drain()
        XCTAssertNil(d.replace)
        XCTAssertTrue(d.append.isEmpty)
    }

    func testAReAskResultThatOutlivedAResetIsDropped() {
        let script = ScriptedFetch([flagged(["old"]), flagged(["new"], stale: false), flagged(["new"], stale: false)])
        script.gate(at: 2)                 // hold the re-walk's page
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.callCount > 2 }, "never reached the re-walk")
        _ = f.drain()
        f.reset()
        script.release(at: 2)
        usleep(80_000)
        let d = f.drain()
        XCTAssertNil(d.replace, "a re-ask result landed after a provenance switch")
        XCTAssertTrue(d.append.isEmpty)
    }

    func testStartWhileAReAskIsInFlightDoesNotStackAnother() {
        let script = ScriptedFetch([flagged(["old"]), flagged(["new"], stale: false), flagged(["new"], stale: false)])
        script.gate(at: 1)                 // hold the first probe
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(settleUntil { script.callCount > 1 }, "never reached the probe")
        f.start()
        f.start()
        usleep(80_000)
        XCTAssertEqual(script.callCount, 2, "a second walk started beside the re-ask")
        script.release(at: 1)
        var last: [Row]? = nil
        XCTAssertTrue(settleUntil {
            if let r = f.drain().replace { last = r }
            return last == [Row(id: "new")]
        })
        XCTAssertEqual(script.callCount, 3)
    }


    // MARK: - The generation and instance a drain carries
    //
    // A cover is asked for under the generation and `library_instance` of the list
    // page its row came from, so the drain says which ones the rows it hands over
    // were read under.

    func testDrainedCarriesThePagesGeneration() {
        let script = ScriptedFetch([page(["a"], generation: 4, next: "c1"),
                                    page(["b"], generation: 4, next: nil)])
        let f = feed(script.fetch)
        XCTAssertNil(f.drain().generation, "nothing has landed yet")
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done == true })
        let after = f.drain()
        XCTAssertEqual(after.generation, 4, "level state: still there once the rows were consumed")

        let single = ScriptedFetch([page(["a"], generation: 9, next: nil)])
        let g = feed(single.fetch)
        g.start()
        XCTAssertTrue(g.waitForWorkersForTest(timeout: 5))
        let d = g.drain()
        XCTAssertEqual(d.replace, [Row(id: "a")])
        XCTAssertEqual(d.generation, 9)
    }

    func testARestartClearsTheGenerationUntilTheNewFirstPage() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1"),
                                    page(["b"], generation: 2, next: "c2"),
                                    page(["z"], generation: 3, next: nil)])
        script.gate(at: 2)   // the restarted attempt's first page
        let f = feed(script.fetch)
        f.start()
        XCTAssertTrue(settleUntil { script.callCount >= 3 }, "the walk never restarted")
        let between = f.drain()
        XCTAssertNil(between.replace)
        XCTAssertNil(between.generation, "generation 1 described rows the restart discarded")
        script.release(at: 2)
        var generation: Int?
        XCTAssertTrue(settleUntil { let d = f.drain(); generation = d.generation; return d.done })
        XCTAssertEqual(generation, 3)
    }

    func testAReaskReplacementCarriesItsGeneration() {
        func stalePage(_ ids: [String], generation: Int, stale: Bool) -> MusicPage {
            MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                      nextCursor: nil, total: ids.count, generation: generation, stale: stale)
        }
        let script = ScriptedFetch([stalePage(["old"], generation: 5, stale: true),    // initial walk
                                    stalePage(["new"], generation: 6, stale: false),   // probe
                                    stalePage(["new"], generation: 6, stale: false)])  // the re-walk
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        let d = f.drain()
        XCTAssertTrue(d.reasked)
        XCTAssertEqual(d.replace, [Row(id: "new")])
        XCTAssertEqual(d.generation, 6, "the replacement's own generation, not the walk's")
    }

    func testDrainedCarriesThePagesLibraryInstance() {
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1", instance: "inst-A"),
                                    page(["b"], generation: 1, next: nil, instance: "inst-A")])
        let f = feed(script.fetch)
        XCTAssertNil(f.drain().libraryInstance)
        f.start()
        XCTAssertTrue(settleUntil { f.drain().done == true })
        XCTAssertEqual(f.drain().libraryInstance, "inst-A", "level state, like listRev")

        let none = ScriptedFetch([page(["a"], generation: 1, next: nil)])
        let g = feed(none.fetch)
        g.start()
        XCTAssertTrue(g.waitForWorkersForTest(timeout: 5))
        XCTAssertNil(g.drain().libraryInstance, "a SpanDAC that sends none leaves it nil")
    }

    func testPagesThatDisagreeOnTheInstanceLeaveItNil() {
        for (first, second) in [("inst-A", "inst-B"), ("inst-A", nil), (nil, "inst-A")] as [(String?, String?)] {
            let script = ScriptedFetch([page(["a"], generation: 1, next: "c1", instance: first),
                                        page(["b"], generation: 1, next: nil, instance: second)])
            let f = feed(script.fetch)
            f.start()
            XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
            let d = f.drain()
            XCTAssertEqual(d.replace, [Row(id: "a")], "the rows still land")
            XCTAssertEqual(d.append, [Row(id: "b")])
            XCTAssertNil(d.libraryInstance, "\(String(describing: first)) then \(String(describing: second))")
        }
        // A third page that agrees with the first does not undo the disagreement.
        let script = ScriptedFetch([page(["a"], generation: 1, next: "c1", instance: "inst-A"),
                                    page(["b"], generation: 1, next: "c2", instance: "inst-B"),
                                    page(["c"], generation: 1, next: nil, instance: "inst-A")])
        let f = feed(script.fetch)
        f.start()
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        XCTAssertNil(f.drain().libraryInstance)
    }

    func testAReaskUnderANewInstanceCarriesTheNewInstance() {
        func instancePage(_ ids: [String], instance: String, stale: Bool) -> MusicPage {
            MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                      nextCursor: nil, total: ids.count, generation: 1, stale: stale, libraryInstance: instance)
        }
        let script = ScriptedFetch([instancePage(["old"], instance: "inst-A", stale: true),   // initial walk
                                    instancePage(["new"], instance: "inst-B", stale: false),  // probe
                                    instancePage(["new"], instance: "inst-B", stale: false)]) // the re-walk
        let f = reaskFeed(script.fetch, SleepRecorder())
        f.start()
        XCTAssertTrue(f.waitForWorkersForTest(timeout: 5))
        let d = f.drain()
        XCTAssertTrue(d.reasked)
        XCTAssertEqual(d.libraryInstance, "inst-B", "SpanDAC restarted between the walk and the re-walk")
    }
}

private extension BridgeListFeedTests.ScriptedFetch {
    // Small helpers so the reset/start tests can wait for a specific gate to
    // have been reached without re-deriving the index from context each time.
    func reachedGateAt1() -> Bool { callCount > 1 }
    func reachedGateAt0() -> Bool { callCount > 0 }
}

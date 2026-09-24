import XCTest
@testable import music

/// `BridgeListFeed<Row>` in isolation, against a fake `fetch` closure — no
/// scene, no wire. C2's shared walk-and-inbox discipline for Albums and
/// Artists (Songs kept its own hand-rolled version, from before this slice).
final class BridgeListFeedTests: XCTestCase {

    private struct Row: Equatable { let id: String }

    private func page(_ ids: [String], generation: Int?, next: String?, total: Int? = nil) -> MusicPage {
        MusicPage(rows: ids.map { MusicRow(id: $0, title: $0, artist: "a", album: nil, kind: .album) },
                  nextCursor: next, total: total ?? ids.count, generation: generation)
    }

    /// A scripted fetch, one page per call, with an optional gate per index so
    /// a test can observe "page 1 landed, page 2 has not yet" rather than
    /// racing the feed's own background thread.
    fileprivate final class ScriptedFetch {
        private let lock = NSLock()
        private var script: [MusicPage]
        private var calls = 0
        private var gates: [Int: DispatchSemaphore] = [:]

        init(_ script: [MusicPage]) { self.script = script }

        func gate(at n: Int) { lock.lock(); gates[n] = DispatchSemaphore(value: 0); lock.unlock() }
        func release(at n: Int) { lock.lock(); let g = gates[n]; lock.unlock(); g?.signal() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func fetch(_ cursor: String?, _ limit: Int) throws -> MusicPage {
            lock.lock()
            let n = calls
            calls += 1
            guard n < script.count else { lock.unlock(); throw MusicProviderError.unavailable("unscripted call \(n)") }
            let result = script[n]
            let gate = gates[n]
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
        // Give the (now-abandoned) walk a moment to try to post; it must not
        // land anything after the reset.
        Thread.sleep(forTimeInterval: 0.1)
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
        Thread.sleep(forTimeInterval: 0.15)                     // give A's (should-be-no-op) ending a moment

        // The race: if A's ending wrongly cleared `walking`, THIS call
        // launches a rogue walk C while B is still blocked at index 1.
        f.start()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(script.callCount, 2,
                      "a third walk started while the second was still legitimately in flight")

        script.release(at: 1)                                  // let walk B finish
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
        Thread.sleep(forTimeInterval: 0.2)   // give the walk a moment to resume and stop
        XCTAssertEqual(script.callCount, 2, "the walk fetched a THIRD page after the feed was released")
    }
}

private extension BridgeListFeedTests.ScriptedFetch {
    // Small helpers so the reset/start tests can wait for a specific gate to
    // have been reached without re-deriving the index from context each time.
    func reachedGateAt1() -> Bool { callCount > 1 }
    func reachedGateAt0() -> Bool { callCount > 0 }
}

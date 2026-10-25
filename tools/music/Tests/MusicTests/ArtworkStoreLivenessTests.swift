// tools/music/Tests/MusicTests/ArtworkStoreLivenessTests.swift
import XCTest
@testable import music

/// Two review blockers on the 2026-10-25 scheduler:
/// 1. Liveness without paints: a retry deadline or a stale-slot deadline must be
///    acted on by `pump()` (which scene ticks call), not only by a later render
///    ask, because `ShellRenderGate` now suppresses idle repaints.
/// 2. Physical capacity: a cancelled job keeps its slot (and its key) until its
///    body has actually returned, so the pool bounds running work, not
///    bookkeeping.
/// Every fetch and render is an injected fake, time is an injected clock, stalls
/// are semaphores the test releases. The only timed waits are expectations
/// (positive: fail on timeout) and short inverted expectations that prove an
/// over-limit start did NOT happen; neither sleeps and then asserts.
final class ArtworkStoreLivenessTests: XCTestCase {

    final class Clock {
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ by: TimeInterval) { lock.lock(); t += by; lock.unlock() }
    }

    /// Thread-safe call log plus concurrency high-water marks.
    final class Meter {
        private let lock = NSLock()
        private var urls: [String] = []
        private var active = 0
        private var activeByKey: [String: Int] = [:]
        private(set) var peakStorage = 0
        private var peakByKeyStorage: [String: Int] = [:]
        func add(_ u: String) { lock.lock(); urls.append(u); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
        var count: Int { all.count }
        func enter(_ key: String) {
            lock.lock()
            active += 1; peakStorage = max(peakStorage, active)
            activeByKey[key, default: 0] += 1
            peakByKeyStorage[key] = max(peakByKeyStorage[key] ?? 0, activeByKey[key]!)
            lock.unlock()
        }
        func leave(_ key: String) {
            lock.lock(); active -= 1; activeByKey[key, default: 0] -= 1; lock.unlock()
        }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return peakStorage }
        func peak(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return peakByKeyStorage[key] ?? 0 }
    }

    private var dirs: [String] = []
    private func tmpDir() -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-live-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs = []
        super.tearDown()
    }

    // MARK: - Blocker 1: liveness with no further ask

    /// The reviewer's harness: one ask, a temporary failure, then nothing but
    /// `pump()` (the scene tick) while fake time passes 31 s against a 10 s
    /// cooldown. The cover must be fetched again and land with no render call.
    func testPumpRetriesTheWantedCoverAfterItsCooldownWithNoFurtherAsk() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Meter()
        let readyCount = Meter()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in
                                     calls.add(url)
                                     return calls.count == 1 ? .temporary : .data(Data([1, 2]))
                                 },
                                 render: { _, _, _ in ["ART"] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "t", url: "t", width: 8, height: 4) { readyCount.add("ready") })
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1)

        // Ticks inside the cooldown fetch nothing.
        for _ in 0..<20 { clock.advance(0.25); store.pump() }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1, "no fetch inside the cooldown")

        // 31 s idle in all: the deadline passes and a tick alone recovers it.
        for _ in 0..<104 { clock.advance(0.25); store.pump() }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 2, "the deadline re-issued the wanted cover")
        XCTAssertEqual(readyCount.count, 1, "onReady fired, so the scene's tick reports a change")
        XCTAssertEqual(store.lines(key: "t", url: "t", width: 8, height: 4) { }, ["ART"])

        // Satisfied demand is not retried again.
        for _ in 0..<200 { clock.advance(1); store.pump() }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 2)
    }

    /// A dead CDN under pump-only liveness still walks the cooldown ladder
    /// (attempts at 0, 10, 30, 70 s inside two minutes), never once per tick.
    func testPumpRetriesFollowTheBackoffLadder() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Meter()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return .temporary },
                                 render: { _, _, _ in XCTFail("nothing to render"); return [] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "dead", url: "dead", width: 8, height: 4) { })
        for _ in 0..<480 {   // 120 s of 4 Hz ticks, no further asks
            store.waitUntilIdleForTesting()
            clock.advance(0.25)
            store.pump()
        }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 4)
    }

    /// A permanent failure and dropped demand are never pumped.
    func testPumpLeavesPermanentFailuresAndDroppedDemandAlone() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Meter()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return url == "p" ? .permanent : .temporary },
                                 render: { _, _, _ in [] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "p", url: "p", width: 8, height: 4) { })
        store.waitUntilIdleForTesting()
        for _ in 0..<100 { clock.advance(1); store.pump() }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.all, ["p"])

        // Focus moved to a row with no cover: the scene drops demand.
        XCTAssertNil(store.lines(key: "t", url: "t", width: 8, height: 4) { })
        store.waitUntilIdleForTesting()
        store.dropDemand()
        for _ in 0..<100 { clock.advance(1); store.pump() }
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.all, ["p", "t"], "a cover nobody shows is not retried")
    }

    /// Both slots busy with covers asked for 1 s ago; the current cover is
    /// queued behind them (nothing is stale yet). When the 2 s stale deadline
    /// arrives, a tick alone must cancel a stale job and start the queued cover.
    func testPumpReconsidersAPendingCoverWhenTheStaleDeadlineArrives() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Meter()
        let releaseA = DispatchSemaphore(value: 0), releaseB = DispatchSemaphore(value: 0)
        defer { releaseA.signal(); releaseB.signal() }
        let started = expectation(description: "a and b fetching")
        started.expectedFulfillmentCount = 2
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, token in
                                     calls.add(url)
                                     switch url {
                                     case "a", "b":
                                         let gate = url == "a" ? releaseA : releaseB
                                         token.onCancel { gate.signal() }
                                         started.fulfill()
                                         gate.wait()
                                         return .temporary
                                     default:
                                         return .data(Data([1]))
                                     }
                                 },
                                 render: { _, _, _ in ["ART"] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "a", url: "a", width: 8, height: 4) { })
        XCTAssertNil(store.lines(key: "b", url: "b", width: 8, height: 4) { })
        wait(for: [started], timeout: 5)
        clock.advance(1)
        let cReady = expectation(description: "c rendered")
        XCTAssertNil(store.lines(key: "c", url: "c", width: 8, height: 4) { cReady.fulfill() })
        XCTAssertFalse(calls.all.contains("c"), "nothing is stale yet, so c waits")

        clock.advance(1.5)   // a and b are now 2.5 s unasked
        store.pump()         // the tick; no lines()/block() call
        wait(for: [cReady], timeout: 5)
        XCTAssertEqual(calls.all.filter { $0 == "c" }.count, 1)
        XCTAssertEqual(store.lines(key: "c", url: "c", width: 8, height: 4) { }, ["ART"])
    }

    // MARK: - Blocker 2: physical capacity

    /// The reviewer's repro: two slots, bytes immediately, both renders held.
    /// Asking for C and then D after 3 s must not start a third or fourth
    /// render while A and B are still physically running.
    func testCancelledRendersKeepTheirSlotsUntilTheyReturn() {
        let dir = tmpDir()
        let clock = Clock()
        let renders = Meter()
        let holds = ["a": DispatchSemaphore(value: 0), "b": DispatchSemaphore(value: 0)]
        defer { holds.values.forEach { $0.signal() } }
        let heldStarted = expectation(description: "a and b rendering")
        heldStarted.expectedFulfillmentCount = 2
        let overLimit = expectation(description: "a render started beyond the limit")
        overLimit.isInverted = true
        overLimit.assertForOverFulfill = false
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { _, _ in .data(Data([1])) },
                                 render: { path, _, _ in
                                     let k = URL(fileURLWithPath: path).lastPathComponent
                                     renders.enter("all")
                                     defer { renders.leave("all") }
                                     renders.add(k)
                                     if renders.peak > 2 { overLimit.fulfill() }
                                     if let h = holds[k] { heldStarted.fulfill(); h.wait() }
                                     return [k]
                                 },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "a", url: "a", width: 8, height: 4) { })
        XCTAssertNil(store.lines(key: "b", url: "b", width: 8, height: 4) { })
        wait(for: [heldStarted], timeout: 5)
        clock.advance(3)
        let cReady = expectation(description: "c"), dReady = expectation(description: "d")
        XCTAssertNil(store.lines(key: "c", url: "c", width: 8, height: 4) { cReady.fulfill() })
        XCTAssertNil(store.lines(key: "d", url: "d", width: 8, height: 4) { dReady.fulfill() })
        wait(for: [overLimit], timeout: 0.5)

        // Free exactly one physical slot (b stays held): the newest waiting
        // cover takes it, and the other runs only once that slot frees again.
        holds["a"]!.signal()
        wait(for: [dReady, cReady], timeout: 5, enforceOrder: true)
        XCTAssertEqual(Array(renders.all.dropFirst(2)), ["d", "c"], "newest first, one at a time beside the held render")
        holds["b"]!.signal()
        store.waitUntilIdleForTesting()
        XCTAssertLessThanOrEqual(renders.peak, 2, "physical render peak must stay within maxConcurrent")
    }

    /// One slot. A stale fetch is cancelled for new art, sees the cancellation
    /// asynchronously, and keeps running a while after it. Until it returns,
    /// neither the new art nor another size of the SAME key may start: the slot
    /// and the per-key exclusivity are held until physical retirement, not until
    /// the cancellation is noticed.
    func testCancelledFetchHoldsItsSlotAndKeyUntilItReturns() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Meter()
        let inFlight = Meter()
        let retire = DispatchSemaphore(value: 0)
        defer { retire.signal() }
        let sawCancel = expectation(description: "first a fetch observed its cancellation")
        let overLimit = expectation(description: "a fetch started while the cancelled one ran")
        overLimit.isInverted = true
        overLimit.assertForOverFulfill = false
        var limits = ArtworkStore.Limits.default
        limits.maxConcurrent = 1
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, token in
                                     calls.add(url)
                                     inFlight.enter(url)
                                     defer { inFlight.leave(url) }
                                     if inFlight.peak > 1 { overLimit.fulfill() }
                                     if calls.count == 1 {
                                         let cancelled = DispatchSemaphore(value: 0)
                                         token.onCancel { DispatchQueue.global().async { cancelled.signal() } }
                                         cancelled.wait()
                                         sawCancel.fulfill()
                                         retire.wait()   // still running after the cancel landed
                                         return .temporary
                                     }
                                     return .data(Data([1]))
                                 },
                                 render: { path, w, _ in ["\(URL(fileURLWithPath: path).lastPathComponent)@\(w)"] },
                                 now: clock.now, limits: limits)
        XCTAssertNil(store.lines(key: "a", url: "a", width: 8, height: 4) { })
        clock.advance(3)
        let bReady = expectation(description: "b"), a9Ready = expectation(description: "a at 9 wide")
        XCTAssertNil(store.lines(key: "b", url: "b", width: 8, height: 4) { bReady.fulfill() })
        wait(for: [sawCancel], timeout: 5)
        XCTAssertNil(store.lines(key: "a", url: "a", width: 9, height: 4) { a9Ready.fulfill() })
        wait(for: [overLimit], timeout: 0.5)

        retire.signal()
        wait(for: [a9Ready, bReady], timeout: 5)
        store.waitUntilIdleForTesting()
        XCTAssertLessThanOrEqual(inFlight.peak, 1, "physical fetch peak must stay within maxConcurrent")
        XCTAssertLessThanOrEqual(inFlight.peak("a"), 1, "one fetch per key until physical retirement")
        XCTAssertEqual(calls.all, ["a", "a", "b"], "newest first after the cancelled fetch retired")
        XCTAssertEqual(store.lines(key: "a", url: "a", width: 9, height: 4) { }, ["a@9"])
        XCTAssertEqual(store.lines(key: "b", url: "b", width: 8, height: 4) { }, ["b@8"])
    }
}

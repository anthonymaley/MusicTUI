// tools/music/Tests/MusicTests/ArtworkStoreSchedulingTests.swift
import XCTest
@testable import music

/// Scheduling, failure classification and memory bounds of `ArtworkStore`.
/// Every fetch is an injected fake (no network), every render is injected (no
/// chafa), time is an injected clock, and stalls are semaphores the test
/// releases — nothing here sleeps and then asserts.
final class ArtworkStoreSchedulingTests: XCTestCase {

    private final class Clock {
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ by: TimeInterval) { lock.lock(); t += by; lock.unlock() }
    }

    /// Thread-safe record of which URLs the fetcher was called with, in order.
    private final class Calls {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ u: String) { lock.lock(); urls.append(u); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
        var count: Int { all.count }
    }

    private var dirs: [String] = []
    private func tmpDir() -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-sched-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs = []
        super.tearDown()
    }

    // MARK: - A stalled old download never blocks newly focused art

    /// Through the legacy `fetch:` seam (the one the store has always had): a
    /// fetch for the old cover that never returns must not stop the new cover
    /// from being fetched and rendered. On the old serial queue the new
    /// request waited behind the stall forever.
    func testStalledFetchForOldArtDoesNotBlockNewArt() {
        let dir = tmpDir()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }   // release the stalled worker at the end
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { url in
                                     if url == "old" { gate.wait() }
                                     return Data([1, 2, 3])
                                 },
                                 render: { path, _, _ in [URL(fileURLWithPath: path).lastPathComponent] })
        XCTAssertNil(store.lines(key: "old", url: "old", width: 8, height: 4) { })
        let ready = expectation(description: "new art rendered")
        XCTAssertNil(store.lines(key: "new", url: "new", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(store.lines(key: "new", url: "new", width: 8, height: 4) { }, ["new"])
    }

    /// With a single slot, a stalled fetch for art nobody has asked for since
    /// (older than `staleAfter`) is cancelled when new art needs the slot. The
    /// cancelled fetch records no failure: asking for the old art again
    /// fetches it again.
    func testSingleSlotCancelsAStaleInFlightFetchForNewArt() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Calls()
        let oldReleased = expectation(description: "old fetch observed its cancellation")
        var limits = ArtworkStore.Limits.default
        limits.maxConcurrent = 1
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, token in
                                     calls.add(url)
                                     if url == "old", calls.all.filter({ $0 == "old" }).count == 1 {
                                         let gate = DispatchSemaphore(value: 0)
                                         token.onCancel { gate.signal() }
                                         gate.wait()
                                         oldReleased.fulfill()
                                         return .temporary
                                     }
                                     return .data(Data([1]))
                                 },
                                 render: { path, _, _ in [URL(fileURLWithPath: path).lastPathComponent] },
                                 now: clock.now, limits: limits)
        XCTAssertNil(store.lines(key: "old", url: "old", width: 8, height: 4) { })
        clock.advance(limits.staleAfter + 0.5)
        let ready = expectation(description: "new art rendered")
        XCTAssertNil(store.lines(key: "new", url: "new", width: 8, height: 4) { ready.fulfill() })
        wait(for: [oldReleased, ready], timeout: 5)
        XCTAssertEqual(store.lines(key: "new", url: "new", width: 8, height: 4) { }, ["new"])

        // Cancelled, not failed: no cooldown, no negative cache.
        store.waitUntilIdleForTesting()
        let oldReady = expectation(description: "old art rendered on a later request")
        XCTAssertNil(store.lines(key: "old", url: "old", width: 8, height: 4) { oldReady.fulfill() })
        wait(for: [oldReady], timeout: 5)
        XCTAssertEqual(calls.all.filter { $0 == "old" }.count, 2)
    }

    // MARK: - Obsolete queued work is discarded before it starts

    func testObsoleteQueuedRequestsNeverCallTheFetcher() {
        let dir = tmpDir()
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "first fetch started")
        var limits = ArtworkStore.Limits.default
        limits.maxConcurrent = 1
        limits.maxPending = 2
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in
                                     calls.add(url)
                                     if url == "a" { started.fulfill(); gate.wait() }
                                     return .data(Data([1]))
                                 },
                                 render: { _, _, _ in ["ART"] },
                                 now: { 0 }, limits: limits)
        XCTAssertNil(store.lines(key: "a", url: "a", width: 8, height: 4) { })
        wait(for: [started], timeout: 5)
        // Scrolled past b and c; d and e are the latest two asks.
        for k in ["b", "c", "d", "e"] {
            XCTAssertNil(store.lines(key: k, url: k, width: 8, height: 4) { })
        }
        gate.signal()
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.all, ["a", "e", "d"], "newest first; b and c dropped unfetched")
        XCTAssertEqual(store.lines(key: "e", url: "e", width: 8, height: 4) { }, ["ART"])
        XCTAssertEqual(store.lines(key: "d", url: "d", width: 8, height: 4) { }, ["ART"])

        // A dropped request is not a failure: asking again fetches it.
        XCTAssertNil(store.lines(key: "b", url: "b", width: 8, height: 4) { })
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.all, ["a", "e", "d", "b"])
    }

    // MARK: - Temporary failures retry after a cooldown; permanent ones do not

    func testTransientFailureIsRetriedAfterItsCooldownAndSucceeds() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Calls()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in
                                     calls.add(url)
                                     return calls.count == 1 ? .temporary : .data(Data([1, 2]))
                                 },
                                 render: { _, _, _ in ["ART"] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "t", url: "t", width: 8, height: 4) { XCTFail("first attempt fails") })
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1)

        // Inside the cooldown: no fetch.
        clock.advance(ArtworkStore.Limits.default.retryBase - 1)
        XCTAssertNil(store.lines(key: "t", url: "t", width: 8, height: 4) { XCTFail("cooling down") })
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1)

        // Past it: retried, and it lands without a restart.
        clock.advance(2)
        let ready = expectation(description: "retry rendered")
        XCTAssertNil(store.lines(key: "t", url: "t", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(store.lines(key: "t", url: "t", width: 8, height: 4) { }, ["ART"])
        XCTAssertEqual(calls.count, 2)
    }

    func testTransientFailureOnTheKittyPathIsAlsoRetried() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Calls()
        guard let png = Self.tinyPNG() else { return XCTFail("fixture") }
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in
                                     calls.add(url)
                                     return calls.count == 1 ? .temporary : .data(png)
                                 },
                                 render: { _, _, _ in [] },
                                 now: clock.now)
        XCTAssertNil(store.block(key: "k", url: "k", width: 8, height: 4, kitty: true) { })
        store.waitUntilIdleForTesting()
        clock.advance(ArtworkStore.Limits.default.retryBase + 1)
        let ready = expectation(description: "kitty retry ready")
        XCTAssertNil(store.block(key: "k", url: "k", width: 8, height: 4, kitty: true) { ready.fulfill() })
        wait(for: [ready], timeout: 5)
        guard case .kitty(_, let transmit)? = store.block(key: "k", url: "k", width: 8, height: 4, kitty: true, onReady: {}) else {
            return XCTFail("expected .kitty")
        }
        XCTAssertNotNil(transmit)
    }

    /// A caller repaints every tick and asks every tick; a dead CDN must cost
    /// a handful of fetches, not one per frame. Backoff doubles from
    /// `retryBase` (10 s): attempts at 0, 10, 30, 70 s inside two minutes.
    func testRepeatedTransientFailuresBackOffInsteadOfHammering() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Calls()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return .temporary },
                                 render: { _, _, _ in XCTFail("nothing to render"); return [] },
                                 now: clock.now)
        for _ in 0..<480 {   // 120 s of 4 Hz repaints
            XCTAssertNil(store.lines(key: "dead", url: "dead", width: 8, height: 4) { XCTFail("never ready") })
            store.waitUntilIdleForTesting()
            clock.advance(0.25)
        }
        XCTAssertEqual(calls.count, 4)
    }

    func testBackoffIsCapped() {
        var limits = ArtworkStore.Limits.default
        limits.retryBase = 10; limits.retryCap = 300
        XCTAssertEqual(limits.backoff(afterFailures: 1), 10)
        XCTAssertEqual(limits.backoff(afterFailures: 2), 20)
        XCTAssertEqual(limits.backoff(afterFailures: 5), 160)
        XCTAssertEqual(limits.backoff(afterFailures: 6), 300)
        XCTAssertEqual(limits.backoff(afterFailures: 60), 300)
    }

    func testPermanentFailureStaysNegativeForTheSession() {
        let dir = tmpDir()
        let clock = Clock()
        let calls = Calls()
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in calls.add(url); return .permanent },
                                 render: { _, _, _ in XCTFail("nothing to render"); return [] },
                                 now: clock.now)
        XCTAssertNil(store.lines(key: "p", url: "p", width: 8, height: 4) { })
        store.waitUntilIdleForTesting()
        clock.advance(24 * 3600)
        XCTAssertNil(store.lines(key: "p", url: "p", width: 8, height: 4) { })
        XCTAssertNil(store.block(key: "p", url: "p", width: 8, height: 4, kitty: true) { })
        store.waitUntilIdleForTesting()
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Classifying a real response (pure; no request is made)

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/a.jpg")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testClassifyOutcomes() {
        let bytes = Data([1, 2, 3])
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(200), error: nil), .data(bytes))
        XCTAssertEqual(ArtworkStore.classify(data: Data(), response: http(200), error: nil), .permanent)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(404), error: nil), .permanent)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(410), error: nil), .permanent)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(500), error: nil), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(503), error: nil), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(429), error: nil), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: bytes, response: http(408), error: nil), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: nil, response: nil, error: URLError(.timedOut)), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: nil, response: nil, error: URLError(.notConnectedToInternet)), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: nil, response: nil, error: URLError(.networkConnectionLost)), .temporary)
        XCTAssertEqual(ArtworkStore.classify(data: nil, response: nil, error: URLError(.badURL)), .permanent)
        XCTAssertEqual(ArtworkStore.classify(data: nil, response: nil, error: URLError(.unsupportedURL)), .permanent)
    }

    /// The deadline is real: the dedicated session has a total-resource bound,
    /// not URLSession's 7-day default that `Data(contentsOf:)` lived under.
    func testNetworkSessionHasABoundedDeadline() {
        let config = ArtworkStore.networkSession.configuration
        XCTAssertEqual(config.timeoutIntervalForRequest, ArtworkStore.requestTimeout)
        XCTAssertEqual(config.timeoutIntervalForResource, ArtworkStore.resourceTimeout)
        XCTAssertLessThanOrEqual(ArtworkStore.resourceTimeout, 20)
    }

    // MARK: - Memory caches are byte-bounded LRU

    func testByteLRUEvictsLeastRecentlyUsedBeyondBudget() {
        let lru = ByteBoundedLRU<String>(budget: 10) { $0.utf8.count }
        lru.set("a", "AAAA")
        lru.set("b", "BBBB")
        XCTAssertEqual(lru.get("a"), "AAAA")      // a is now most recent
        lru.set("c", "CCCC")                      // 12 > 10: evict b, the LRU
        XCTAssertNil(lru.get("b"))
        XCTAssertEqual(lru.get("a"), "AAAA")
        XCTAssertEqual(lru.get("c"), "CCCC")
        XCTAssertEqual(lru.totalBytes, 8)
    }

    func testByteLRUKeepsASingleOversizeEntryRatherThanThrashing() {
        let lru = ByteBoundedLRU<String>(budget: 4) { $0.utf8.count }
        lru.set("a", "AA")
        lru.set("big", "BIGBIGBIG")
        XCTAssertNil(lru.get("a"))
        XCTAssertEqual(lru.get("big"), "BIGBIGBIG", "the newest entry survives even over budget")
    }

    func testByteLRUReplacingAKeyUpdatesItsCost() {
        let lru = ByteBoundedLRU<String>(budget: 10) { $0.utf8.count }
        lru.set("a", "AAAA")
        lru.set("a", "AAAAAAAA")
        XCTAssertEqual(lru.totalBytes, 8)
        lru.set("b", "BB")
        XCTAssertEqual(lru.totalBytes, 10)
        XCTAssertEqual(lru.get("a"), "AAAAAAAA")
    }

    func testRenderedLinesCacheEvictsLRUBeyondItsBudget() {
        let dir = tmpDir()
        let renders = Calls()
        var limits = ArtworkStore.Limits.default
        limits.renderedBytes = 10
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { _, _ in .data(Data([1])) },
                                 render: { path, _, _ in
                                     renders.add(path)
                                     return [URL(fileURLWithPath: path).lastPathComponent + "xxx"]   // 4 bytes
                                 },
                                 now: { 0 }, limits: limits)
        func load(_ k: String) {
            let e = expectation(description: k)
            XCTAssertNil(store.lines(key: k, url: k, width: 8, height: 4) { e.fulfill() })
            wait(for: [e], timeout: 5)
        }
        load("a"); load("b")
        XCTAssertEqual(store.lines(key: "a", url: "a", width: 8, height: 4) { }, ["axxx"])  // touch a
        load("c")                                                                            // evicts b
        XCTAssertEqual(store.lines(key: "a", url: "a", width: 8, height: 4) { }, ["axxx"])
        XCTAssertEqual(store.lines(key: "c", url: "c", width: 8, height: 4) { }, ["cxxx"])
        XCTAssertNil(store.lines(key: "b", url: "b", width: 8, height: 4) { }, "b was evicted; a re-render is kicked")
        store.waitUntilIdleForTesting()
        XCTAssertEqual(renders.count, 4, "b re-rendered from disk once")
    }

    func testKittyEscapeCacheEvictsLRUBeyondItsBudget() {
        let dir = tmpDir()
        let fetches = Calls()
        guard let png = Self.tinyPNG() else { return XCTFail("fixture") }
        var limits = ArtworkStore.Limits.default
        limits.kittyBytes = 1   // only the newest escape fits
        let store = ArtworkStore(cacheDir: dir,
                                 fetcher: { url, _ in fetches.add(url); return .data(png) },
                                 render: { _, _, _ in [] },
                                 now: { 0 }, limits: limits)
        func load(_ k: String) {
            let e = expectation(description: k)
            XCTAssertNil(store.block(key: k, url: k, width: 8, height: 4, kitty: true) { e.fulfill() })
            wait(for: [e], timeout: 5)
        }
        load("a"); load("b")
        guard case .kitty(_, let t)? = store.block(key: "b", url: "b", width: 8, height: 4, kitty: true, onReady: {}) else {
            return XCTFail("newest escape kept")
        }
        XCTAssertNotNil(t)
        XCTAssertNil(store.block(key: "a", url: "a", width: 8, height: 4, kitty: true) { }, "a's escape was evicted")
        store.waitUntilIdleForTesting()
        XCTAssertEqual(fetches.all, ["a", "b"], "re-conversion reads the disk cache, never the network")
    }

    // MARK: - fixtures

    static func tinyPNG() -> Data? {
        // 1x1 opaque PNG.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
    }
}

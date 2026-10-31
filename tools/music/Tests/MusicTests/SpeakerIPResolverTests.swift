// tools/music/Tests/MusicTests/SpeakerIPResolverTests.swift
import XCTest
@testable import music

final class SpeakerIPResolverTests: XCTestCase {
    // MARK: - raceToFirstNonNil

    func testRaceEmptyProducerListIsNil() {
        XCTAssertNil(BonjourSpeakerResolver.raceToFirstNonNil([], timeout: 1))
    }

    func testRaceReturnsNilWhenAllProducersEmpty() {
        let r = BonjourSpeakerResolver.raceToFirstNonNil([{ nil }, { nil }, { nil }], timeout: 1)
        XCTAssertNil(r)
    }

    func testRaceReturnsTheNonNilProducer() {
        let r = BonjourSpeakerResolver.raceToFirstNonNil([{ nil }, { "10.0.0.5" }, { nil }], timeout: 1)
        XCTAssertEqual(r, "10.0.0.5")
    }

    // The whole point of the change: a fast winner must not block on a slow
    // loser. Before concurrency, a dead `.local` candidate delayed the browse.
    func testRaceDoesNotWaitForASlowLoser() {
        let start = Date()
        let r = BonjourSpeakerResolver.raceToFirstNonNil([
            { Thread.sleep(forTimeInterval: 3); return "slow" },
            { "fast" },
        ], timeout: 5)
        XCTAssertEqual(r, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testRaceHonorsOverallTimeout() {
        let start = Date()
        let r = BonjourSpeakerResolver.raceToFirstNonNil([
            { Thread.sleep(forTimeInterval: 3); return "too-late" },
        ], timeout: 0.2)
        XCTAssertNil(r)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - CachingSpeakerResolver

    /// Counts inner resolves so cache hits are observable.
    private final class CountingResolver: SpeakerIPResolving {
        let ip: String?
        let calls = LockedBox<Int>(0)
        init(ip: String?) { self.ip = ip }
        func resolveIP(forSpeaker name: String) -> String? {
            calls.set(calls.get() + 1)
            return ip
        }
    }

    private func tempCache() -> (ResultCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-test-\(UUID().uuidString)")
        return (ResultCache(directory: dir.path), dir)
    }

    func testCachingResolverHitsDiskOnSecondCallAcrossInstances() {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counting = CountingResolver(ip: "10.0.0.9")

        let first = CachingSpeakerResolver(inner: counting, cache: cache).resolveIP(forSpeaker: "Kitchen")
        XCTAssertEqual(first, "10.0.0.9")
        XCTAssertEqual(counting.calls.get(), 1)

        // A brand-new decorator (like a fresh CLI process) must hit the on-disk
        // cache and NOT touch the inner resolver again.
        let second = CachingSpeakerResolver(inner: counting, cache: cache).resolveIP(forSpeaker: "Kitchen")
        XCTAssertEqual(second, "10.0.0.9")
        XCTAssertEqual(counting.calls.get(), 1, "second resolve should be served from cache")
    }

    func testCachingResolverExpiredTTLConsultsInnerAgain() {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counting = CountingResolver(ip: "10.0.0.9")

        _ = CachingSpeakerResolver(inner: counting, cache: cache).resolveIP(forSpeaker: "Kitchen")
        XCTAssertEqual(counting.calls.get(), 1)
        // ttl 0 → the cached entry is stale immediately → inner is consulted.
        _ = CachingSpeakerResolver(inner: counting, cache: cache, ttl: 0).resolveIP(forSpeaker: "Kitchen")
        XCTAssertEqual(counting.calls.get(), 2)
    }

    func testCachingResolverDoesNotMemoizeAMiss() {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counting = CountingResolver(ip: nil)  // resolver can't find it

        XCTAssertNil(CachingSpeakerResolver(inner: counting, cache: cache).resolveIP(forSpeaker: "Ghost"))
        // A miss must not be cached — nothing to serve, so inner runs again.
        XCTAssertNil(CachingSpeakerResolver(inner: counting, cache: cache).resolveIP(forSpeaker: "Ghost"))
        XCTAssertEqual(counting.calls.get(), 2)
    }
}

// tools/music/Tests/MusicTests/LibraryCoverFetcherTests.swift
import CryptoKit
import XCTest
@testable import music

/// The shell's one cover fetcher: the rest, the cancel paths, readiness validity
/// and renewal, every outcome's disposition, the atomic install, the disk key and
/// eviction. A scripted SpanDAC, a fake clock, a settable data epoch, lanes that
/// run inline or hold their jobs, and a temp cache directory: no socket, no
/// playback, no real art cache.
final class LibraryCoverFetcherTests: XCTestCase {

    typealias Target = LibraryCoverFetcher.Target
    typealias Lane = LibraryCoverFetcher.Lane

    static let instanceA = "6F1C2A44-0B1E-4C1D-9A55-2D3B6B8E1F00"
    static let instanceB = "9D3E7B10-4C2A-4F8E-8B61-7A0C5E2D9F31"
    static let albumID = "1945713005063419934"
    static let playlistID = "p.ABC123"

    // MARK: seams

    /// Seconds from an integral origin, so quarter-second rests compare exactly.
    final class Clock {
        var t: TimeInterval = 0
        var date: Date { Date(timeIntervalSinceReferenceDate: 1_000_000 + t) }
    }

    /// Runs a job inline unless its lane is held; a held job waits for `release`.
    final class Lanes {
        var held: Set<Lane> = []
        private(set) var waiting: [Lane: [() -> Void]] = [:]

        func submit(_ lane: Lane, _ job: @escaping () -> Void) {
            if held.contains(lane) { waiting[lane, default: []].append(job) } else { job() }
        }

        func release(_ lane: Lane) {
            held.remove(lane)
            let jobs = waiting[lane] ?? []
            waiting[lane] = []
            jobs.forEach { $0() }
        }

        func waitingCount(_ lane: Lane) -> Int { waiting[lane]?.count ?? 0 }
    }

    /// A SpanDAC on a script. Serves any cover it holds under whatever generation
    /// and instance it is asked with (as a SpanDAC whose live core generation
    /// happens to match would), so only the fetcher decides what is asked.
    final class FakeSpanDAC: MusicDataProvider {
        let clock: Clock
        var readiness: () throws -> LibraryArtworkReadiness
        private(set) var statusReadTimes: [TimeInterval] = []
        /// "kind|id|generation" first, then "kind|id"; absent → `no_artwork`.
        var covers: [String: Data] = [:]
        /// Consumed first, one per first request, before any cover is served.
        var firstReplies: [LibraryArtworkReply] = []
        /// Called with the chunk index before a later chunk is answered.
        var onChunk: ((Int) -> Void)?
        /// Replaces the answer for a chunk index when it returns non-nil.
        var chunkOverride: ((Int) -> LibraryArtworkReply?)?
        var corruptDigest = false
        private(set) var firstRequests: [LibraryArtworkRequest] = []
        private(set) var chunkRequests: [String] = []
        private var transfers: [String: (request: LibraryArtworkRequest, data: Data)] = [:]

        init(clock: Clock, instance: String = LibraryCoverFetcherTests.instanceA) {
            self.clock = clock
            self.readiness = { LibraryArtworkReadiness(supported: true, instance: instance) }
        }

        func libraryArtworkReadiness() throws -> LibraryArtworkReadiness {
            statusReadTimes.append(clock.t)
            return try readiness()
        }

        func libraryArtwork(kind: LibraryArtworkKind, id: String, generation: Int, libraryInstance: String,
                            px: Int) throws -> LibraryArtworkReply {
            let request = LibraryArtworkRequest(kind: kind, id: id, generation: generation,
                                                libraryInstance: libraryInstance, px: px)
            firstRequests.append(request)
            if !firstReplies.isEmpty { return firstReplies.removeFirst() }
            guard let data = covers["\(kind.rawValue)|\(id)|\(generation)"] ?? covers["\(kind.rawValue)|\(id)"] else {
                return .refused(.noArtwork)
            }
            let transfer = String(format: "%032x", firstRequests.count)
            transfers[transfer] = (request, data)
            return .chunk(chunk(0, transfer: transfer))
        }

        func libraryArtworkChunk(cursor: String) throws -> LibraryArtworkReply {
            chunkRequests.append(cursor)
            let parts = cursor.split(separator: "|")
            guard parts.count == 3, let index = Int(parts[2]), transfers[String(parts[1])] != nil else {
                return .refused(.transferExpired)
            }
            onChunk?(index)
            if let replaced = chunkOverride?(index) { return replaced }
            return .chunk(chunk(index, transfer: String(parts[1])))
        }

        private func chunk(_ index: Int, transfer: String) -> LibraryArtworkChunk {
            let (request, data) = transfers[transfer]!
            let size = libraryArtworkChunkBytes
            let count = (data.count + size - 1) / size
            let slice = data.subdata(in: (index * size)..<min((index + 1) * size, data.count))
            let digest = corruptDigest ? String(repeating: "0", count: 64)
                : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return LibraryArtworkChunk(
                generation: request.generation, libraryInstance: request.libraryInstance, kind: request.kind,
                id: request.id, transfer: transfer, chunk: index, chunks: count,
                dataBase64: slice.base64EncodedString(),
                nextCursor: index + 1 < count ? "c|\(transfer)|\(index + 1)" : nil,
                manifest: index == 0 ? LibraryArtworkManifest(mediaType: "image/jpeg", px: request.px,
                                                              bytes: data.count, sha256: digest) : nil)
        }

        func librarySongs(cursor: String?, limit: Int) throws -> MusicPage {
            throw MusicProviderError.notImplemented("not used here")
        }
        func play(ids: [String]) throws -> BridgeNow.Queue {
            throw MusicProviderError.notImplemented("not used here")
        }
        func nowPlaying() throws -> SourceStatus {
            throw MusicProviderError.notImplemented("not used here")
        }
    }

    struct ReadFailed: Error {}

    final class Harness {
        let clock = Clock()
        let lanes = Lanes()
        let spandac: FakeSpanDAC
        let dir: String
        var epoch = 0
        private(set) var fetcher: LibraryCoverFetcher!

        init(dir: String? = nil, eviction: LibraryCoverEviction = .standard) {
            spandac = FakeSpanDAC(clock: clock)
            if let dir {
                self.dir = dir
            } else {
                self.dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("covers-test-\(UUID().uuidString)").path
                try? FileManager.default.createDirectory(atPath: self.dir, withIntermediateDirectories: true)
            }
            fetcher = LibraryCoverFetcher(provider: { [spandac] in spandac },
                                          dataEpoch: { [unowned self] in self.epoch },
                                          cacheDir: self.dir,
                                          now: { [clock] in clock.date },
                                          queue: { [lanes] lane, job in lanes.submit(lane, job) },
                                          px: 512, eviction: eviction)
            fetcher.observeShell(active: .library, dataEpoch: 0)
        }

        /// One scene tick at `t` with `target` focused.
        func tick(_ t: TimeInterval, _ target: Target?) {
            clock.t = t
            fetcher.focus(target)
        }

        /// A tick every 0.1 s from `from` through `to`, `each` after every tick.
        func ticks(from: TimeInterval, to: TimeInterval, _ target: Target?,
                   each: ((TimeInterval) -> Void)? = nil) {
            for tenth in Int((from * 10).rounded())...Int((to * 10).rounded()) {
                let t = Double(tenth) / 10
                tick(t, target)
                each?(t)
            }
        }

        /// Focuses `target` at `t - 0.25` and ticks at `t`: the rest ends at `t`.
        func rest(_ target: Target, at t: TimeInterval = 0) {
            tick(t - 0.25, target)
            tick(t, target)
        }

        func key(_ target: Target) -> String { LibraryCoverFetcher.cacheKey(for: target, px: 512) }

        func files() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        }

        func contents(_ target: Target) -> Data? {
            FileManager.default.contents(atPath: "\(dir)/\(key(target))")
        }

        func statusReads() -> Int { spandac.statusReadTimes.count }

        deinit { try? FileManager.default.removeItem(atPath: dir) }
    }

    static func payload(_ count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8(($0 + seed) % 251) })
    }

    func album(_ id: String = LibraryCoverFetcherTests.albumID, generation: Int = 2,
               instance: String = LibraryCoverFetcherTests.instanceA, epoch: Int = 0) -> Target {
        Target(owner: .libraryAlbums, kind: .album, id: id, generation: generation,
               libraryInstance: instance, dataEpoch: epoch)
    }

    func playlist(_ id: String = LibraryCoverFetcherTests.playlistID, generation: Int = 2,
                  instance: String = LibraryCoverFetcherTests.instanceA) -> Target {
        Target(owner: .playlists, kind: .playlist, id: id, generation: generation,
               libraryInstance: instance, dataEpoch: 0)
    }

    /// A harness whose SpanDAC holds a two-chunk cover for the default album.
    func served(_ bytes: Int = 40_000) -> Harness {
        let h = Harness()
        h.spandac.covers["album|\(Self.albumID)"] = Self.payload(bytes)
        return h
    }

    // MARK: the rest

    func testNothingIsAskedBeforeTheRest() {
        let h = served()
        let a = album()
        h.tick(0, a); h.tick(0.1, a); h.tick(0.24, a)
        XCTAssertEqual(h.statusReads(), 0)
        XCTAssertTrue(h.spandac.firstRequests.isEmpty)
        XCTAssertNil(h.fetcher.cover(for: a))
    }

    func testOneRequestAfterTheRest() {
        let h = served()
        let a = album()
        h.tick(0, a)
        h.tick(0.25, a)
        XCTAssertEqual(h.spandac.statusReadTimes, [0.25])
        XCTAssertEqual(h.spandac.firstRequests,
                       [LibraryArtworkRequest(kind: .album, id: Self.albumID, generation: 2,
                                              libraryInstance: Self.instanceA, px: 512)])
        XCTAssertEqual(h.spandac.chunkRequests.count, 1)
        XCTAssertEqual(h.contents(a), Self.payload(40_000))
        XCTAssertEqual(h.fetcher.cover(for: a),
                       LibraryCover(key: h.key(a), url: URL(fileURLWithPath: "\(h.dir)/\(h.key(a))").absoluteString))
        h.ticks(from: 0.3, to: 3.0, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 1, "an installed cover is never asked for again")
    }

    func testAFastScrollAsksOnlyForTheLastRow() {
        let h = Harness()
        let rows = (0..<10).map { album("r\($0)") }
        for (i, row) in rows.enumerated() {   // a row every 125 ms, never resting
            h.spandac.covers["album|r\(i)"] = Self.payload(1_000, seed: i)
            h.tick(Double(i) * 0.125, row)
        }
        XCTAssertEqual(h.statusReads(), 0)
        h.tick(9 * 0.125 + 0.25, rows[9])
        XCTAssertEqual(h.spandac.firstRequests.map(\.id), ["r9"])
        XCTAssertEqual(h.statusReads(), 1)
    }

    // MARK: cancel

    func testATabSwitchBeforeTheFirstRequestAsksNothing() {
        let h = served()
        let a = album()
        h.lanes.held = [.fetch]
        h.rest(a)
        XCTAssertEqual(h.lanes.waitingCount(.fetch), 1)
        h.fetcher.observeShell(active: .nowPlaying, dataEpoch: 0)
        h.lanes.release(.fetch)
        XCTAssertTrue(h.spandac.firstRequests.isEmpty)
        XCTAssertNil(h.fetcher.cover(for: a))
    }

    func testATabSwitchBetweenChunksInstallsNothing() {
        let h = served(70_000)   // three chunks
        let a = album()
        h.spandac.onChunk = { index in
            if index == 1 { h.fetcher.observeShell(active: .playlists, dataEpoch: 0) }
        }
        h.rest(a)
        XCTAssertEqual(h.spandac.chunkRequests.count, 1, "chunk 2 is never asked for")
        XCTAssertEqual(h.files(), [])
    }

    func testAnInactiveSourceSwitchBeforeTheFirstRequestAsksNothing() {
        let h = served()
        let a = album()
        h.lanes.held = [.fetch]
        h.rest(a)
        h.epoch = 1   // the routing coordinator flips; no scene ticks, no observeShell
        h.lanes.release(.fetch)
        XCTAssertTrue(h.spandac.firstRequests.isEmpty)
        XCTAssertEqual(h.files(), [])
    }

    func testAnInactiveSourceSwitchBetweenChunksInstallsNothing() {
        let h = served(70_000)
        let a = album()
        h.spandac.onChunk = { index in if index == 1 { h.epoch = 1 } }
        h.rest(a)
        XCTAssertEqual(h.spandac.chunkRequests.count, 1)
        XCTAssertEqual(h.files(), [])
    }

    func testCancelAfterTheLastChunkBeforeRenameInstallsNothing() {
        let h = served()   // two chunks: chunk 1 is the last
        let a = album()
        h.spandac.onChunk = { index in if index == 1 { h.fetcher.cancelAll() } }
        h.rest(a)
        XCTAssertEqual(h.spandac.chunkRequests.count, 1)
        XCTAssertEqual(h.files(), [], "no cover and no temp file left")
        XCTAssertNil(h.fetcher.cover(for: a))
    }

    func testFocusFromAnInactiveOwnerIsIgnored() {
        let h = served()
        h.spandac.covers["playlist|\(Self.playlistID)"] = Self.payload(500)
        h.fetcher.observeShell(active: .playlists, dataEpoch: 0)
        let a = album()
        h.ticks(from: 0, to: 2, a)
        XCTAssertEqual(h.statusReads(), 0)
        XCTAssertTrue(h.spandac.firstRequests.isEmpty)
        let p = playlist()
        h.rest(p, at: 3)
        XCTAssertEqual(h.spandac.firstRequests.map(\.kind), [.playlist])
        XCTAssertNotNil(h.fetcher.cover(for: p))
    }

    func testLandedMovesOnInstallNegativeAndCancel() {
        let h = served()
        let a = album()
        h.lanes.held = [.fetch]
        h.rest(a)
        var before = h.fetcher.landed
        h.lanes.release(.fetch)
        XCTAssertGreaterThan(h.fetcher.landed, before, "install")

        let other = album("no-cover")
        h.lanes.held = [.fetch]
        h.rest(other, at: 1)
        before = h.fetcher.landed
        h.lanes.release(.fetch)
        XCTAssertEqual(h.spandac.firstRequests.last?.id, "no-cover")
        XCTAssertGreaterThan(h.fetcher.landed, before, "negative")

        before = h.fetcher.landed
        h.fetcher.cancelAll()
        XCTAssertGreaterThan(h.fetcher.landed, before, "cancel")
    }

    func testFocusMovingBetweenChunksStopsTheTransferAndInstallsNothing() {
        let h = served(70_000)
        let a = album()
        let b = album("other")
        h.spandac.covers["album|other"] = Self.payload(500)
        h.spandac.onChunk = { index in if index == 1 { h.fetcher.focus(b) } }
        h.rest(a)
        XCTAssertEqual(h.spandac.chunkRequests.count, 1)
        XCTAssertNil(h.contents(a))
        XCTAssertEqual(h.spandac.firstRequests.count, 1, "b is still resting")
        h.tick(0.25, b)
        XCTAssertEqual(h.spandac.firstRequests.map(\.id), [Self.albumID, "other"])
        XCTAssertNil(h.contents(a))
        XCTAssertNotNil(h.contents(b))
    }

    // MARK: install and next session

    func testAnInstalledCoverIsAtomicAndServedFromDiskNextSession() {
        let h = served()
        let a = album()
        h.rest(a)
        XCTAssertEqual(h.files(), [h.key(a)], "one file, no temp file beside it")
        XCTAssertEqual(h.contents(a), Self.payload(40_000))

        let next = Harness(dir: h.dir)
        XCTAssertNil(next.fetcher.cover(for: a), "nothing shows before a readiness read")
        next.rest(a)
        XCTAssertEqual(next.statusReads(), 1)
        XCTAssertTrue(next.spandac.firstRequests.isEmpty)
        XCTAssertEqual(next.fetcher.cover(for: a)?.key, h.key(a))
    }

    // MARK: instance

    func testAnInstanceACoverIsNotShownOnceStatusSaysInstanceB() {
        let h = served()
        let a = album()
        h.rest(a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
        h.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        h.ticks(from: 0.1, to: 3.9, a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
        h.tick(4.0, a)   // the renewal names B
        XCTAssertNil(h.fetcher.cover(for: a))
        h.ticks(from: 4.1, to: 12, a) { _ in XCTAssertNil(h.fetcher.cover(for: a)) }
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
    }

    func testRowsObservedUnderAAreNeverRequestedUnderBEvenAtTheSameGeneration() {
        let h = served()
        let a = album(generation: 2, instance: Self.instanceA)
        h.rest(a)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        // SpanDAC restarts as B, whose live core generation is also 2: the fake
        // would serve an A-instance request. The applied rows still carry A.
        h.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        h.ticks(from: 0.1, to: 60, a) { t in
            if t >= 4.0 { XCTAssertNil(h.fetcher.cover(for: a), "at \(t)") }
        }
        XCTAssertEqual(h.spandac.firstRequests.count, 1, "nothing asked under B for A-observed rows")
        // The scene applies a list drain observed under B.
        let b = album(generation: 2, instance: Self.instanceB)
        h.rest(b, at: 60.25)
        XCTAssertEqual(h.spandac.firstRequests.count, 2)
        XCTAssertEqual(h.spandac.firstRequests.last?.libraryInstance, Self.instanceB)
        XCTAssertNotNil(h.fetcher.cover(for: b))
    }

    func testAnInstanceBNoArtworkLeavesTheGradient() {
        let h = served()
        let a = album(generation: 2, instance: Self.instanceA)
        h.rest(a)
        h.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        h.ticks(from: 0.1, to: 4.0, a)
        let b = album(generation: 3, instance: Self.instanceB)
        h.spandac.firstReplies = [.refused(.noArtwork)]
        h.rest(b, at: 5)
        XCTAssertEqual(h.spandac.firstRequests.last?.libraryInstance, Self.instanceB)
        XCTAssertNil(h.fetcher.cover(for: b), "the A cover is never B's interim")
        XCTAssertNil(h.fetcher.cover(for: a))
    }

    // MARK: readiness validity and renewal

    func testWithoutAFreshValidationTheHeroIsGradient() {
        let h = served()
        let a = album()
        h.rest(a)
        h.spandac.readiness = { throw ReadFailed() }
        h.ticks(from: 0.1, to: 4.9, a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
        h.ticks(from: 5.0, to: 6.9, a) { t in XCTAssertNil(h.fetcher.cover(for: a), "at \(t)") }
        h.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceA) }
        h.tick(7.0, a)   // the retry ladder's third read (4, 5, 7) succeeds
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 4, 5, 7])
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    func testADelayedRenewalAcrossFourSecondsShowsNoFlashBeforeFive() {
        let h = served()
        let a = album()
        h.rest(a)   // validated at 0
        h.ticks(from: 0.1, to: 3.9, a)
        h.lanes.held = [.status]
        for t in [4.0, 4.5, 4.99] {
            h.tick(t, a)
            XCTAssertNotNil(h.fetcher.cover(for: a), "at \(t)")
        }
        XCTAssertEqual(h.statusReads() + h.lanes.waitingCount(.status), 2, "one renewal, held, nothing more")
        h.clock.t = 4.99
        h.lanes.release(.status)
        h.tick(5.0, a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
        h.ticks(from: 5.1, to: 9.0, a) { t in XCTAssertNotNil(h.fetcher.cover(for: a), "at \(t)") }
    }

    func testAHungRenewalShowsTheGradientAtTheDeadline() {
        let h = served()
        let a = album()
        h.rest(a)
        h.ticks(from: 0.1, to: 3.9, a)
        h.lanes.held = [.status]
        h.ticks(from: 4.0, to: 4.9, a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
        h.tick(5.0, a)
        XCTAssertNil(h.fetcher.cover(for: a))
        h.ticks(from: 5.1, to: 6.9, a)
        XCTAssertEqual(h.statusReads(), 1)
        XCTAssertEqual(h.lanes.waitingCount(.status), 1, "no second read while the renewal is held")
        h.clock.t = 7.0
        h.lanes.release(.status)
        h.tick(7.0, a)
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    func testAFailedRenewalRetriesWithBackoffNotBusyPolling() {
        let h = served()
        let a = album()
        h.rest(a)
        h.spandac.readiness = { throw ReadFailed() }
        h.ticks(from: 0.1, to: 20, a) { t in
            if t >= 5.0 { XCTAssertNil(h.fetcher.cover(for: a), "at \(t)") }
            else { XCTAssertNotNil(h.fetcher.cover(for: a), "at \(t)") }
        }
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 4, 5, 7, 11, 19])
    }

    func testUnsupportedOrBlankInstanceDropsTheCoverAtOnce() {
        for answer in [LibraryArtworkReadiness(supported: false, instance: Self.instanceA),
                       LibraryArtworkReadiness(supported: false, instance: nil)] {
            let h = served()
            let a = album()
            h.rest(a)
            h.ticks(from: 0.1, to: 3.9, a)
            h.spandac.readiness = { answer }
            h.tick(4.0, a)
            XCTAssertNil(h.fetcher.cover(for: a), "\(answer)")
            h.ticks(from: 4.1, to: 40, a)
            XCTAssertEqual(h.spandac.statusReadTimes, [0, 4, 34], "\(answer)")
        }
    }

    // MARK: a status call that outlives the focus it was made for

    /// The first status call is held "in flight" by running `whileHeld` inside it;
    /// it then answers `stale`. Every later call gets the supported default.
    private func holdFirstStatusCall(_ h: Harness, whileHeld: @escaping () -> Void,
                                     answer stale: @escaping () throws -> LibraryArtworkReadiness) {
        var calls = 0
        h.spandac.readiness = {
            calls += 1
            if calls == 1 { whileHeld(); return try stale() }
            return LibraryArtworkReadiness(supported: true, instance: Self.instanceA)
        }
    }

    func testAStaleUnsupportedAnswerAfterATabCancelIsDiscarded() {
        let h = served()
        let a = album()
        holdFirstStatusCall(h, whileHeld: { h.fetcher.observeShell(active: .playlists, dataEpoch: 0) },
                            answer: { LibraryArtworkReadiness(supported: false, instance: Self.instanceA) })
        h.rest(a)                                    // the read starts and is cancelled under it
        XCTAssertEqual(h.statusReads(), 1)
        XCTAssertNil(h.fetcher.cover(for: a))
        h.fetcher.observeShell(active: .library, dataEpoch: 0)   // back to a valid target
        h.rest(a, at: 1.0)
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 1.0], "a fresh read at once, not 30 s later")
        XCTAssertEqual(h.contents(a), Self.payload(40_000))
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    func testAStaleUnsupportedAnswerAfterAnUnobservedDataEpochMoveIsDiscarded() {
        let h = served()
        let a = album()
        holdFirstStatusCall(h, whileHeld: { h.epoch = 1 },     // no observeShell: only the live epoch moved
                            answer: { LibraryArtworkReadiness(supported: false, instance: Self.instanceA) })
        h.rest(a)
        XCTAssertEqual(h.statusReads(), 1)
        let b = album(epoch: 1)
        h.fetcher.observeShell(active: .library, dataEpoch: 1)
        h.rest(b, at: 1.0)
        XCTAssertNotNil(h.fetcher.cover(for: b), "the obsolete unsupported answer must not hold the gradient")
        XCTAssertLessThan(h.clock.t, LibraryCoverFetcher.unsupportedReread)
    }

    func testAStaleTransportFailureImposesNoRetryDelayOnTheNewFocus() {
        let h = served()
        let a = album()
        holdFirstStatusCall(h, whileHeld: { h.fetcher.observeShell(active: .playlists, dataEpoch: 0) },
                            answer: { throw ReadFailed() })
        h.rest(a)
        XCTAssertEqual(h.statusReads(), 1)
        h.fetcher.observeShell(active: .library, dataEpoch: 0)
        h.rest(a, at: 0.5)                           // inside the 1 s retry the stale failure would set
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 0.5])
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    // MARK: interim and generations

    func testAGenerationBNegativeClearsTheGenerationAInterim() {
        let h = served()
        let gen1 = album(generation: 1)
        h.rest(gen1)
        let gen2 = album(generation: 2)
        let gen3 = album(generation: 3)
        h.lanes.held = [.fetch]
        h.rest(gen2, at: 1)
        XCTAssertEqual(h.fetcher.cover(for: gen2)?.key, h.key(gen1), "the interim while gen 2 is drawn")
        XCTAssertEqual(h.fetcher.cover(for: gen3)?.key, h.key(gen1))
        h.spandac.firstReplies = [.refused(.noArtwork)]
        h.lanes.release(.fetch)
        XCTAssertNil(h.fetcher.cover(for: gen2))
        XCTAssertNil(h.fetcher.cover(for: gen3), "the interim is gone, not only gen 2's answer")
    }

    func testChangedArtUnderTheSameIDIsReplacedOnTheNextGeneration() {
        let h = Harness()
        h.spandac.covers["album|\(Self.albumID)|1"] = Self.payload(800, seed: 1)
        h.spandac.covers["album|\(Self.albumID)|2"] = Self.payload(900, seed: 2)
        let gen1 = album(generation: 1)
        let gen2 = album(generation: 2)
        h.rest(gen1)
        h.lanes.held = [.fetch]
        h.rest(gen2, at: 1)
        XCTAssertEqual(h.fetcher.cover(for: gen2)?.key, h.key(gen1))
        h.lanes.release(.fetch)
        XCTAssertEqual(h.fetcher.cover(for: gen2)?.key, h.key(gen2))
        XCTAssertEqual(h.contents(gen2), Self.payload(900, seed: 2))
    }

    // MARK: outcomes

    func testADigestMismatchInstallsNothingAndBacksOff() {
        let h = served()
        h.spandac.corruptDigest = true
        let a = album()
        h.rest(a)
        XCTAssertEqual(h.files(), [])
        h.ticks(from: 0.1, to: 29.9, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        h.tick(30.0, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 2)
        XCTAssertEqual(h.files(), [])
    }

    func testTimeoutBacksOffThenRetries() {
        let h = served()
        h.spandac.firstReplies = [.refused(.renderTimeout)]
        let a = album()
        h.rest(a)
        XCTAssertNil(h.fetcher.cover(for: a))
        h.ticks(from: 0.1, to: 29.9, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        h.tick(30.0, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 2)
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    func testWarmingRetriesAfterItsHintWithAOneSecondFloor() {
        let h = served()
        h.spandac.firstReplies = [.refused(.warming(retryAfter: 0.2))]
        let a = album()
        h.rest(a)
        h.ticks(from: 0.1, to: 0.9, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        h.tick(1.0, a)
        XCTAssertEqual(h.spandac.firstRequests.count, 2)
        XCTAssertNotNil(h.fetcher.cover(for: a))
    }

    func testTransientOutcomesNeverPoisonArtworkStore() {
        let h = served()
        h.spandac.firstReplies = [.refused(.busy)]
        let store = ArtworkStore(cacheDir: h.dir,
                                 fetch: { _ in XCTFail("an installed cover is never fetched"); return nil },
                                 render: { _, _, _ in ["ART"] })
        let a = album()
        h.rest(a)
        XCTAssertNil(h.fetcher.cover(for: a), "a scene has nothing to hand the store")
        h.ticks(from: 0.1, to: 30, a)
        guard let cover = h.fetcher.cover(for: a) else { return XCTFail("installed after the backoff") }
        let ready = expectation(description: "rendered")
        XCTAssertNil(store.lines(key: cover.key, url: cover.url, width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: cover.key, url: cover.url, width: 8, height: 4) { }, ["ART"])
    }

    func testNoArtworkIsNegativeOnlyForThatGeneration() {
        let h = served()
        h.spandac.firstReplies = [.refused(.noArtwork)]
        let gen1 = album(generation: 1)
        h.rest(gen1)
        h.ticks(from: 0.1, to: 60, gen1)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        XCTAssertNil(h.fetcher.cover(for: gen1))
        let gen2 = album(generation: 2)
        h.rest(gen2, at: 61)
        XCTAssertEqual(h.spandac.firstRequests.map(\.generation), [1, 2])
        XCTAssertNotNil(h.fetcher.cover(for: gen2))
    }

    func testStaleGenerationWaitsForANewGeneration() {
        let h = served()
        h.spandac.firstReplies = [.refused(.staleGeneration)]
        let gen1 = album(generation: 1)
        h.rest(gen1)
        XCTAssertEqual(h.statusReads(), 1)
        h.tick(0.1, gen1)
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 0.1], "stale_generation forces a read")
        h.ticks(from: 0.2, to: 60, gen1)
        XCTAssertEqual(h.spandac.firstRequests.count, 1)
        let gen2 = album(generation: 2)
        h.rest(gen2, at: 61)
        XCTAssertEqual(h.spandac.firstRequests.map(\.generation), [1, 2])
        XCTAssertNotNil(h.fetcher.cover(for: gen2))
    }

    func testRestartWithTheSameGenerationIsAnotherKey() {
        let h = served()
        let underA = album(generation: 2, instance: Self.instanceA)
        let underB = album(generation: 2, instance: Self.instanceB)
        XCTAssertNotEqual(h.key(underA), h.key(underB))
        h.rest(underA)
        h.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        h.ticks(from: 0.1, to: 4.0, underA)
        XCTAssertNil(h.fetcher.cover(for: underB), "A's file is not B's")
        h.rest(underB, at: 5)
        XCTAssertEqual(h.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA, Self.instanceB])
        XCTAssertEqual(h.fetcher.cover(for: underB)?.key, h.key(underB))
        XCTAssertEqual(h.files(), [h.key(underA), h.key(underB)].sorted())
    }

    func testTransferExpiredRestartsOnce() {
        let once = served()
        var expiredOnce = false
        once.spandac.chunkOverride = { _ in
            guard !expiredOnce else { return nil }
            expiredOnce = true
            return .refused(.transferExpired)
        }
        let a = album()
        once.rest(a)
        XCTAssertEqual(once.spandac.firstRequests.count, 2, "one restart from the first request")
        XCTAssertNotNil(once.fetcher.cover(for: a))

        let always = served()
        always.spandac.chunkOverride = { _ in .refused(.transferExpired) }
        always.rest(a)
        XCTAssertEqual(always.spandac.firstRequests.count, 2)
        XCTAssertEqual(always.files(), [])
        always.ticks(from: 0.1, to: 29.9, a)
        XCTAssertEqual(always.spandac.firstRequests.count, 2, "then the backoff")
        always.tick(30.0, a)
        XCTAssertEqual(always.spandac.firstRequests.count, 4)
    }

    func testUnsupportedAsksNothing() {
        let h = served()
        h.spandac.readiness = { .unsupported }
        let a = album()
        h.rest(a)
        h.ticks(from: 0.1, to: 60, a)
        XCTAssertTrue(h.spandac.firstRequests.isEmpty)
        XCTAssertEqual(h.spandac.statusReadTimes, [0, 30, 60])
        XCTAssertNil(h.fetcher.cover(for: a))

        // An `unknown_op` answer to the request itself: readiness is false until
        // it is read again, so nothing more is asked meanwhile.
        let old = served()
        old.spandac.firstReplies = [.refused(.unsupported)]
        old.rest(a)
        old.ticks(from: 0.1, to: 29.9, a) { t in XCTAssertNil(old.fetcher.cover(for: a), "at \(t)") }
        XCTAssertEqual(old.spandac.firstRequests.count, 1)
        XCTAssertEqual(old.spandac.statusReadTimes, [0])
    }

    // MARK: disk

    func testEvictionKeepsWithinBounds() throws {
        XCTAssertEqual(LibraryCoverEviction.standard,
                       LibraryCoverEviction(maximumAge: 30 * 86_400, triggerFiles: 1_500, triggerBytes: 48 * 1_048_576,
                                            targetFiles: 1_200, targetBytes: 38 * 1_048_576, everyInstalls: 25))
        let small = LibraryCoverEviction(maximumAge: 100, triggerFiles: 5, triggerBytes: 1_000,
                                         targetFiles: 3, targetBytes: 600, everyInstalls: 2)
        let fm = FileManager.default
        let clock = Clock()
        func plant(_ dir: String, _ name: String, bytes: Int, age: TimeInterval) throws {
            let path = "\(dir)/\(name)"
            try Data(count: bytes).write(to: URL(fileURLWithPath: path))
            try fm.setAttributes([.modificationDate: clock.date.addingTimeInterval(-age)], ofItemAtPath: path)
        }

        // By count, after the age pass; another owner's file is never touched.
        let byCount = Harness()
        try plant(byCount.dir, "sd_old", bytes: 10, age: 200)
        for i in 1...6 { try plant(byCount.dir, "sd_\(i)", bytes: 10, age: Double(10 - i)) }
        try plant(byCount.dir, "l_keep", bytes: 10, age: 10_000)
        let countPass = Harness(dir: byCount.dir, eviction: small)
        XCTAssertEqual(countPass.files(), ["l_keep", "sd_4", "sd_5", "sd_6"])

        // By bytes.
        let byBytes = Harness()
        for i in 1...3 { try plant(byBytes.dir, "sd_\(i)", bytes: 400, age: Double(10 - i)) }
        let bytesPass = Harness(dir: byBytes.dir, eviction: small)
        XCTAssertEqual(bytesPass.files(), ["sd_3"])

        // Every `everyInstalls` installs, not only at init.
        let h = Harness(eviction: small)
        h.spandac.covers["album|x1"] = Self.payload(10)
        h.spandac.covers["album|x2"] = Self.payload(10)
        try plant(h.dir, "sd_stale", bytes: 10, age: 200)
        h.rest(album("x1"))
        XCTAssertTrue(h.files().contains("sd_stale"), "one install: no pass yet")
        h.rest(album("x2"), at: 1)
        XCTAssertFalse(h.files().contains("sd_stale"), "the second install runs a pass")
        XCTAssertEqual(h.files().count, 2)
    }

    func testTheKeySurvivesArtworkStoreCacheKey() {
        let target = album()
        let key = LibraryCoverFetcher.cacheKey(for: target, px: 512)
        let text = "v1|\(Self.instanceA)|2|album|\(Self.albumID)|512"
        let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(key, "sd_" + hex.prefix(32))
        XCTAssertEqual(ArtworkStore.cacheKey(key), key)
        XCTAssertNotEqual(key, LibraryCoverFetcher.cacheKey(for: target, px: 300))
        XCTAssertNotEqual(key, LibraryCoverFetcher.cacheKey(for: playlist(Self.albumID), px: 512))
    }

    func testInstalledFileNamesCarryNoID() {
        let h = Harness()
        h.spandac.covers["album|\(Self.albumID)"] = Self.payload(40_000)
        h.spandac.covers["playlist|\(Self.playlistID)"] = Self.payload(500, seed: 3)
        h.rest(album())
        h.fetcher.observeShell(active: .playlists, dataEpoch: 0)
        h.rest(playlist(), at: 1)
        let names = h.files()
        XCTAssertEqual(names.count, 2)
        let secrets = [Self.albumID, Self.playlistID, "ABC123", Self.instanceA, "6F1C2A44"]
        for name in names {
            XCTAssertTrue(name.hasPrefix("sd_"), name)
            XCTAssertTrue(name.allSatisfy { $0 == "_" || $0.isNumber || ("a"..."z").contains($0) }, name)
            for secret in secrets { XCTAssertFalse(name.contains(secret), "\(name) carries \(secret)") }
            let bytes = FileManager.default.contents(atPath: "\(h.dir)/\(name)") ?? Data()
            for secret in secrets {
                XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(name)'s bytes carry \(secret)")
            }
        }
    }
}

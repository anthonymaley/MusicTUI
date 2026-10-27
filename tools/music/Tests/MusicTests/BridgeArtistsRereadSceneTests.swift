// tools/music/Tests/MusicTests/BridgeArtistsRereadSceneTests.swift
import XCTest
@testable import music

/// The SpanDAC Artists list reading itself again once SpanDAC has finished a
/// library refresh or restarted: the scene's `slice.status` watch while Artists
/// is the sub-view on screen, the checkpoint it keeps, and the one re-read each
/// new checkpoint earns. SpanDAC is a scripted server behind a fixture transport
/// (real-shaped artist pages, which carry no `library_instance`), the scene's
/// clock is a fake one, and a read the test must hold is held at the server
/// until the test lets it go. No socket, no playback, no keychain, and the tier
/// cache is a temp directory.
final class BridgeArtistsRereadSceneTests: XCTestCase {

    private let frame = shellLayout(width: 100, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private static let instanceA = "inst-A"
    private static let instanceB = "inst-B"
    private static let artistsOp = "slice.libraryArtists"
    private static let statusOp = "slice.status"

    /// A clock the test moves and the scene's workers read: locked.
    private final class Clock {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var t: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
        var date: Date { Date(timeIntervalSinceReferenceDate: 1_000_000 + t) }
    }

    /// SpanDAC as far as these tests need it: its status (process and the latest
    /// rebuild's end), its artists (one page, shaped as SpanDAC sends them), an
    /// artist's albums, and per-request holds and failures. A hold blocks only the
    /// request's own thread, never the server's lock.
    private final class Server {
        private let lock = NSLock()
        private var instance: String? = BridgeArtistsRereadSceneTests.instanceA
        private var completion: (instance: String, ticket: Int, result: String)? = nil
        private var artists: [(id: String, name: String)]
        private var generation = 3
        private var draining = false
        private var failing: [String: Set<Int>] = [:]
        private var statusFailsFrom: Int? = nil
        private var counts: [String: Int] = [:]
        private var holds: [String: [Int: DispatchSemaphore]] = [:]
        private var threads: [String: [Int: Thread]] = [:]
        private var waiting: [String: Int] = [:]
        private var unsupportedAt: Set<Int> = []
        /// Rows per page; the artists list is served in pages of this many, each
        /// naming the next by cursor, as SpanDAC pages a library of 725.
        var pageSize = Int.max
        /// The artists request (0-based) at which a drain that is running lands:
        /// the list stops being flagged and the rebuild's ticket ends `installed`.
        var drainLandsAt: Int? = nil
        private var order: [String] = []

        init(_ artists: [(id: String, name: String)]) { self.artists = artists }

        func setStatus(instance: String?, completion: (instance: String, ticket: Int, result: String)?) {
            lock.lock(); self.instance = instance; self.completion = completion; lock.unlock()
        }
        func setArtists(_ artists: [(id: String, name: String)], generation: Int? = nil) {
            lock.lock(); self.artists = artists; if let generation { self.generation = generation }; lock.unlock()
        }
        func setDraining(_ on: Bool) { lock.lock(); draining = on; lock.unlock() }
        /// The Nth (0-based) request of `op` answers `bad_request`.
        func fail(_ op: String, at n: Int) { lock.lock(); failing[op, default: []].insert(n); lock.unlock() }
        /// Every status read from now on fails, or (nil) none does.
        func failStatus(_ on: Bool) {
            lock.lock(); statusFailsFrom = on ? (counts[BridgeArtistsRereadSceneTests.statusOp] ?? 0) : nil; lock.unlock()
        }
        /// The Nth (0-based) status read answers as an older SpanDAC: no process named.
        func unsupportedStatus(at n: Int) { lock.lock(); unsupportedAt.insert(n); lock.unlock() }
        /// Every request's op, in the order they arrived.
        func ops() -> [String] { lock.lock(); defer { lock.unlock() }; return order }
        func hold(_ op: String, at n: Int) { lock.lock(); holds[op, default: [:]][n] = DispatchSemaphore(value: 0); lock.unlock() }
        func release(_ op: String, at n: Int) { lock.lock(); let g = holds[op]?[n]; lock.unlock(); g?.signal() }

        func count(_ op: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[op] ?? 0 }
        /// Requests of `op` held at this moment.
        func held(_ op: String) -> Int { lock.lock(); defer { lock.unlock() }; return waiting[op] ?? 0 }
        func reached(_ op: String, at n: Int) -> Bool { count(op) > n }
        func ended(_ op: String, at n: Int) -> Bool {
            lock.lock(); let t = threads[op]?[n]; lock.unlock()
            return t?.isFinished ?? false
        }

        func transport(_ path: String, _ line: String) throws -> String {
            let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
            let op = body["op"] as? String ?? ""
            lock.lock()
            let n = counts[op, default: 0]
            counts[op] = n + 1
            order.append(op)
            let unsupported = op == BridgeArtistsRereadSceneTests.statusOp && unsupportedAt.contains(n)
            threads[op, default: [:]][n] = Thread.current
            let fails = failing[op]?.contains(n) == true
                || (op == BridgeArtistsRereadSceneTests.statusOp && statusFailsFrom.map { n >= $0 } == true)
            let gate = holds[op]?[n]
            if gate != nil { waiting[op, default: 0] += 1 }
            lock.unlock()
            if let gate {
                _ = gate.wait(timeout: .now() + 10)
                lock.lock(); waiting[op, default: 1] -= 1; lock.unlock()
            }
            // The reply is read AFTER a hold, as a server answering then would.
            lock.lock(); defer { lock.unlock() }
            if op == BridgeArtistsRereadSceneTests.artistsOp, n == drainLandsAt, let c = completion {
                draining = false
                completion = (c.instance, c.ticket + 1, "installed")
            }
            if fails { return Self.bad(op) }
            if unsupported { return #"{"ok":true,"op":"slice.status","status":{"playback":"stopped"}}"# }
            switch op {
            case BridgeArtistsRereadSceneTests.statusOp: return statusReply()
            case BridgeArtistsRereadSceneTests.artistsOp: return artistsReply(cursor: body["cursor"] as? String)
            case "slice.libraryArtistAlbums": return artistAlbumsReply()
            default: return Self.bad(op)
            }
        }

        private func statusReply() -> String {
            var fields = [#""playback":"stopped""#]
            if let instance { fields.append(#""library_instance":"\#(instance)""#) }
            if let c = completion {
                fields.append(#""library_refresh":{"instance":"\#(c.instance)","ticket":\#(c.ticket),"result":"\#(c.result)"}"#)
            } else if instance != nil {
                fields.append(#""library_refresh":null"#)
            }
            return #"{"ok":true,"op":"slice.status","status":{\#(fields.joined(separator: ","))}}"#
        }

        /// The keys SpanDAC's artists reply carries (measured 2026-10-27): generation,
        /// next_cursor, ok, op, refreshing, stale, total and the items. No instance.
        private func artistsReply(cursor: String?) -> String {
            let start = cursor.flatMap(Int.init) ?? 0
            let end = min(artists.count, start + min(pageSize, artists.count - start))
            let items = artists[start..<end].map { #"{"id":"\#($0.id)","title":"\#($0.name)","kind":"artist"}"# }.joined(separator: ",")
            let next = end < artists.count ? #""\#(end)""# : "null"
            return #"{"ok":true,"op":"slice.libraryArtists","generation":\#(generation),"total":\#(artists.count),"items":[\#(items)],"stale":false,"refreshing":\#(draining),"next_cursor":\#(next)}"#
        }

        private func artistAlbumsReply() -> String {
            #"{"ok":true,"op":"slice.libraryArtistAlbums","generation":2,"library_instance":"inst-A","items":[{"id":"al1","title":"Dummy","artist":"Portishead","track_count":11,"kind":"album"}],"stale":false,"refreshing":false}"#
        }

        static func bad(_ op: String) -> String {
            #"{"ok":false,"op":"\#(op)","error":{"kind":"bad_request","detail":"scripted failure"}}"#
        }
    }

    /// Counts the scene's watch status reads that have ended (posted or dropped).
    private final class Ended {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private final class Rig {
        let clock = Clock()
        let server: Server
        let flag = BridgeSelectedFlag(true)
        let statusEnded = Ended()
        let scene: LibraryScene

        init(_ server: Server, warmUpSleep: @escaping (TimeInterval) -> Void = { _ in }) {
            self.server = server
            let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
            store.set(.source)
            let routing = RoutingCoordinator(store: store, surface: .tui,
                                             makeSource: { SourceAppClient(path: "/nonexistent", transport: server.transport) })
            let status = StatusStore()
            let flag = self.flag, clock = self.clock
            scene = LibraryScene(
                backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                sources: LibraryAppleScriptSpy().sources(), appQueue: AppQueueStore(), status: status,
                actions: ActionRunner(status: status),
                makeProvider: {
                    flag.selected
                        ? BridgeMusicProvider(control: SourceAppControl(
                            path: "/nonexistent", transport: server.transport, libraryTransport: server.transport))
                        : nil
                },
                warmUpSleep: warmUpSleep,
                resultCache: temporaryResultCache().cache,
                now: { clock.date },
                screenWidth: { 80 })
            let ended = statusEnded
            scene.artistsStatusReadFinishedForTest = { ended.add() }
        }
    }

    private func artists(_ ids: String...) -> [(id: String, name: String)] {
        ids.map { (id: $0, name: "Artist \($0)") }
    }

    private func shows(_ rig: Rig, _ text: String) -> Bool {
        rig.scene.render(frame: frame, snapshot: idle).contains(text)
    }

    /// The Artists list (the default sub-view) after its first walk, at fake time 0.
    /// Unless `baseline`, the status read before that walk (status read 0) fails, so
    /// the rows have no checkpoint and the watch's first one earns its conservative
    /// re-read: the starting point most of these tests want.
    private func loadedRig(_ server: Server, showing first: String, baseline: Bool = false,
                           warmUpSleep: @escaping (TimeInterval) -> Void = { _ in }) -> Rig {
        if !baseline { server.fail(Self.statusOp, at: 0) }
        let rig = Rig(server, warmUpSleep: warmUpSleep)
        XCTAssertEqual(rig.scene.subViewForTest, .artists)
        XCTAssertTrue(settleScene(rig.scene) { self.shows(rig, first) }, "the artists never loaded")
        return rig
    }

    /// One tick at fake time `t`, then a wait (wall time, bounded) until the watch's
    /// status read, if one is out, has ended or is held, so the next tick sees its reply.
    private func tick(_ rig: Rig, at t: TimeInterval) {
        rig.clock.t = t
        _ = rig.scene.tick(snapshot: idle)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, rig.scene.artistsStatusReadInFlightForTest, rig.server.held(Self.statusOp) == 0 {
            usleep(1_000)
        }
    }

    /// Waits (wall time, bounded) without ticking the scene.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if condition() { return true }; usleep(1_000) }
        return condition()
    }

    /// Ticks every half fake second from `from` up to `to`, never a gap the scene
    /// would read as the tab having been left.
    private func run(_ rig: Rig, from: TimeInterval, to: TimeInterval) {
        var t = from
        while t <= to { tick(rig, at: t); t += 0.5 }
    }

    /// Ticks at `t` until the Nth (0-based) artists read has been served and its
    /// worker has ended, then once more: its rows are drained and a failure's retry
    /// is stamped at `t`.
    private func artistsRead(_ rig: Rig, at t: TimeInterval, _ n: Int) -> Bool {
        let ok = settleScene(rig.scene) {
            self.tick(rig, at: t)
            return rig.server.reached(Self.artistsOp, at: n) && rig.server.ended(Self.artistsOp, at: n)
        }
        XCTAssertTrue(rig.scene.artistsFeedForTest.waitForWorkersForTest(timeout: 5), "a feed worker never ended")
        tick(rig, at: t)
        return ok
    }

    // MARK: - the checkpoint taken before the first walk

    /// The live shape that looped (2026-10-27, Studio): 725 artists in eight pages of
    /// 100 with no instance, a status whose `library_instance` and `library_refresh`
    /// name the same process (ticket 9, installed), nothing changing. The list is read
    /// once and never again, however long the view is watched.
    func testTheLiveShapeReadsTheListOnceAndNeverLoops() {
        let server = Server((1...725).map { (id: "ar\($0)", name: "Artist \($0)") })
        server.pageSize = 100
        server.setStatus(instance: "9CFA0525-0000-0000-0000-000000000000",
                         completion: ("9CFA0525-0000-0000-0000-000000000000", 9, "installed"))
        let rig = loadedRig(server, showing: "Artist 1", baseline: true)
        XCTAssertTrue(settleScene(rig.scene) { server.count(Self.artistsOp) >= 8 && server.ended(Self.artistsOp, at: 7) })
        run(rig, from: 0, to: 60)
        XCTAssertTrue(rig.scene.artistsFeedForTest.waitForWorkersForTest(timeout: 5))
        XCTAssertEqual(server.count(Self.artistsOp), 8, "the list was read again: \(server.ops().filter { $0 == Self.artistsOp }.count) pages")
        XCTAssertGreaterThanOrEqual(server.count(Self.statusOp), 12, "the watch did not run")
    }

    /// A healthy status answered before the first page: launch reads Artists once.
    func testALaunchReadsArtistsExactlyOnceWithAHealthyStatus() {
        let server = Server(artists("ar1", "ar2"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar2", baseline: true)
        XCTAssertEqual(Array(server.ops().prefix(2)), [Self.statusOp, Self.artistsOp],
                       "the status was not read before the walk's first page")
        run(rig, from: 0, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 1, "launch read the Artists list twice")
        XCTAssertGreaterThanOrEqual(server.count(Self.statusOp), 6, "the watch did not run")
    }

    /// A refresh that ends while the first walk is out is a newer checkpoint than the
    /// one taken before it: exactly one re-read.
    func testACompletionDuringTheFirstWalkEarnsExactlyOneReread() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        server.hold(Self.artistsOp, at: 0)
        let rig = Rig(server)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.artistsOp) == 1 }, "the first walk never began")
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.setArtists(artists("ar1", "ar2"))
        server.release(Self.artistsOp, at: 0)
        XCTAssertTrue(settleScene(rig.scene) { self.shows(rig, "Artist ar2") }, "the first walk never landed")
        XCTAssertTrue(artistsRead(rig, at: 0, 1), "the refresh that ended during the walk was taken as read")
        run(rig, from: 0.5, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "more than one re-read")
    }

    /// The status read before the walk fails: no baseline is invented, and the watch's
    /// first checkpoint earns one conservative re-read.
    func testAFailedPreWalkStatusFallsBackToOneConservativeReread() {
        let server = Server(artists("ar1"))
        let rig = loadedRig(server, showing: "Artist ar1")   // status read 0 fails
        run(rig, from: 0, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 2)
    }

    /// The status read before the walk names no process, but the watch's later ones do:
    /// no baseline, one conservative re-read. (A SpanDAC that never names one stays a
    /// no-op: `testAStatusThatNamesNoProcessIsANoOp`.)
    func testAnUnsupportedPreWalkStatusFallsBackToOneConservativeReread() {
        let server = Server(artists("ar1"))
        server.unsupportedStatus(at: 0)
        let rig = loadedRig(server, showing: "Artist ar1", baseline: true)
        run(rig, from: 0, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 2)
    }

    /// A status read that does not answer in time does not hold the first page; its
    /// late answer is no baseline, and the list gets its one conservative re-read.
    func testASlowPreWalkStatusDoesNotHoldTheFirstPage() {
        let server = Server(artists("ar1"))
        server.hold(Self.statusOp, at: 0)
        let rig = Rig(server)
        XCTAssertTrue(settleScene(rig.scene, seconds: 5) { server.reached(Self.artistsOp, at: 0) },
                      "the first page waited on a status read that had not answered")
        XCTAssertEqual(server.held(Self.statusOp), 1, "the status read answered after all")
        XCTAssertTrue(settleScene(rig.scene) { self.shows(rig, "Artist ar1") })
        server.release(Self.statusOp, at: 0)
        XCTAssertTrue(waitUntil { rig.statusEnded.count == 1 })
        run(rig, from: 0, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "a late answer was taken as the walk's checkpoint")
    }

    /// The live sequence of 2026-10-27 16:01:39 (SpanDAC log): the first read after the
    /// snapshot passed its 600 s refresh age started a drain, so the walk's pages came
    /// back flagged and the feed's own re-ask (unchanged since 3.23.0) probed page 1 at
    /// its interval until the drain landed, then walked the list again. The drain's
    /// ticket ending is a newer checkpoint than the one taken before the walk: ONE
    /// re-read after the re-ask, then nothing. A bounded sequence, not a loop.
    func testAColdSnapshotsDrainProbesThenRereadsOnceAndStops() {
        let server = Server((1...725).map { (id: "ar\($0)", name: "Artist \($0)") })
        server.pageSize = 100
        let instance = "9CFA0525-0000-0000-0000-000000000000"
        server.setStatus(instance: instance, completion: (instance, 8, "installed"))
        server.setDraining(true)
        server.drainLandsAt = 11          // the walk (0-7), three flagged probes (8-10), then clean
        let rig = loadedRig(server, showing: "Artist 1", baseline: true)
        // The walk, the probes, the clean probe and the re-ask's re-walk (12-19).
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 0); return server.count(Self.artistsOp) >= 20 },
                      "the re-ask never re-walked after the drain")
        run(rig, from: 0.5, to: 60)
        XCTAssertTrue(rig.scene.artistsFeedForTest.waitForWorkersForTest(timeout: 5))
        run(rig, from: 60.5, to: 120)
        XCTAssertEqual(server.count(Self.artistsOp), 28, "the drain's ending earned other than exactly one re-read")
    }

    // MARK: - the checkpoint and the one re-read it earns

    /// No Albums opened, no covers anywhere: the Artists list on its own sees a
    /// completed refresh and reads itself again once, with real-shaped pages that
    /// carry no instance.
    func testAnArtistsOnlyViewReadsItselfAgainOnceARefreshCompletes() {
        let server = Server(artists("ar1", "ar2"))
        let rig = loadedRig(server, showing: "Artist ar2")
        XCTAssertEqual(server.count(Self.artistsOp), 1)

        // The first checkpoint over rows read before any: one conservative re-read.
        tick(rig, at: 0)
        XCTAssertEqual(server.count(Self.statusOp), 2, "the watch did not read SpanDAC's status at once")
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1), "the first checkpoint never read the list again")

        // Nothing changed: status reads every five seconds, and no list read.
        run(rig, from: 1, to: 14)
        XCTAssertEqual(server.count(Self.statusOp), 4, "the status was not read every five seconds")
        XCTAssertEqual(server.count(Self.artistsOp), 2, "an unchanged status read the list again")

        // SpanDAC finishes a refresh; the person's library has a new artist.
        server.setArtists(artists("ar0", "ar1", "ar2"), generation: 4)
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        run(rig, from: 14.5, to: 21)
        XCTAssertTrue(artistsRead(rig, at: 21, 2), "the completed refresh never read the list again")
        XCTAssertTrue(shows(rig, "Artist ar0"), "the re-read's rows never landed")

        run(rig, from: 21.5, to: 60)
        XCTAssertEqual(server.count(Self.artistsOp), 3, "one completion, one re-read")
        XCTAssertGreaterThan(server.count(Self.statusOp), 9)
        XCTAssertEqual(server.held(Self.statusOp), 0)
    }

    /// An unchanged status, however long it is watched, reads nothing more, even when
    /// another list's pages carry a higher generation (Albums answer the core one,
    /// Artists the full one): generations are never compared.
    func testAnUnchangedStatusReadsNothingMoreAndGenerationsAreNeverCompared() {
        let server = Server(artists("ar1", "ar2"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar2")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        server.setArtists(artists("ar1", "ar2"), generation: 8)
        run(rig, from: 1, to: 120)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "an unchanged checkpoint read the list again")
        XCTAssertGreaterThanOrEqual(server.count(Self.statusOp), 20)
    }

    /// A restart: a new process whose rebuild record is still null, then one whose
    /// first rebuild reuses the old process's ticket number, under a list whose
    /// generation number repeats too. Each is a checkpoint of its own.
    func testARestartWithRepeatedNumbersAndNoCompletionYetIsReadForEachCheckpoint() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))

        server.setStatus(instance: Self.instanceB, completion: nil)   // restarted, nothing ended yet
        server.setArtists(artists("ar1", "ar2"), generation: 3)
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2), "the restart never read the list again")
        XCTAssertTrue(shows(rig, "Artist ar2"))

        server.setStatus(instance: Self.instanceB, completion: (Self.instanceB, 7, "installed"))
        server.setArtists(artists("ar1", "ar2", "ar3"), generation: 3)
        XCTAssertTrue(artistsRead(rig, at: 10.5, 3), "the new process's ticket 7 was taken for the old one's")
        XCTAssertTrue(shows(rig, "Artist ar3"))

        run(rig, from: 11, to: 40)
        XCTAssertEqual(server.count(Self.artistsOp), 4)
    }

    /// A rebuild that failed or was cancelled is still a new ending: read conservatively.
    func testAFailedRebuildIsReadForConservatively() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "cancelled"))
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2))
        run(rig, from: 6, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 3)
    }

    /// The checkpoint is captured before the read: a completion seen while that read is
    /// held stays due, and earns exactly one more read once the held one has ended.
    func testACompletionSeenDuringAHeldRereadStaysDueAndEarnsExactlyOneMore() {
        let server = Server(artists("ar1"))
        let rig = loadedRig(server, showing: "Artist ar1")
        server.hold(Self.artistsOp, at: 1)
        tick(rig, at: 0)
        tick(rig, at: 0.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.artistsOp) == 1 }, "the conservative re-read never began")

        // A refresh completes while that read is held; the watch sees it.
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.setArtists(artists("ar1", "ar9"))
        run(rig, from: 1, to: 12)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "a second read went out beside the held one")

        server.release(Self.artistsOp, at: 1)
        XCTAssertTrue(artistsRead(rig, at: 12.5, 2), "the completion seen during the held read was lost")
        XCTAssertTrue(shows(rig, "Artist ar9"))
        run(rig, from: 13, to: 40)
        XCTAssertEqual(server.count(Self.artistsOp), 3, "exactly one more read")
    }

    // MARK: - bounds

    /// A status read that fails backs off (15, 45, then 60 seconds, capped), never a
    /// tick-rate loop, and once it answers again the watch carries on.
    func testAFailingStatusReadBacksOffToABoundedRate() {
        let server = Server(artists("ar1"))
        server.failStatus(true)
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)                                            // read 1 fails
        run(rig, from: 0.5, to: 14.5)
        XCTAssertEqual(server.count(Self.statusOp), 2, "a failed status read was asked again inside 15 s")
        run(rig, from: 15, to: 15.5)
        XCTAssertEqual(server.count(Self.statusOp), 3)
        run(rig, from: 16, to: 60)
        XCTAssertEqual(server.count(Self.statusOp), 3, "the second failure did not back off to 45 s")
        run(rig, from: 60.5, to: 61)
        XCTAssertEqual(server.count(Self.statusOp), 4)
        // Then every 60 seconds (and a half: the reply is taken on the next tick).
        run(rig, from: 61.5, to: 245)
        XCTAssertEqual(server.count(Self.statusOp), 7, "the backoff was not capped at 60 s")
        XCTAssertEqual(server.count(Self.artistsOp), 1, "a failed status read the list again")

        server.failStatus(false)
        run(rig, from: 245.5, to: 310)
        XCTAssertTrue(artistsRead(rig, at: 310, 1), "the watch never recovered once SpanDAC answered")
    }

    /// A re-read that fails is retried after 5, 15 and 45 seconds and then is spent for
    /// that checkpoint, however many status reads repeat it; a new checkpoint is heard.
    func testAFailedRereadIsRetriedABoundedFewTimesPerCheckpoint() {
        let server = Server(artists("ar1"))
        for n in 1...4 { server.fail(Self.artistsOp, at: n) }
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        run(rig, from: 1, to: 5)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "a retry did not wait out its delay")
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2))
        run(rig, from: 6, to: 20)
        XCTAssertEqual(server.count(Self.artistsOp), 3)
        XCTAssertTrue(artistsRead(rig, at: 20.5, 3))
        run(rig, from: 21, to: 65)
        XCTAssertEqual(server.count(Self.artistsOp), 4)
        XCTAssertTrue(artistsRead(rig, at: 65.5, 4))
        run(rig, from: 66, to: 300)
        XCTAssertEqual(server.count(Self.artistsOp), 5, "spent: no fifth retry for the same checkpoint")
        XCTAssertTrue(shows(rig, "Artist ar1"), "a failed re-read touched the rows on screen")
        XCTAssertFalse(shows(rig, "SpanDAC couldn't"), "a failed automatic re-read spoke to the person")

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 9, "installed"))
        server.setArtists(artists("ar1", "ar5"))
        XCTAssertTrue(artistsRead(rig, at: 305.5, 5), "a new checkpoint after a spent one was not heard")
        XCTAssertTrue(shows(rig, "Artist ar5"))
    }

    /// An older SpanDAC whose status names no process: nothing to watch. No re-read and
    /// no further status reads while the view stays up; one more read on coming back.
    func testAStatusThatNamesNoProcessIsANoOp() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: nil, completion: nil)
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        run(rig, from: 0.5, to: 60)
        XCTAssertEqual(server.count(Self.statusOp), 2, "an unsupported status was polled again")
        XCTAssertEqual(server.count(Self.artistsOp), 1, "an unsupported status read the list again")
        goToSubView(rig.scene, .albums)
        run(rig, from: 60.5, to: 61)
        goToSubView(rig.scene, .artists)
        run(rig, from: 61.5, to: 120)
        XCTAssertEqual(server.count(Self.statusOp), 3)
        XCTAssertEqual(server.count(Self.artistsOp), 1)
    }

    // MARK: - leaving the view, the tab or the library

    /// Off the Artists sub-view nothing is read; a status reply that was in flight when
    /// the view was left is dropped (it would have earned a read); coming back reads the
    /// status at once and only that fresh reply moves anything.
    func testLeavingTheViewDropsAHeldObservationAndComingBackReadsAtOnce() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.hold(Self.statusOp, at: 2)
        run(rig, from: 1, to: 5.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.statusOp) == 1 })
        goToSubView(rig.scene, .albums)
        tick(rig, at: 6)
        server.release(Self.statusOp, at: 2)
        XCTAssertTrue(settleScene(rig.scene) { server.ended(Self.statusOp, at: 2) && rig.statusEnded.count == 3 })
        run(rig, from: 6.5, to: 40)
        XCTAssertEqual(server.count(Self.statusOp), 3, "the status was read off the Artists view")
        XCTAssertEqual(server.count(Self.artistsOp), 2, "a reply that arrived off the view read the list")

        // Back on Artists: the first tick asks afresh and reads nothing on the old reply.
        server.hold(Self.statusOp, at: 3)
        goToSubView(rig.scene, .artists)
        tick(rig, at: 40.5)
        XCTAssertEqual(server.count(Self.statusOp), 4, "coming back did not read the status at once")
        run(rig, from: 41, to: 43)
        XCTAssertEqual(server.count(Self.artistsOp), 2, "the dropped reply was acted on")
        server.release(Self.statusOp, at: 3)
        XCTAssertTrue(artistsRead(rig, at: 43.5, 2), "the fresh reply never read the list")
    }

    /// A status read asked before the view was left that only answers after it is back:
    /// that reply belongs to the watch that stopped and is dropped (it would have earned
    /// a read); one read at a time still holds, and only the fresh read moves anything.
    func testAReplyAskedBeforeLeavingThatLandsAfterComingBackIsDropped() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.hold(Self.statusOp, at: 2)
        run(rig, from: 1, to: 5.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.statusOp) == 1 })
        goToSubView(rig.scene, .albums)
        tick(rig, at: 6)
        goToSubView(rig.scene, .artists)
        tick(rig, at: 6.5)
        XCTAssertEqual(server.count(Self.statusOp), 3, "a second status read went out beside the held one")

        server.hold(Self.statusOp, at: 3)
        server.release(Self.statusOp, at: 2)
        XCTAssertTrue(waitUntil { rig.statusEnded.count == 3 })
        run(rig, from: 7, to: 9)
        XCTAssertEqual(server.count(Self.statusOp), 4, "the fresh read did not follow the old one's end")
        XCTAssertEqual(server.count(Self.artistsOp), 2, "the reply from before leaving was acted on")
        server.release(Self.statusOp, at: 3)
        XCTAssertTrue(artistsRead(rig, at: 9.5, 2), "the fresh reply never read the list")
    }

    /// Back on the tab before the next read was due: it is read at once all the same.
    func testComingBackToTheTabReadsAtOnceEvenBeforeTheNextReadIsDue() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        run(rig, from: 1, to: 5.5)                          // a read at 5 or 5.5, taken by 6
        tick(rig, at: 6)
        let before = server.count(Self.statusOp)
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        tick(rig, at: 10)                                    // four seconds off the tab; the next read is due at 11
        XCTAssertEqual(server.count(Self.statusOp), before + 1, "coming back to the tab waited for the interval")
        XCTAssertTrue(artistsRead(rig, at: 10.5, 2))
    }

    /// The tab stops ticking while a status read is out: its reply is dropped, and the
    /// first tick back reads the status again at once.
    func testLeavingTheTabDropsAHeldObservationAndComingBackReadsAtOnce() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.hold(Self.statusOp, at: 2)
        run(rig, from: 1, to: 5.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.statusOp) == 1 })
        rig.clock.t = 30                                   // the tab is not ticking
        server.release(Self.statusOp, at: 2)
        XCTAssertTrue(waitUntil { rig.statusEnded.count == 3 })
        XCTAssertEqual(server.count(Self.artistsOp), 2)

        server.hold(Self.statusOp, at: 3)
        tick(rig, at: 30)                                  // back on the tab
        XCTAssertEqual(server.count(Self.statusOp), 4, "coming back to the tab did not read the status at once")
        XCTAssertEqual(server.count(Self.artistsOp), 2, "the reply that landed off the tab was acted on")
        server.release(Self.statusOp, at: 3)
        XCTAssertTrue(artistsRead(rig, at: 30.5, 2))
    }

    /// A switch of data source while a status read is out: the list resets, the reply is
    /// dropped, and with Music.app selected the status is never read.
    func testAProvenanceChangeDropsAHeldObservation() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.hold(Self.statusOp, at: 2)
        run(rig, from: 1, to: 5.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.statusOp) == 1 })

        rig.flag.selected = false
        tick(rig, at: 6)
        server.release(Self.statusOp, at: 2)
        XCTAssertTrue(settleScene(rig.scene, seconds: 5) { rig.statusEnded.count == 3 })
        run(rig, from: 6.5, to: 40)
        XCTAssertEqual(server.count(Self.statusOp), 3, "the status was read with Music.app selected")
        XCTAssertEqual(server.count(Self.artistsOp), 2, "the dropped reply read SpanDAC's list")
    }

    /// Away to Music.app and back: the list is read afresh and its watch starts from
    /// nothing. With no checkpoint before the fresh walk (its status read fails), even
    /// a checkpoint the old list was read for earns the new list its one conservative
    /// read: the record went with the list.
    func testAProvenanceRoundTripWatchesTheReloadedListFromScratch() {
        let server = Server(artists("ar1"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar1")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        rig.flag.selected = false
        run(rig, from: 1, to: 2)
        server.fail(Self.statusOp, at: server.count(Self.statusOp))   // the fresh walk's own status read
        rig.flag.selected = true
        server.setArtists(artists("ar1", "ar2"))
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 2.5); return self.shows(rig, "Artist ar2") })
        XCTAssertEqual(server.count(Self.artistsOp), 3, "the switch back did not walk the list afresh")
        XCTAssertTrue(artistsRead(rig, at: 3, 3), "the reloaded list's first checkpoint was taken as read")
        run(rig, from: 3.5, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 4)
    }

    // MARK: - claims handed back

    /// The first walk came back while SpanDAC was still draining, so the list's own
    /// re-ask is waiting: the watch's read JOINS it (nothing started, the claim handed
    /// back at once) and, once the re-ask has landed, reads exactly once more for the
    /// checkpoint it never satisfied.
    func testAJoinedReaskHandsTheClaimBackAndOneReadFollowsTheDrain() {
        final class HeldSleep {
            private let lock = NSLock(); private let gate = DispatchSemaphore(value: 0)
            private var open = false; private var count = 0
            var entered: Int { lock.lock(); defer { lock.unlock() }; return count }
            func sleep(_ s: TimeInterval) {
                lock.lock(); count += 1; let passes = open; lock.unlock()
                if !passes { _ = gate.wait(timeout: .now() + 10) }
            }
            func openAll() { lock.lock(); open = true; lock.unlock(); for _ in 0..<8 { gate.signal() } }
        }
        let held = HeldSleep()
        defer { held.openAll() }
        let server = Server(artists("ar1"))
        server.setDraining(true)
        let rig = loadedRig(server, showing: "Artist ar1", warmUpSleep: held.sleep)
        XCTAssertTrue(settleScene(rig.scene) { held.entered == 1 }, "the walk's own re-ask never began")

        tick(rig, at: 0)
        tick(rig, at: 0.5)                                 // the checkpoint: the read joins the re-ask
        let checkpoint = LibraryCoverFetcher.ListReread.Reason.refreshed(instance: Self.instanceA, ticket: nil)
        XCTAssertTrue(rig.scene.artistsRereadForTest.due(checkpoint, now: rig.clock.date).any,
                      "a joined read left its claim standing")
        run(rig, from: 1, to: 3)
        XCTAssertEqual(server.count(Self.artistsOp), 1, "a walk went out beside the list's own re-ask")

        server.setDraining(false)
        server.setArtists(artists("ar1", "ar2"))
        held.openAll()
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 3.5); return self.shows(rig, "Artist ar2") })
        // The walk, the re-ask's probe and its re-walk, then ONE read for the checkpoint
        // the joined ask never satisfied: it is due again as soon as the feed is idle.
        XCTAssertTrue(artistsRead(rig, at: 4, 3), "the unsatisfied checkpoint never read once more")
        run(rig, from: 4.5, to: 30)
        XCTAssertEqual(server.count(Self.artistsOp), 4, "more than one read after the drain")
    }

    /// A refresh a person asks for (`BridgeListFeed.refresh` without `joinReask`; Artists
    /// has no key for it, so the test makes the call) takes the automatic read over, and
    /// its claim is handed back at once rather than after the in-flight bound.
    func testAPersonsRefreshTakesOverTheAutomaticReadAndItsClaimIsReleasedAtOnce() {
        let server = Server(artists("ar1"))
        let rig = loadedRig(server, showing: "Artist ar1")
        server.hold(Self.artistsOp, at: 1)
        tick(rig, at: 0)
        tick(rig, at: 0.5)
        XCTAssertTrue(settleScene(rig.scene) { server.held(Self.artistsOp) == 1 }, "the automatic read never began")
        let checkpoint = LibraryCoverFetcher.ListReread.Reason.refreshed(instance: Self.instanceA, ticket: nil)
        XCTAssertFalse(rig.scene.artistsRereadForTest.due(checkpoint, now: rig.clock.date).any)

        server.setArtists(artists("ar1", "arMINE"))
        let claim = rig.scene.artistsFeedForTest.refresh()
        XCTAssertEqual(claim, .tookOver)
        XCTAssertTrue(rig.scene.artistsRereadForTest.due(checkpoint, now: rig.clock.date).any,
                      "the displaced read's claim was not released until its bound")
        server.release(Self.artistsOp, at: 1)
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 1); return self.shows(rig, "Artist arMINE") })
        XCTAssertTrue(rig.scene.artistsFeedForTest.waitForWorkersForTest(timeout: 5))
    }

    /// A failed Artists walk is not watched (nothing is on screen to keep fresh); the
    /// person's `r` resets the feed AND the re-read record together, and the recovered
    /// list is watched from scratch. The failed walk had a checkpoint (its status read
    /// answered); the fresh walk's status read fails, so only the reset lets the
    /// recovered list earn its one conservative read, then nothing.
    func testAFailedWalkIsNotWatchedAndRRecoversWithAFreshWatch() {
        let server = Server(artists("ar1"))
        server.fail(Self.artistsOp, at: 0)
        server.fail(Self.statusOp, at: 1)
        let rig = Rig(server)
        XCTAssertTrue(settleScene(rig.scene) { self.shows(rig, "scripted failure") || self.shows(rig, "SpanDAC") })
        XCTAssertTrue(settleScene(rig.scene) { server.ended(Self.artistsOp, at: 0) })
        run(rig, from: 0, to: 20)
        XCTAssertEqual(server.count(Self.statusOp), 1, "a failed list was watched (only the walk's own status read)")

        _ = rig.scene.handle(.char("r"))
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 20.5); return self.shows(rig, "Artist ar1") })
        XCTAssertTrue(artistsRead(rig, at: 21, 2), "the recovered list was never read for its first checkpoint")
        run(rig, from: 21.5, to: 50)
        XCTAssertEqual(server.count(Self.artistsOp), 3)
        let checkpoint = LibraryCoverFetcher.ListReread.Reason.refreshed(instance: Self.instanceA, ticket: nil)
        XCTAssertFalse(rig.scene.artistsRereadForTest.due(checkpoint, now: rig.clock.date).any)
    }

    // MARK: - where the cursor is when the replacement lands

    func testTheRootCursorStaysOnItsArtistAcrossTheReread() {
        let server = Server(artists("ar1", "ar2", "ar3"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar3")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        _ = rig.scene.handle(.down)
        XCTAssertEqual(rig.scene.selectionIDForTest, "ar2")

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.setArtists(artists("ar0", "arA", "ar1", "ar2", "ar3"))
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2))
        XCTAssertTrue(shows(rig, "Artist ar0"))
        XCTAssertEqual(rig.scene.selectionIDForTest, "ar2", "the cursor stayed on a row index, not its artist")
    }

    func testAFilteredRootCursorStaysOnItsArtistAcrossTheReread() {
        let server = Server([(id: "ar1", name: "Portishead"), (id: "ar2", name: "Pulp"), (id: "ar3", name: "Radiohead")])
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Radiohead")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        _ = rig.scene.handle(.char("/"))
        _ = rig.scene.handle(.char("P"))
        _ = rig.scene.handle(.enter)
        _ = rig.scene.handle(.down)
        XCTAssertEqual(rig.scene.selectionIDForTest, "ar2")

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.setArtists([(id: "ar0", name: "Pantera"), (id: "ar1", name: "Portishead"),
                           (id: "ar2", name: "Pulp"), (id: "ar3", name: "Radiohead")])
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2))
        XCTAssertTrue(shows(rig, "Pantera"))
        XCTAssertEqual(rig.scene.selectionIDForTest, "ar2", "the filtered cursor stayed on a row index")
    }

    /// Drilled into an artist when the replacement lands: the open artist's albums are
    /// neither read again nor touched, and Back lands on the opened artist by id.
    func testARereadUnderAnOpenArtistLeavesItAloneAndBackFindsItById() {
        let server = Server(artists("ar1", "ar2", "ar3"))
        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 7, "installed"))
        let rig = loadedRig(server, showing: "Artist ar3")
        tick(rig, at: 0)
        XCTAssertTrue(artistsRead(rig, at: 0.5, 1))
        _ = rig.scene.handle(.down)
        _ = rig.scene.handle(.enter)
        XCTAssertTrue(settleScene(rig.scene) { self.tick(rig, at: 1); return rig.scene.artistAlbumsForTest.map(\.id) == ["al1"] })
        XCTAssertEqual(server.count("slice.libraryArtistAlbums"), 1)
        let level = rig.scene.levelForTest

        server.setStatus(instance: Self.instanceA, completion: (Self.instanceA, 8, "installed"))
        server.setArtists(artists("ar0", "arA", "ar1", "ar2", "ar3"))
        XCTAssertTrue(artistsRead(rig, at: 5.5, 2), "the watch did not run under an open artist")
        run(rig, from: 6, to: 12)
        XCTAssertEqual(rig.scene.levelForTest, level, "the replacement moved the drill")
        XCTAssertEqual(rig.scene.artistAlbumsForTest.map(\.id), ["al1"])
        XCTAssertEqual(server.count("slice.libraryArtistAlbums"), 1, "the open artist's albums were read again")

        _ = rig.scene.handle(.left)
        XCTAssertEqual(rig.scene.selectionIDForTest, "ar2", "Back did not find the opened artist by id")
    }

    // MARK: - the record

    func testACheckpointIsReadForOnceAndANewOneIsDue() {
        let reread = LibraryCoverFetcher.ListReread()
        let at = Date(timeIntervalSinceReferenceDate: 0)
        let first = LibraryCoverFetcher.ListReread.Reason.refreshed(instance: "i", ticket: nil)
        let due = reread.due(first, now: at)
        XCTAssertEqual(due.reasons, [first])
        let ticket = reread.began(due, now: at)
        XCTAssertFalse(reread.due(first, now: at).any, "an attempt in flight was due again")
        XCTAssertTrue(reread.due(.refreshed(instance: "i", ticket: 1), now: at).any, "a newer checkpoint waited behind it")
        reread.finished(ticket, succeeded: true)
        XCTAssertFalse(reread.due(first, now: at.addingTimeInterval(10_000)).any, "a checkpoint read for was due again")
    }
}

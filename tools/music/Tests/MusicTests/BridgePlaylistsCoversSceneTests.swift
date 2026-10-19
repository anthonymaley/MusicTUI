import CryptoKit
import XCTest
@testable import music

/// C4: the Playlists tab's top-level Bridge hero draws SpanDAC's cover. A scripted
/// SpanDAC behind the shell's one `LibraryCoverFetcher` (fake clock, inline lanes,
/// temp cache directory), an injected `ArtworkStore` render, and the same wire
/// the other Bridge Playlists scene tests use: no real socket, playback or art cache.
final class BridgePlaylistsCoversSceneTests: XCTestCase {

    private typealias Clock = LibraryCoverFetcherTests.Clock
    private typealias Lanes = LibraryCoverFetcherTests.Lanes
    private typealias FakeSpanDAC = LibraryCoverFetcherTests.FakeSpanDAC

    private static let instanceA = LibraryCoverFetcherTests.instanceA
    private static let instanceB = LibraryCoverFetcherTests.instanceB
    private static let marker = "COVERMARK"

    private let frame = shellLayout(width: 110, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func page(generation: Int = 3, instance: String? = BridgePlaylistsCoversSceneTests.instanceA,
                      flagged: Bool = false, leading: String? = nil) -> String {
        let inst = instance.map { ",\"library_instance\":\"\($0)\"" } ?? ""
        let first = leading.map { "{\"id\":\"pl0\",\"title\":\"\($0)\",\"kind\":\"playlist\"}," } ?? ""
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":\(generation),"total":\(leading == nil ? 2 : 3),"stale":\(flagged),"refreshing":\(flagged),
         "items":[\(first){"id":"pl1","title":"Top 25 Most Played","kind":"playlist"},
                  {"id":"pl2","title":"Road Trip","kind":"playlist"}],
         "next_cursor":null\(inst)}
        """
    }

    /// A Bridge Playlists scene wired to a fetcher whose SpanDAC holds a cover for `pl1`.
    private final class Rig {
        let clock = Clock()
        let lanes = Lanes()
        let spandac: FakeSpanDAC
        let wire: BridgeLibraryReadsWire
        let flag = BridgeSelectedFlag(true)
        let dir: String
        let routing: RoutingCoordinator
        let statusStore = StatusStore()
        let fetcher: LibraryCoverFetcher
        let scene: PlaylistsScene

        init(pages: [String], withFetcher: Bool = true, warmUpSleep: @escaping (TimeInterval) -> Void = { _ in },
             width: Int = 110) {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("playlist-covers-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            spandac = FakeSpanDAC(clock: clock)
            spandac.covers["playlist|pl1"] = LibraryCoverFetcherTests.payload(40_000)
            wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": pages])
            let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
            store.set(.source)
            let wire = self.wire
            let routing = RoutingCoordinator(store: store, surface: .tui,
                                             makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
            self.routing = routing
            fetcher = LibraryCoverFetcher(provider: { [spandac] in spandac }, dataEpoch: { routing.dataEpoch },
                                          cacheDir: dir, now: { [clock] in clock.date },
                                          queue: { [lanes] lane, job in lanes.submit(lane, job) })
            fetcher.observeShell(active: .playlists, dataEpoch: routing.dataEpoch)
            let flag = self.flag
            let store2 = ArtworkStore(cacheDir: dir, fetch: { _ in nil },
                                      render: { _, _, h in Array(repeating: BridgePlaylistsCoversSceneTests.marker, count: h) })
            scene = PlaylistsScene(
                backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                playlists: [], sources: .empty,
                appQueue: AppQueueStore(), status: statusStore, actions: ActionRunner(status: StatusStore()),
                // A temporary metadata cache, never the real one.
                metaCache: temporaryPlaylistMetaCache().cache,
                libraryCovers: withFetcher ? fetcher : nil,
                artwork: store2,
                makeProvider: {
                    flag.selected
                        ? BridgeMusicProvider(control: SourceAppControl(
                            path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                        : nil
                },
                warmUpSleep: warmUpSleep,
                // The scene's own clock is the fake one, so a retry's delay is read off it.
                now: { [clock] in clock.date },
                screenWidth: { width })
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func settleRows(_ rig: Rig) {
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip") },
                      "the rail never showed")
    }

    /// One scene tick at fake time `t`.
    @discardableResult
    private func tick(_ rig: Rig, at t: TimeInterval) -> Bool {
        rig.clock.t = t
        return rig.scene.tick(snapshot: idle)
    }

    // MARK: -

    func testABridgePlaylistHeroDrawsItsInstalledCover() {
        let rig = Rig(pages: [page()])
        settleRows(rig)
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker), "no cover yet")
        tick(rig, at: 0.25)
        XCTAssertEqual(rig.spandac.firstRequests.count, 1)
        // ArtworkStore renders off the main thread; the scene repaints once it lands.
        var out = ""
        XCTAssertTrue(settleScene(rig.scene) {
            out = rig.scene.render(frame: frame, snapshot: idle)
            return out.contains(Self.marker)
        }, "the installed cover never reached the hero")
        // Geometry is the gradient's: the cover and the hint line sit where they did.
        XCTAssertTrue(out.contains("[Enter]"))
    }

    func testWithNoCoverTheBridgeHeroIsByteIdenticalToToday() {
        // Captured from the code before this step (same scene, same wire, same frame):
        // the whole two-zone frame, SHA-256 and byte count.
        let expected = "4c739f6f4176278a4c85df39d3ac6caa83699bd35dc016faa04361ae664d7071"
        let page = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl1","title":"Top 25 Most Played","kind":"playlist"},
                  {"id":"pl2","title":"Road Trip","kind":"playlist"}],
         "next_cursor":null,"library_instance":"inst-A"}
        """
        let rig = Rig(pages: [page])
        settleRows(rig)
        let out = rig.scene.render(frame: frame, snapshot: idle)
        XCTAssertEqual(out.utf8.count, 3148)
        XCTAssertEqual(SHA256.hash(data: Data(out.utf8)).map { String(format: "%02x", $0) }.joined(), expected)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
    }

    func testTheFocusedPlaylistIsAskedForWithItsPagesGeneration() {
        let rig = Rig(pages: [page(generation: 7)])
        settleRows(rig)
        tick(rig, at: 0.25)
        let request = rig.spandac.firstRequests.first
        XCTAssertEqual(rig.spandac.firstRequests.count, 1)
        XCTAssertEqual(request?.kind, .playlist)
        XCTAssertEqual(request?.id, "pl1")
        XCTAssertEqual(request?.generation, 7)
        XCTAssertEqual(request?.libraryInstance, Self.instanceA)
    }

    func testLeavingTheBridgeRailStopsAsking() {
        let rig = Rig(pages: [page()])
        settleRows(rig)
        rig.flag.selected = false   // the output moves off SpanDAC before the rest ends
        tick(rig, at: 0.25)
        tick(rig, at: 1)
        tick(rig, at: 6)
        XCTAssertTrue(rig.spandac.statusReadTimes.isEmpty, "a readiness read for a rail that is gone")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertNil(rig.fetcher.cover(for: LibraryCoverFetcher.Target(
            owner: .playlists, kind: .playlist, id: "pl1", generation: 3,
            libraryInstance: Self.instanceA, dataEpoch: rig.routing.dataEpoch)))
    }

    func testALandingRepaints() {
        let rig = Rig(pages: [page()])
        settleRows(rig)
        XCTAssertTrue(tick(rig, at: 0.25), "an install must make the tab repaint")
        XCTAssertFalse(tick(rig, at: 0.26), "nothing changed since")
    }

    func testTheTargetCarriesTheAppliedPagesInstance() {
        // Instance A applied -> A asked. A stale-snapshot re-ask replacement read
        // under B, applied -> B asked. Held between the two so A is what is on screen.
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA, flagged: true),
                              page(generation: 4, instance: Self.instanceB),
                              page(generation: 4, instance: Self.instanceB),
                              page(generation: 4, instance: Self.instanceB),
                              page(generation: 4, instance: Self.instanceB)])
        // Four reads follow the first, not one (measured: four reads in all, every
        // run). Which of them lands the rows is a scheduling race, so every read past
        // the first answers with B. A script of three left a late read with an
        // "unscripted" error and the list on A.
        rig.wire.gate(op: "slice.libraryPlaylists", at: 1)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [3])

        // The flagged page's replacement read is the gated call: wait for it to be
        // IN FLIGHT, so readiness never changes before it started (the order is not
        // otherwise fixed, and which read lands the replacement depends on it).
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.reached(op: "slice.libraryPlaylists", at: 1) },
                      "the replacement read was never issued")
        rig.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        rig.wire.release(op: "slice.libraryPlaylists", at: 1)
        // The replacement lands on a later tick; a changed target restarts the rest.
        var t = 10.0
        XCTAssertTrue(settleScene(rig.scene) {
            t += 0.25
            self.tick(rig, at: t)
            return rig.spandac.firstRequests.count >= 2
        }, "the replacement's target was never asked for")
        XCTAssertEqual(rig.spandac.firstRequests.last?.libraryInstance, Self.instanceB)
        XCTAssertEqual(rig.spandac.firstRequests.last?.generation, 4)

        // A page that states no instance names no target at all.
        let bare = Rig(pages: [page(instance: nil)])
        settleRows(bare)
        tick(bare, at: 0.25)
        tick(bare, at: 6)
        XCTAssertTrue(bare.spandac.statusReadTimes.isEmpty)
        XCTAssertTrue(bare.spandac.firstRequests.isEmpty)
    }

    // MARK: - SpanDAC restarted under the Playlists list

    private func restartSpanDAC(_ rig: Rig) {
        rig.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
    }

    /// Ticks at fake times from `from`, every 0.25 s, until `done` (the re-read lands on a feed thread).
    private func tickUntil(_ rig: Rig, from: Double, _ done: () -> Bool) -> Bool {
        var t = from
        return settleScene(rig.scene) {
            t += 0.25
            self.tick(rig, at: t)
            return done()
        }
    }

    func testARestartedSpanDACRereadsThePlaylistsOnceAndTheNextRestGetsACover() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)   // the rest ends: readiness names B, the list is under A
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 1, "a focused row on the old list must still read readiness")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "nothing is asked under the old instance")
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count == 2
                                                && rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") },
                      "the restart never made the scene read its playlists again")

        XCTAssertTrue(tickUntil(rig, from: 10) { !rig.spandac.firstRequests.isEmpty }, "the new list's row was never asked for")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [4])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl1"])
        var out = ""
        XCTAssertTrue(settleScene(rig.scene) {
            out = rig.scene.render(frame: frame, snapshot: idle)
            return out.contains(Self.marker)
        }, "the cover never reached the hero")
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "exactly one re-read")
        XCTAssertEqual(rig.wire.sent("slice.libraryRefresh").count, 0, "the re-read must not ask SpanDAC to rebuild")
    }

    func testTheRestartRereadSaysNothingOnTheStatusLine() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
        XCTAssertEqual(rig.statusStore.current()?.text, before, "the re-read posted to the status line")
    }

    func testAPlaylistsRereadThatStillCarriesTheOldInstanceDoesNotLoop() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 3, instance: Self.instanceA),
                              page(generation: 3, instance: Self.instanceA)])
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count == 2 })
        for step in 0..<40 { tick(rig, at: 1 + Double(step)); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "no loop on an unchanged instance")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
    }

    func testAPlaylistsRereadThatOnlyBumpsTheGenerationUnderTheOldInstanceDoesNotLoop() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceA),
                              page(generation: 5, instance: Self.instanceA),
                              page(generation: 6, instance: Self.instanceA)])
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count == 2 })
        for step in 0..<40 { tick(rig, at: 1 + Double(step)); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2)
    }

    /// Ticks at fake time `t` until request number `n` of the Playlists read has been served
    /// and its worker has ENDED (its outcome is recorded), then once more so the tick stamps
    /// a failure's retry time at `t`. No wall-time wait.
    private func attempt(_ rig: Rig, at t: TimeInterval, expecting n: Int) -> Bool {
        let op = "slice.libraryPlaylists"
        rig.clock.t = t
        let ok = settleScene(rig.scene) { rig.wire.sent(op).count >= n && rig.wire.threadEnded(op: op, at: n - 1) }
        tick(rig, at: t)
        return ok
    }

    private static let badReply =
        "{\"ok\":false,\"op\":\"slice.libraryPlaylists\",\"error\":{\"kind\":\"bad_request\",\"detail\":\"scripted failure\"}}"

    /// Ticks every fake second-ish between `from` and `to`: whatever it asks is in the count.
    private func quietCount(_ rig: Rig, from: Double, to: Double) -> Int {
        var t = from
        while t < to { tick(rig, at: t); t += (to - from) / 20 }
        usleep(100_000)
        return rig.wire.sent("slice.libraryPlaylists").count
    }

    func testAFailedPlaylistsRereadDoesNotLoopOrSpeak() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA)])   // the re-read is answered bad_request
        restartSpanDAC(rig)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2))
        XCTAssertEqual(quietCount(rig, from: 0.3, to: 5.2), 2, "a retry waits out its delay, never a tick")
        XCTAssertTrue(rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip"), "the list on screen is untouched")
        XCTAssertEqual(rig.statusStore.current()?.text, before)
    }

    func testAFailedPlaylistsRereadIsRetriedAfterADelayAndTheCoverFollows() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA), Self.badReply,
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2), "the restart never made the scene read again")
        XCTAssertEqual(quietCount(rig, from: 0.3, to: 5.2), 2, "the retry waits out its delay")
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3), "a failed read was never retried")
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") },
                      "the retry's replacement never landed")
        XCTAssertTrue(tickUntil(rig, from: 10) { !rig.spandac.firstRequests.isEmpty })
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB])
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker) },
                      "the cover never reached the hero")
        XCTAssertEqual(quietCount(rig, from: 30, to: 400), 3, "a read that succeeded is not asked again")
        XCTAssertEqual(rig.statusStore.current()?.text, before, "no status line at any point")
    }

    func testAFailedPlaylistsRereadIsRetriedAtMostABoundedFewTimes() {
        let bad = Self.badReply
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA), bad, bad, bad, bad,
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)
        // The first attempt, then retries 5, 15 and 45 seconds after each failure.
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2))
        XCTAssertEqual(quietCount(rig, from: 0.3, to: 5.2), 2)
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3))
        XCTAssertEqual(quietCount(rig, from: 5.5, to: 20.3), 3)
        XCTAssertTrue(attempt(rig, at: 20.5, expecting: 4))
        XCTAssertEqual(quietCount(rig, from: 20.6, to: 65.4), 4)
        XCTAssertTrue(attempt(rig, at: 65.6, expecting: 5))
        XCTAssertEqual(quietCount(rig, from: 66, to: 6_000), 5, "spent: no fifth retry however long it waits")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix"))
    }

    func testAProvenanceResetDuringAPlaylistsRetryForgetsItsDelayAndItsFailures() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA), Self.badReply,
                              page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2))   // failed: the retry waits until 5.25

        rig.flag.selected = false
        XCTAssertTrue(settleScene(rig.scene) { !rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip") })
        rig.flag.selected = true
        settleRows(rig)
        tick(rig, at: 1.0)
        tick(rig, at: 1.3)
        // Still long before 5.25, and the old list is read again at once.
        XCTAssertTrue(attempt(rig, at: 1.4, expecting: 4), "the reset left the old retry delay in force")
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
    }

    /// A `sleep` that holds its FIRST call until the test lets it go and says when it is
    /// held; every later call returns at once: the automatic re-read's wait on a flagged list.
    private final class FirstSleepGate {
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var held = false
        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
        func sleep(_ seconds: TimeInterval) {
            lock.lock(); calls += 1; let first = calls == 1; if first { held = true }; lock.unlock()
            guard first else { return }
            _ = release.wait(timeout: .now() + 10)
        }
        func open() { release.signal() }
    }

    /// The scene noticed a SpanDAC restart and read Playlists again by itself; the list
    /// it got back still says it is refreshing, so that read is waiting out the rest of
    /// the bound. A person's `r` then must not be told "already refreshing" with nothing
    /// sent: it takes the wait over, asks SpanDAC to rebuild, follows it, and lands its
    /// own rows; the displaced read's claim is released at once, and its late post and
    /// ending change nothing.
    func testRDuringAnAutomaticRereadWaitingOnAFlaggedListTakesItOverAndRefreshes() {
        let gate = FirstSleepGate()
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, flagged: true),   // the automatic read: still draining
                              page(generation: 5, instance: Self.instanceB, leading: "Aardvark Mix"),
                              page(generation: 5, instance: Self.instanceB, leading: "Late Mix")],   // the old worker, if it read again
                      warmUpSleep: gate.sleep)
        // SpanDAC lists `library.refresh`, starts ticket 7, and has already installed it.
        rig.wire.handler = { op, _ in
            switch op {
            case "slice.status":
                return "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"stopped\",\"capabilities\":[\"slice.status\",\"library.refresh\"],\"library_refresh\":{\"instance\":\"inst-1\",\"ticket\":7,\"result\":\"installed\"}}}"
            case "slice.libraryRefresh":
                return "{\"ok\":true,\"op\":\"slice.libraryRefresh\",\"outcome\":\"started\",\"ticket\":7,\"instance\":\"inst-1\"}"
            default: return nil
            }
        }
        let op = "slice.libraryPlaylists"
        rig.wire.gate(op: op, at: 2)   // the person's read, held while the claim is checked
        restartSpanDAC(rig)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { gate.isHeld }, "the automatic re-read never began waiting")
        XCTAssertTrue(rig.wire.sent("slice.libraryRefresh").isEmpty, "nothing was asked of SpanDAC yet")
        let applied = LibraryCoverFetcher.StaleList(generation: 3, libraryInstance: Self.instanceA)
        func due() -> Bool {
            rig.scene.playlistsRereadForTest.due(applied: applied, staleRefusal: nil, readyInstance: Self.instanceB,
                                                 now: rig.clock.date).any
        }
        XCTAssertFalse(due(), "the automatic read is in flight")

        _ = rig.scene.handle(.char("r"))
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.reached(op: op, at: 2) }, "the person's refresh never read the list")
        XCTAssertEqual(rig.wire.sent("slice.libraryRefresh").count, 1, "`r` sent no refresh request")
        XCTAssertNotEqual(rig.statusStore.current()?.text, "Already refreshing your playlists\u{2026}")
        XCTAssertTrue(due(), "the displaced read's claim was not released until its bound")

        rig.wire.release(op: op, at: 2)
        XCTAssertTrue(settleScene(rig.scene) {
            rig.statusStore.current()?.text == "Playlists refreshed. New playlists need a song; press r again."
        }, "the refresh never ended: \(rig.statusStore.current()?.text ?? "nothing")")
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
        gate.open()   // the old worker wakes up and finds it was taken over
        XCTAssertTrue(rig.scene.playlistsFeedForTest.waitForWorkersForTest(timeout: 5), "a worker never ended")
        tick(rig, at: 1.0)
        XCTAssertEqual(rig.wire.sent(op).count, 3, "the displaced worker read the list after it was taken over")
        XCTAssertEqual(rig.statusStore.current()?.text, "Playlists refreshed. New playlists need a song; press r again.",
                       "the displaced worker spoke after the takeover")
        let out = rig.scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Aardvark Mix") && !out.contains("Late Mix"), "the displaced worker's rows landed")
        XCTAssertEqual(rig.wire.sent("slice.libraryRefresh").count, 1)
    }

    func testTheCursorStaysOnTheSamePlaylistAcrossTheRestartReread() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")])
        restartSpanDAC(rig)
        settleRows(rig)
        _ = rig.scene.handle(.down)   // pl2
        tick(rig, at: 0.25)
        tick(rig, at: 0.6)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
        XCTAssertTrue(tickUntil(rig, from: 10) { !rig.spandac.firstRequests.isEmpty })
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl2"], "the cursor moved off the playlist")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB])
    }

    // MARK: - a refresh moved the snapshot under the Playlists list

    func testAStaleGenerationRefusalRereadsThePlaylistsOnceAndTheNextRestGetsACover() {
        let rig = Rig(pages: [page(generation: 1), page(generation: 2, leading: "Aardvark Mix")])
        rig.spandac.serverGeneration = 2
        settleRows(rig)
        tick(rig, at: 0.25)   // the rest ends: asked under generation 1, refused as stale
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1])
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count == 2
                                                && rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") },
                      "the stale refusal never made the scene read its playlists again")

        XCTAssertTrue(tickUntil(rig, from: 10) { rig.spandac.firstRequests.count >= 2 }, "the new list's row was never asked for")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1, 2])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl1", "pl1"])
        var out = ""
        XCTAssertTrue(settleScene(rig.scene) {
            out = rig.scene.render(frame: frame, snapshot: idle)
            return out.contains(Self.marker)
        }, "the cover never reached the hero")
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "exactly one re-read")
        XCTAssertEqual(rig.wire.sent("slice.libraryRefresh").count, 0, "the re-read must not ask SpanDAC to rebuild")
    }

    func testAStalePlaylistsRereadThatStillCarriesTheOldGenerationDoesNotLoop() {
        let rig = Rig(pages: [page(generation: 1), page(generation: 1), page(generation: 1)])
        rig.spandac.serverGeneration = 2
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count == 2 })
        for step in 0..<40 { tick(rig, at: 1 + Double(step)); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "no loop on an unchanged generation")
    }

    func testAFailedStalePlaylistsRereadIsRetriedAfterADelayAndSpeaksNothing() {
        let rig = Rig(pages: [page(generation: 1), Self.badReply, page(generation: 2, leading: "Aardvark Mix")])
        rig.spandac.serverGeneration = 2
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2))
        XCTAssertEqual(quietCount(rig, from: 0.3, to: 5.2), 2, "a retry waits out its delay, never a tick")
        XCTAssertTrue(rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip"))
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3), "a failed read was never retried")
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
        XCTAssertEqual(rig.statusStore.current()?.text, before)
    }

    func testTheCursorStaysOnTheSamePlaylistAcrossTheStaleRereadAndItsCoverIsAsked() {
        let rig = Rig(pages: [page(generation: 1), page(generation: 2, leading: "Aardvark Mix")])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["playlist|pl2"] = LibraryCoverFetcherTests.payload(40_000)
        settleRows(rig)
        _ = rig.scene.handle(.down)   // pl2
        tick(rig, at: 0.25)
        tick(rig, at: 0.6)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: frame, snapshot: idle).contains("Aardvark Mix") })
        XCTAssertTrue(tickUntil(rig, from: 10) { rig.spandac.firstRequests.count >= 2 })
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl2", "pl2"], "the cursor moved off the playlist")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1, 2])
    }

    // MARK: - a re-read that lands while the person is inside a playlist's tracks

    /// Wide enough for the tracks pane, which only the three-zone layout draws.
    private let wide = shellLayout(width: 138, height: 30)

    /// One playlist's tracks, `count` of them, ids `t01...`, titles `Song 01...`.
    private func trackPage(count: Int) -> String {
        let rows = (1...count).map {
            "{\"id\":\"t\(String(format: "%02d", $0))\",\"title\":\"Song \(String(format: "%02d", $0))\",\"artist\":\"Art\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":\(count),
         "items":[\(rows)],"next_cursor":null,"skipped_videos":0}
        """
    }

    /// A key, then a paint, as the app does (scroll follows the cursor at render time).
    private func press(_ rig: Rig, _ key: KeyPress, _ n: Int = 1) {
        for _ in 0..<n { _ = rig.scene.handle(key); _ = rig.scene.render(frame: wide, snapshot: idle) }
    }

    /// Drills into Road Trip (`pl2`), the second row, and moves down its tracks until the
    /// pane has scrolled. Returns what the person is looking at.
    private func drillIntoRoadTripAndScroll(_ rig: Rig) -> (titles: [String], cursor: Int, scroll: Int, reads: Int) {
        let tracksOp = "slice.libraryPlaylistTracks"
        press(rig, .down)                                   // Road Trip
        press(rig, .enter)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.drilledTrackTitlesForTest.count == 40 }, "the tracks never opened")
        XCTAssertEqual(rig.scene.drilledPlaylistIDForTest, "pl2")
        press(rig, .down, 30)
        XCTAssertEqual(rig.scene.trackCursorForTest, 30)
        XCTAssertGreaterThan(rig.scene.trackScrollForTest, 0, "the tracks pane never scrolled, so a reset would go unseen")
        return (rig.scene.drilledTrackTitlesForTest, rig.scene.trackCursorForTest, rig.scene.trackScrollForTest,
                rig.wire.sent(tracksOp).count)
    }

    private func assertTracksPaneUntouched(_ rig: Rig, _ was: (titles: [String], cursor: Int, scroll: Int, reads: Int),
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.scene.drilledPlaylistIDForTest, "pl2", "the tracks pane was yanked", file: file, line: line)
        XCTAssertEqual(rig.scene.drilledTrackTitlesForTest, was.titles, "the open tracks were replaced", file: file, line: line)
        XCTAssertEqual(rig.scene.trackCursorForTest, was.cursor, "the track selection moved", file: file, line: line)
        XCTAssertEqual(rig.scene.trackScrollForTest, was.scroll, "the tracks pane scrolled", file: file, line: line)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylistTracks").count, was.reads,
                       "the re-read of the list read the playlist's tracks again", file: file, line: line)
        // Still in the tracks pane: a render draws the selected track, and Down moves the track cursor.
        XCTAssertTrue(rig.scene.render(frame: wide, snapshot: idle).contains("Song \(String(format: "%02d", was.cursor + 1))"),
                      "the selected track is off screen", file: file, line: line)
    }

    /// SpanDAC restarted while the person was reading the list; the scene's own re-read is in
    /// flight (held) when they open Road Trip and scroll down its tracks. The re-read's rows
    /// land under the open pane: the pane, its rows, its selection and its scroll are
    /// untouched; the rail cursor has followed Road Trip to its new row; and the list the
    /// person returns to is the new one, on the same playlist.
    func testARestartRereadLandingInsideAPlaylistLeavesTheTracksPaneAndUpdatesTheListOnReturn() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA),
                              page(generation: 4, instance: Self.instanceB, leading: "Aardvark Mix")], width: 138)
        rig.wire.script("slice.libraryPlaylistTracks", Array(repeating: trackPage(count: 40), count: 6))   // previews and the drill-in read it
        let listOp = "slice.libraryPlaylists"
        rig.wire.gate(op: listOp, at: 1)
        restartSpanDAC(rig)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.reached(op: listOp, at: 1) }, "the re-read never began")

        let was = drillIntoRoadTripAndScroll(rig)
        XCTAssertEqual(rig.scene.railNamesForTest, ["Top 25 Most Played", "Road Trip"], "the re-read landed before it was released")

        rig.wire.release(op: listOp, at: 1)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.railNamesForTest == ["Aardvark Mix", "Top 25 Most Played", "Road Trip"] },
                      "the re-read's rows never landed: \(rig.scene.railNamesForTest)")
        assertTracksPaneUntouched(rig, was)
        XCTAssertEqual(rig.scene.railCursorForTest, 2, "the rail cursor did not follow Road Trip to its new row")

        // Back: the new list, on the same playlist, with the pane closed.
        press(rig, .escape)
        XCTAssertEqual(rig.scene.railCursorForTest, 2)
        let out = rig.scene.render(frame: wide, snapshot: idle)
        XCTAssertTrue(out.contains("Aardvark Mix") && out.contains("Road Trip"), "the list on return is not the new one")
        press(rig, .down)
        XCTAssertEqual(rig.scene.railCursorForTest, 2, "Back left the focus in the tracks pane (Down moved no rail row)")
        press(rig, .up)
        XCTAssertEqual(rig.scene.railCursorForTest, 1)
        XCTAssertEqual(rig.statusStore.current()?.text, before, "the re-read spoke")
        XCTAssertEqual(rig.wire.sent(listOp).count, 2, "exactly one re-read")
    }

    /// The bounded retry: a stale-generation re-read failed, and its delayed retry (5 s)
    /// comes due while the person is inside Road Trip's tracks. Same promise as above, and
    /// the new list is what the next rest draws a cover from once they are back.
    func testAStaleRereadsRetryLandingInsideAPlaylistLeavesTheTracksPane() {
        let rig = Rig(pages: [page(generation: 1), Self.badReply, page(generation: 2, leading: "Aardvark Mix")], width: 138)
        rig.wire.script("slice.libraryPlaylistTracks", Array(repeating: trackPage(count: 40), count: 6))   // previews and the drill-in read it
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["playlist|pl2"] = LibraryCoverFetcherTests.payload(40_000)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        press(rig, .down)                                   // Road Trip is the focused row when the refusal comes
        tick(rig, at: 0.25)
        tick(rig, at: 0.6)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl2"])
        XCTAssertTrue(attempt(rig, at: 0.25, expecting: 2), "the stale refusal never made the scene read again")
        XCTAssertEqual(rig.scene.railNamesForTest, ["Top 25 Most Played", "Road Trip"], "a failed read changed the list")

        // Inside the playlist while the retry waits out its delay.
        press(rig, .enter)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.drilledTrackTitlesForTest.count == 40 }, "the tracks never opened")
        press(rig, .down, 30)
        XCTAssertGreaterThan(rig.scene.trackScrollForTest, 0)
        let was = (titles: rig.scene.drilledTrackTitlesForTest, cursor: rig.scene.trackCursorForTest,
                   scroll: rig.scene.trackScrollForTest, reads: rig.wire.sent("slice.libraryPlaylistTracks").count)
        XCTAssertEqual(quietCount(rig, from: 0.3, to: 5.2), 2, "a retry waits out its delay, never a tick")

        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3), "the retry was never made while the person was in the tracks")
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.railNamesForTest == ["Aardvark Mix", "Top 25 Most Played", "Road Trip"] },
                      "the retry's rows never landed: \(rig.scene.railNamesForTest)")
        assertTracksPaneUntouched(rig, was)
        XCTAssertEqual(rig.scene.railCursorForTest, 2)

        press(rig, .escape)
        XCTAssertEqual(rig.scene.railCursorForTest, 2)
        XCTAssertTrue(rig.scene.render(frame: wide, snapshot: idle).contains("Aardvark Mix"))
        XCTAssertTrue(tickUntil(rig, from: 10) { rig.spandac.firstRequests.count >= 2 }, "the new list's row was never asked for")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["pl2", "pl2"], "the cursor is not on the playlist it left")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1, 2])
        XCTAssertEqual(rig.statusStore.current()?.text, before, "the retry spoke")
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 3)
    }
}

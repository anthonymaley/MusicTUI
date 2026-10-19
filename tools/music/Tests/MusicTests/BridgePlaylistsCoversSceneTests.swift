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

        init(pages: [String], withFetcher: Bool = true) {
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
                warmUpSleep: { _ in },
                screenWidth: { 110 })
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
                              page(generation: 4, instance: Self.instanceB)])
        rig.wire.gate(op: "slice.libraryPlaylists", at: 1)
        settleRows(rig)
        tick(rig, at: 0.25)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [3])

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

    func testAFailedPlaylistsRereadDoesNotLoopOrSpeak() {
        let rig = Rig(pages: [page(generation: 3, instance: Self.instanceA)])   // the re-read is answered bad_request
        restartSpanDAC(rig)
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count >= 2 })
        for step in 0..<40 { tick(rig, at: 1 + Double(step)); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "a failed re-read is not retried")
        XCTAssertTrue(rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip"), "the list on screen is untouched")
        XCTAssertEqual(rig.statusStore.current()?.text, before)
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

    func testAFailedStalePlaylistsRereadDoesNotLoopOrSpeak() {
        let rig = Rig(pages: [page(generation: 1)])   // the re-read is answered bad_request
        rig.spandac.serverGeneration = 2
        settleRows(rig)
        let before = rig.statusStore.current()?.text
        tick(rig, at: 0.25)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.sent("slice.libraryPlaylists").count >= 2 })
        for step in 0..<40 { tick(rig, at: 1 + Double(step)); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryPlaylists").count, 2, "a failed re-read is not retried")
        XCTAssertTrue(rig.scene.render(frame: frame, snapshot: idle).contains("Road Trip"))
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
}

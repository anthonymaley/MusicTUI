// tools/music/Tests/MusicTests/BridgeLibraryCoversSceneTests.swift
import XCTest
@testable import music

/// SpanDAC's covers on the Library tab's top-level Albums hero: which row the
/// scene focuses and with what generation and instance, when it cancels, when a
/// landing repaints, and that the hero draws the installed cover (or the
/// gradient). The fetcher is the real one on a scripted SpanDAC, a fake clock and
/// inline lanes; the scene's Bridge lists come from a canned wire; the art cache
/// is a temp directory and the renderer returns marker lines. No socket, no
/// playback, no real art cache.
final class BridgeLibraryCoversSceneTests: XCTestCase {

    typealias Clock = LibraryCoverFetcherTests.Clock
    typealias Lanes = LibraryCoverFetcherTests.Lanes
    typealias FakeSpanDAC = LibraryCoverFetcherTests.FakeSpanDAC
    typealias Target = LibraryCoverFetcher.Target

    private static let instanceA = LibraryCoverFetcherTests.instanceA
    private static let instanceB = LibraryCoverFetcherTests.instanceB
    private static let marker = "SPANDACCOVERMARKER"

    private let frame = shellLayout(width: 100, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func albumPage(instance: String?, generation: Int = 3) -> String {
        let inst = instance.map { "\"library_instance\":\"\($0)\"," } ?? ""
        return """
        {"ok":true,"op":"slice.libraryAlbums","generation":\(generation),\(inst)"total":2,
         "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"},
                  {"id":"al2","title":"Mezzanine","artist":"Massive Attack","track_count":11,"kind":"album"}],
         "next_cursor":null}
        """
    }

    private let artistPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
    """
    private let artistAlbumsPage = """
    {"ok":true,"op":"slice.libraryArtistAlbums","generation":3,"total":1,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],
     "next_cursor":null}
    """

    /// One scene, one fetcher, one scripted SpanDAC, a temp art cache.
    private final class Rig {
        let clock = Clock()
        let lanes = Lanes()
        let spandac: FakeSpanDAC
        let wire: BridgeLibraryReadsWire
        let spy = LibraryAppleScriptSpy()
        let flag: BridgeSelectedFlag
        let dir: String
        let fetcher: LibraryCoverFetcher
        let scene: LibraryScene

        init(wire: BridgeLibraryReadsWire, bridge: Bool = true) {
            self.wire = wire
            flag = BridgeSelectedFlag(bridge)
            spandac = FakeSpanDAC(clock: clock, instance: BridgeLibraryCoversSceneTests.instanceA)
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("covers-scene-test-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
            store.set(.source)
            let routing = RoutingCoordinator(store: store, surface: .tui,
                                             makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
            let clock = self.clock, lanes = self.lanes, spandac = self.spandac
            fetcher = LibraryCoverFetcher(provider: { spandac }, dataEpoch: { routing.dataEpoch },
                                          cacheDir: dir, now: { clock.date },
                                          queue: { lane, job in lanes.submit(lane, job) }, px: 512)
            fetcher.observeShell(active: .library, dataEpoch: routing.dataEpoch)
            let status = StatusStore()
            let flag = self.flag
            scene = LibraryScene(
                backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                sources: spy.sources(), appQueue: AppQueueStore(), status: status,
                actions: ActionRunner(status: status),
                libraryCovers: fetcher,
                artwork: ArtworkStore(cacheDir: dir, fetch: { _ in nil },
                                      render: { _, _, _ in [BridgeLibraryCoversSceneTests.marker] }),
                makeProvider: {
                    flag.selected
                        ? BridgeMusicProvider(control: SourceAppControl(
                            path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                        : nil
                },
                warmUpSleep: { _ in },
                resultCache: temporaryResultCache().cache)
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }

        func target(_ id: String = "al1", generation: Int = 3, instance: String = BridgeLibraryCoversSceneTests.instanceA) -> Target {
            Target(owner: .libraryAlbums, kind: .album, id: id, generation: generation,
                   libraryInstance: instance, dataEpoch: 0)
        }

        /// Plants the file the fetcher would have installed for `target`.
        func install(_ target: Target) {
            let key = LibraryCoverFetcher.cacheKey(for: target, px: 512)
            FileManager.default.createFile(atPath: "\(dir)/\(key)", contents: LibraryCoverFetcherTests.payload(2_000))
        }

        func tick(at t: TimeInterval, snapshot: NowPlayingSnapshot) -> Bool {
            clock.t = t
            return scene.tick(snapshot: snapshot)
        }
    }

    private func loadedAlbumsRig(_ pages: [String], bridge: Bool = true) -> Rig {
        let rig = Rig(wire: BridgeLibraryReadsWire(["slice.libraryAlbums": pages]), bridge: bridge)
        goToSubView(rig.scene, .albums)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") },
                      "the albums never loaded")
        return rig
    }

    private func heroShowsMarker(_ rig: Rig) -> Bool {
        settleScene(rig.scene, seconds: 2) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains(Self.marker) }
    }

    // MARK: - the hero

    func testABridgeAlbumHeroDrawsItsInstalledCover() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA)])
        rig.install(rig.target())

        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)   // the rest ends, readiness is read
        XCTAssertTrue(heroShowsMarker(rig), "the installed cover never reached the hero")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "an installed cover must not be asked for again")
    }

    func testWithoutTheCapabilityTheHeroStaysGradient() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA)])
        rig.spandac.readiness = { LibraryArtworkReadiness(supported: false, instance: Self.instanceA) }
        rig.install(rig.target())

        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        for _ in 0..<20 { _ = rig.scene.tick(snapshot: idle); usleep(5_000) }
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
    }

    func testTheMusicAppAlbumPathIsUnchanged() {
        let rig = Rig(wire: BridgeLibraryReadsWire(), bridge: false)
        rig.spy.albums = [LibraryAlbum(id: "ma1", name: "Kid A", artist: "Radiohead", trackCount: 10)]
        goToSubView(rig.scene, .albums)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Kid A") })

        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.5, snapshot: idle)
        _ = rig.tick(at: 1.0, snapshot: idle)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0, "Music.app rows must never read SpanDAC's status")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertTrue(rig.wire.opsInOrder().isEmpty, "the Music.app path must not touch SpanDAC")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
    }

    // MARK: - what is asked

    func testTheFocusedAlbumIsAskedForWithItsPagesGeneration() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA, generation: 7)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)

        _ = rig.tick(at: 0, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "nothing is asked before the rest")
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.count, 1)
        let request = rig.spandac.firstRequests.first
        XCTAssertEqual(request?.kind, .album)
        XCTAssertEqual(request?.id, "al1")
        XCTAssertEqual(request?.generation, 7)
        XCTAssertEqual(request?.libraryInstance, Self.instanceA)
    }

    func testTheTargetCarriesTheAppliedPagesInstance() {
        // Instance A applied -> a target under A.
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA), albumPage(instance: Self.instanceB, generation: 4)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA])

        // The list is replaced by a walk observed under B (status now names B): a target under B.
        rig.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
        rig.flag.selected = false
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("(no albums)") })
        rig.flag.selected = true
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        _ = rig.tick(at: 10, snapshot: idle)
        _ = rig.tick(at: 10.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA, Self.instanceB])
        XCTAssertEqual(rig.spandac.firstRequests.last?.generation, 4)
    }

    func testAPageWithNoInstanceHasNoTarget() {
        let rig = loadedAlbumsRig([albumPage(instance: nil)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        _ = rig.tick(at: 5, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0, "no target, so not even a readiness read")
    }

    func testAnArtistsAlbumsRailNeverAsks() {
        // The Albums list is loaded first, so its generation and instance ARE
        // applied: only the scope, not a missing pair, keeps the rail gradient.
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage(instance: Self.instanceA)],
                                           "slice.libraryArtists": [artistPage],
                                           "slice.libraryArtistAlbums": [artistAlbumsPage]])
        let rig = Rig(wire: wire)
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        goToSubView(rig.scene, .albums)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        goToSubView(rig.scene, .artists)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Radiohead") })
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)

        _ = rig.scene.handle(.enter)   // the artist's albums rail
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        _ = rig.tick(at: 1, snapshot: idle)
        _ = rig.tick(at: 1.3, snapshot: idle)

        _ = rig.scene.handle(.enter)   // an album opened from it
        _ = rig.tick(at: 2, snapshot: idle)
        _ = rig.tick(at: 2.3, snapshot: idle)
        _ = rig.tick(at: 9, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "an artist's albums keep the gradient")
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0, "an artist's albums never even read readiness")
    }

    func testTheTracksViewOpenedFromTheAlbumsListIsStillAskedFor() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.scene.handle(.enter)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al1"])
    }

    // MARK: - cancel and repaint

    func testAProvenanceSwitchCancels() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)             // focused, resting
        let before = rig.fetcher.landed

        rig.flag.selected = false                        // the output leaves SpanDAC
        _ = rig.tick(at: 0.1, snapshot: idle)
        XCTAssertNotEqual(rig.fetcher.landed, before, "the reset must cancel the fetcher")
        _ = rig.tick(at: 1, snapshot: idle)
        _ = rig.tick(at: 5, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "a switch away from SpanDAC must ask nothing")
    }

    func testALandingRepaints() {
        let rig = loadedAlbumsRig([albumPage(instance: Self.instanceA)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        // Quiet the scene with the clock inside the rest.
        var quiet = false
        for _ in 0..<50 where !quiet { quiet = !rig.tick(at: 0, snapshot: idle) }
        XCTAssertTrue(quiet, "the scene never settled")
        let before = rig.fetcher.landed

        XCTAssertTrue(rig.tick(at: 0.3, snapshot: idle), "an installed cover must repaint")
        XCTAssertNotEqual(rig.fetcher.landed, before)
        XCTAssertFalse(rig.tick(at: 0.4, snapshot: idle), "nothing new, nothing to repaint")
    }
}

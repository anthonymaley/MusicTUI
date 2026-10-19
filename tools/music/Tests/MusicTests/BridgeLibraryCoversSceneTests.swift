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

        init(wire: BridgeLibraryReadsWire, bridge: Bool = true,
             warmUpSleep: @escaping (TimeInterval) -> Void = { _ in }) {
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
                warmUpSleep: warmUpSleep,
                resultCache: temporaryResultCache().cache,
                // The scene's own clock is the fake one, so a retry's delay is read off it.
                now: { clock.date })
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }

        func target(_ id: String = "al1", generation: Int = 3, instance: String = BridgeLibraryCoversSceneTests.instanceA) -> Target {
            Target(owner: .libraryAlbums, kind: .album, id: id, generation: generation,
                   libraryInstance: instance, dataEpoch: 0)
        }

        func artistTarget(_ id: String = "al1", generation: Int = 3, instance: String = BridgeLibraryCoversSceneTests.instanceA) -> Target {
            Target(owner: .libraryArtistAlbums, kind: .album, id: id, generation: generation,
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

    func testASongsListNeverAsks() {
        let rig = Rig(wire: BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage(instance: Self.instanceA)]]))
        goToSubView(rig.scene, .songs)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        _ = rig.tick(at: 5, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0)
    }

    // MARK: - an artist's albums

    /// An artist's albums reply: `ids` in order, under the rows' core `generation`.
    private func artistAlbumsPage(_ ids: [String] = ["al1"], generation: Int = 3,
                                  instance: String? = instanceA) -> String {
        let inst = instance.map { "\"library_instance\":\"\($0)\"," } ?? ""
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"In Rainbows \($0)\",\"artist\":\"Radiohead\",\"track_count\":9,\"kind\":\"album\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryArtistAlbums","generation":\(generation),\(inst)
         "items":[\(items)],"stale":false,"refreshing":false}
        """
    }

    /// The Artists sub-view on a scripted SpanDAC, one artist listed.
    private func artistsRig(_ artistAlbums: [String]) -> Rig {
        let rig = Rig(wire: BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage],
                                                    "slice.libraryArtistAlbums": artistAlbums]))
        goToSubView(rig.scene, .artists)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Radiohead") },
                      "the artists never loaded")
        return rig
    }

    /// Enter on the artist: its albums rail, once the first album is on screen.
    private func openArtist(_ rig: Rig) {
        _ = rig.scene.handle(.enter)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al1") },
                      "the artist's albums never loaded")
    }

    func testAnArtistsAlbumsRailAsksUnderTheRepliesGenerationAndInstance() {
        let rig = artistsRig([artistAlbumsPage(["al1", "al2"], generation: 7)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        // The Artists list itself has no covers: no target, no readiness read.
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0)

        rig.clock.t = 1      // the rows' rest starts when the rail opens, not before
        openArtist(rig)
        _ = rig.tick(at: 1.1, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "nothing is asked before the rest")
        _ = rig.tick(at: 1.4, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.count, 1)
        let request = rig.spandac.firstRequests.first
        XCTAssertEqual(request?.kind, .album)
        XCTAssertEqual(request?.id, "al1")
        XCTAssertEqual(request?.generation, 7)
        XCTAssertEqual(request?.libraryInstance, Self.instanceA)
        XCTAssertNotNil(rig.fetcher.cover(for: rig.artistTarget(generation: 7)), "the cover arrives")
        XCTAssertTrue(heroShowsMarker(rig))
    }

    func testAnAlbumOpenedFromAnArtistIsAskedForUnderTheSameGenerationAndInstance() {
        let rig = artistsRig([artistAlbumsPage(["al1", "al2"], generation: 7)])
        rig.spandac.covers["album|al2"] = LibraryCoverFetcherTests.payload(40_000)
        openArtist(rig)
        _ = rig.scene.handle(.down)    // al2
        _ = rig.scene.handle(.enter)   // its tracks
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al2"])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [7])
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceA])
        XCTAssertTrue(heroShowsMarker(rig))
    }

    func testMovingOffAnArtistsAlbumBeforeTheRestAsksForTheNewOneOnly() {
        let rig = artistsRig([artistAlbumsPage(["al1", "al2"])])
        rig.spandac.covers["album|al2"] = LibraryCoverFetcherTests.payload(40_000)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.scene.handle(.down)
        _ = rig.tick(at: 0.2, snapshot: idle)
        _ = rig.tick(at: 0.4, snapshot: idle)   // 0.2 s on al2: still resting
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        _ = rig.tick(at: 0.5, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al2"])
    }

    func testAnArtistsAlbumsFromASpanDACWithoutAnInstanceStayGradient() {
        // SpanDAC 0.3.6: no `library_instance` on the reply, and its generation is
        // the full snapshot's. Nothing is asked and readiness is not even read.
        let rig = artistsRig([artistAlbumsPage(instance: nil)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        _ = rig.scene.handle(.enter)
        _ = rig.tick(at: 2, snapshot: idle)
        _ = rig.tick(at: 2.3, snapshot: idle)
        _ = rig.tick(at: 9, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0)
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
    }

    func testBackingOutOfTheArtistDropsItsTargetAndAnotherOpenIsReadAgain() {
        let rig = artistsRig([artistAlbumsPage(generation: 7), artistAlbumsPage(generation: 8)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [7])

        _ = rig.scene.handle(.escape)
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.count, 1, "the Artists list asks for nothing")

        // Opened again: read again, and the rows are asked for under the NEW read's generation.
        openArtist(rig)
        _ = rig.tick(at: 10, snapshot: idle)
        _ = rig.tick(at: 10.3, snapshot: idle)
        XCTAssertEqual(rig.wire.sent("slice.libraryArtistAlbums").count, 2)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [7, 8])
    }

    func testTheMusicAppArtistPathIsUnchanged() {
        let rig = Rig(wire: BridgeLibraryReadsWire(), bridge: false)
        rig.spy.artists = [LibraryArtist(id: "ma1", name: "Radiohead")]
        goToSubView(rig.scene, .artists)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Radiohead") })
        _ = rig.scene.handle(.enter)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.5, snapshot: idle)
        _ = rig.tick(at: 1.0, snapshot: idle)
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 0, "Music.app rows must never read SpanDAC's status")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertTrue(rig.wire.opsInOrder().isEmpty, "the Music.app path must not touch SpanDAC")
    }

    func testAStaleGenerationRefusalReadsTheArtistsAlbumsAgainOnce() {
        let rig = artistsRig([artistAlbumsPage(["al1", "al2"], generation: 1),
                              artistAlbumsPage(["al1", "al2"], generation: 2)])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)   // asked under 1, refused as stale
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1])
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryArtistAlbums").count == 2 },
                      "the stale refusal never made the scene read the artist's albums again")
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertTrue(settleResting(rig, from: 5.3) { rig.spandac.firstRequests.map(\.generation) == [1, 2] },
                      "a rest asks under the new generation")
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.wire.sent("slice.libraryArtistAlbums").count, 2, "exactly one re-read")
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 0, "the Albums list is not this list")
    }

    func testAnArtistsReadThatStillCarriesTheOldGenerationDoesNotLoop() {
        let rig = artistsRig([artistAlbumsPage(generation: 1), artistAlbumsPage(generation: 1),
                              artistAlbumsPage(generation: 1)])
        rig.spandac.serverGeneration = 2
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryArtistAlbums").count == 2 })
        for step in 0..<40 { _ = rig.tick(at: 1 + Double(step), snapshot: idle); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryArtistAlbums").count, 2, "no loop on an unchanged generation")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
    }

    func testARestartedSpanDACReadsTheArtistsAlbumsAgainOnce() {
        let rig = artistsRig([artistAlbumsPage(generation: 1, instance: Self.instanceA),
                              artistAlbumsPage(generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "nothing is asked under the old instance")
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryArtistAlbums").count == 2 },
                      "the restart never made the scene read the artist's albums again")
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertTrue(settleResting(rig, from: 5.3) { rig.spandac.firstRequests.map(\.libraryInstance) == [Self.instanceB] })
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [2])
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.wire.sent("slice.libraryArtistAlbums").count, 2, "exactly one re-read")
    }

    func testAnArtistsReadThatStillCarriesTheOldInstanceDoesNotLoop() {
        let rig = artistsRig([artistAlbumsPage(generation: 1), artistAlbumsPage(generation: 2),
                              artistAlbumsPage(generation: 3), artistAlbumsPage(generation: 4)])
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryArtistAlbums").count == 2 })
        for step in 0..<40 { _ = rig.tick(at: 1 + Double(step), snapshot: idle); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryArtistAlbums").count, 2, "no loop under the same old instance")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
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

    // MARK: - a refresh moved the snapshot under the Albums list

    /// An albums page: `ids` in order, under `generation`.
    private func albumsPage(_ ids: [String], generation: Int, instance: String? = instanceA) -> String {
        let inst = instance.map { "\"library_instance\":\"\($0)\"," } ?? ""
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"In Rainbows \($0)\",\"artist\":\"Artist\",\"track_count\":9,\"kind\":\"album\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryAlbums","generation":\(generation),\(inst)"total":\(ids.count),
         "items":[\(items)],"next_cursor":null}
        """
    }

    /// Ticks the scene at `t` until `until` holds (the re-read runs on a feed thread).
    private func settle(_ rig: Rig, at t: TimeInterval, seconds: Double = 20, until: () -> Bool) -> Bool {
        rig.clock.t = t
        return settleScene(rig.scene, seconds: seconds, until: until)
    }

    /// Waits for a REST to end and its request to be made, with the fake clock moving
    /// forward every pass the way the app's does. A constant clock cannot do this: a
    /// re-read that lands while the loop waits is a new target, which restarts the
    /// rest from the clock's value, and a clock that never moves never ends it.
    private func settleResting(_ rig: Rig, from t: TimeInterval, seconds: Double = 20, until: () -> Bool) -> Bool {
        var now = t
        return settleScene(rig.scene, seconds: seconds) {
            now += 0.1
            rig.clock.t = now
            return until()
        }
    }

    func testAStaleGenerationRefusalRereadsTheListOnceAndTheNextRestGetsACover() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1),
                                   albumsPage(["al1", "al2"], generation: 2)])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)

        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)   // the rest ends: asked under generation 1, refused as stale
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1])
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 },
                      "the stale refusal never made the scene read its Albums list again")

        // The re-read applies; the focused row is a new target, rested on afresh.
        XCTAssertTrue(settle(rig, at: 0.4) { rig.fetcher.cover(for: rig.target(generation: 2)) == nil
                                              && rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al1") })
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1, 2], "a rest asks under the new generation")
        XCTAssertNotNil(rig.fetcher.cover(for: rig.target(generation: 2)), "the cover arrives")
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "exactly one re-read")
    }

    func testAReadThatStillCarriesTheOldGenerationDoesNotLoop() {
        // The re-read comes back under generation 1 again; the server stays at 2.
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1),
                                   albumsPage(["al1", "al2"], generation: 1),
                                   albumsPage(["al1", "al2"], generation: 1)])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 })
        // Plenty of ticks and time: still one re-read, no second.
        for step in 0..<40 { _ = rig.tick(at: 1 + Double(step), snapshot: idle); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "no loop on an unchanged generation")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
    }

    func testAFailedRereadDoesNotLoopOrSpeak() {
        // Only the first read is scripted: every re-read is answered `bad_request`.
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1)])
        rig.spandac.serverGeneration = 2
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2))
        // Ticks, however many, inside the delay ask nothing.
        for step in 0..<40 { _ = rig.tick(at: 0.4 + Double(step) * 0.1, snapshot: idle); usleep(2_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "a retry waits out its delay, never a tick")
        let out = rig.scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("In Rainbows al1"), "the list on screen is untouched")
        XCTAssertFalse(out.contains("SpanDAC couldn't"), "no error message to the person")
    }

    /// Ticks at fake time `t` until request number `n` of `op` has been served and its
    /// worker has ENDED (its outcome is recorded), then once more so the tick stamps a
    /// failure's retry time at `t`. No wall-time wait.
    private func attempt(_ rig: Rig, at t: TimeInterval, expecting n: Int,
                         op: String = "slice.libraryAlbums") -> Bool {
        rig.clock.t = t
        let ok = settleScene(rig.scene) { rig.wire.sent(op).count >= n && rig.wire.threadEnded(op: op, at: n - 1) }
        _ = rig.tick(at: t, snapshot: idle)
        return ok
    }

    private static func badReply(_ op: String) -> String {
        "{\"ok\":false,\"op\":\"\(op)\",\"error\":{\"kind\":\"bad_request\",\"detail\":\"scripted failure\"}}"
    }

    /// Asks nothing on any tick between `from` and `to` (fake seconds), then reports the request count.
    private func quietCount(_ rig: Rig, op: String, from: TimeInterval, to: TimeInterval) -> Int {
        var t = from
        while t < to { _ = rig.tick(at: t, snapshot: idle); t += (to - from) / 20 }
        usleep(100_000)
        return rig.wire.sent(op).count
    }

    func testAFailedRestartRereadIsRetriedAfterADelayAndTheCoverFollows() {
        let op = "slice.libraryAlbums"
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   Self.badReply(op),
                                   albumsPage(["al0", "al1", "al2"], generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2), "the restart never made the scene read again")
        XCTAssertEqual(quietCount(rig, op: op, from: 0.4, to: 5.2), 2, "the retry waits out its delay")
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3), "a failed read was never retried")
        XCTAssertTrue(settle(rig, at: 5.4) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") },
                      "the retry's replacement never landed")
        _ = rig.tick(at: 10, snapshot: idle)
        _ = rig.tick(at: 10.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB], "a rest asks under the new instance")
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(quietCount(rig, op: op, from: 20, to: 400), 3, "a read that succeeded is not asked again")
    }

    func testAFailedRestartRereadIsRetriedAtMostABoundedFewTimes() {
        let op = "slice.libraryAlbums"
        let bad = Self.badReply(op)
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   bad, bad, bad, bad,
                                   albumsPage(["al0", "al1", "al2"], generation: 2, instance: Self.instanceB)])
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        // The first attempt, then retries 5, 15 and 45 seconds after each failure.
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2))
        XCTAssertEqual(quietCount(rig, op: op, from: 0.4, to: 5.2), 2)
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3))
        XCTAssertEqual(quietCount(rig, op: op, from: 5.5, to: 20.3), 3)
        XCTAssertTrue(attempt(rig, at: 20.5, expecting: 4))
        XCTAssertEqual(quietCount(rig, op: op, from: 20.6, to: 65.4), 4)
        XCTAssertTrue(attempt(rig, at: 65.6, expecting: 5))
        XCTAssertEqual(quietCount(rig, op: op, from: 66, to: 6_000), 5, "spent: no fifth retry however long it waits")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains("In Rainbows al0"))
    }

    func testAProvenanceResetDuringARetryForgetsItsDelayAndItsFailures() {
        let op = "slice.libraryAlbums"
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   Self.badReply(op),
                                   albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al0", "al1", "al2"], generation: 2, instance: Self.instanceB)])
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2))   // failed: the retry waits until 5.3

        rig.flag.selected = false
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("(no albums)") })
        rig.flag.selected = true
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        _ = rig.tick(at: 1.0, snapshot: idle)
        _ = rig.tick(at: 1.3, snapshot: idle)
        // Still long before 5.3, and the old list is read again at once.
        XCTAssertTrue(attempt(rig, at: 1.4, expecting: 4), "the reset left the old retry delay in force")
        XCTAssertTrue(settle(rig, at: 1.4) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") })
    }

    // MARK: - a failed re-read of the open artist's albums

    func testAFailedArtistAlbumsRereadIsRetriedAfterADelayAndTheCoverFollows() {
        let op = "slice.libraryArtistAlbums"
        let rig = artistsRig([artistAlbumsPage(["al1"], generation: 1, instance: Self.instanceA),
                              Self.badReply(op),
                              artistAlbumsPage(["al0", "al1"], generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2, op: op), "the restart never made the scene read again")
        XCTAssertEqual(quietCount(rig, op: op, from: 0.4, to: 5.2), 2, "the retry waits out its delay")
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3, op: op), "a failed read was never retried")
        XCTAssertTrue(settle(rig, at: 5.4) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") },
                      "the retry's replacement never landed")
        _ = rig.tick(at: 10, snapshot: idle)
        _ = rig.tick(at: 10.3, snapshot: idle)
        XCTAssertTrue(settleResting(rig, from: 10.3) { rig.spandac.firstRequests.map(\.libraryInstance) == [Self.instanceB] })
        XCTAssertEqual(quietCount(rig, op: op, from: 20, to: 400), 3, "a read that succeeded is not asked again")
    }

    func testAFailedArtistAlbumsRereadIsRetriedAtMostABoundedFewTimes() {
        let op = "slice.libraryArtistAlbums"
        let bad = Self.badReply(op)
        let rig = artistsRig([artistAlbumsPage(["al1"], generation: 1, instance: Self.instanceA),
                              bad, bad, bad, bad,
                              artistAlbumsPage(["al0", "al1"], generation: 2, instance: Self.instanceB)])
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2, op: op))
        XCTAssertEqual(quietCount(rig, op: op, from: 0.4, to: 5.2), 2)
        XCTAssertTrue(attempt(rig, at: 5.4, expecting: 3, op: op))
        XCTAssertEqual(quietCount(rig, op: op, from: 5.5, to: 20.3), 3)
        XCTAssertTrue(attempt(rig, at: 20.5, expecting: 4, op: op))
        XCTAssertEqual(quietCount(rig, op: op, from: 20.6, to: 65.4), 4)
        XCTAssertTrue(attempt(rig, at: 65.6, expecting: 5, op: op))
        XCTAssertEqual(quietCount(rig, op: op, from: 66, to: 6_000), 5, "spent: no fifth retry however long it waits")
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains("In Rainbows al0"))
    }

    func testOpeningTheArtistAgainDuringARetryForgetsItsDelayAndItsFailures() {
        let op = "slice.libraryArtistAlbums"
        let rig = artistsRig([artistAlbumsPage(["al1"], generation: 1, instance: Self.instanceA),
                              Self.badReply(op),
                              artistAlbumsPage(["al1"], generation: 1, instance: Self.instanceA),
                              artistAlbumsPage(["al0", "al1"], generation: 2, instance: Self.instanceB)])
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2, op: op))   // failed: the retry waits until 5.3

        _ = rig.scene.handle(.escape)
        _ = rig.tick(at: 0.5, snapshot: idle)
        openArtist(rig)   // read again: the open's own read, which is under the old instance
        _ = rig.tick(at: 1.0, snapshot: idle)
        _ = rig.tick(at: 1.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 1.4, expecting: 4, op: op), "the reset left the old retry delay in force")
        XCTAssertTrue(settle(rig, at: 1.4) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") })
    }

    func testAReplyDiscardedBecauseTheTabStoppedTickingIsRetried() {
        let op = "slice.libraryArtistAlbums"
        let rig = artistsRig([artistAlbumsPage(["al1"], generation: 1, instance: Self.instanceA),
                              artistAlbumsPage(["al0", "al1"], generation: 2, instance: Self.instanceB),
                              artistAlbumsPage(["al0", "al1"], generation: 2, instance: Self.instanceB)])
        rig.wire.gate(op: op, at: 1)   // hold the re-read's request until the tab has gone quiet
        restartSpanDAC(rig)
        openArtist(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settleScene(rig.scene) { rig.wire.reached(op: op, at: 1) }, "the re-read never began")
        // The tab stops ticking for longer than its heartbeat, then the reply arrives.
        rig.clock.t = 200
        rig.wire.release(op: op, at: 1)
        XCTAssertTrue(waitUntil { rig.wire.threadEnded(op: op, at: 1) })
        _ = rig.tick(at: 200, snapshot: idle)   // the tab is back: stamps the failure at 200
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains("In Rainbows al0"), "the reply was applied after all")
        XCTAssertEqual(quietCount(rig, op: op, from: 200.1, to: 204.9), 2, "the retry waits out its delay")
        XCTAssertTrue(attempt(rig, at: 205.5, expecting: 3, op: op), "a discarded reply was never read again")
        XCTAssertTrue(settle(rig, at: 205.5) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") })
    }

    private func waitUntil(seconds: Double = 5, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if done() { return true }; usleep(2_000) }
        return done()
    }

    func testTheCursorStaysOnTheSameAlbumAcrossTheRereadAndNewAlbumsAppear() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2", "al3"], generation: 1),
                                   albumsPage(["al0", "al1", "al2", "al3"], generation: 2)])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al2"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.scene.handle(.down)   // al2
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al2"])
        XCTAssertTrue(settle(rig, at: 0.3) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") },
                      "the new album never appeared")
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al2", "al2"], "the cursor moved off the album")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1, 2])
        XCTAssertTrue(heroShowsMarker(rig))
    }

    func testARereadWhileDrilledIntoAnAlbumAppliesUnderneathWithoutMovingThem() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1),
                                   albumsPage(["al0", "al1", "al2"], generation: 2)])
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.scene.handle(.enter)   // the tracks of al1
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1])
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 })
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertTrue(settleResting(rig, from: 5.3) { rig.spandac.firstRequests.map(\.generation) == [1, 2] },
                      "the tracks view's album is asked for again under the new generation")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al1", "al1"])
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.scene.subViewForTest, .albums)
    }

    // MARK: - SpanDAC restarted under the Albums list

    /// Readiness now names instance B, as a restarted SpanDAC's status does.
    private func restartSpanDAC(_ rig: Rig) {
        rig.spandac.readiness = { LibraryArtworkReadiness(supported: true, instance: Self.instanceB) }
    }

    func testARestartedSpanDACRereadsTheListOnceAndTheNextRestGetsACover() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al0", "al1", "al2"], generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)

        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)   // the rest ends: readiness names B, the list is under A
        XCTAssertEqual(rig.spandac.statusReadTimes.count, 1, "a focused row on the old list must still read readiness")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty, "nothing is asked under the old instance")
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 },
                      "the restart never made the scene read its Albums list again")
        XCTAssertTrue(settle(rig, at: 0.4) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") },
                      "the replacement never landed")

        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB], "a rest asks under the new instance")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [2])
        XCTAssertNotNil(rig.fetcher.cover(for: rig.target(generation: 2, instance: Self.instanceB)), "the cover arrives")
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "exactly one re-read")
    }

    func testARereadThatStillCarriesTheOldInstanceDoesNotLoop() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 })
        for step in 0..<40 { _ = rig.tick(at: 1 + Double(step), snapshot: idle); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "no loop on an unchanged instance")
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertFalse(rig.scene.render(frame: frame, snapshot: idle).contains(Self.marker))
    }

    func testARereadThatBumpsOnlyTheGenerationUnderTheOldInstanceDoesNotLoop() {
        // Each read comes back under A with a newer generation; readiness stays B.
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al1", "al2"], generation: 2, instance: Self.instanceA),
                                   albumsPage(["al1", "al2"], generation: 3, instance: Self.instanceA),
                                   albumsPage(["al1", "al2"], generation: 4, instance: Self.instanceA)])
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 })
        for step in 0..<40 { _ = rig.tick(at: 1 + Double(step), snapshot: idle); usleep(5_000) }
        usleep(100_000)
        XCTAssertEqual(rig.wire.sent("slice.libraryAlbums").count, 2, "a newer generation under the same old instance is no reason to read again")
    }

    func testAFailedRestartRereadDoesNotLoopOrSpeak() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA)])
        restartSpanDAC(rig)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(attempt(rig, at: 0.3, expecting: 2))
        XCTAssertEqual(quietCount(rig, op: "slice.libraryAlbums", from: 0.4, to: 5.2), 2, "a retry waits out its delay, never a tick")
        let out = rig.scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("In Rainbows al1"), "the list on screen is untouched")
        XCTAssertFalse(out.contains("SpanDAC couldn't"), "no error message to the person")
    }

    func testTheCursorStaysOnTheSameAlbumAcrossARestartRereadAndNewAlbumsAppear() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2", "al3"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al0", "al1", "al2", "al3"], generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al2"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        _ = rig.scene.handle(.down)   // al2
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al0") },
                      "the new album never appeared")
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al2"], "the cursor moved off the album")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.libraryInstance), [Self.instanceB])
        XCTAssertTrue(heroShowsMarker(rig))
    }

    func testARestartRereadWhileDrilledIntoAnAlbumAppliesUnderneathWithoutMovingThem() {
        let rig = loadedAlbumsRig([albumsPage(["al1", "al2"], generation: 1, instance: Self.instanceA),
                                   albumsPage(["al0", "al1", "al2"], generation: 2, instance: Self.instanceB)])
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        restartSpanDAC(rig)
        _ = rig.scene.handle(.enter)   // the tracks of al1
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertTrue(rig.spandac.firstRequests.isEmpty)
        XCTAssertTrue(settle(rig, at: 0.3) { rig.wire.sent("slice.libraryAlbums").count == 2 })
        _ = rig.tick(at: 5, snapshot: idle)
        _ = rig.tick(at: 5.3, snapshot: idle)
        XCTAssertTrue(settleResting(rig, from: 5.3) { rig.spandac.firstRequests.map(\.libraryInstance) == [Self.instanceB] },
                      "the tracks view's album is asked for again under the new instance")
        XCTAssertEqual(rig.spandac.firstRequests.map(\.id), ["al1"])
        XCTAssertTrue(heroShowsMarker(rig))
        XCTAssertEqual(rig.scene.subViewForTest, .albums)
    }

    // MARK: - one walk at a time on a cold start

    /// A SpanDAC with state of its own for `slice.libraryAlbums`: it serves two pages
    /// of the albums it holds, under its core's generation, flagged `refreshing`
    /// while it drains and not once it has. The first page names a second, so a read
    /// that was a WALK (it asked for page 2) is told from a probe (page 1 alone).
    private final class DrainingAlbums {
        private let lock = NSLock()
        private var generation = 1
        private var draining = true
        private var ids = ["al1", "al2", "al3"]
        /// How an artist's albums are written, from the scene's own helper.
        var artistReply: ((_ generation: Int, _ draining: Bool, _ ids: [String]) -> String)?
        /// Reads of the artist's albums so far.
        private(set) var artistReads = 0

        /// The library refresh finished: a newer generation, still draining.
        func moveOn() { lock.lock(); generation = 2; lock.unlock() }
        /// The drain is over: the albums it holds now include one the first read lacked.
        func finishDraining() { lock.lock(); draining = false; ids.append("al9"); lock.unlock() }

        private func artistAlbums() -> String? {
            lock.lock(); defer { lock.unlock() }
            artistReads += 1
            return artistReply?(generation, draining, Array(ids.prefix(2)) + (draining ? [] : ["al9"]))
        }

        func handle(_ op: String, _ body: [String: Any]) -> String? {
            if op == "slice.libraryArtistAlbums" { return artistAlbums() }
            guard op == "slice.libraryAlbums" else { return nil }
            lock.lock(); defer { lock.unlock() }
            let second = (body["cursor"] as? String) != nil
            let page = second ? Array(ids.dropFirst(2)) : Array(ids.prefix(2))
            let items = page.map { "{\"id\":\"\($0)\",\"title\":\"In Rainbows \($0)\",\"artist\":\"Artist\",\"track_count\":9,\"kind\":\"album\"}" }
                .joined(separator: ",")
            return """
            {"ok":true,"op":"slice.libraryAlbums","generation":\(generation),"library_instance":"\(BridgeLibraryCoversSceneTests.instanceA)",
             "total":\(ids.count),"items":[\(items)],"stale":false,"refreshing":\(draining),
             "next_cursor":\(second ? "null" : "\"c2\"")}
            """
        }
    }

    /// An artist's albums, whole in one reply, flagged while SpanDAC drains.
    private func artistAlbumsReply(generation: Int, draining: Bool, ids: [String]) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"In Rainbows \($0)\",\"artist\":\"Radiohead\",\"track_count\":9,\"kind\":\"album\"}" }
            .joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryArtistAlbums","generation":\(generation),"library_instance":"\(Self.instanceA)",
         "items":[\(items)],"stale":false,"refreshing":\(draining)}
        """
    }

    /// The wait between a re-ask's probes, held until the test lets it go: the clock
    /// of a re-ask that has no wall time in it. `entered` counts the waits begun.
    private final class HeldSleep {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var open = false
        private var count = 0
        var entered: Int { lock.lock(); defer { lock.unlock() }; return count }

        func sleep(_ seconds: TimeInterval) {
            lock.lock(); count += 1; let passes = open; lock.unlock()
            if !passes { _ = gate.wait(timeout: .now() + 10) }   // a safety net, never the clock
        }
        /// Every wait, now and from here on, returns at once.
        func openAll() {
            lock.lock(); open = true; lock.unlock()
            for _ in 0..<8 { gate.signal() }
        }
    }

    /// Whole-list reads of Albums so far (they asked for page 2), and every read of
    /// page 1 (a walk's first page or a probe).
    private func albumWalks(_ wire: BridgeLibraryReadsWire) -> (walks: Int, firstPages: Int) {
        let sent = wire.sent("slice.libraryAlbums")
        return (sent.filter { $0["cursor"] != nil }.count, sent.filter { $0["cursor"] == nil }.count)
    }

    func testAColdStartWalksTheAlbumsListOnceMoreAfterTheDrainNotTwice() {
        let server = DrainingAlbums()
        let wire = BridgeLibraryReadsWire()
        wire.handler = server.handle
        let held = HeldSleep()
        defer { held.openAll() }
        let rig = Rig(wire: wire, warmUpSleep: held.sleep)
        goToSubView(rig.scene, .albums)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        // The first read came back refreshing: the feed's own re-ask probes and waits.
        XCTAssertTrue(settleScene(rig.scene) { held.entered == 1 }, "the walk's own re-ask never began")
        XCTAssertEqual(albumWalks(wire).walks, 1)

        // The library refresh finishes while SpanDAC is still draining: the row on
        // screen is asked for under generation 1 and refused as stale.
        server.moveOn()
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1])
        for step in 1...5 { _ = rig.tick(at: 0.3 + 0.1 * Double(step), snapshot: idle) }

        // Then the drain ends and the re-ask's wait is over.
        server.finishDraining()
        held.openAll()
        XCTAssertTrue(settle(rig, at: 1) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al9") },
                      "the list never came back whole after the drain")
        for step in 0..<20 { _ = rig.tick(at: 2 + Double(step), snapshot: idle) }
        let counts = albumWalks(wire)
        XCTAssertEqual(counts.walks, 2, "the first walk and ONE read after the drain, not a third")
        XCTAssertEqual(counts.firstPages, 3, "two walks' first pages and the one probe that found the drain over")
    }

    func testAnArtistsAlbumsStaleRereadJoinsTheirOwnReAskAndReadsOnceAfterTheDrain() {
        let server = DrainingAlbums()
        server.artistReply = artistAlbumsReply
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistPage]])
        wire.handler = server.handle
        let held = HeldSleep()
        defer { held.openAll() }
        let rig = Rig(wire: wire, warmUpSleep: held.sleep)
        goToSubView(rig.scene, .artists)
        XCTAssertTrue(settleScene(rig.scene) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("Radiohead") })
        openArtist(rig)
        // The read came back refreshing: the artist's own re-ask waits for the drain.
        XCTAssertTrue(settleScene(rig.scene) { held.entered == 1 }, "the artist's re-ask never began")

        server.moveOn()
        rig.spandac.serverGeneration = 2
        rig.spandac.covers["album|al1"] = LibraryCoverFetcherTests.payload(40_000)
        _ = rig.tick(at: 0, snapshot: idle)
        _ = rig.tick(at: 0.3, snapshot: idle)
        XCTAssertEqual(rig.spandac.firstRequests.map(\.generation), [1], "asked under 1, refused as stale")
        for step in 1...5 { _ = rig.tick(at: 0.3 + 0.1 * Double(step), snapshot: idle) }
        XCTAssertEqual(server.artistReads, 1, "the stale refusal read the artist's albums beside the re-ask")

        server.finishDraining()
        held.openAll()
        XCTAssertTrue(settle(rig, at: 1) { rig.scene.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows al9") },
                      "the artist's albums never came back whole after the drain")
        for step in 0..<20 { _ = rig.tick(at: 2 + Double(step), snapshot: idle) }
        XCTAssertEqual(server.artistReads, 3, "the first read, the probe, and ONE read after the drain")
    }
}

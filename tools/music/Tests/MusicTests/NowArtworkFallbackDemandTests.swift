// tools/music/Tests/MusicTests/NowArtworkFallbackDemandTests.swift
import XCTest
@testable import music

/// Now's art ladder has two store rungs: SpanDAC's own cover (the primary) and
/// the REST library-album cover (the fallback). Render falls through to the
/// fallback whenever the primary gives no block yet (fetch pending, cooling
/// down after a temporary failure, or unusable). The demand tick retains must
/// be the one render actually asked for, for every rung render may reach, so
/// an idle paused screen recovers on ticks alone (review round 3, 2026-10-25).
/// And a primary that becomes available later still wins over the fallback.
///
/// Nothing reaches the network (injected fetcher and REST lookup), playback,
/// osascript (`/usr/bin/true`), the SpanDAC socket (`/nonexistent`), the
/// keychain or ~/.config/music (temp art dir). Time is one fake clock.
final class NowArtworkFallbackDemandTests: XCTestCase {

    private static let primaryURL = "https://art.invalid/spandac/primary.jpg"
    private static let restTemplate = "https://art.invalid/rest/{w}x{h}.jpg"
    private static let restURL = ArtworkStore.resolveURL(restTemplate, width: 300, height: 300)

    private final class Rig {
        let clock = ArtworkStoreLivenessTests.Clock()
        let calls = ArtworkStoreLivenessTests.Meter()
        let dir: String
        private let lock = NSLock()
        private var storesStorage: [ArtworkStore] = []
        var stores: [ArtworkStore] { lock.lock(); defer { lock.unlock() }; return storesStorage }
        var scene: NowPlayingScene!

        /// `outcome(url, n)`: the fetch result for the n-th (1-based) request of `url`.
        init(outcome: @escaping (String, Int) -> ArtworkFetchOutcome) {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("now-art-fallback-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let calls = self.calls, clock = self.clock, dir = self.dir
            let make: () -> ArtworkStore = { [unowned self] in
                let store = ArtworkStore(cacheDir: dir,
                                         fetcher: { url, _ in
                                             calls.add(url)
                                             return outcome(url, calls.all.filter { $0 == url }.count)
                                         },
                                         render: { path, _, h in
                                             Array(repeating: path.contains("spandac") ? "PRIMARYART" : "RESTART",
                                                   count: max(1, h))
                                         },
                                         now: clock.now)
                self.lock.lock(); self.storesStorage.append(store); self.lock.unlock()
                return store
            }
            let mode = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
            mode.set(.source)
            let status = StatusStore()
            scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                                    status: status, actions: ActionRunner(status: status),
                                    routing: RoutingCoordinator(store: mode, surface: .tui,
                                                                makeSource: { SourceAppClient(path: "/nonexistent") }),
                                    makeArtworkStore: make,
                                    restLookup: { _, _, _ in (id: "l.albumx", url: NowArtworkFallbackDemandTests.restTemplate) })
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }

        func idle() { stores.forEach { $0.waitUntilIdleForTesting() } }
        func requests(_ url: String) -> Int { calls.all.filter { $0 == url }.count }
    }

    private let frame = shellLayout(width: 120, height: 40)

    private func np() -> NowPlayingState {
        var np = NowPlayingState()
        np.track = "Song One"; np.artist = "Artist X"; np.album = "Album X"; np.state = "paused"
        return np
    }

    /// The Music.app snapshot that resolved album X's REST cover earlier.
    private func musicAppSnapshot() -> NowPlayingSnapshot {
        NowPlayingSnapshot(outcome: .active(np()), history: [], surrounding: [])
    }

    /// SpanDAC, paused on the same album, with a remote artwork URL.
    private func bridgeSnapshot() -> NowPlayingSnapshot {
        var snap = NowPlayingSnapshot(outcome: .active(np()), history: [], surrounding: [])
        var bridge = BridgeNow(link: .answering, playback: "paused", title: "Song One", artist: "Artist X",
                               queue: .none, index: nil)
        bridge.artworkURL = Self.primaryURL
        snap.bridge = bridge
        return snap
    }

    /// Resolve album X's REST cover (restArt) on the Music.app output, without
    /// painting, so no cover fetch happens yet. Polls for the tick that drains
    /// the lookup's inbox, bounded.
    private func resolveRestFallback(_ rig: Rig) {
        let deadline = Date().addingTimeInterval(10)
        var landed = false
        while !landed, Date() < deadline {
            landed = rig.scene.tick(snapshot: musicAppSnapshot())
            if !landed { usleep(2_000) }
        }
        XCTAssertTrue(landed, "the REST lookup never landed")
        XCTAssertEqual(rig.calls.count, 0, "resolving the album must not fetch a cover")
    }

    /// Paint once on SpanDAC, then 31 s of the shell loop at 4 Hz with the
    /// render gate shut: the same snapshot, no key, no position change. Only a
    /// tick that reports a change paints, as Shell.swift does.
    private func paintOnceThenIdle(_ rig: Rig) -> String {
        let snap = bridgeSnapshot()
        var last = rig.scene.render(frame: frame, snapshot: snap)
        rig.idle()
        var gate = ShellRenderGate()
        _ = gate.snapshotNeedsRender(snapshot: snap, generation: 1, active: .nowPlaying)
        for _ in 0..<124 {
            rig.clock.advance(0.25)
            XCTAssertFalse(gate.snapshotNeedsRender(snapshot: snap, generation: 1, active: .nowPlaying),
                           "the gate must stay shut: only ticks may drive recovery")
            rig.idle()
            if rig.scene.tick(snapshot: snap) { last = rig.scene.render(frame: frame, snapshot: snap) }
        }
        rig.idle()
        if rig.scene.tick(snapshot: snap) { last = rig.scene.render(frame: frame, snapshot: snap) }
        return last
    }

    /// Codex's case: the primary is unusable (permanent failure), the fallback
    /// fails temporarily once. Ticks alone must retry and show the fallback.
    func testAnUnusablePrimaryLeavesTheFallbackRetryAliveOnTicksAlone() {
        let rig = Rig(outcome: { url, n in
            if url == Self.primaryURL { return .permanent }
            return n == 1 ? .temporary : .data(Data([1, 2, 3]))
        })
        resolveRestFallback(rig)
        let last = paintOnceThenIdle(rig)
        XCTAssertEqual(rig.requests(Self.primaryURL), 1, "an unusable primary is never re-asked")
        XCTAssertEqual(rig.requests(Self.restURL), 2, "the fallback's retry was dropped: \(rig.calls.all)")
        XCTAssertTrue(last.contains("RESTART"), "the fallback cover never recovered")
    }

    /// The primary keeps failing temporarily (still pending, as far as the
    /// ladder knows); the fallback fails once, then succeeds.
    func testAPendingPrimaryLeavesTheFallbackRetryAliveOnTicksAlone() {
        let rig = Rig(outcome: { url, n in
            if url == Self.primaryURL { return .temporary }
            return n == 1 ? .temporary : .data(Data([1, 2, 3]))
        })
        resolveRestFallback(rig)
        let last = paintOnceThenIdle(rig)
        XCTAssertEqual(rig.requests(Self.restURL), 2, "the fallback's retry was dropped: \(rig.calls.all)")
        XCTAssertGreaterThanOrEqual(rig.requests(Self.primaryURL), 2, "the primary's own retry was dropped")
        XCTAssertTrue(last.contains("RESTART"), "the fallback cover never recovered")
    }

    /// The ladder's order holds: the fallback shows while the primary cools
    /// down, and the primary replaces it once its retry lands, on ticks alone.
    func testAPrimaryThatLaterArrivesWinsOverTheShownFallback() {
        let rig = Rig(outcome: { url, n in
            if url == Self.primaryURL { return n == 1 ? .temporary : .data(Data([4, 5, 6])) }
            return .data(Data([1, 2, 3]))
        })
        resolveRestFallback(rig)
        let last = paintOnceThenIdle(rig)
        XCTAssertEqual(rig.requests(Self.primaryURL), 2, "the primary's retry was dropped: \(rig.calls.all)")
        XCTAssertTrue(last.contains("PRIMARYART"), "the primary never replaced the fallback")
        XCTAssertFalse(last.contains("RESTART"), "the fallback still shows over an available primary")
    }
}

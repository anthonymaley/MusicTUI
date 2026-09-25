import XCTest
@testable import music

/// DoD 7's middle clause covers the routing coordinator
/// (`RoutingCoordinatorTests.testMusicAppModeNeverInvokesTheSourceFactory`), but
/// step 4 gave the POLLER its own Bridge client, built from its own factory and
/// outside the coordinator. Nothing pinned that the poller stays away from
/// Bridge in Music.app mode, and a wrong branch there would put Bridge's state
/// on a Music.app screen — the exact defect step 4 existed to remove, wearing
/// the other face.
final class PollerModeBoundaryTests: XCTestCase {

    private final class Factory {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func make() -> SourceAppClient {
            lock.lock(); _calls += 1; lock.unlock()
            // A dead socket: the poller's read fails and it takes its own
            // failure path, which is all this test needs it to do.
            return SourceAppClient(path: "/nonexistent")
        }
    }

    private func poller(mode: PlaybackMode, factory: Factory) -> (PlaybackPoller, NowPlayingStore) {
        let store = NowPlayingStore()
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(mode)
        let routing = RoutingCoordinator(store: modeStore, surface: .tui, makeSource: { factory.make() })
        let poller = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                    appQueue: AppQueueStore(),
                                    queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                                    routing: routing,
                                    makeSourceClient: { factory.make() })
        return (poller, store)
    }

    /// Bridge selected: the poller reads Bridge, and only Bridge.
    func testBridgeModeReadsBridge() {
        let factory = Factory()
        let (poller, store) = poller(mode: .source, factory: factory)
        poller.tick()
        XCTAssertGreaterThan(factory.calls, 0, "Bridge mode must ask Bridge for the state it shows")
        XCTAssertNotNil(store.read().bridge, "the snapshot must carry Bridge's own state")
    }

    /// Music.app selected: the poller never builds a Bridge client, and the
    /// snapshot carries no Bridge state for a scene to render.
    func testMusicAppModeNeverBuildsABridgeClient() {
        let factory = Factory()
        let (poller, store) = poller(mode: .musicApp, factory: factory)
        poller.tick()
        XCTAssertEqual(factory.calls, 0, "Music.app mode built a Bridge client")
        XCTAssertNil(store.read().bridge, "a Music.app snapshot must carry no Bridge state")
    }
}

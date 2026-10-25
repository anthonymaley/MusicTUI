import XCTest
@testable import music

/// The shell repainted the whole body on every poller write, so a paused,
/// unchanged song cost a full-screen repaint every poll (dear over SSH). The
/// decision is `ShellRenderGate`; these pin what must and must not repaint.
final class ShellRenderGateTests: XCTestCase {
    private func snap(track: String = "Nude", position: Int = 10, state: String = "playing") -> NowPlayingSnapshot {
        var np = NowPlayingState()
        np.track = track; np.artist = "Radiohead"; np.album = "In Rainbows"
        np.duration = 255; np.position = position; np.state = state
        return NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])
    }

    /// Writes through a real store and asks the gate, as the loop does each pass.
    private func pass(_ gate: inout ShellRenderGate, _ store: NowPlayingStore,
                      _ next: NowPlayingSnapshot, on scene: SceneID) -> Bool {
        store.write(next)
        let (s, g) = store.readWithGeneration()
        return gate.snapshotNeedsRender(snapshot: s, generation: g, active: scene)
    }

    func testFirstSnapshotPaints() {
        var gate = ShellRenderGate(); let store = NowPlayingStore()
        XCTAssertTrue(pass(&gate, store, snap(), on: .library))
    }

    func testIdenticalSnapshotWrittenTwiceRequestsNoRender() {
        for scene in [SceneID.library, .nowPlaying] {
            var gate = ShellRenderGate(); let store = NowPlayingStore()
            XCTAssertTrue(pass(&gate, store, snap(state: "paused"), on: scene))
            XCTAssertFalse(pass(&gate, store, snap(state: "paused"), on: scene), "\(scene)")
            XCTAssertFalse(pass(&gate, store, snap(state: "paused"), on: scene), "\(scene)")
        }
    }

    func testTrackChangeRendersOnEveryScene() {
        for scene in [SceneID.library, .playlists, .nowPlaying, .radio, .discover, .speakers] {
            var gate = ShellRenderGate(); let store = NowPlayingStore()
            _ = pass(&gate, store, snap(track: "Nude"), on: scene)
            XCTAssertTrue(pass(&gate, store, snap(track: "Weird Fishes", position: 0), on: scene), "\(scene)")
        }
    }

    func testPlayStateChangeRendersOnEveryScene() {
        for scene in [SceneID.library, .nowPlaying] {
            var gate = ShellRenderGate(); let store = NowPlayingStore()
            _ = pass(&gate, store, snap(state: "playing"), on: scene)
            XCTAssertTrue(pass(&gate, store, snap(state: "paused"), on: scene), "\(scene)")
        }
    }

    func testElapsedChangeOnTheNowTabRenders() {
        var gate = ShellRenderGate(); let store = NowPlayingStore()
        _ = pass(&gate, store, snap(position: 10), on: .nowPlaying)
        XCTAssertTrue(pass(&gate, store, snap(position: 11), on: .nowPlaying))
        XCTAssertTrue(pass(&gate, store, snap(position: 12), on: .nowPlaying))
    }

    func testElapsedOnlyChangeOnASceneWithNoProgressRequestsNoRender() {
        for scene in [SceneID.library, .playlists, .radio, .discover, .speakers] {
            var gate = ShellRenderGate(); let store = NowPlayingStore()
            _ = pass(&gate, store, snap(position: 10), on: scene)
            XCTAssertFalse(pass(&gate, store, snap(position: 11), on: scene), "\(scene)")
            XCTAssertFalse(pass(&gate, store, snap(position: 12), on: scene), "\(scene)")
        }
    }

    /// A tick swallowed on Library must not be lost: the track change that
    /// follows is compared against the last snapshot SEEN, and still paints.
    func testTrackChangeAfterSwallowedElapsedTicksStillRenders() {
        var gate = ShellRenderGate(); let store = NowPlayingStore()
        _ = pass(&gate, store, snap(position: 10), on: .library)
        XCTAssertFalse(pass(&gate, store, snap(position: 11), on: .library))
        XCTAssertTrue(pass(&gate, store, snap(track: "Weird Fishes", position: 12), on: .library))
    }

    /// Elapsed ticks arrive while on Library; switching to Now is a keypress
    /// (which repaints regardless), but a poll right after must still be judged
    /// against the current scene, not stale state.
    func testSwitchingSceneJudgesTheNextElapsedTickByTheNewScene() {
        var gate = ShellRenderGate(); let store = NowPlayingStore()
        _ = pass(&gate, store, snap(position: 10), on: .library)
        XCTAssertFalse(pass(&gate, store, snap(position: 11), on: .library))
        XCTAssertTrue(pass(&gate, store, snap(position: 12), on: .nowPlaying))
    }

    func testToastAppearingChangingAndExpiringStillRender() {
        var gate = ShellRenderGate()
        let t1 = StatusToast(text: "Saved", isError: false, expiresAt: Date(timeIntervalSince1970: 100))
        let t2 = StatusToast(text: "Failed", isError: true, expiresAt: nil)
        XCTAssertFalse(gate.toastNeedsRender(nil), "no toast, none before")
        XCTAssertTrue(gate.toastNeedsRender(t1), "appears")
        XCTAssertFalse(gate.toastNeedsRender(t1), "unchanged")
        XCTAssertTrue(gate.toastNeedsRender(t2), "changes")
        XCTAssertTrue(gate.toastNeedsRender(nil), "expires")
    }

    func testBridgeChangeRenders() {
        var gate = ShellRenderGate(); let store = NowPlayingStore()
        var a = snap(); a.bridge = BridgeNow.empty
        var b = a; b.bridge?.playback = "playing"
        _ = pass(&gate, store, a, on: .library)
        XCTAssertTrue(pass(&gate, store, b, on: .library))
    }
}

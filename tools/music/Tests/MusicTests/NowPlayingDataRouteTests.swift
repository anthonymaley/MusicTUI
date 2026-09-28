// tools/music/Tests/MusicTests/NowPlayingDataRouteTests.swift
//
// Now, the poller and transport follow the OUTPUT only (score: data route and
// output, step 5). SpanDAC data with the MusicTUI output reads what MusicTUI
// plays, never SpanDAC; a SpanDAC output reads that output; a blocked output
// (C-REPAIR) builds no SpanDAC client at all. Fakes and temp stores only; the
// AppleScript backend is `/usr/bin/true`, so nothing reaches Apple's Music app.
import XCTest
@testable import music

final class NowPlayingDataRouteTests: XCTestCase {

    private func poller(_ rig: SceneDataRig, routing: RoutingCoordinator) -> (PlaybackPoller, NowPlayingStore) {
        let store = NowPlayingStore()
        let poller = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                    appQueue: AppQueueStore(),
                                    queueStore: QueueStore(path: (rig.dir as NSString).appendingPathComponent("q.json")),
                                    routing: routing,
                                    makeSourceClient: { rig.makeOutput(.source) })
        return (poller, store)
    }

    private func nowScene(_ routing: RoutingCoordinator, status: StatusStore) -> NowPlayingScene {
        NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                        status: status, actions: ActionRunner(status: status), routing: routing)
    }

    /// The same accepted SpanDAC data under three outputs: the poller reads
    /// the OUTPUT (SpanDAC's state only on a SpanDAC output), and never the
    /// data client; Now's keys follow the output's column.
    func testNowFollowsTheOutputNotTheData() {
        // SpanDAC data, the MusicTUI output: MusicTUI's own player, no SpanDAC.
        let tui = SceneDataRig(output: .musicApp, accepted: true)
        let tuiRouting = tui.coordinator()
        let (p1, s1) = poller(tui, routing: tuiRouting)
        p1.tick()
        XCTAssertEqual(tui.dataBuilt, 0, "Now read the data client")
        XCTAssertEqual(tui.outputBuilt, [], "Now built a SpanDAC client for the MusicTUI output")
        XCTAssertNil(s1.read().bridge)
        let tuiScene = nowScene(tuiRouting, status: StatusStore())
        XCTAssertFalse(tuiScene.footerHint.hasPrefix("[ ] Seek  x Quiet"),
                       "the MusicTUI output keeps its own Now keys")

        // SpanDAC data, SpanDAC on this Mac as the output: that output's state.
        let mac = SceneDataRig(output: .source, accepted: true)
        let (p2, s2) = poller(mac, routing: mac.coordinator())
        p2.tick()
        XCTAssertEqual(mac.dataBuilt, 0, "Now read the data client")
        XCTAssertEqual(mac.outputBuilt, [.source])
        XCTAssertEqual(mac.sent("slice.status").map(\.tag), ["output:musictui_source"])
        XCTAssertNotNil(s2.read().bridge)

        // SpanDAC data, a network SpanDAC output: that output, not the Mac.
        let pad = SceneDataRig(output: .networkSource(SceneDataRig.ipad), accepted: true)
        let (p3, s3) = poller(pad, routing: pad.coordinator())
        p3.tick()
        XCTAssertEqual(pad.dataBuilt, 0)
        XCTAssertEqual(pad.sent("slice.status").map(\.tag), ["output:\(SceneDataRig.ipad)"])
        XCTAssertNotNil(s3.read().bridge)
    }

    /// A blocked output: the poller builds no SpanDAC client of either kind
    /// and asks no player; Now says why, and its keys refuse in the
    /// finish-switching sentence.
    func testABlockedOutputPollsNothingAndNowSaysWhy() {
        let rig = SceneDataRig(output: .source, accepted: false)
        let routing = rig.coordinator()
        let (p, store) = poller(rig, routing: routing)
        p.tick()

        XCTAssertEqual(rig.dataBuilt, 0)
        XCTAssertEqual(rig.outputBuilt, [])
        XCTAssertTrue(rig.sent.isEmpty)
        XCTAssertNil(store.read().bridge)

        let status = StatusStore()
        let scene = nowScene(routing, status: status)
        let out = scene.render(frame: shellLayout(width: 120, height: 40), snapshot: store.read())
        XCTAssertTrue(out.contains("MusicTUI hasn't finished switching to SpanDAC"), out)
        _ = scene.handle(.char("s"))
        XCTAssertEqual(status.current()?.text, finishSwitchingToSpanDAC)
    }
}

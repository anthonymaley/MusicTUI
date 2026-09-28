// tools/music/Tests/MusicTests/RadioDataRouteTests.swift
//
// The Radio tab on two axes (score: data route and output, step 5): its lists
// come from the DATA selection, and a station on the MusicTUI output plays by
// its share URL. Fakes and temp stores only (see `SceneDataRig`).
import XCTest
@testable import music

final class RadioDataRouteTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let amOne = Station(id: "ra.978194965", name: "Apple Music 1",
                                url: "https://music.apple.com/us/station/apple-music-1/ra.978194965",
                                isLive: true, artworkURL: nil)

    private func radio(_ rig: SceneDataRig, opener: Opener) -> (RadioScene, RoutingCoordinator) {
        let routing = rig.coordinator()
        let store = StationStore(path: (rig.dir as NSString).appendingPathComponent("stations.json"))
        return (RadioScene(routing: routing, store: store, catalog: nil, opener: opener), routing)
    }

    private func tickUntil(_ s: RadioScene, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { _ = s.tick(snapshot: idle); usleep(2_000) }
    }

    /// With SpanDAC data and the MusicTUI output, a station plays by its share
    /// URL through the opener: SpanDAC is never asked to play it, and no
    /// SpanDAC output client is built.
    func testRadioStationsPlayByURLOnTheMusicTUIOutput() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let opener = SceneRecordingOpener()
        let (s, _) = radio(rig, opener: opener)

        s.execute(.play(amOne))

        XCTAssertEqual(opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertEqual(s.message, "▶ Apple Music 1")
        XCTAssertEqual(rig.sent("slice.playStation").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
    }

    /// A blocked output plays nothing on either output, in the finish-switching
    /// sentence, and builds no SpanDAC client.
    func testABlockedOutputRefusesAStationAndBuildsNoClient() {
        let rig = SceneDataRig(output: .source, accepted: false)
        let opener = SceneRecordingOpener()
        let (s, _) = radio(rig, opener: opener)

        s.execute(.play(amOne))

        XCTAssertEqual(s.message, "✗ " + finishSwitchingToSpanDAC)
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(rig.dataBuilt, 0)
        XCTAssertEqual(rig.outputBuilt, [])
    }

    /// Live comes from SpanDAC on this Mac with SpanDAC data, on the MusicTUI
    /// output with no developer key at all.
    func testRadioListsComeFromTheMacOnTheMusicTUIOutput() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let (s, _) = radio(rig, opener: SceneRecordingOpener())

        tickUntil(s) { s.liveLoaded }

        XCTAssertEqual(s.live.map(\.id), ["ra.978194965"])
        XCTAssertEqual(rig.sent("slice.liveStations").map(\.tag), ["mac-data"])
        XCTAssertEqual(rig.outputBuilt, [])
    }

    /// A Live row read before stopping using SpanDAC plays nothing afterwards:
    /// the lists reload, and the old row's play refuses.
    func testALiveRowReadBeforeTheDataSwitchPlaysNothing() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let opener = SceneRecordingOpener()
        let (s, routing) = radio(rig, opener: opener)
        tickUntil(s) { s.liveLoaded }
        _ = s.handle(.char("]"))   // Favorites -> Live
        XCTAssertEqual(try routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in }),
                       .stopped)

        _ = s.handle(.enter)

        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(s.message, "✗ " + sourceChangedNothingPlayed)
        _ = s.tick(snapshot: idle)
        XCTAssertFalse(s.liveLoaded, "the lists from SpanDAC go once data is MusicTUI's own again")
    }
}

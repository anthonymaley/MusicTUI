// tools/music/Tests/MusicTests/MusicTUIOutputWithoutADACTests.swift
//
// Music data and sound are independent. With SpanDAC on this Mac as the data
// source and the MusicTUI output selected (Apple's Music player, to the Mac's
// speakers or AirPlay), nothing needs a DAC: SpanDAC only reads and adds. A
// DAC matters only when a SpanDAC IS the selected output.
//
// Every store is a temp path and every client a fake transport. No test here
// reaches a real player, Apple's Music app, the network or ~/.config/music.
import XCTest
@testable import music

/// SpanDAC on this Mac answering, allowed Apple Music, with no DAC on its
/// cable. Ready for music data; not ready to play on that SpanDAC.
let noDACStatus =
    #"{"ok":true,"op":"slice.status","status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":[],"output":{"dac":"not_connected"}}}"#

final class MusicTUIOutputWithoutADACTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    /// A Discover album on the MusicTUI output with SpanDAC data and no
    /// DAC: SpanDAC on this Mac ensures the container, and it plays by the
    /// persistent ID SpanDAC returned. No DAC refusal, nothing queued on any
    /// SpanDAC. (An album since 2026-10-02: a catalogue playlist there plays
    /// on Apple's own copy instead, `DiscoverFromHereRoutingTests`.)
    func testDiscoverContainerOnMusicTUIOutputWithoutADAC() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.status"] = noDACStatus
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let log = SceneLifecycleLog()
        let mac = FakeSpanDACMac(library: FakeAppleLibrary())
        mac.outputDAC = "not_connected"
        log.mac = mac
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }),
            readCountByPersistentID: { _ in 100 },
            confirmReadByPersistentID: { _ in discoverConfirmedToken },
            readContainerTrackIDsByPersistentID: { log.mac?.containerTrackIDs($0) },
            readTracksByPersistentID: { hexes in
                guard let mac = log.mac else { throw Stop.stop }
                return try mac.library.persistentIDReader.tracks(persistentIDs: hexes)
            })
        let lifecycle = DiscoverLifecycleCoordinator(seams: seams)
        lifecycle.completeLaunchSweep(.swept)
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle, routing: rig.coordinator(), opener: SceneRecordingOpener())
        scene.libraryOps = mac.client
        let deadline = Date().addingTimeInterval(5)
        while scene.rails.isEmpty && scene.loadFailure == nil && Date() < deadline {
            _ = scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertNil(scene.loadFailure, "no DAC is no reason to refuse Discover's rails")

        let row = DiscoverItem(id: "1440857781", name: "Boom Bap", subtitle: nil, url: nil, artworkURL: nil,
                               detail: .album(trackCount: nil, year: nil, genre: nil))
        scene.playAllFromRail(row)
        drain(actions)

        XCTAssertEqual(mac.ops("slice.libraryEnsurePlaylist").count, 1, "ensured by SpanDAC on this Mac")
        XCTAssertEqual(log.played, [discoverPlayScripts(persistentID: "0000000000000F01", disableShuffle: false)],
                       "played by the persistent ID SpanDAC returned")
        XCTAssertFalse(status.current()?.text.contains("DAC") ?? false,
                       "got: \(String(describing: status.current()?.text))")
        XCTAssertEqual(rig.sent("slice.queue").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
    }

    /// OUTPUT readiness keeps its DAC: with SpanDAC data accepted and no DAC,
    /// switching the output to SpanDAC on this Mac refuses with the DAC reason
    /// and the MusicTUI output stays selected. The same status is ready for
    /// music data.
    func testPlayingOnASpanDACOutputStillNeedsItsDAC() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.status"] = noDACStatus
        let routing = rig.coordinator()
        let incoming = rig.makeOutput(.source)

        XCTAssertThrowsError(try routing.switchMode(to: .source, readiness: { incoming.readiness() },
                                                    pauseOutgoing: { _ in true }, dropQueue: { _ in })) { error in
            XCTAssertTrue((error as? ActionError)?.message.contains("plug in your DAC") ?? false, "\(error)")
        }
        XCTAssertEqual(routing.mode, .musicApp, "the output did not change")
        XCTAssertEqual(rig.sent("slice.queue").count + rig.sent("slice.play").count, 0, "nothing played")
        XCTAssertEqual(try rig.makeOutput(.source).control.status().dataReadiness, .ready,
                       "no DAC is ready for music data")
    }
}

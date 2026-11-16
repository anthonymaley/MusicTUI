// tools/music/Tests/MusicTests/MacRouteFix1Tests.swift
//
// Mac route fix round 1 (after Codex's whole-build review), finding 2: a CLI
// station play on the Mac DAC route moves the fence and takes the lease like the
// TUI's station does, instead of opening under the ordinary output lock alone.
//
// Fakes only: the mode store, the output lock and the fence files are in a temp
// directory (`CLIDataRouteHarness`), SpanDAC is a scripted transport, the opener
// counts. No audio, no AppleScript, no socket, no keychain, never ~/.config/music.
import ArgumentParser
import XCTest
@testable import music

final class MacRouteFix1Tests: XCTestCase {

    private final class Clock { var t: TimeInterval = 0 }
    private final class NoMusic: RateMusicControlling {
        func playTrack(persistentID: String) throws {}
        func pause() throws {}
        func resume() throws {}
        func seekToStart() throws {}
        func readCurrentTrack() -> RateTrackRead? { nil }
        func readPlayerState() -> RatePlayerState? { nil }
    }

    /// A route player over the harness's own state directory and a scripted SpanDAC.
    private func player(_ h: CLIDataRouteHarness, on: Bool = true, owner: String = "cli-station",
                        ops: @escaping (String) -> Void) -> MacRoutePlayer {
        let clock = Clock()
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                ops(body["op"] as? String ?? "")
                let rate: [String: Any] = ["fence": body["fence"] as? Int ?? 0, "outcome": "quiet",
                                           "dac_rate_hz": 96000, "rate_seq": 1]
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "rate": rate])
                return String(decoding: data, as: UTF8.self)
            }
        }
        var control = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        control.rateSender = { transport($0) }
        return MacRoutePlayer(
            route: MacDACRouteState(initial: on), outputIsMusicApp: { true },
            fence: RateFence(store: h.env.modeStore), owner: owner,
            makeMusic: { _ in NoMusic() }, resolvePersistentID: { _, _ in nil },
            makeFollow: { SourceRateFollow(token: $0, control: control, offered: true,
                                           now: { clock.t }, sleep: { clock.t += $0 }) },
            post: { _ in }, now: { clock.t })
    }

    private let readyWithoutADAC =
        #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"output":{"dac":"not_connected"}}}"#

    private let appleMusic1 = "https://music.apple.com/us/station/apple-music-1/ra.978194965"

    private func harness() -> CLIDataRouteHarness {
        CLIDataRouteHarness(output: .musicApp, data: .accepted,
                            dataReplies: ["slice.status": [readyWithoutADAC]])
    }

    /// The station moves the fence past a queue runner's and takes the lease, so
    /// the runner stops at its next look and an older rate write or correction
    /// cannot land after the station starts; the open runs under the lock with the
    /// token revalidated; and no rate is prepared or confirmed for a station.
    func testACLIStationOnTheRouteMovesTheFenceAndTakesTheLeaseFromAQueueRunner() throws {
        let h = harness()
        let fence = RateFence(store: h.env.modeStore)
        let runnerToken = try fence.begin(.play, owner: "queue-runner")
        var ops: [String] = []
        let p = player(h, ops: { ops.append($0) })
        let opener = CLIRadioCountingOpener()
        opener.lockPath = h.env.routing.outputLock!.path
        let stations = StationStore(path: h.directory + "/stations.json")

        try runRadioPlay(query: [appleMusic1], env: h.env, opener: opener, stations: stations,
                         routePlayer: { p }, musicApp: { _ in XCTFail("the shipped radio body ran") })

        XCTAssertEqual(opener.urls, [stationPlayURL(appleMusic1)!])
        XCTAssertEqual(opener.lockedDuringOpen, [true], "the open runs under the output lock")
        XCTAssertGreaterThan(try fence.current(), runnerToken.fence, "the station did not move the fence")
        XCTAssertEqual(fence.leaseStatus(owner: "queue-runner"), .another, "the runner kept its lease")
        XCTAssertEqual(fence.leaseStatus(owner: "cli-station"), .ours)
        XCTAssertFalse(ops.contains(sourcePrepareRateOp), "a station never prepares a rate")
        XCTAssertFalse(ops.contains(sourceConfirmRateOp), "a station never confirms a rate")
        XCTAssertTrue(ops.contains(sourceRateFenceOp) || ops.contains(sourceRateSettleOp), "SpanDAC was not told the fence")
        XCTAssertEqual(h.io.out, ["▶ Apple Music 1"])
    }

    /// The command's mode revalidation, which the plain path got from
    /// `cliUnderOutputLock`, still happens: the output changed during the quiet
    /// wait, so nothing is opened and the CLI says so.
    func testACLIStationOnTheRouteStillRefusesWhenTheOutputChangedUnderIt() throws {
        let h = harness()
        let opener = CLIRadioCountingOpener()
        let stations = StationStore(path: h.directory + "/stations.json")
        let p = player(h, ops: { _ in _ = h.env.modeStore.set(.source) })       // the switch lands mid-wait
        var thrown: Error?
        do {
            try runRadioPlay(query: [appleMusic1], env: h.env, opener: opener, stations: stations,
                             routePlayer: { p }, musicApp: { _ in })
        } catch { thrown = error }
        XCTAssertEqual(opener.urls, [], "a station opened over a route switch")
        XCTAssertEqual(thrown as? ExitCode, .failure)
        XCTAssertEqual(h.io.out.count, 1)
        XCTAssertTrue(h.io.out[0].contains("Output changed to"), "\(h.io.out)")
    }

    /// Off the route (the player says so), or with no route player, a CLI station is
    /// what it always was: no fence move, one open under the plain lock.
    func testACLIStationOffTheRouteIsWhatItAlwaysWas() throws {
        let h = harness()
        let fence = RateFence(store: h.env.modeStore)
        var ops: [String] = []
        let off = player(h, on: false, ops: { ops.append($0) })
        let opener = CLIRadioCountingOpener()
        opener.lockPath = h.env.routing.outputLock!.path
        let stations = StationStore(path: h.directory + "/stations.json")
        try runRadioPlay(query: [appleMusic1], env: h.env, opener: opener, stations: stations,
                         routePlayer: { off }, musicApp: { _ in })
        try runRadioPlay(query: [appleMusic1], env: h.env, opener: opener, stations: stations, musicApp: { _ in })
        XCTAssertEqual(opener.urls.count, 2)
        XCTAssertEqual(opener.lockedDuringOpen, [true, true])
        XCTAssertEqual(try fence.current(), 0)
        XCTAssertEqual(ops, [])
    }
}

// tools/music/Tests/MusicTests/MacRouteScopeTests.swift
//
// Score step P7 (mac-route-plan.md 3.9, D3, ruling 2026-11-14 17:21): on the
// Mac DAC route a search play takes the catalogue `.add` path instead of being
// refused; the DJ's artist mix stays iPhone/iPad only, said plainly; a station
// moves the fence and its line never claims "converted" without a delivered
// rate. Fakes only: temp stores, a scripted rate transport, a fake Music.
import XCTest
@testable import music

final class MacRouteScopeTests: XCTestCase {

    // MARK: search on the route (the coordinator)

    func testASearchPlayOnTheMacRouteTakesTheAddPathAndIsAdmitted() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        routing.macRouteStore.set(true)
        var paths: [MusicTUIPlayPath] = []
        let serial = routing.playSerial
        try routing.perform(.discoverTrackPlay, expecting: routing.stamp, origin: .spandacCatalogue,
                            searchOrigin: true, musicApp: { paths.append($0) },
                            source: { _ in XCTFail("source ran") }, unaffected: {})
        XCTAssertEqual(paths, [.add])
        XCTAssertEqual(routing.playSerial, serial + 1)
    }

    func testASearchPlayOffTheRouteStillRefuses() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        XCTAssertThrowsError(try routing.perform(.discoverTrackPlay, expecting: routing.stamp,
                                                 origin: .spandacCatalogue, searchOrigin: true,
                                                 musicApp: { _ in XCTFail("body ran") },
                                                 source: { _ in XCTFail("source ran") }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, searchPlaysOnSpanDACOnly)
        }
    }

    /// The route's saved choice is not enough with MusicTUI's own data: the
    /// refusal stands, since there is no SpanDAC data to add through.
    func testASearchPlayOnTheRouteWithMusicTUIDataStillRefuses() {
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let routing = rig.coordinator()
        routing.macRouteStore.set(true)
        XCTAssertThrowsError(try routing.perform(.discoverTrackPlay, expecting: nil,
                                                 origin: .openData(resultNumber: nil), searchOrigin: true,
                                                 musicApp: { _ in XCTFail("body ran") },
                                                 source: { _ in XCTFail("source ran") }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, searchPlaysOnSpanDACOnly)
        }
    }

    // MARK: the DJ sentence

    func testTheDJArtistMixStaysRefusedOnTheMacRouteWithAPlainSentence() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        routing.macRouteStore.set(true)
        var ran = false
        XCTAssertThrowsError(try routing.perform(.discoverTrackPlay, expecting: routing.stamp, origin: .djArtistMix,
                                                 musicApp: { _ in ran = true },
                                                 source: { _ in XCTFail("source ran") }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message,
                           "The DJ plays artist mixes on an iPhone or iPad SpanDAC only. Pick one on the Output tab.")
        }
        XCTAssertFalse(ran)
    }

    // MARK: the station line

    func testTheStationLineNeverClaimsConvertedWithoutADeliveredRate() {
        XCTAssertEqual(stationRateLine(dacRateHz: 96000, deliveredHz: nil), "Radio")
        XCTAssertEqual(stationRateLine(dacRateHz: nil, deliveredHz: nil), "Radio")
        XCTAssertEqual(stationRateLine(dacRateHz: nil, deliveredHz: 44100), "Radio")
        XCTAssertEqual(stationRateLine(dacRateHz: 48000, deliveredHz: 44100), "converted to 48 kHz: radio")
        XCTAssertEqual(stationRateLine(dacRateHz: 44100, deliveredHz: 44100), "44.1 kHz: radio")
        XCTAssertEqual(macRateKHzText(176400), "176.4")
    }

    // MARK: a station on the route

    private final class Clock { var t: TimeInterval = 0 }
    private final class NoMusic: RateMusicControlling {
        func playTrack(persistentID: String) throws {}
        func pause() throws {}
        func resume() throws {}
        func seekToStart() throws {}
        func readCurrentTrack() -> RateTrackRead? { nil }
        func readPlayerState() -> RatePlayerState? { nil }
    }

    private func player(ops: @escaping (String) -> Void, posts: @escaping (String) -> Void = { _ in },
                        route: MacDACRouteState, dir: String) -> MacRoutePlayer {
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
            route: route, outputIsMusicApp: { true },
            fence: RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001)),
            owner: "tui", makeMusic: { _ in NoMusic() }, resolvePersistentID: { _, _ in nil },
            makeFollow: { SourceRateFollow(token: $0, control: control, offered: true,
                                           now: { clock.t }, sleep: { clock.t += $0 }) },
            post: posts, now: { clock.t })
    }

    func testAStationOnTheRouteMovesTheFenceAndSaysRadio() throws {
        let dir = OutputLockTestSupport.tempDir()
        let route = MacDACRouteState(initial: true)
        var ops: [String] = []
        let p = player(ops: { ops.append($0) }, route: route, dir: dir)
        var opened: [String] = []
        let opener = MacRouteOpener(base: RecordingOpener { opened.append($0) }, route: { p })

        try opener.open("music://music.apple.com/us/station/x/ra.1")

        XCTAssertEqual(opened, ["music://music.apple.com/us/station/x/ra.1"])
        XCTAssertGreaterThanOrEqual(try p.fence.current(), 1, "the station did not move the fence")
        XCTAssertFalse(ops.contains(sourcePrepareRateOp), "a station never prepares a rate")
        XCTAssertFalse(ops.contains(sourceConfirmRateOp), "a station never confirms a rate")
        XCTAssertEqual(opener.takeStationLine(), "Radio")
        XCTAssertNil(opener.takeStationLine(), "the line is said once")
        XCTAssertEqual(stationPlayingLine("Apple Music 1", opener: opener), "Playing Apple Music 1",
                       "no line left over from the play before")
    }

    func testAStationOffTheRouteIsOpenedAsItAlwaysWasWithNoFenceMove() throws {
        let dir = OutputLockTestSupport.tempDir()
        let route = MacDACRouteState(initial: false)
        var ops: [String] = []
        let p = player(ops: { ops.append($0) }, route: route, dir: dir)
        var opened: [String] = []
        let opener = MacRouteOpener(base: RecordingOpener { opened.append($0) }, route: { p })

        try opener.open("music://x")

        XCTAssertEqual(opened, ["music://x"])
        XCTAssertEqual(ops, [])
        XCTAssertEqual(try p.fence.current(), 0)
        XCTAssertNil(opener.takeStationLine())
    }

    func testAStationThatFailsToOpenOnTheRouteSaysSoAndLeavesNoLine() {
        let dir = OutputLockTestSupport.tempDir()
        let p = player(ops: { _ in }, route: MacDACRouteState(initial: true), dir: dir)
        struct Boom: Error {}
        let opener = MacRouteOpener(base: RecordingOpener { _ in throw Boom() }, route: { p })
        XCTAssertThrowsError(try opener.open("music://x")) {
            XCTAssertEqual(($0 as? ActionError)?.message, stationCouldNotStartLine)
        }
        XCTAssertNil(opener.takeStationLine())
    }

    private struct RecordingOpener: Opener {
        let body: (String) throws -> Void
        init(_ body: @escaping (String) throws -> Void) { self.body = body }
        func open(_ url: String) throws { try body(url) }
    }
}

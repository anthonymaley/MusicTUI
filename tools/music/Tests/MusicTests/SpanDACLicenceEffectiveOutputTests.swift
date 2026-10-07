// tools/music/Tests/MusicTests/SpanDACLicenceEffectiveOutputTests.swift
//
// Codex review 101, blocking 1: the shell's decisions about SOUND follow the
// coordinator's effective output, never the stored choice. While SpanDAC on
// this Mac is stored but not serving, MusicTUI is the output; while a
// SpanDAC's queue plays out, that SpanDAC is. These drive the real shell
// wiring (global Next/Previous, the Now scene, the Output tab and the footer),
// not the coordinator alone.
//
// Design section 7, "Play-out on iPhone/iPad" (Anthony, 2026-10-05 15:06): a
// new play during an iPhone/iPad play-out is refused, never a replacement, so
// MusicTUI never sounds beside that device. The routing half is pinned in
// `SpanDACLicenceRoutingTests`; here, the shell and the Output tab.
//
// Every store is a temp path and every SpanDAC client a fixture transport
// (`LicenceRig`): nothing here reaches a socket, a player or ~/.config/music.
import XCTest
@testable import music

final class SpanDACLicenceEffectiveOutputTests: XCTestCase {

    private let ipad = LicenceRig.ipad
    private var device: PlaybackMode { .networkSource(ipad) }

    /// SpanDAC on this Mac stored, data accepted, and not serving: the MusicTUI
    /// output, with nothing playing out.
    private func macNotServing() -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        // Every status it gives says so, as a SpanDAC that is not serving does
        // (an absent licence object reads as serving).
        rig.reply = { _, _ in LicenceRig.status(playback: "idle", serving: false) }
        rig.says(serving: false, playback: "idle")
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.mode, .source)
        return (rig, c)
    }

    /// An iPhone/iPad output whose own queue was playing when the Mac stopped
    /// serving: a recorded play-out on that device.
    private func networkPlayingOut() throws -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: device, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: device).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, device)
        return (rig, c)
    }

    /// The real global Next/Previous wiring, with a MusicTUI branch that logs.
    private func pressSkip(_ step: Int, _ c: RoutingCoordinator, _ log: BranchLog) {
        globalSkip(step, routing: c,
                   musicTUI: { log.append("musicTUI:\(step)") },
                   run: { label, body in
                       do { try body() } catch let e as ActionError {
                           log.append("refused:\(label):\(e.message)")
                       } catch {
                           log.append("failed:\(label)")
                       }
                   })
    }

    private func ops(_ rig: LicenceRig, after count: Int) -> [String?] {
        rig.sent.dropFirst(count).map { LicenceRig.op($0.line) }
    }

    private func nowScene(_ c: RoutingCoordinator) -> NowPlayingScene {
        let status = StatusStore()
        return NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               status: status, actions: ActionRunner(status: status), routing: c)
    }

    private func outputScene(_ c: RoutingCoordinator, speakers: [[String: Any]] = []) -> SpeakersScene {
        SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                      status: StatusStore(), actions: ActionRunner(status: StatusStore()),
                      routing: c, confirmMusicAppPaused: musicAppPauseTripwire,
                      macName: "Studio Mac",
                      fetchSpeakers: { speakers },
                      fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                      fetchVisualizer: { _ in false },
                      macSocketExists: { false })
    }

    private var stoppedSnapshot: NowPlayingSnapshot { NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []) }

    /// The Output tab's "Playing through" line, escapes removed.
    private func playingThroughLine(_ c: RoutingCoordinator) -> String {
        let out = outputScene(c).render(frame: shellLayout(width: 120, height: 40), snapshot: stoppedSnapshot)
        let plain = out
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*H", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.components(separatedBy: "\n").first { $0.hasPrefix("Playing through") } ?? "<no line>"
    }

    /// The Output tab with one active AirPlay speaker, rendered once its row
    /// has loaded.
    private func outputWithASpeaker(_ c: RoutingCoordinator) -> String {
        let scene = outputScene(c, speakers: [["name": "Kitchen", "selected": true, "volume": 58, "kind": "AirPlay"]])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, scene.speakerRowsForTest.count != 1 {
            _ = scene.tick(snapshot: stoppedSnapshot)
            usleep(10_000)
        }
        XCTAssertEqual(scene.speakerRowsForTest.count, 1, "the speaker row never loaded")
        return scene.render(frame: shellLayout(width: 120, height: 40), snapshot: stoppedSnapshot)
    }

    // MARK: - The shell follows the effective output

    /// SpanDAC on this Mac stored but not serving: the effective output is
    /// MusicTUI, and so are global Next and Previous. Before Codex 101's fix
    /// they took the SpanDAC branch from the stored mode and handed the
    /// coordinator an EMPTY MusicTUI body: nothing moved.
    func testGlobalNextAndPreviousReachMusicTUIForAStoredMacSpanDACThatIsNotServing() {
        let (rig, c) = macNotServing()
        XCTAssertEqual(c.effectiveOutput, .musicApp)
        let sentBefore = rig.sent.count
        let log = BranchLog()
        pressSkip(1, c, log)
        pressSkip(-1, c, log)
        XCTAssertEqual(log.log, ["musicTUI:1", "musicTUI:-1"])
        XCTAssertEqual(rig.sent.count, sentBefore)
    }

    /// Unchanged columns: a live SpanDAC output, and an iPhone/iPad play-out,
    /// get the device's next and never MusicTUI's; the MusicTUI output gets
    /// MusicTUI's; a blocked output refuses in its own sentence and runs
    /// neither.
    func testGlobalSkipStillFollowsEveryOtherOutput() throws {
        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        let liveBefore = live.sent.count
        let log = BranchLog()
        pressSkip(1, onDevice, log)
        XCTAssertEqual(log.log, [])
        XCTAssertEqual(ops(live, after: liveBefore), ["slice.next"])
        XCTAssertEqual(live.sent.last?.tag, "output:\(ipad)")

        let (out, playingOut) = try networkPlayingOut()
        let outBefore = out.sent.count
        let outLog = BranchLog()
        pressSkip(-1, playingOut, outLog)
        XCTAssertEqual(outLog.log, [], "MusicTUI never moves during an iPhone/iPad play-out")
        XCTAssertEqual(ops(out, after: outBefore), ["slice.previous"])
        XCTAssertEqual(out.sent.last?.tag, "output:\(ipad)")

        let tui = LicenceRig(output: .musicApp, accepted: false)
        let tuiLog = BranchLog()
        pressSkip(-1, tui.coordinator(licensed: false), tuiLog)
        XCTAssertEqual(tuiLog.log, ["musicTUI:-1"])

        let blocked = LicenceRig(output: .source, accepted: false)
        let blockedLog = BranchLog()
        pressSkip(1, blocked.coordinator(), blockedLog)
        XCTAssertEqual(blockedLog.log, ["refused:Skip:\(finishSwitchingToSpanDAC)"])
        XCTAssertTrue(blocked.sent.isEmpty)
    }

    /// One value says where sound is: a play-out's device, MusicTUI for a
    /// stored Mac SpanDAC not serving, a blocked stored output, or the
    /// selection's output. The Now poller agrees.
    func testEffectiveOutputAcrossTheLicenceStates() throws {
        let (_, mac) = macNotServing()
        XCTAssertEqual(mac.effectiveOutput, .musicApp)
        XCTAssertEqual(pollTarget(selection: mac.selection, playOut: mac.playOutMode), .musicApp)

        let rig = LicenceRig(output: device, accepted: true)
        let live = rig.coordinator()
        rig.says(serving: true)
        XCTAssertEqual(live.effectiveOutput, device)

        let (_, playingOut) = try networkPlayingOut()
        XCTAssertEqual(playingOut.effectiveOutput, device, "a play-out still sounds on the device")
        XCTAssertEqual(pollTarget(selection: playingOut.selection, playOut: playingOut.playOutMode), .bridge(device))

        let blocked = LicenceRig(output: .source, accepted: false)
        XCTAssertEqual(blocked.coordinator().effectiveOutput, .source)
    }

    /// Now's controls follow the effective output: MusicTUI's grid and keys
    /// for a stored Mac SpanDAC not serving; SpanDAC's set on a live device.
    func testNowShowsMusicTUIControlsForAStoredMacSpanDACThatIsNotServing() {
        let (_, c) = macNotServing()
        let scene = nowScene(c)
        XCTAssertFalse(scene.footerHint.hasPrefix("[ ] Seek  x Quiet"), scene.footerHint)
        XCTAssertEqual(scene.handle(.left), .redraw, "the MusicTUI control grid can take focus")

        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        let deviceScene = nowScene(onDevice)
        XCTAssertTrue(deviceScene.footerHint.hasPrefix("[ ] Seek  x Quiet"), deviceScene.footerHint)
        XCTAssertEqual(deviceScene.handle(.left), .none)
    }

    /// The Output tab's "Playing through" line and the footer's global keys
    /// describe the effective output; the stored row is untouched.
    func testOutputLineAndFooterNameTheEffectiveOutput() {
        let (_, c) = macNotServing()
        XCTAssertEqual(playingThroughLine(c), "Playing through  MusicTUI")
        XCTAssertEqual(shellFooterGlobals(for: c), shellFooterGlobals(mode: .musicApp))

        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        XCTAssertTrue(playingThroughLine(onDevice).hasPrefix("Playing through  SpanDAC"), playingThroughLine(onDevice))
        XCTAssertEqual(shellFooterGlobals(for: onDevice), shellFooterGlobals(mode: device))
    }

    /// Codex review 102, should-fix: the MusicTUI section's "switches back"
    /// hint and its dimming follow the effective output. MusicTUI and its
    /// AirPlay speakers carry the sound for a stored Mac SpanDAC not serving;
    /// on a live device output the section is dimmed and says how to return.
    func testOutputSpeakerSectionFollowsTheEffectiveOutput() {
        let hint = "Enter on a speaker switches back"
        let dimmedVolume = "\(ANSICode.dim) 58\(ANSICode.reset)"
        let dimmedDot = "\(ANSICode.dim)\u{25CF}\(ANSICode.reset)"

        let (_, c) = macNotServing()
        let tui = outputWithASpeaker(c)
        XCTAssertFalse(tui.contains(hint), "no 'a SpanDAC plays' hint")
        XCTAssertFalse(tui.contains(dimmedVolume), "the speaker carrying the sound is not dimmed")
        XCTAssertFalse(tui.contains(dimmedDot), "the active speaker's dot is not dimmed")
        XCTAssertTrue(tui.contains(" 58"), "the speaker row was drawn")

        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        let deviceOut = outputWithASpeaker(onDevice)
        XCTAssertTrue(deviceOut.contains(hint))
        XCTAssertTrue(deviceOut.contains(dimmedVolume))
        XCTAssertTrue(deviceOut.contains(dimmedDot))
    }

    // MARK: - Codex review 103, blocking 1, after the 15:06 ruling

    /// "Stop using SpanDAC for music data" during an iPhone/iPad play-out,
    /// when the device cannot be left (pause unconfirmed, or queue drop
    /// failed): data stops, the stored device is the ordinary repair block,
    /// so the Output tab still offers the Stop row to retry, the play-out
    /// keeps the device's transport, and nothing ever started on MusicTUI.
    func testAFailedDataStopDuringANetworkPlayOutKeepsTheStopRowAndTheDevice() throws {
        let failures: [(String, (PlaybackMode) throws -> Bool, (PlaybackMode) throws -> Void)] = [
            ("pause unconfirmed", { _ in false }, { _ in }),
            ("drop failed", { _ in true }, { _ in throw SourceAppError.notRunning }),
        ]
        for (label, pause, drop) in failures {
            let (rig, c) = try networkPlayingOut()
            let result = try c.stopUsingSpanDACData(pauseOutgoing: pause, dropQueue: drop)
            guard case .outputStillBlocked = result else { XCTFail("\(label): \(result)"); continue }
            XCTAssertEqual(c.selection, .outputBlocked(stored: device), label)
            XCTAssertEqual(c.effectiveOutput, device, "the device is what sounds: \(label)")
            XCTAssertTrue(outputScene(c).displayRowsForTest.contains(.stopUsingSpanDAC),
                          "the Stop row is offered to retry: \(label)")
            let sentBefore = rig.sent.count
            let log = BranchLog()
            pressSkip(1, c, log)
            XCTAssertEqual(log.log, [], "MusicTUI never moved: \(label)")
            XCTAssertEqual(ops(rig, after: sentBefore), ["slice.next"], label)
            XCTAssertEqual(rig.sent.last?.tag, "output:\(ipad)", label)
        }
    }
}

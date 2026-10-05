// tools/music/Tests/MusicTests/SpanDACLicenceEffectiveOutputTests.swift
//
// Codex review 101, blocking 1 and 2. Conductor ruling A8 as amended: after a
// new play replaces an iPhone/iPad play-out, the EFFECTIVE output is MusicTUI
// for transport, Now and new plays, while the stored output stays the device.
// These drive the real shell wiring (global Next/Previous, the Now scene, the
// Output tab and the footer), not the coordinator alone. When serving returns,
// MusicTUI is the outgoing output: it is paused and status-confirmed before the
// first device transport or play, or that action is refused and MusicTUI stays
// effective.
//
// Every store is a temp path, every SpanDAC client a fixture transport
// (`LicenceRig`), and MusicTUI's own player a fake: nothing here reaches a
// socket, a player or ~/.config/music.
import XCTest
@testable import music

/// MusicTUI's own player as the handoff sees it. Playing until a pause reaches
/// it; `honoursPause` false keeps it playing, `unreadable` makes the confirming
/// read throw. Records how many device commands had been sent at each call, so
/// a test can prove the pause came first.
private final class FakeMusicTUI {
    private let lock = NSLock()
    private var _playing = true
    private var _confirmedAtSent: [Int] = []
    var honoursPause = true
    var unreadable = false
    weak var rig: LicenceRig?

    var playing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _playing }
        set { lock.lock(); _playing = newValue; lock.unlock() }
    }
    var confirmedAtSent: [Int] { lock.lock(); defer { lock.unlock() }; return _confirmedAtSent }

    func confirmPaused() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        _confirmedAtSent.append(rig?.sent.count ?? -1)
        if honoursPause { _playing = false }
        if unreadable { throw MusicAppPauseUnconfirmed(reason: "fixture") }
        return !_playing
    }
}

final class SpanDACLicenceEffectiveOutputTests: XCTestCase {

    private let ipad = LicenceRig.ipad
    private var device: PlaybackMode { .networkSource(ipad) }
    private let handoffRefusal = "Couldn't confirm MusicTUI paused; nothing was sent to the iPhone/iPad SpanDAC."

    /// Ruling A8's state: an iPhone/iPad play-out was replaced by a new play
    /// on MusicTUI, which is now playing.
    private func replaced(_ tui: FakeMusicTUI = FakeMusicTUI()) throws -> (LicenceRig, RoutingCoordinator, FakeMusicTUI) {
        let rig = LicenceRig(output: device, accepted: true)
        tui.rig = rig
        let c = rig.coordinator(musicTUIPaused: { try tui.confirmPaused() })
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: device).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, device)
        rig.reply = LicenceRig.pausesWhenAsked(serving: nil)
        try c.perform(.libraryPlay, expecting: nil, origin: .openData(resultNumber: nil),
                      musicApp: { _ in tui.playing = true },
                      source: { _ in XCTFail("the replacing play reached the device") },
                      unaffected: {})
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.replacedPlayOutMode, device)
        XCTAssertTrue(tui.playing)
        XCTAssertEqual(tui.confirmedAtSent, [], "the replacement itself never pauses MusicTUI")
        return (rig, c, tui)
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

    /// The Output tab's "Playing through" line, escapes removed.
    private func playingThroughLine(_ c: RoutingCoordinator) -> String {
        let scene = SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                  status: StatusStore(), actions: ActionRunner(status: StatusStore()),
                                  routing: c, macName: "Studio Mac",
                                  fetchSpeakers: { [] },
                                  fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                                  fetchVisualizer: { _ in false },
                                  macSocketExists: { false })
        let out = scene.render(frame: shellLayout(width: 120, height: 40),
                               snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        let plain = out
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*H", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.components(separatedBy: "\n").first { $0.hasPrefix("Playing through") } ?? "<no line>"
    }

    // MARK: - Blocking 1: the shell follows the effective output

    /// After a replacement, the global Next and Previous keys reach MusicTUI's
    /// own branch. Before the fix they took the SpanDAC branch from the stored
    /// mode and handed the coordinator an EMPTY MusicTUI body: nothing moved.
    func testGlobalNextAndPreviousReachMusicTUIAfterAReplacement() throws {
        let (rig, c, _) = try replaced()
        let sentBefore = rig.sent.count
        let log = BranchLog()
        pressSkip(1, c, log)
        pressSkip(-1, c, log)
        XCTAssertEqual(log.log, ["musicTUI:1", "musicTUI:-1"])
        XCTAssertEqual(rig.sent.count, sentBefore, "nothing reached the device")
    }

    /// The same defect for a stored SpanDAC on this Mac while it is not
    /// serving: the effective output is MusicTUI, and so are Next/Previous.
    func testGlobalNextReachesMusicTUIForAStoredMacSpanDACThatIsNotServing() {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: false, playback: "idle")
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.effectiveOutput, .musicApp)
        let sentBefore = rig.sent.count
        let log = BranchLog()
        pressSkip(1, c, log)
        XCTAssertEqual(log.log, ["musicTUI:1"])
        XCTAssertEqual(rig.sent.count, sentBefore)
    }

    /// Unchanged columns: a live SpanDAC output gets the device's next and
    /// never MusicTUI's; the MusicTUI output gets MusicTUI's; a blocked output
    /// refuses in its own sentence and runs neither.
    func testGlobalSkipStillFollowsEveryOtherOutput() {
        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        let liveBefore = live.sent.count
        let log = BranchLog()
        pressSkip(1, onDevice, log)
        XCTAssertEqual(log.log, [])
        XCTAssertEqual(ops(live, after: liveBefore), ["slice.next"])
        XCTAssertEqual(live.sent.last?.tag, "output:\(ipad)")

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

    /// One value says where sound is: a play-out's device, A8's MusicTUI, a
    /// blocked stored output, or the selection's output. The poller agrees.
    func testEffectiveOutputAcrossTheLicenceStates() throws {
        let (_, a8, _) = try replaced()
        XCTAssertEqual(a8.effectiveOutput, .musicApp)
        XCTAssertEqual(a8.mode, device, "the stored choice is unchanged")
        XCTAssertEqual(pollTarget(selection: a8.selection, playOut: a8.playOutMode), .musicApp)

        let rig = LicenceRig(output: device, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true)
        XCTAssertEqual(c.effectiveOutput, device)
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: device).control.status()
        rig.says(serving: false)
        XCTAssertEqual(c.playOutMode, device)
        XCTAssertEqual(c.effectiveOutput, device, "a play-out still sounds on the device")

        let blocked = LicenceRig(output: .source, accepted: false)
        XCTAssertEqual(blocked.coordinator().effectiveOutput, .source)
    }

    /// Now's controls follow the effective output: after a replacement the
    /// MusicTUI grid and its keys, not SpanDAC's seek-and-quiet set.
    func testNowShowsMusicTUIControlsAfterAReplacement() throws {
        let (_, c, _) = try replaced()
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
    /// describe the effective output; the stored device row is untouched.
    func testOutputLineAndFooterNameMusicTUIAfterAReplacement() throws {
        let (_, c, _) = try replaced()
        XCTAssertEqual(playingThroughLine(c), "Playing through  MusicTUI")
        XCTAssertEqual(shellFooterGlobals(for: c), shellFooterGlobals(mode: .musicApp))

        let live = LicenceRig(output: device, accepted: true)
        let onDevice = live.coordinator()
        live.says(serving: true)
        XCTAssertTrue(playingThroughLine(onDevice).hasPrefix("Playing through  SpanDAC"), playingThroughLine(onDevice))
        XCTAssertEqual(shellFooterGlobals(for: onDevice), shellFooterGlobals(mode: device))
    }

    // MARK: - Blocking 2: serving returns, MusicTUI is handed off, never abandoned

    /// MusicTUI is left PLAYING when serving returns. It stays the effective
    /// output (Now reads it) until a device transport or play; that action
    /// first pauses MusicTUI and confirms it, and only then reaches the device.
    func testServingReturningHandsOffOnlyAfterAConfirmedMusicTUIPause() throws {
        // Choose a song.
        do {
            let (rig, c, tui) = try replaced()
            let modeBefore = rig.bytes(rig.modePath), dataBefore = rig.bytes(rig.dataPath)
            rig.says(serving: true)
            XCTAssertTrue(tui.playing)
            XCTAssertEqual(c.effectiveOutput, .musicApp, "MusicTUI still sounds")
            XCTAssertEqual(pollTarget(selection: c.selection, playOut: c.playOutMode), .musicApp)
            rig.reply = { _, _ in LicenceRig.status(playback: "paused", phase: "complete") }
            let sentBefore = rig.sent.count
            let log = BranchLog()
            try c.perform(.libraryPlay, expecting: nil, origin: .spandacLibrary,
                          musicApp: { log.append("musicApp:\($0)") },
                          source: { client in
                              log.append("source:\(rig.sent.count - sentBefore)")
                              try client.control.resume()
                          },
                          unaffected: { log.append("unaffected") })
            XCTAssertEqual(tui.confirmedAtSent, [sentBefore], "MusicTUI was confirmed paused before any device command")
            XCTAssertFalse(tui.playing)
            XCTAssertEqual(log.log, ["source:0"], "the play went to the device, after the handoff")
            XCTAssertEqual(rig.sent.dropFirst(sentBefore).map(\.tag), ["output:\(ipad)"])
            XCTAssertEqual(c.effectiveOutput, device)
            XCTAssertNil(c.replacedPlayOutMode)
            XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: device))
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, "no stored file is written")
            XCTAssertEqual(rig.bytes(rig.dataPath), dataBefore)
        }
        // Press Next, through the real global wiring.
        do {
            let (rig, c, tui) = try replaced()
            rig.says(serving: true)
            rig.reply = { _, _ in LicenceRig.status(playback: "paused", phase: "complete") }
            let sentBefore = rig.sent.count
            let log = BranchLog()
            pressSkip(1, c, log)
            XCTAssertEqual(tui.confirmedAtSent, [sentBefore])
            XCTAssertEqual(log.log, [], "MusicTUI's own next did not run")
            XCTAssertEqual(ops(rig, after: sentBefore), ["slice.next"])
            XCTAssertEqual(c.effectiveOutput, device)
            // Handed off once: the next press does not pause MusicTUI again.
            pressSkip(1, c, log)
            XCTAssertEqual(tui.confirmedAtSent.count, 1)
            XCTAssertEqual(ops(rig, after: sentBefore), ["slice.next", "slice.next"])
        }
    }

    /// MusicTUI cannot be confirmed paused (still playing, or its state cannot
    /// be read): the action is refused in a sentence naming MusicTUI, nothing
    /// reaches the device, and MusicTUI stays the effective output.
    func testAnUnconfirmedMusicTUIPauseRefusesAndKeepsMusicTUIEffective() throws {
        let cases: [(String, (FakeMusicTUI) -> Void)] = [
            ("still playing", { $0.honoursPause = false }),
            ("unreadable", { $0.unreadable = true }),
        ]
        for (label, configure) in cases {
            let tui = FakeMusicTUI()
            configure(tui)
            let (rig, c, _) = try replaced(tui)
            rig.says(serving: true)
            let sentBefore = rig.sent.count
            let log = BranchLog()
            XCTAssertThrowsError(try c.perform(.libraryPlay, expecting: nil, origin: .spandacLibrary,
                                               musicApp: { log.append("musicApp:\($0)") },
                                               source: { _ in log.append("source") },
                                               unaffected: {}), label) {
                XCTAssertEqual(($0 as? ActionError)?.message, handoffRefusal, label)
            }
            pressSkip(1, c, log)
            XCTAssertEqual(log.log, ["refused:Skip:\(handoffRefusal)"], label)
            XCTAssertFalse(handoffRefusal.contains("Music.app"))
            XCTAssertEqual(rig.sent.count, sentBefore, "nothing reached the device: \(label)")
            XCTAssertEqual(tui.confirmedAtSent.count, 2, label)
            XCTAssertEqual(c.effectiveOutput, .musicApp, label)
            XCTAssertEqual(c.replacedPlayOutMode, device, label)
            XCTAssertEqual(pollTarget(selection: c.selection, playOut: c.playOutMode), .musicApp, label)
        }
    }

    /// Until the handoff, an action that cannot start or advance the device
    /// stays on MusicTUI and pauses nothing.
    func testBeforeTheHandoffNowStatusAndVolumeStayOnMusicTUI() throws {
        let (rig, c, tui) = try replaced()
        rig.says(serving: true)
        let sentBefore = rig.sent.count
        let log = BranchLog()
        for action: MusicTUIAction in [.nowStatus, .volume] {
            try c.perform(action, expecting: nil, origin: nil,
                          musicApp: { log.append("musicApp:\($0)") },
                          source: { _ in log.append("source") },
                          unaffected: { log.append("unaffected") })
        }
        XCTAssertEqual(log.log, ["musicApp:shipped", "musicApp:shipped"])
        XCTAssertEqual(tui.confirmedAtSent, [])
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.effectiveOutput, .musicApp)
    }

    /// Serving ends again before the handoff: MusicTUI is still the one
    /// sounding, so A8 holds; the paused device's loaded queue does not
    /// become a play-out that would take transport back to it.
    func testServingEndingAgainBeforeTheHandoffKeepsMusicTUI() throws {
        let (rig, c, tui) = try replaced()
        rig.says(serving: true)
        rig.says(serving: false)
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.effectiveOutput, .musicApp)
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
        let sentBefore = rig.sent.count
        let log = BranchLog()
        pressSkip(1, c, log)
        XCTAssertEqual(log.log, ["musicTUI:1"])
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(tui.confirmedAtSent, [])
    }

    // MARK: - Ruling A8b: a switch's outgoing player is the effective output

    /// A switch with the Output tab's shape: the pause and the drop are
    /// recorded by mode, MusicTUI's pause goes to the fake, a SpanDAC's is
    /// confirmed as the shell's own status read would.
    private func switchTo(_ target: PlaybackMode, _ c: RoutingCoordinator, _ tui: FakeMusicTUI,
                          paused: BranchLog, dropped: BranchLog) throws -> RoutingCoordinator.SwitchResult {
        try c.switchMode(to: target, readiness: { .ready },
                         pauseOutgoing: { outgoing in
                             paused.append("\(outgoing)")
                             return outgoing == .musicApp ? try tui.confirmPaused() : true
                         },
                         dropQueue: { dropped.append("\($0)") })
    }

    /// During A8 and during a pending handoff MusicTUI is what sounds, so a
    /// switch to another SpanDAC pauses and confirms MusicTUI as the outgoing
    /// player. Before A8b it paused the already-paused device and left
    /// MusicTUI playing beside the new output. The device's stale queue is
    /// still dropped, as before.
    func testASwitchDuringA8PausesMusicTUIAsTheOutgoingPlayer() throws {
        for pending in [false, true] {
            let label = pending ? "pending handoff" : "A8"
            let (rig, c, tui) = try replaced()
            if pending { rig.says(serving: true) }
            let paused = BranchLog(), dropped = BranchLog()
            XCTAssertEqual(try switchTo(.source, c, tui, paused: paused, dropped: dropped), .switched(to: .source), label)
            XCTAssertEqual(paused.log, ["\(PlaybackMode.musicApp)"], "MusicTUI is the outgoing player: \(label)")
            XCTAssertFalse(tui.playing, "MusicTUI was left playing: \(label)")
            XCTAssertEqual(tui.confirmedAtSent.count, 1, label)
            XCTAssertEqual(dropped.log, ["\(device)"], "the device's stale queue is dropped as before: \(label)")
            XCTAssertEqual(c.mode, .source, label)
            XCTAssertNil(c.replacedPlayOutMode, label)
        }
    }

    /// MusicTUI cannot be confirmed paused: the switch is refused in its
    /// existing shape, naming MusicTUI, and touches nothing: no drop, no
    /// save, no epoch, no device command, and MusicTUI stays effective.
    func testASwitchDuringA8ThatCannotPauseMusicTUIIsRefusedAndTouchesNothing() throws {
        for pending in [false, true] {
            let label = pending ? "pending handoff" : "A8"
            let tui = FakeMusicTUI()
            tui.honoursPause = false
            let (rig, c, _) = try replaced(tui)
            if pending { rig.says(serving: true) }
            let modeBefore = rig.bytes(rig.modePath), epoch = c.epoch, sentBefore = rig.sent.count
            let paused = BranchLog(), dropped = BranchLog()
            XCTAssertThrowsError(try switchTo(.source, c, tui, paused: paused, dropped: dropped), label) {
                XCTAssertEqual(($0 as? ActionError)?.message, "Couldn't confirm MusicTUI paused; still using it", label)
            }
            XCTAssertEqual(paused.log, ["\(PlaybackMode.musicApp)"], label)
            XCTAssertEqual(dropped.log, [], label)
            XCTAssertEqual(rig.bytes(rig.modePath), modeBefore, label)
            XCTAssertEqual(c.epoch, epoch, label)
            XCTAssertEqual(rig.sent.count, sentBefore, label)
            XCTAssertEqual(c.mode, device, label)
            XCTAssertEqual(c.replacedPlayOutMode, device, label)
            XCTAssertEqual(c.effectiveOutput, .musicApp, label)
        }
    }

    /// Unchanged outside A8: a normal switch pauses the stored output, and a
    /// switch TO MusicTUI during A8 (MusicTUI is the incoming player, not the
    /// outgoing one) pauses the device as before and leaves MusicTUI playing.
    func testOtherSwitchesStillPauseTheStoredOutput() throws {
        let live = LicenceRig(output: device, accepted: true)
        let liveTUI = FakeMusicTUI()
        let normal = live.coordinator(musicTUIPaused: { try liveTUI.confirmPaused() })
        live.says(serving: true)
        let paused = BranchLog(), dropped = BranchLog()
        XCTAssertEqual(try switchTo(.source, normal, liveTUI, paused: paused, dropped: dropped), .switched(to: .source))
        XCTAssertEqual(paused.log, ["\(device)"])
        XCTAssertEqual(dropped.log, ["\(device)"])
        XCTAssertEqual(liveTUI.confirmedAtSent, [])

        let (_, c, tui) = try replaced()
        let toTUIPaused = BranchLog(), toTUIDropped = BranchLog()
        XCTAssertEqual(try switchTo(.musicApp, c, tui, paused: toTUIPaused, dropped: toTUIDropped), .switched(to: .musicApp))
        XCTAssertEqual(toTUIPaused.log, ["\(device)"])
        XCTAssertEqual(toTUIDropped.log, ["\(device)"])
        XCTAssertTrue(tui.playing, "switching to MusicTUI keeps it playing")
        XCTAssertEqual(tui.confirmedAtSent, [])
    }
}

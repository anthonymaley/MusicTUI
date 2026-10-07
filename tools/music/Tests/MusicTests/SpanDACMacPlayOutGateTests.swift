// tools/music/Tests/MusicTests/SpanDACMacPlayOutGateTests.swift
//
// Anthony's ruling of 2026-10-05 16:07: as for iPhone/iPad, when the Mac's
// SpanDAC licence stops serving mid-queue on SpanDAC for Mac, every action that
// can start or replace sound in MusicTUI is refused through ONE gate, while
// pause, next, previous, seek, stop and Quiet keep reaching SpanDAC until its
// queue ends or is stopped. The Mac's "pause SpanDAC, then play on MusicTUI"
// replacement is gone, so two players at once cannot arise (Codex review 104,
// both blocking findings).
//
// Every store is a temp path and every SpanDAC client a fixture transport
// (`LicenceRig`). The Now scene's AppleScript backend is a counting script
// (`AppleScriptCallCounter`), never osascript, and every MusicTUI body here is
// a closure that only logs: nothing reaches a socket, a player, the keychain
// or ~/.config/music.
import ArgumentParser
import XCTest
@testable import music

final class SpanDACMacPlayOutGateTests: XCTestCase {

    /// The Mac's sentence, pinned literally (mirrors the iPhone/iPad one).
    private let macPlayOutSentence =
        "SpanDAC for Mac is finishing its queue without a licence; stop it or let it end to play something new."

    func testTheMacSentenceIsTheOneTheGateUses() {
        XCTAssertEqual(macPlayOutRefusal, macPlayOutSentence)
    }

    /// SpanDAC on this Mac stored with data accepted, playing its queue when
    /// serving ended: a recorded Mac play-out. Every later status from it says
    /// it is still playing and still not serving.
    private func macPlayingOut(_ surface: InvocationSurface = .tui) -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .source, accepted: true)
        // The CLI holds the output lock around a playback body, as `live` does.
        let c = rig.coordinator(surface, outputLock: surface == .cli)
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "playing", phase: "complete")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: false) }
        XCTAssertEqual(c.playOutMode, .source)
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
        return (rig, c)
    }

    /// Runs `action` through the coordinator with bodies that only log.
    private func run(_ c: RoutingCoordinator, _ action: MusicTUIAction, _ log: BranchLog,
                     origin: PlayOrigin? = nil) throws {
        try c.perform(action, expecting: nil, origin: origin,
                      musicApp: { log.append("musicApp:\($0)") },
                      source: { client in _ = try client.control.status(); log.append("source") },
                      unaffected: { log.append("unaffected") })
    }

    /// Refused with the Mac's sentence, and nothing happened: no branch ran,
    /// nothing was sent to SpanDAC, the play serial did not move, and the
    /// play-out keeps its transport.
    private func assertRefusedAndStartsNothing(_ rig: LicenceRig, _ c: RoutingCoordinator, _ label: String,
                                               _ body: () throws -> Void, log: BranchLog,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let sentBefore = rig.sent.count, serial = c.playSerial
        XCTAssertThrowsError(try body(), label, file: file, line: line) {
            XCTAssertEqual(($0 as? ActionError)?.message, macPlayOutSentence, label, file: file, line: line)
        }
        XCTAssertEqual(log.log, [], "nothing started on MusicTUI: \(label)", file: file, line: line)
        XCTAssertEqual(rig.sent.count, sentBefore, "nothing sent to SpanDAC: \(label)", file: file, line: line)
        XCTAssertEqual(c.playSerial, serial, label, file: file, line: line)
        XCTAssertEqual(c.playOutMode, .source, "the play-out is kept: \(label)", file: file, line: line)
    }

    // MARK: - Codex 104, blocking 1: wider than `playsChosenMusic`

    /// The global `z` (`Shell.swift`, `.collectionShuffle` through the
    /// coordinator's shipped-body form, as the shell calls it).
    func testGlobalZDuringAMacPlayOutIsRefusedAndStartsNothing() {
        let (rig, c) = macPlayingOut()
        let log = BranchLog()
        assertRefusedAndStartsNothing(rig, c, "z", {
            try c.perform(.collectionShuffle,
                          musicApp: { log.append("musicApp") },
                          source: { _ in log.append("source") },
                          unaffected: { log.append("unaffected") })
        }, log: log)
    }

    /// Bare `music play` is `.cliPlayResume`, dispatched by the CLI's real
    /// seam: it prints the sentence, exits non-zero, and its shipped body (an
    /// AppleScript `play`) never runs. The body here only logs.
    func testBareMusicPlayDuringAMacPlayOutIsRefusedAndStartsNothing() throws {
        XCTAssertEqual(playAction(args: [], playlist: nil, album: nil, song: nil, artist: nil), .cliPlayResume)
        let (rig, c) = macPlayingOut(.cli)
        let printed = BranchLog()
        let env = CLIBridgeEnv(routing: c, modeStore: rig.modes,
                               cache: ResultCache(directory: rig.dir + "/cache"),
                               out: { printed.append($0) }, err: { _ in }, sleep: { _ in })
        let log = BranchLog()
        let sentBefore = rig.sent.count
        XCTAssertThrowsError(try cliDispatch(.cliPlayResume, json: false, env: env,
                                             musicApp: { log.append("musicApp") },
                                             bridge: { _ in log.append("bridge") })) {
            XCTAssertTrue($0 is ExitCode, "\($0)")
        }
        XCTAssertEqual(printed.log, [macPlayOutSentence])
        XCTAssertEqual(log.log, [], "the shipped `play` never ran")
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.playOutMode, .source)
    }

    // MARK: - Scene paths that used to start sound after only `askMatrix`

    private func nowScene(_ c: RoutingCoordinator, backend: AppleScriptBackend,
                          status: StatusStore) -> (NowPlayingScene, ActionRunner) {
        let actions = ActionRunner(status: status)
        return (NowPlayingScene(backend: backend, appQueue: AppQueueStore(), status: status,
                                actions: actions, routing: c), actions)
    }

    /// Now's Up Next row Enter (`.queueJump`) during a Mac play-out: refused
    /// in the sentence, and not one AppleScript call is made.
    func testNowQueueRowEnterDuringAMacPlayOutIsRefusedAndRunsNoAppleScript() {
        let (rig, c) = macPlayingOut()
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let (scene, actions) = nowScene(c, backend: counter.backend, status: status)
        let rows = [TrackListEntry(index: 1, name: "A", artist: "X", isCurrent: true),
                    TrackListEntry(index: 2, name: "B", artist: "Y", isCurrent: false)]
        _ = scene.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: rows))
        let callsBefore = counter.callCount, sentBefore = rig.sent.count
        _ = scene.handle(.down)
        _ = scene.handle(.enter)
        actions.waitUntilIdle()
        XCTAssertEqual(counter.callCount, callsBefore, "no AppleScript ran: nothing started on MusicTUI")
        XCTAssertEqual(status.current()?.text, macPlayOutSentence)
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.playOutMode, .source)
    }

    /// Now's Genius Shuffle (`g`) during a Mac play-out: refused in the
    /// sentence, and not one AppleScript call is made.
    func testGeniusDuringAMacPlayOutIsRefusedAndRunsNoAppleScript() {
        let (rig, c) = macPlayingOut()
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let (scene, actions) = nowScene(c, backend: counter.backend, status: status)
        let callsBefore = counter.callCount, sentBefore = rig.sent.count
        _ = scene.handle(.char("g"))
        actions.waitUntilIdle()
        XCTAssertEqual(counter.callCount, callsBefore, "Genius Shuffle never reached Apple's Music app")
        XCTAssertEqual(status.current()?.text, macPlayOutSentence)
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.playOutMode, .source)
    }

    // MARK: - Codex review of 903825f: Quiet, the mode cells and the current track

    /// A SpanDAC Now snapshot that offers both mode cells, shuffle on and
    /// repeat all, read through a poller over a fixture client of its own.
    private func modesSnapshot() -> NowPlayingSnapshot {
        let store = NowPlayingStore()
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.source)
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"Teardrop","artist":"Massive Attack","shuffle":true,"repeat":"all","capabilities":["slice.status","slice.shuffle","slice.repeat"],"queue":{"phase":"complete","requested":2,"present":2,"index":0}}}"#
        let client = { SourceAppClient(path: "/nonexistent", transport: { _, _ in reply }) }
        let p = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                               routing: RoutingCoordinator(store: modeStore, surface: .tui, makeSource: client),
                               makeSourceClient: client)
        p.tick()
        return store.read()
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Finding 1. Now shows `x Quiet` during a Mac play-out (the effective
    /// output is SpanDAC), so `x` must pause the SpanDAC that is sounding, on
    /// the play-out's own client, and never run Apple's Music app `pause`.
    func testQuietDuringAMacPlayOutPausesThePlayOutAndNeverTouchesMusicApp() {
        let (rig, c) = macPlayingOut()
        rig.reply = LicenceRig.pausesWhenAsked(serving: false)
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let (scene, actions) = nowScene(c, backend: counter.backend, status: status)
        XCTAssertTrue(scene.footerHint.contains("x Quiet"), scene.footerHint)
        let callsBefore = counter.callCount, sentBefore = rig.sent.count
        _ = scene.handle(.char("x"))
        actions.waitUntilIdle()
        XCTAssertEqual(counter.callCount, callsBefore, "Quiet never reached Apple's Music app")
        let sent = rig.sent.dropFirst(sentBefore)
        XCTAssertTrue(sent.contains { $0.tag == rig.tag(.source) && LicenceRig.op($0.line) == "slice.pause" },
                      "the play-out's own SpanDAC was paused: \(sent.map(\.line))")
        XCTAssertFalse(status.current()?.isError ?? false, "\(status.current()?.text ?? "")")
        XCTAssertEqual(c.playOutMode, .source, "a pause does not end the play-out")
    }

    /// Finding 2. The SpanDAC grid is live during a Mac play-out, so `s` and
    /// `r` are refused in the play-out sentence: no optimistic cell change,
    /// nothing sent, no AppleScript.
    func testShuffleAndRepeatDuringAMacPlayOutAreRefusedWithNoOptimisticChange() {
        let snap = modesSnapshot()
        XCTAssertTrue(snap.bridge?.offersShuffle ?? false)
        for key in [KeyPress.char("s"), .char("r")] {
            let (rig, c) = macPlayingOut()
            let counter = AppleScriptCallCounter()
            let status = StatusStore()
            let (scene, actions) = nowScene(c, backend: counter.backend, status: status)
            _ = scene.tick(snapshot: snap)
            let before = plain(scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap))
            XCTAssertTrue(before.contains("[On]") && before.contains("[All]"), before)
            let sentBefore = rig.sent.count
            _ = scene.handle(key)
            actions.waitUntilIdle()
            let after = plain(scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap))
            XCTAssertEqual(status.current()?.text, macPlayOutSentence, "\(key)")
            XCTAssertTrue(after.contains("[On]") && after.contains("[All]"), "no optimistic change: \(key) \(after)")
            XCTAssertEqual(rig.sent.count, sentBefore, "\(key)")
            XCTAssertEqual(counter.callCount, 0, "\(key)")
            XCTAssertEqual(c.playOutMode, .source)
        }
    }

    /// Finding 3. `l` during a Mac play-out would favourite whatever Apple's
    /// Music app was left on, not the song SpanDAC is playing: refused in the
    /// current-track sentence, and no AppleScript runs.
    func testFavouriteDuringAMacPlayOutIsRefusedAndRunsNoAppleScript() {
        let (rig, c) = macPlayingOut()
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let (scene, actions) = nowScene(c, backend: counter.backend, status: status)
        let sentBefore = rig.sent.count
        _ = scene.handle(.char("l"))
        actions.waitUntilIdle()
        XCTAssertEqual(counter.callCount, 0, "nothing was favourited in Apple's Music app")
        XCTAssertEqual(status.current()?.text, currentTrackIsStaleInBridge)
        XCTAssertEqual(rig.sent.count, sentBefore)
        XCTAssertEqual(c.playOutMode, .source)
    }

    /// Path level (Codex review of 903825f): during a Mac play-out, which
    /// branch each action ran. Nothing that acts on the sounding output or on
    /// its current track runs on MusicTUI: Quiet reaches the play-out, the
    /// mode cells and the current-track verbs are refused before any branch.
    /// `.eq`, `.visualizer` and `.volume` set Apple's Music app's own state and
    /// still run there; that is reported, not decided here.
    func testDuringAMacPlayOutNothingActingOnTheSoundingOutputRunsOnMusicTUI() {
        let settingsOnly: Set<MusicTUIAction> = [.eq, .visualizer, .volume]
        let forbidden = musicTUIOutputVerbs
            .union(MusicTUIAction.allCases.filter(\.readsMusicAppCurrentTrack))
            .subtracting(settingsOnly)
        for surface in InvocationSurface.allCases {
            for action in MusicTUIAction.allCases {
                let (rig, c) = macPlayingOut(surface)
                rig.reply = LicenceRig.pausesWhenAsked(serving: false)
                let log = BranchLog()
                let sentBefore = rig.sent.count
                _ = try? run(c, action, log, origin: .openData(resultNumber: nil))
                let label = "\(surface) \(action)"
                if forbidden.contains(action) {
                    XCTAssertFalse(log.log.contains { $0.hasPrefix("musicApp") }, "ran on MusicTUI: \(label)")
                }
                if action == .quiet {
                    XCTAssertEqual(log.log, ["source"], label)
                    XCTAssertEqual(rig.sent.dropFirst(sentBefore).map(\.tag), [rig.tag(.source)], label)
                }
            }
        }
    }

    // MARK: - A chosen play is refused, never a replacement

    /// Every chosen play, from either surface: refused before any pause is
    /// sent to SpanDAC and before any MusicTUI body. SpanDAC would confirm a
    /// pause here (`pausesWhenAsked`), so the old replacement would have
    /// gone ahead; it must not.
    func testAChosenPlayDuringAMacPlayOutIsRefusedNotAReplacement() {
        let plays: [(InvocationSurface, MusicTUIAction)] = [
            (.tui, .libraryPlay), (.tui, .playlistPlay), (.tui, .discoverTrackPlay), (.tui, .discoverPlayAll),
            (.tui, .radioStationPlay), (.cli, .playlistTemp), (.cli, .cliPlaySong), (.cli, .cliPlayPlaylist),
            (.cli, .cliPlayAlbum), (.cli, .cliPlayArtist), (.cli, .cliPlayIndex), (.cli, .cliPlayQuery),
            (.cli, .cliPlayCatalogSong), (.cli, .radioStationPlay),
        ]
        for (surface, action) in plays {
            let (rig, c) = macPlayingOut(surface)
            rig.reply = LicenceRig.pausesWhenAsked(serving: false)
            let log = BranchLog()
            assertRefusedAndStartsNothing(rig, c, "\(surface) \(action)", {
                try run(c, action, log, origin: .openData(resultNumber: nil))
            }, log: log)
        }
    }

    // MARK: - Codex 104, blocking 2: serving returning cannot leave two players

    /// A Mac play-out, every kind of new play attempted during it, then
    /// serving returns. Every attempt was refused, no pause ever reached
    /// SpanDAC on a play's behalf, and no MusicTUI body ran at any point; once
    /// serving is back the stored SpanDAC output is the only player, so a new
    /// play goes to it. Two players at once never arose.
    func testAMacPlayOutThenServingReturningNeverLeavesTwoPlayersSounding() throws {
        let (rig, c) = macPlayingOut()
        rig.reply = LicenceRig.pausesWhenAsked(serving: false)
        let log = BranchLog()
        let attempts: [(MusicTUIAction, PlayOrigin?)] = [
            (.libraryPlay, .openData(resultNumber: nil)), (.playlistPlay, .openData(resultNumber: nil)),
            (.discoverPlayAll, .openData(resultNumber: nil)), (.radioStationPlay, .openData(resultNumber: nil)),
            (.collectionShuffle, nil), (.cliPlayResume, nil), (.queueJump, nil), (.genius, nil),
        ]
        for (action, origin) in attempts {
            XCTAssertThrowsError(try run(c, action, log, origin: origin), "\(action)") {
                XCTAssertEqual(($0 as? ActionError)?.message, macPlayOutSentence, "\(action)")
            }
        }
        XCTAssertFalse(rig.sent.contains { LicenceRig.op($0.line) == "slice.pause" },
                       "no play silenced SpanDAC to replace it")
        XCTAssertEqual(c.playOutMode, .source)

        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: true) }
        rig.says(serving: true, playback: "playing", phase: "complete")
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.selection, .consistent(data: .spandacMac, output: .source))
        try run(c, .libraryPlay, log, origin: .spandacLibrary)
        XCTAssertEqual(log.log, ["source"], "the only play went to SpanDAC; MusicTUI never ran")
    }

    // MARK: - One exhaustive gate

    /// Every verb that resolves its target through Apple's Music app's current
    /// track is refused during a play-out, in one class or the other.
    func testEveryCurrentTrackVerbIsRefusedDuringAPlayOut() {
        for action in MusicTUIAction.allCases where action.readsMusicAppCurrentTrack {
            XCTAssertTrue([.readsTheCurrentTrack, .startsOrReplacesSound].contains(action.playOutClass), "\(action)")
        }
        XCTAssertEqual(Set(MusicTUIAction.allCases.filter { $0.playOutClass == .readsTheCurrentTrack }),
                       [.loveTrack, .addCurrentTrackToPlaylist, .removeCurrentTrackFromPlaylist,
                        .newReleasesLikeCurrentTrack])
    }

    /// The gate is wider than `playsChosenMusic`: every chosen play is in it,
    /// and so are the four Codex review 104 found outside it.
    func testTheGateCoversEveryChosenPlayAndTheFourThatChooseNothing() {
        for action in MusicTUIAction.allCases where action.playsChosenMusic {
            XCTAssertEqual(action.playOutClass, .startsOrReplacesSound, "\(action)")
        }
        for action in [MusicTUIAction.collectionShuffle, .cliPlayResume, .queueJump, .genius] {
            XCTAssertFalse(action.playsChosenMusic, "\(action)")
            XCTAssertEqual(action.playOutClass, .startsOrReplacesSound, "\(action)")
        }
        XCTAssertEqual(Set(MusicTUIAction.allCases.filter { $0.playOutClass == .followsThePlayOut }),
                       [.playPause, .next, .previous, .seek, .stop, .quiet, .nowStatus])
    }

    /// Every action, from both surfaces, during a Mac play-out and during an
    /// iPhone/iPad play-out: the classification alone decides. Sound-starting
    /// actions are refused in that device's sentence with nothing sent and
    /// nothing run; transport reaches the play-out device and never MusicTUI;
    /// the rest are never refused in a play-out sentence.
    func testEveryActionIsDecidedByTheOneGateDuringEitherPlayOut() throws {
        for surface in InvocationSurface.allCases {
            for device in [PlaybackMode.source, .networkSource(LicenceRig.ipad)] {
                for action in MusicTUIAction.allCases {
                    let (rig, c) = try playingOut(on: device, surface)
                    let label = "\(surface) \(device) \(action)"
                    let sentence = device == .source ? macPlayOutSentence : iPhoneIPadNeedsLicensedMac
                    let log = BranchLog()
                    let sentBefore = rig.sent.count, serial = c.playSerial
                    var thrown: String?
                    do { try run(c, action, log, origin: .openData(resultNumber: nil)) } catch {
                        thrown = (error as? ActionError)?.message ?? "\(error)"
                    }
                    switch action.playOutClass {
                    case .startsOrReplacesSound:
                        XCTAssertEqual(thrown, sentence, label)
                        XCTAssertEqual(log.log, [], label)
                        XCTAssertEqual(rig.sent.count, sentBefore, label)
                        XCTAssertEqual(c.playSerial, serial, label)
                        XCTAssertEqual(c.playOutMode, device, label)
                    case .readsTheCurrentTrack:
                        XCTAssertEqual(thrown, device == .source ? currentTrackIsStaleInBridge : sentence, label)
                        XCTAssertEqual(log.log, [], label)
                        XCTAssertEqual(rig.sent.count, sentBefore, label)
                        XCTAssertEqual(c.playOutMode, device, label)
                    case .followsThePlayOut:
                        XCTAssertNil(thrown, label)
                        XCTAssertEqual(log.log, ["source"], label)
                        XCTAssertEqual(rig.sent.dropFirst(sentBefore).map(\.tag), [rig.tag(device)], label)
                    case .cannotStartSound:
                        // Routed as without a play-out (the matrix may still
                        // refuse it); never in the Mac's play-out sentence,
                        // and nothing reaches the device playing out.
                        XCTAssertNotEqual(thrown, macPlayOutSentence, label)
                        XCTAssertFalse(rig.sent.dropFirst(sentBefore).contains { $0.tag == rig.tag(device) }, label)
                        // And the branch that ran is the one the selection's
                        // matrix names, and no other (Codex review of 903825f).
                        let ran = log.log
                        XCTAssertLessThanOrEqual(ran.count, 1, label)
                        switch routeAction(action, selection: c.selection, from: surface).sound {
                        case .musicApp:   XCTAssertTrue(ran.allSatisfy { $0.hasPrefix("musicApp:") }, "\(label) \(ran)")
                        case .source:     XCTAssertTrue(ran.allSatisfy { $0 == "source" }, "\(label) \(ran)")
                        case .unaffected: XCTAssertEqual(ran, ["unaffected"], label)
                        case .refused:    XCTAssertEqual(ran, [], label); XCTAssertNotNil(thrown, label)
                        }
                    }
                }
            }
        }
    }

    /// A recorded play-out on `device`, as each kind arises.
    private func playingOut(on device: PlaybackMode,
                            _ surface: InvocationSurface) throws -> (LicenceRig, RoutingCoordinator) {
        guard device != .source else { return macPlayingOut(surface) }
        let rig = LicenceRig(output: device, accepted: true)
        let c = rig.coordinator(surface)
        rig.says(serving: true, playback: "idle")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete") }
        _ = try c.client(for: device).control.status()
        rig.says(serving: false, playback: "idle")
        XCTAssertEqual(c.playOutMode, device)
        return (rig, c)
    }

    /// The CLI verbs that can start sound but do not dispatch through the
    /// coordinator (`music speaker`'s route heal, bare `music suggest`'s
    /// picker), and the current-track verbs (`music love`, `music remove`),
    /// are gated by `refuseInBridge`, which reads the stored files. A
    /// play-out exists only while the stored output is a SpanDAC, and for
    /// every such stored selection that gate refuses every one of them, so
    /// none can sound, or act on a stale track, beside a play-out either.
    func testTheCLIFileGateRefusesEverySoundStartingActionWhileASpanDACIsStored() {
        let stored: [EffectiveSelection] = [
            .consistent(data: .spandacMac, output: .source),
            .consistent(data: .spandacMac, output: .networkSource(LicenceRig.ipad)),
            .outputBlocked(stored: .source),
            .outputBlocked(stored: .networkSource(LicenceRig.ipad)),
        ]
        for selection in stored {
            for action in MusicTUIAction.allCases
            where action.playOutClass == .startsOrReplacesSound || action.playOutClass == .readsTheCurrentTrack {
                XCTAssertNotNil(cliBridgeRefusal(action, selection: selection), "\(selection) \(action)")
            }
        }
    }
}

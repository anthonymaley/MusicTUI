// tools/music/Tests/MusicTests/RouteOutputRefusalTests.swift
//
// SpanDAC's `route_output_refused` (SpanDAC 0d84807): `slice.prepareRate` on the
// Mac route could not make the chosen DAC the Mac's default output, so it played
// nothing and answered `{"ok":false,"error":{"kind":"route_output_refused",
// "detail":"..."}}` with no `rate` object. MusicTUI must then NOT play the song
// (it would sound on whatever device the Mac is on), must not move the queue on,
// and must say SpanDAC's own sentence as the play's failure; every other
// `ok:false` stays what it was (the song plays, the line says SpanDAC was
// unavailable).
//
// Fakes only: SpanDAC is a scripted transport, Music is a recorder, the fence and
// lock files are in a temp directory. No audio, no AppleScript, no socket, no
// keychain, and never `~/.config/music`.
import ArgumentParser
import XCTest
@testable import music

final class RouteOutputRefusalTests: XCTestCase {

    private let detail = "Couldn't make SSL 2+ the Mac's output; nothing was played."

    private func refusalReply(detail: String? = nil, kind: String = "route_output_refused") -> String {
        var error: [String: Any] = ["kind": kind]
        if let detail { error["detail"] = detail }
        let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error])
        return String(decoding: data, as: UTF8.self)
    }

    private func settled(_ fence: Int) -> String {
        let rate: [String: Any] = ["fence": fence, "outcome": "settled", "rate_seq": 1, "step": 0, "target_hz": 96000]
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "rate": rate]), as: UTF8.self)
    }

    private final class Clock { var t: TimeInterval = 0 }

    private final class Wire {
        var requests: [[String: Any]] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        var ops: [String] { requests.compactMap { $0["op"] as? String } }
    }

    private func control(_ wire: Wire, clock: Clock) -> SourceAppControl {
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                wire.requests.append(body)
                do { return try wire.script(body) } catch SourceAppError.timedOut {
                    clock.t += timeout ?? 2.5
                    throw SourceAppError.timedOut
                }
            }
        }
        var c = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        c.rateSender = { transport($0) }
        return c
    }

    private final class FakeMusic: RateMusicControlling {
        var log: [String] = []
        var played: [String] = []
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        func playTrack(persistentID: String) throws {
            log.append("play"); played.append(persistentID)
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 0)
        }
        func pause() throws { log.append("pause") }
        func resume() throws { log.append("resume") }
        func seekToStart() throws { log.append("seek0") }
        func readCurrentTrack() -> RateTrackRead? {
            state.persistentID.map { RateTrackRead(persistentID: $0, databaseID: 1, sampleRateHz: 96000) }
        }
        func readPlayerState() -> RatePlayerState? {
            let shown = state
            if state.state == .playing {
                state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position + 0.5)
            }
            return shown
        }
    }

    // MARK: the wire

    /// The reply decodes on its KIND, to SpanDAC's own sentence, and the prepare's
    /// wait ends at once (no polling a refusal).
    func testARefusedPrepareIsFailedWithSpanDACsOwnSentenceAndIsNotPolled() {
        let clock = Clock(), wire = Wire()
        wire.script = { _ in self.refusalReply(detail: self.detail) }
        let follow = SourceRateFollow(token: RateToken(fence: 7, owner: "tui", command: .play),
                                      control: control(wire, clock: clock), offered: true,
                                      now: { clock.t }, sleep: { clock.t += $0 })
        let out = follow.prepare(dacUID: "ssl", persistentID: "9", catalogID: nil)
        XCTAssertEqual(out, .failed(.routeOutputRefused(detail)))
        XCTAssertEqual(wire.ops, [sourcePrepareRateOp], "a refusal was polled for")
    }

    func testARefusalWithNoDetailSaysSomethingPlain() {
        let clock = Clock(), wire = Wire()
        wire.script = { _ in self.refusalReply() }
        let follow = SourceRateFollow(token: RateToken(fence: 7, owner: "tui", command: .play),
                                      control: control(wire, clock: clock), offered: true,
                                      now: { clock.t }, sleep: { clock.t += $0 })
        XCTAssertEqual(follow.prepare(dacUID: nil, persistentID: "9", catalogID: nil),
                       .failed(.routeOutputRefused(SourceAppError.routeOutputRefusedSentence)))
    }

    /// The correction asks the same op, so a refusal there decodes the same way.
    func testARefusedCorrectionDecodesTheSameWay() {
        let clock = Clock(), wire = Wire()
        wire.script = { _ in self.refusalReply(detail: self.detail) }
        let follow = SourceRateFollow(token: RateToken(fence: 7, owner: "tui", command: .play),
                                      control: control(wire, clock: clock), offered: true,
                                      now: { clock.t }, sleep: { clock.t += $0 })
        XCTAssertEqual(follow.correct(toHz: 96000, dacUID: "ssl", persistentID: "9"),
                       .failed(.routeOutputRefused(detail)))
    }

    // MARK: the transition

    private struct Rig {
        let transition: RateAwareTransition
        let wire: Wire
        let music: FakeMusic
        let fence: RateFence
    }

    private func rig(_ dir: String = OutputLockTestSupport.tempDir(), owner: String = "tui",
                     script: @escaping ([String: Any]) throws -> String) -> Rig {
        let clock = Clock(), wire = Wire(), music = FakeMusic()
        wire.script = script
        let fence = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let c = control(wire, clock: clock)
        let transition = RateAwareTransition(
            fence: fence, owner: owner, music: music,
            makeFollow: { SourceRateFollow(token: $0, control: c, offered: true, now: { clock.t }, sleep: { clock.t += $0 }) },
            now: { clock.t }, streamWait: RateStreamWait(sleep: { clock.t += $0 }))
        return Rig(transition: transition, wire: wire, music: music, fence: fence)
    }

    private func plan(isCurrent: @escaping () -> Bool = { true }) -> RateTransitionPlan {
        RateTransitionPlan(command: .play, sound: .track(persistentID: "AAAA", catalogID: nil), dacUID: "ssl",
                           isCurrent: isCurrent)
    }

    /// The refusal plays NOTHING: no play, no pause, no resume, no confirm, and
    /// the result touches no retry gate.
    func testARefusedPrepareStartsNothingAndTouchesNoGate() {
        let r = rig { _ in self.refusalReply(detail: self.detail) }
        let result = r.transition.run(plan())
        XCTAssertEqual(result, .routeRefused(detail))
        XCTAssertNil(result.playOutcome, "a refusal must not count as a play failure (the gate would skip the song)")
        XCTAssertEqual(r.music.log, [], "Music was touched: \(r.music.log)")
        XCTAssertEqual(r.wire.ops, [sourcePrepareRateOp], "nothing was confirmed or corrected")
    }

    /// Every other `ok:false` is what it was: the song plays once, at the DAC's
    /// rate, and the start line says SpanDAC was unavailable.
    func testAnyOtherFailedReplyStillPlaysTheSong() throws {
        for kind in ["unavailable", "not_in_library", "something_new", "too_large"] {
            let r = rig { _ in self.refusalReply(detail: "nope", kind: kind) }
            let result = r.transition.run(plan())
            guard case .played(let played) = result else { return XCTFail("\(kind): \(result)") }
            XCTAssertEqual(played.startLine, .unavailable(.refused("nope")), kind)
            XCTAssertEqual(r.music.played, ["AAAA"], "\(kind): the song must play once")
            XCTAssertEqual(result.playOutcome, true, kind)
        }
    }

    /// A refusal for a request a newer command has already replaced is not spoken:
    /// the newer command owns the player, and nothing plays either way.
    func testARefusalForASupersededRequestIsInvalidatedNotSpoken() throws {
        let dir = OutputLockTestSupport.tempDir()
        let other = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let r = rig(dir) { _ in
            _ = try other.begin(.next, owner: "runner")
            return self.refusalReply(detail: self.detail)
        }
        XCTAssertEqual(r.transition.run(plan()), .invalidated)
        XCTAssertEqual(r.music.log, [])
    }

    // MARK: the player

    private func player(dir: String = OutputLockTestSupport.tempDir(), owner: String = "tui",
                        wire: Wire, music: FakeMusic, posts: @escaping (String) -> Void) -> MacRoutePlayer {
        let clock = Clock()
        let c = control(wire, clock: clock)
        return MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true },
            fence: RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001)), owner: owner,
            makeMusic: { _ in music },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { SourceRateFollow(token: $0, control: c, offered: true, now: { clock.t }, sleep: { clock.t += $0 }) },
            post: posts, now: { clock.t })
    }

    /// A queue-entry play that SpanDAC refuses: not played, not accepted (so no
    /// caller rolls the queue forward), SpanDAC's sentence posted and noted for the
    /// action; the next play clears the note.
    func testARefusedQueuePlayIsNotPlayedAndSaysSpanDACsWords() {
        let wire = Wire(), music = FakeMusic()
        var refuse = true
        wire.script = { body in
            if refuse { return self.refusalReply(detail: self.detail) }
            return self.settled(body["fence"] as? Int ?? 0)
        }
        var posted: [String] = []
        let p = player(wire: wire, music: music, posts: { posted.append($0) })
        let outcome = p.play(playlist: "Mix", position: 1, command: .play, isCurrent: { true })
        XCTAssertEqual(outcome, .routeRefused(detail))
        XCTAssertFalse(outcome.accepted)
        XCTAssertEqual(music.log, [], "a refused play touched Music")
        XCTAssertEqual(posted, [detail])
        XCTAssertEqual(p.routeRefusal.take(), detail)
        XCTAssertNil(p.routeRefusal.take(), "a refusal is spoken once")

        refuse = false
        p.routeRefusal.set("stale")
        XCTAssertEqual(p.play(playlist: "Mix", position: 1, command: .play, isCurrent: { true }), .played)
        XCTAssertNil(p.routeRefusal.take(), "a later play must not leave an old refusal behind")
    }

    /// A station on the route is refused as a whole: the open never runs, and the
    /// action's error is SpanDAC's sentence.
    func testARefusedStationDoesNotOpenAndThrowsSpanDACsWords() {
        let wire = Wire(), music = FakeMusic()
        wire.script = { _ in self.refusalReply(detail: self.detail) }
        let p = player(wire: wire, music: music, posts: { _ in })
        var opened = 0
        XCTAssertThrowsError(try p.playStation(start: { opened += 1 })) {
            XCTAssertEqual(($0 as? ActionError)?.message, self.detail)
        }
        XCTAssertEqual(opened, 0, "the station opened on the wrong output")
    }

    // MARK: the runner

    private func runner(wire: Wire, music: FakeMusic, control: RunQueueControlling? = nil,
                        queue: AppQueueStore) -> (RunQueueRunner, MacRoutePlayer) {
        let clock = Clock()
        let p = player(wire: wire, music: music, posts: { _ in })
        let watcher = PlayingWatcher(music)
        let r = RunQueueRunner(queue: queue, player: p, route: MacDACRouteState(initial: true),
                               routeStillChosen: { true }, watcher: watcher,
                               sleep: { clock.t += $0 }, now: { clock.t },
                               pollInterval: 1, startGracePolls: 3, maxUnreadablePolls: 3, maxNotStarted: 3,
                               control: control)
        return (r, p)
    }

    /// Music shows whatever the fake last played, mid-song.
    private final class PlayingWatcher: RunQueueWatching {
        let music: FakeMusic
        init(_ music: FakeMusic) { self.music = music }
        func musicIsRunning() -> Bool { true }
        func readPlayback() -> RunQueuePlayback? {
            RunQueuePlayback(state: .playing, persistentID: music.state.persistentID, position: 10, duration: 200)
        }
        func songRepeat() -> RepeatMode? { nil }
    }

    private final class RecordingControl: RunQueueControlling {
        var acks: [String] = []
        var skips: [RunQueueSkipRequest] = []
        func register() {}
        func markReady() {}
        func unregister() {}
        func takeSkip() -> RunQueueSkipRequest? { skips.isEmpty ? nil : skips.removeFirst() }
        func acknowledge(nonce: String, outcome: RunQueueSkipOutcome) { acks.append("\(nonce) \(outcome.rawValue)") }
        func acknowledgeRefused(nonce: String, detail: String) { acks.append("\(nonce) refused \(detail)") }
    }

    /// The runner asked for the first song, SpanDAC refuses: nothing plays, the
    /// song is asked for ONCE (no retry, no skip past it) and the queue stays on it.
    func testTheRunnerDoesNotPlayOrAdvanceOnARefusal() {
        let wire = Wire(), music = FakeMusic()
        wire.script = { _ in self.refusalReply(detail: self.detail) }
        let ids = ["AAAAAAAAAAAAAAA1", "BBBBBBBBBBBBBBB2"]
        let queue = AppQueueStore()
        queue.set(runQueueAppQueue(ids: ids, label: "Mixtape"))
        let (r, _) = runner(wire: wire, music: music, queue: queue)
        XCTAssertEqual(r.run(), .routeRefused(detail))
        XCTAssertEqual(music.log, [], "the runner played or paused something")
        XCTAssertEqual(wire.ops.filter { $0 == sourcePrepareRateOp }.count, 1, "the refused song was asked for again")
        XCTAssertEqual(queue.read()?.currentIndex, 1, "the queue moved on past a song that never played")
    }

    /// A skip whose song is refused is answered with SpanDAC's sentence, and the
    /// runner leaves without playing the refused song or any after it.
    func testASkipWhoseSongIsRefusedIsAnsweredWithTheSentence() {
        let wire = Wire(), music = FakeMusic()
        var prepares = 0
        wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp {
                prepares += 1
                if prepares >= 2 { return self.refusalReply(detail: self.detail) }
            }
            return self.settled(body["fence"] as? Int ?? 0)
        }
        let control = RecordingControl()
        control.skips = [RunQueueSkipRequest(step: 1, nonce: "SKIP1")]
        let queue = AppQueueStore()
        queue.set(runQueueAppQueue(ids: ["AAAAAAAAAAAAAAA1", "BBBBBBBBBBBBBBB2", "CCCCCCCCCCCCCCC3"], label: "Mixtape"))
        let (r, _) = runner(wire: wire, music: music, control: control, queue: queue)
        XCTAssertEqual(r.run(), .routeRefused(detail))
        XCTAssertEqual(music.played, ["AAAAAAAAAAAAAAA1"], "the refused song, or one after it, played")
        XCTAssertEqual(control.acks, ["SKIP1 refused \(detail)"])
        XCTAssertEqual(prepares, 2, "a refused skip was asked for again")
    }

    // MARK: the skip channel

    private func tempDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "route-refusal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// The ack file carries SpanDAC's sentence (on one line, with its spaces) and
    /// the client hands it back whole, so `music skip` can print it.
    func testTheSkipClientHearsSpanDACsSentenceThroughTheAckFile() throws {
        let files = RunQueueControlFiles(directory: try tempDirectory())
        let runner = FileRunQueueControl(files: files, owner: "runner-1", pid: 4242)
        runner.register(); runner.markReady()
        var taken: RunQueueSkipRequest?
        var c = RunQueueSkipClient(files: files, leaseStatus: { _ in .ours })
        c.isAlive = { _ in true }
        c.newNonce = { "NONCE" }
        let clock = Clock()
        c.now = { clock.t }
        c.sleep = {
            clock.t += $0
            if taken == nil { taken = runner.takeSkip() }
            else if let taken { runner.acknowledgeRefused(nonce: taken.nonce, detail: self.detail) }
        }
        XCTAssertEqual(c.send(step: 1), .refused(detail))
    }

    func testMusicSkipPrintsSpanDACsSentenceAndFails() throws {
        let files = RunQueueControlFiles(directory: try tempDirectory())
        let runner = FileRunQueueControl(files: files, owner: "runner-1", pid: 4242)
        runner.register(); runner.markReady()
        var taken: RunQueueSkipRequest?
        var c = RunQueueSkipClient(files: files, leaseStatus: { _ in .ours })
        c.isAlive = { _ in true }
        c.newNonce = { "NONCE" }
        let clock = Clock()
        c.now = { clock.t }
        c.sleep = {
            clock.t += $0
            if taken == nil { taken = runner.takeSkip() }
            else if let taken { runner.acknowledgeRefused(nonce: taken.nonce, detail: self.detail) }
        }
        var said: [String] = []
        XCTAssertThrowsError(try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: c,
                                                   show: { _ in XCTFail("shown as playing") },
                                                   fail: { said.append($0) })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(said, [detail])
    }

    /// A control that cannot carry the sentence (an older one) still says the skip did not start.
    func testAControlWithoutTheSentenceFallsBackToNotStarted() {
        let control = LegacyControl()
        control.acknowledgeRefused(nonce: "N", detail: detail)
        XCTAssertEqual(control.acks, ["N notStarted"])
    }
    private final class LegacyControl: RunQueueControlling {
        var acks: [String] = []
        func register() {}
        func markReady() {}
        func unregister() {}
        func takeSkip() -> RunQueueSkipRequest? { nil }
        func acknowledge(nonce: String, outcome: RunQueueSkipOutcome) { acks.append("\(nonce) \(outcome.rawValue)") }
    }

    // MARK: the TUI's play line

    /// An action whose play was refused says SpanDAC's sentence, not "Couldn't
    /// play ..."; without a refusal it says what it always said; an action that does
    /// not start anything never speaks a refusal.
    func testAFailedPlayActionSaysSpanDACsSentenceInsteadOfTheGenericOne() {
        let note = RouteRefusalNote()
        let status = StatusStore()
        let actions = ActionRunner(status: status, routeRefusal: note)

        actions.run("Play") { note.set(self.detail); throw ActionError(message: "Couldn't play 'Mix'.") }
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, detail)
        XCTAssertEqual(status.current()?.isError, true)

        actions.run("Play") { throw ActionError(message: "Couldn't play 'Mix'.") }
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, "Couldn't play 'Mix'.", "an old refusal was spoken for another failure")

        actions.run("Volume") { note.set(self.detail); throw ActionError(message: "Couldn't set volume.") }
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, "Couldn't set volume.")
    }
}

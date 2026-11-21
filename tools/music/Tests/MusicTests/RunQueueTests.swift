// tools/music/Tests/MusicTests/RunQueueTests.swift
//
// The CLI's half of the Mac DAC route (mac-route-plan.md section 3.1, D1; score
// step P5): on the route `music play` starts a detached `__run-queue` instead of
// building the temporary playlist; the runner plays the queue one song at a time
// through the rate-aware transition and holds the play lease, a newer play from
// the TUI supersedes it and the runner supersedes the TUI; it ends at the queue's
// end, on supersession, when the route is left, and never leaves a follower pause.
//
// Fakes only: the fence files and the output lock live in a temp directory;
// SpanDAC is a scripted transport with a fake clock; Music.app is `FakeMusic`
// and its reads are a simulation driven by the runner's own sleep seam; the
// launcher is a recorder. No process is launched, no audio, no AppleScript, no
// socket, and never `~/.config/music`.
import XCTest
@testable import music

final class RunQueueTests: XCTestCase {

    // MARK: support (the shapes MacRouteWiringTests uses)

    private final class Clock { var t: TimeInterval = 0 }

    private final class Wire {
        let clock: Clock
        var requests: [[String: Any]] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        init(_ clock: Clock) { self.clock = clock }
        var ops: [String] { requests.compactMap { $0["op"] as? String } }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                wire.requests.append(body)
                do { return try wire.script(body) } catch SourceAppError.timedOut {
                    wire.clock.t += timeout ?? 2.5
                    throw SourceAppError.timedOut
                }
            }
        }
        var c = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        c.rateSender = { transport($0) }
        return c
    }

    private func answer(_ fence: Int, _ outcome: String, step: Int? = nil, target: Int? = nil) -> String {
        var rate: [String: Any] = ["fence": fence, "outcome": outcome, "rate_seq": 1]
        if let step { rate["step"] = step }
        if let target { rate["target_hz"] = target }
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "rate": rate])
        return String(decoding: data, as: UTF8.self)
    }

    private func settlingScript(confirm: String = "own_rate") -> ([String: Any]) throws -> String {
        { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2): return self.answer(f, "settled", step: 2, target: 96000)
            case (sourcePrepareRateOp, _): return self.answer(f, "settled", step: 0, target: 96000)
            case (sourceConfirmRateOp, _): return self.answer(f, confirm, step: 1, target: 96000)
            default: return self.answer(f, "quiet")
            }
        }
    }

    private final class FakeMusic: RateMusicControlling {
        var log: [String] = []
        var played: [String] = []
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        var current: RateTrackRead?
        var playError: Error?
        /// After a pause, this many state reads still say playing (Music's player
        /// state lags a pause by a moment).
        var pauseLagReads = 0
        /// Runs as a play reaches Music (a report arriving mid-start).
        var onPlay: (() -> Void)?
        /// Plays after this many have started throw (Music refusing them); nil never.
        var failPlaysAfter: Int?
        /// The sample rates successive reads of the current track return, the last one
        /// repeating; empty reads the track's own 96000.
        var rateReads: [Int] = []
        private var lagging = 0
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        func playTrack(persistentID: String) throws {
            log.append("play")
            onPlay?()
            if let playError { throw playError }
            if let limit = failPlaysAfter, played.count >= limit { throw ActionError(message: "refused") }
            played.append(persistentID)
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 0)
            current = RateTrackRead(persistentID: persistentID, databaseID: 1, sampleRateHz: 96000)
        }
        func pause() throws {
            log.append("pause")
            state = RatePlayerState(state: .paused, persistentID: state.persistentID, position: 12)
            lagging = pauseLagReads
        }
        func resume() throws {
            log.append("resume")
            state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position)
        }
        func seekToStart() throws { log.append("seek0") }
        func readCurrentTrack() -> RateTrackRead? {
            guard let current, !rateReads.isEmpty else { return current }
            let hz = rateReads.count > 1 ? rateReads.removeFirst() : rateReads[0]
            return RateTrackRead(persistentID: current.persistentID, databaseID: current.databaseID, sampleRateHz: hz)
        }
        func readPlayerState() -> RatePlayerState? {
            if state.state == .paused, lagging > 0 {
                lagging -= 1
                return RatePlayerState(state: .playing, persistentID: state.persistentID, position: 12)
            }
            let shown = state
            // A playing stream advances between reads (the stream-up proof).
            if state.state == .playing {
                state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position + 0.5)
            }
            return shown
        }
    }

    /// Music's player as the runner's wait reads it. By default each song is
    /// playing at 10 s, playing 1 s before its 200 s end, then stopped (Autoplay
    /// off): three polls. `script` replaces a poll's answer, keyed by the
    /// 1-based play count and the 1-based poll of that song.
    private final class Sim: RunQueueWatching {
        let music: FakeMusic
        var running = true
        var duration: TimeInterval = 200
        var script: [String: RunQueuePlayback?] = [:]
        var live = false   // read Music's own state as it is
        /// Music's song repeat, as the wrap check reads it; nil says nothing.
        var repeatMode: RepeatMode?
        func songRepeat() -> RepeatMode? { repeatMode }
        private var plays = 0
        private var polls = 0
        init(_ music: FakeMusic) { self.music = music }
        func musicIsRunning() -> Bool { running }
        func readPlayback() -> RunQueuePlayback? {
            if music.count("play") != plays { plays = music.count("play"); polls = 0 }
            polls += 1
            if let scripted = script["\(plays).\(polls)"] { return scripted }
            let pid = music.state.persistentID
            if live {
                let s = music.state
                return RunQueuePlayback(state: s.state == .playing ? .playing : s.state == .paused ? .paused : .stopped,
                                        persistentID: s.persistentID, position: s.position, duration: duration)
            }
            switch polls {
            case 1: return RunQueuePlayback(state: .playing, persistentID: pid, position: 10, duration: duration)
            case 2: return RunQueuePlayback(state: .playing, persistentID: pid, position: duration - 1, duration: duration)
            default: return RunQueuePlayback(state: .stopped, persistentID: pid, position: 0, duration: duration)
            }
        }
    }

    private let ids = ["AAAAAAAAAAAAAAA1", "BBBBBBBBBBBBBBB2", "CCCCCCCCCCCCCCC3"]

    /// One MusicTUI process (the runner, or the TUI) composed for the route over
    /// a temp state directory.
    private final class Rig {
        let dir: String
        let clock = Clock()
        let wire: Wire
        let music = FakeMusic()
        let route = MacDACRouteState(initial: true)
        var chosen = true
        var transitions: [RateTransitionResult] = []
        let fence: RateFence
        var player: MacRoutePlayer!
        lazy var sim = Sim(music)

        init(dir: String, owner: String, withReporter: Bool = false, streamWait: RateStreamWait = .instant,
             makeControl: (Wire) -> SourceAppControl) {
            self.dir = dir
            wire = Wire(clock)
            fence = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
            let clock = self.clock, music = self.music
            let controlValue = makeControl(wire)
            player = MacRoutePlayer(
                streamWait: streamWait, route: route, outputIsMusicApp: { true }, fence: fence, owner: owner,
                makeMusic: { _ in music },
                resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
                makeFollow: { token in
                    SourceRateFollow(token: token, control: controlValue, offered: true,
                                     now: { clock.t }, sleep: { clock.t += $0 })
                },
                post: { _ in },
                reporter: withReporter ? MacRouteFollowReporter(control: controlValue, schedule: { $0() }) : nil,
                now: { clock.t })
            player.onTransition = { [unowned self] in self.transitions.append($0) }
        }

        func runner(_ queue: AppQueueStore, maxLifetime: TimeInterval = 10_000,
                    firstToken: RateToken? = nil,
                    control: RunQueueControlling? = nil,
                    onSleep: @escaping () -> Void = {}) -> RunQueueRunner {
            let clock = self.clock
            return RunQueueRunner(queue: queue, player: player, route: route,
                                  routeStillChosen: { [unowned self] in self.chosen }, watcher: sim,
                                  firstToken: firstToken,
                                  sleep: { clock.t += $0; onSleep() }, now: { clock.t },
                                  pollInterval: 1, startGracePolls: 3, maxUnreadablePolls: 3, maxNotStarted: 3,
                                  maxLifetime: maxLifetime, control: control)
        }
    }

    private func rig(_ dir: String? = nil, owner: String = "runner", withReporter: Bool = false,
                     streamWait: RateStreamWait = .instant) -> Rig {
        let holder = Rig(dir: dir ?? OutputLockTestSupport.tempDir(), owner: owner, withReporter: withReporter,
                         streamWait: streamWait,
                         makeControl: { [unowned self] wire in self.control(wire) })
        holder.wire.script = settlingScript()
        return holder
    }

    private func queueStore(_ ids: [String]) -> AppQueueStore {
        let store = AppQueueStore()
        store.set(runQueueAppQueue(ids: ids, label: "Mixtape"))
        return store
    }

    // MARK: the runner plays track by track through the transition

    func testTheRunnerPlaysTheQueueTrackByTrackThroughTheTransitionAndEndsAtTheEnd() throws {
        let r = rig()
        let store = queueStore(ids)
        XCTAssertEqual(r.runner(store).run(), .finished)
        XCTAssertEqual(r.music.played, ids, "every song, in order, one at a time")
        // Each song was its own transition: SpanDAC was asked before the song
        // played and told after it.
        XCTAssertEqual(r.wire.ops.filter { $0 == sourcePrepareRateOp }.count, 3)
        XCTAssertEqual(r.wire.ops.filter { $0 == sourceConfirmRateOp }.count, 3)
        XCTAssertEqual(r.wire.ops.first, sourcePrepareRateOp)
        XCTAssertGreaterThanOrEqual(try r.fence.current(), 3, "every song moved the fence first")
        let commands = r.transitions.compactMap { result -> RateCommand? in
            if case .played(let p) = result { return p.token.command }
            return nil
        }
        XCTAssertEqual(commands, [.play, .advance, .advance])
        XCTAssertEqual(r.music.count("pause"), 0)
        XCTAssertEqual(r.player.fence.leaseStatus(owner: r.player.owner), .ours, "the runner held the lease to the end")
        // It does not start the next song until the previous one ended: the
        // plays are separated by the polls that watched each one finish.
        XCTAssertGreaterThanOrEqual(r.clock.t, 9, "three songs of three polls, at a second each")
    }

    /// Finding 3 on the CLI's own path, as the live log shows it (2026-11-17 21:29):
    /// a one-song runner queue, SpanDAC answers the first confirm `correct`, the
    /// runner pauses Music, and Music's player state still says playing for the
    /// first read-back. The runner's player must wait for its own pause to show and
    /// then ask SpanDAC to write the rate (step 2) and resume, not drop the
    /// correction and leave Music paused.
    func testACLISongWhoseConfirmSaysCorrectIsCorrectedEvenWhenMusicShowsThePauseLate() throws {
        let r = rig(streamWait: RateStreamWait(pauseReads: 5, sleep: { _ in }))
        r.wire.script = settlingScript(confirm: "correct")
        r.music.pauseLagReads = 2
        XCTAssertEqual(r.runner(queueStore([ids[0]])).run(), .finished)
        XCTAssertEqual(r.wire.requests.filter { ($0["op"] as? String) == sourcePrepareRateOp && ($0["step"] as? Int) == 2 }.count, 1,
                       "SpanDAC was never asked to write the rate")
        XCTAssertEqual(r.music.count("pause"), 1)
        XCTAssertEqual(r.music.count("resume"), 1, "the runner left Music paused")
        XCTAssertEqual(r.music.state.state, .playing)
    }

    // MARK: skip and back from another process (finding 7, live check 2026-11-18)

    /// The runner's end of the channel, in memory: hands out the scripted skips one at
    /// a time on successive polls and records what the runner said back.
    private final class FakeControl: RunQueueControlling {
        var registered = 0, unregistered = 0
        /// How many songs had been played when the runner said it was ready (held the lease).
        var registeredAtPlays: [Int] = []
        var starts = 0
        var skips: [(afterPlays: Int, request: RunQueueSkipRequest)] = []
        var acks: [(nonce: String, outcome: RunQueueSkipOutcome, playsAtAck: Int)] = []
        var playCount: () -> Int = { 0 }
        func register() { starts += 1 }
        func markReady() { registered += 1; registeredAtPlays.append(playCount()) }
        func unregister() { unregistered += 1 }
        func takeSkip() -> RunQueueSkipRequest? {
            guard let first = skips.first, playCount() >= first.afterPlays else { return nil }
            return skips.removeFirst().request
        }
        func acknowledge(nonce: String, outcome: RunQueueSkipOutcome) { acks.append((nonce, outcome, playCount())) }
    }

    private func skipRig(_ control: FakeControl) -> Rig {
        let r = rig()
        control.playCount = { r.music.count("play") }
        // Song 1 plays on for as long as the polls are scripted; with no skip heard
        // the runner would leave on the stop that follows (`.stoppedEarly`).
        for poll in 1...2 {
            r.sim.script["1.\(poll)"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 10, duration: 200)
        }
        return r
    }

    private func commands(_ r: Rig) -> [RateCommand] {
        r.transitions.compactMap { result -> RateCommand? in
            if case .played(let p) = result { return p.token.command }
            return nil
        }
    }

    /// The live bug: `music skip` on the route restarted the song, because Music has
    /// no next item and the runner never heard of it. A skip the runner is handed
    /// steps ITS queue and plays the next song through the transition (`.next`: the
    /// fence moves, SpanDAC prepares and confirms), at once, not at the song's end.
    func testASkipHeardWhileASongPlaysPlaysTheNextSongThroughTheTransition() throws {
        let control = FakeControl()
        control.skips = [(1, RunQueueSkipRequest(step: 1, nonce: "N1"))]
        let r = skipRig(control)
        let exit = r.runner(queueStore(ids), control: control).run()
        XCTAssertEqual(Array(r.music.played.prefix(2)), [ids[0], ids[1]], "the skip did not reach the runner's queue")
        XCTAssertEqual(Array(commands(r).prefix(2)), [.play, .next])
        XCTAssertNotEqual(exit, .stoppedEarly)
        XCTAssertEqual(r.wire.ops.filter { $0 == sourcePrepareRateOp }.count >= 2, true, "the new song's rate was not prepared")
        XCTAssertEqual(control.acks.map(\.nonce), ["N1"])
        XCTAssertEqual(control.acks.first?.outcome, .played)
        XCTAssertEqual(control.acks.first?.playsAtAck, 2, "acknowledged before the song it led to was started")
        XCTAssertEqual(control.registered, 1)
        XCTAssertEqual(control.unregistered, 1)
    }

    /// Known from the start (a client waits for a runner that is starting instead of
    /// restarting the song through Music), ready to be asked only once the lease is held:
    /// a runner with no reserved ordering takes the lease at its FIRST play.
    func testTheRunnerAnnouncesItselfAtOnceAndIsReadyOnlyOnceItHoldsTheLease() throws {
        let control = FakeControl()
        let r = skipRig(control)
        _ = r.runner(queueStore(ids), control: control).run()
        XCTAssertEqual(control.starts, 1, "the starting runner was never announced")
        XCTAssertEqual(control.registeredAtPlays, [1], "ready before the lease was held, or more than once")
    }

    /// The ack carries what happened: Music refusing the song the skip led to is a
    /// failure the client reports, not a success.
    func testAFailedPlayAfterASkipIsAnsweredAsFailed() throws {
        let control = FakeControl()
        control.skips = [(1, RunQueueSkipRequest(step: 1, nonce: "N1"))]
        let r = skipRig(control)
        r.music.failPlaysAfter = 1       // song 1 plays; every play after it is refused
        _ = r.runner(queueStore(ids), control: control).run()
        XCTAssertEqual(control.acks.map(\.nonce), ["N1"])
        XCTAssertEqual(control.acks.first?.outcome, .failed)
    }

    /// A newer command that owns the player when the skip is heard: answered superseded.
    func testASkipHeardAfterANewerCommandIsAnsweredAsSuperseded() throws {
        let control = FakeControl()
        control.skips = [(1, RunQueueSkipRequest(step: 1, nonce: "N1"))]
        let r = skipRig(control)
        _ = r.runner(queueStore(ids), control: control, onSleep: {
            if r.music.count("play") == 1 { _ = try? r.fence.begin(.next, owner: "someone-else") }
        }).run()
        XCTAssertEqual(control.acks.map(\.nonce), ["N1"])
        XCTAssertEqual(control.acks.first?.outcome, .superseded)
    }

    /// Back steps the queue back one song with the `.previous` command.
    func testABackHeardOnTheSecondSongPlaysTheFirstThroughTheTransition() throws {
        let control = FakeControl()
        control.skips = [(1, RunQueueSkipRequest(step: 1, nonce: "N1")), (2, RunQueueSkipRequest(step: -1, nonce: "N2"))]
        let r = skipRig(control)
        for poll in 1...2 {
            r.sim.script["2.\(poll)"] = RunQueuePlayback(state: .playing, persistentID: ids[1], position: 10, duration: 200)
        }
        _ = r.runner(queueStore(ids), control: control).run()
        XCTAssertEqual(Array(r.music.played.prefix(3)), [ids[0], ids[1], ids[0]])
        XCTAssertEqual(Array(commands(r).prefix(3)), [.play, .next, .previous])
        XCTAssertEqual(control.acks.map(\.nonce), ["N1", "N2"])
    }

    /// Back on the first song plays it again; a skip past the last song plays
    /// nothing but is still answered, so the client is not left waiting.
    func testBackOnTheFirstSongReplaysItAndASkipPastTheEndIsAnsweredAndIgnored() throws {
        let back = FakeControl()
        back.skips = [(1, RunQueueSkipRequest(step: -1, nonce: "B"))]
        let r = skipRig(back)
        _ = r.runner(queueStore(ids), control: back).run()
        XCTAssertEqual(Array(r.music.played.prefix(2)), [ids[0], ids[0]])
        XCTAssertEqual(commands(r).dropFirst().first, .previous)
        XCTAssertEqual(back.acks.map(\.nonce), ["B"])

        let forward = FakeControl()
        forward.skips = [(1, RunQueueSkipRequest(step: 1, nonce: "F"))]
        let r2 = skipRig(forward)
        r2.sim.script["1.3"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 199, duration: 200)
        _ = r2.runner(queueStore([ids[0]]), control: forward).run()
        XCTAssertEqual(r2.music.played, [ids[0]], "a skip past the last song played something")
        XCTAssertEqual(forward.acks.map(\.nonce), ["F"], "the client was left waiting")
    }

    // MARK: Music's decoder upgrades a streamed song mid-song (finding 6, live check 2026-11-18)

    /// Music's decoder reports, by hand: `start` is what the player subscribes with.
    private final class FakeFeed: DecoderRateFeed {
        var onReport: ((DecoderReport) -> Void)?
        var starts = 0, stops = 0
        func start(onReport: @escaping (DecoderReport) -> Void) { starts += 1; self.onReport = onReport }
        func stop() { stops += 1; onReport = nil }
        func emit(_ hz: Int, at: Date = Date()) {
            onReport?(DecoderReport(sampleRateHz: hz, at: at, format: "qlac", rendition: "Lossless"))
        }
    }

    /// A feed whose start takes a moment, as a real child process does; it records
    /// whether it is running when the dust settles.
    private final class SlowFeed: DecoderRateFeed {
        private let lock = NSLock()
        private var _running = false
        var duringStart: () -> Void = {}
        var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }
        func start(onReport: @escaping (DecoderReport) -> Void) {
            duringStart()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); _running = true; lock.unlock()
        }
        func stop() { lock.lock(); _running = false; lock.unlock() }
    }

    /// The player shuts down while the feed is still starting (the first play is in the
    /// middle of starting the child): the stop must not slip in before the start and
    /// leave a child running for ever. Start and stop are one critical section.
    func testAShutdownDuringTheFeedsStartStillEndsTheFeed() throws {
        let r = rig()
        let feed = SlowFeed()
        r.player.decoderFeed = feed
        var shutdown: Thread?
        let done = DispatchSemaphore(value: 0)
        feed.duringStart = {
            let t = Thread { r.player.shutdown(wait: 2); done.signal() }
            shutdown = t
            t.start()
        }
        let entry = try XCTUnwrap(persistentIDQueueEntry(persistentID: ids[0], name: "L", artist: "", album: nil))
        _ = r.player.play(playlist: persistentIDQueueSource, position: entry.index, command: .play, isCurrent: { true })
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the shutdown never finished")
        XCTAssertNotNil(shutdown)
        XCTAssertFalse(feed.running, "a decoder feed was left running after the player shut down")
        // And a feed that was stopped is never started again.
        r.player.decoderFeed = feed
        _ = r.player.play(playlist: persistentIDQueueSource, position: entry.index, command: .play, isCurrent: { true })
        XCTAssertFalse(feed.running, "a closed player started a feed")
    }

    /// The live song: the DAC is at 48000, the AppleScript rate read says 48000 for the whole
    /// song (the lossy start), and a report arrives mid-song with what the decoder opened.
    private func decoderRun(expect: RunQueueExit = .finished, songs: [String]? = nil, emitAfterPlays: Int = 1,
                            reports: @escaping (FakeFeed, Rig) -> Void) throws -> (Rig, FakeFeed, dacHz: () -> Int) {
        let r = rig()
        let feed = FakeFeed()
        var dacHz = 48000
        r.music.rateReads = [48000]
        r.wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2):
                dacHz = body["rate_hz"] as? Int ?? dacHz
                return self.answer(f, "settled", step: 2, target: dacHz)
            case (sourcePrepareRateOp, _): return self.answer(f, "same_rate", step: 0, target: 48000)
            case (sourceConfirmRateOp, _):
                let delivered = body["delivered_hz"] as? Int
                return self.answer(f, delivered == dacHz ? "own_rate" : "correct", step: 1, target: delivered)
            default: return self.answer(f, "quiet")
            }
        }
        r.player.decoderFeed = feed
        r.player.runFollowUp = { $0() }
        var emitted = false
        let runner = r.runner(queueStore(songs ?? [ids[0]]), onSleep: {
            guard !emitted, r.music.count("play") == emitAfterPlays else { return }
            emitted = true
            reports(feed, r)
        })
        XCTAssertEqual(runner.run(), expect)
        return (r, feed, { dacHz })
    }

    private func confirmedHz(_ r: Rig) -> [Int?] {
        r.wire.requests.filter { $0["op"] as? String == sourceConfirmRateOp }.map { $0["delivered_hz"] as? Int }
    }
    private func rateWrites(_ r: Rig) -> Int {
        r.wire.requests.filter { ($0["op"] as? String) == sourcePrepareRateOp && ($0["step"] as? Int) == 2 }.count
    }

    /// The bug: the start confirmed 48000, Music upgraded to 96000 seven seconds in, and
    /// nothing noticed. The decoder's report now confirms 96000, SpanDAC says `correct`,
    /// and the correction runs mid-song: pause, DAC, resume AT THE SAME POSITION (no seek
    /// to the start), once.
    func testAnUpgradeReportMidSongMovesTheDACAndResumesAtTheSamePosition() throws {
        let (r, feed, dacHz) = try decoderRun(reports: { feed, _ in feed.emit(96000) })
        XCTAssertEqual(feed.starts, 1, "the decoder feed was never started")
        XCTAssertEqual(Array(confirmedHz(r).prefix(2)), [48000, 96000], "the rate Music opened was never confirmed")
        XCTAssertEqual(dacHz(), 96000, "the DAC stayed under the song")
        XCTAssertEqual(rateWrites(r), 1)
        XCTAssertEqual(r.music.count("pause"), 1)
        XCTAssertEqual(r.music.count("resume"), 1)
        XCTAssertEqual(r.music.count("seek0"), 0, "a mid-song correction restarted the song")
        XCTAssertEqual(r.music.count("play"), 1)
        XCTAssertEqual(feed.stops, 1, "the decoder feed outlived the player")
    }

    /// Reports that say nothing new change nothing: the same rate, a report from before
    /// the song started, and a second report of the same upgrade.
    func testReportsThatSayNothingNewCorrectNothing() throws {
        let (r, _, _) = try decoderRun(reports: { feed, _ in
            feed.emit(48000)                                          // the start's own rate
            feed.emit(96000, at: Date(timeIntervalSinceNow: -3600))   // the song before this one
        })
        XCTAssertEqual(confirmedHz(r), [48000])
        XCTAssertEqual(r.music.count("pause"), 0)

        let (r2, _, _) = try decoderRun(reports: { feed, _ in feed.emit(96000); feed.emit(96000) })
        XCTAssertEqual(rateWrites(r2), 1, "one upgrade was corrected twice")
        XCTAssertEqual(r2.music.count("pause"), 1)
    }

    // MARK: a report belongs to the song that was playing when it was logged (Codex review)

    /// The outgoing song's upgrade, logged just before the next song started, reaches
    /// the player after the incoming song is installed. It is stamped before the
    /// incoming song's start, so it is not that song's: nothing is corrected.
    func testAnOutgoingSongsLateReportIsNeverAppliedToTheIncomingSong() throws {
        let (r, _, dacHz) = try decoderRun(songs: [ids[0], ids[1]], emitAfterPlays: 2, reports: { feed, _ in
            feed.emit(96000, at: Date(timeIntervalSinceNow: -0.5))
        })
        XCTAssertEqual(confirmedHz(r).compactMap { $0 }.filter { $0 == 96000 }.count, 0,
                       "the outgoing song's rate was confirmed for the incoming song")
        XCTAssertEqual(r.music.count("pause"), 0)
        XCTAssertEqual(rateWrites(r), 0)
        XCTAssertEqual(dacHz(), 48000)
    }

    /// A report that arrives while the next song is still starting (its play is in
    /// flight) has no song to belong to: the old one is cleared at the start of a play.
    func testAReportDuringTheNextSongsStartBelongsToNoSong() throws {
        let r = rig()
        let feed = FakeFeed()
        r.music.rateReads = [48000]
        r.wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, _): return self.answer(f, "same_rate", step: 0, target: 48000)
            case (sourceConfirmRateOp, _): return self.answer(f, "own_rate", step: 1, target: 48000)
            default: return self.answer(f, "quiet")
            }
        }
        r.player.decoderFeed = feed
        var closures: [() -> Void] = []
        r.player.runFollowUp = { closures.append($0) }
        let a = try XCTUnwrap(persistentIDQueueEntry(persistentID: ids[0], name: "A", artist: "", album: nil))
        let b = try XCTUnwrap(persistentIDQueueEntry(persistentID: ids[1], name: "B", artist: "", album: nil))
        _ = r.player.play(playlist: persistentIDQueueSource, position: a.index, command: .play, isCurrent: { true })
        r.music.onPlay = { feed.emit(96000) }                     // while B is being started
        _ = r.player.play(playlist: persistentIDQueueSource, position: b.index, command: .next, isCurrent: { true })
        XCTAssertEqual(closures.count, 0, "a report during a start was taken for a song")
    }

    /// Two reports for one song while a correction runs: the second waits and then runs
    /// for the SAME song; if another song has started meanwhile it is dropped.
    private func pendingRun(playNext: Bool) throws -> (confirmed: [Int?], closures: Int) {
        let r = rig()
        let feed = FakeFeed()
        var dacHz = 48000
        r.music.rateReads = [48000]
        r.wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2):
                dacHz = body["rate_hz"] as? Int ?? dacHz
                return self.answer(f, "settled", step: 2, target: dacHz)
            case (sourcePrepareRateOp, _): return self.answer(f, "same_rate", step: 0, target: 48000)
            case (sourceConfirmRateOp, _):
                let delivered = body["delivered_hz"] as? Int
                return self.answer(f, delivered == dacHz ? "own_rate" : "correct", step: 1, target: delivered)
            default: return self.answer(f, "quiet")
            }
        }
        r.player.decoderFeed = feed
        var closures: [() -> Void] = []
        r.player.runFollowUp = { closures.append($0) }
        let a = try XCTUnwrap(persistentIDQueueEntry(persistentID: ids[0], name: "A", artist: "", album: nil))
        let b = try XCTUnwrap(persistentIDQueueEntry(persistentID: ids[1], name: "B", artist: "", album: nil))
        _ = r.player.play(playlist: persistentIDQueueSource, position: a.index, command: .play, isCurrent: { true })
        feed.emit(96000)             // starts a correction (queued, not yet run)
        feed.emit(192000)            // arrives while it is busy: pending
        if playNext {
            _ = r.player.play(playlist: persistentIDQueueSource, position: b.index, command: .next, isCurrent: { true })
        }
        while !closures.isEmpty && closures.count < 5 {          // run what is queued, in order
            let next = closures.removeFirst()
            next()
            if closures.isEmpty { break }
        }
        return (r.wire.requests.filter { $0["op"] as? String == sourceConfirmRateOp }.map { $0["delivered_hz"] as? Int },
                closures.count)
    }

    func testAPendingReportRunsForTheSameSongOnceTheCorrectionEnds() throws {
        let run = try pendingRun(playNext: false)
        XCTAssertTrue(run.confirmed.contains(192000), "the report that waited was lost: \(run.confirmed)")
    }

    func testAPendingReportIsDroppedWhenAnotherSongStartedMeanwhile() throws {
        let run = try pendingRun(playNext: true)
        XCTAssertFalse(run.confirmed.contains(192000), "a pending report of the old song was applied to the new one: \(run.confirmed)")
    }

    /// A newer command (the fence moved) owns the player: the late report writes nothing.
    func testAReportAfterANewerCommandWritesNothing() throws {
        let (r, _, dacHz) = try decoderRun(expect: .superseded, reports: { feed, r in
            _ = try? r.fence.begin(.next, owner: "someone-else")
            feed.emit(96000)
        })
        XCTAssertEqual(rateWrites(r), 0)
        XCTAssertEqual(r.music.count("pause"), 0)
        XCTAssertEqual(dacHz(), 48000)
    }

    func testTheRunnerAdvancesOnlyWhenTheSongEndedNotWhenItIsPausedOrStillPlaying() throws {
        let r = rig()
        let store = queueStore(ids)
        // Song 1: playing, then a long pause (the person's), then playing near
        // the end, then stopped. Nothing advances before the stop.
        r.sim.script["1.1"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 10, duration: 200)
        r.sim.script["1.2"] = RunQueuePlayback(state: .paused, persistentID: ids[0], position: 11, duration: 200)
        r.sim.script["1.3"] = RunQueuePlayback(state: .paused, persistentID: ids[0], position: 11, duration: 200)
        r.sim.script["1.4"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 199, duration: 200)
        r.sim.script["1.5"] = RunQueuePlayback(state: .stopped, persistentID: ids[0], position: 0, duration: 200)
        var playsAtPause: [Int] = []
        let runner = r.runner(store, onSleep: { playsAtPause.append(r.music.count("play")) })
        XCTAssertEqual(runner.run(), .finished)
        XCTAssertEqual(r.music.played, ids)
        XCTAssertEqual(Array(playsAtPause.prefix(5)), [1, 1, 1, 1, 1], "song 2 started before song 1 ended")
    }

    /// The TUI's twin of the repeat-all loop (live check 2026-11-16): Music's song
    /// repeat "all" loops the one-track context, so no stop comes. The same song
    /// wrapping from near its end to its start, with repeat "all", ends the wait.
    private func wrapRun(repeatMode: RepeatMode?) throws -> (exit: RunQueueExit, plays: [Int], played: [String]) {
        let r = rig()
        r.sim.repeatMode = repeatMode
        let store = queueStore(ids)
        r.sim.script["1.1"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 10, duration: 200)
        r.sim.script["1.2"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 199, duration: 200)
        r.sim.script["1.3"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 1, duration: 200)   // the wrap
        r.sim.script["1.4"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 100, duration: 200)
        r.sim.script["1.5"] = RunQueuePlayback(state: .playing, persistentID: ids[0], position: 199, duration: 200)
        r.sim.script["1.6"] = RunQueuePlayback(state: .stopped, persistentID: ids[0], position: 0, duration: 200)
        var playsAtPoll: [Int] = []
        let exit = r.runner(store, onSleep: { playsAtPoll.append(r.music.count("play")) }).run()
        return (exit, playsAtPoll, r.music.played)
    }

    func testARepeatAllWrapEndsTheWaitAndTheRunnerAdvances() throws {
        let run = try wrapRun(repeatMode: .all)
        XCTAssertEqual(run.exit, .finished)
        XCTAssertEqual(run.played, ids)
        XCTAssertEqual(Array(run.plays.prefix(4)), [1, 1, 1, 2], "song 2 started at the wrap, not at a stop that never comes")
    }

    func testARepeatOneWrapIsLeftToLoopAndSoIsAnUnreadableOrOffSetting() throws {
        for mode in [RepeatMode.one, .off, nil] {
            let run = try wrapRun(repeatMode: mode)
            XCTAssertEqual(Array(run.plays.prefix(6)), [1, 1, 1, 1, 1, 1], "\(String(describing: mode)): advanced past a loop")
            XCTAssertEqual(run.played, ids, "\(String(describing: mode)): the queue still ends at the real stop")
        }
    }

    func testTheRunnerRetriesAFailedPlayThenSkipsIt() throws {
        let r = rig()
        let store = queueStore(Array(ids.prefix(2)))
        r.music.playError = ActionError(message: "no")
        // Music's own failure: three tries on song 1, then it is skipped, three
        // tries on song 2, then the queue is over. Nothing ever played.
        XCTAssertEqual(r.runner(store).run(), .finished)
        XCTAssertEqual(r.music.count("play"), 6)
        XCTAssertEqual(r.music.played, [])
    }

    func testABusyLockStartsNothingAndTheRunnerGivesUp() throws {
        let dir = OutputLockTestSupport.tempDir()
        var ticks = 0.0
        let waiter = OutputLock(path: dir + "/output.lock", pollInterval: 0.001,
                                clock: { ticks += 40; return Date(timeIntervalSince1970: ticks) }, pause: { _ in })
        let held = OutputLock(path: dir + "/output.lock", pollInterval: 0.001)
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? held.withLock { acquired.signal(); release.wait() } }
        acquired.wait()
        defer { release.signal() }
        let r = rig(dir)
        let busy = MacRoutePlayer(streamWait: .instant, route: r.route, outputIsMusicApp: { true }, fence: RateFence(lock: waiter),
                                  owner: "runner", makeMusic: { _ in r.music },
                                  resolvePersistentID: { _, _ in nil },
                                  makeFollow: { _ in fatalError("rate follow built with the lock busy") }, post: { _ in })
        let runner = RunQueueRunner(queue: queueStore(ids), player: busy, route: r.route, routeStillChosen: { true },
                                    watcher: r.sim, sleep: { _ in }, maxNotStarted: 3)
        XCTAssertEqual(runner.run(), .couldNotStart)
        XCTAssertEqual(r.music.count("play"), 0)
    }

    // MARK: the lease, both ways

    /// A newer play from the TUI takes the lease while the runner waits on a
    /// song: the runner plays nothing more, leaves the queue alone and ends.
    func testTheTUIOverTheRunnerEndsTheRunnerBetweenSongs() throws {
        let r = rig()
        let tui = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        let store = queueStore(ids)
        var polls = 0
        let runner = r.runner(store, onSleep: {
            polls += 1
            if polls == 2 { _ = try? tui.begin(.play, owner: "tui") }
        })
        XCTAssertEqual(runner.run(), .superseded)
        XCTAssertEqual(r.music.played, [ids[0]], "the runner played nothing after the TUI's play")
        XCTAssertEqual(store.read()?.currentIndex, 1, "and left its queue where it was")
        XCTAssertEqual(r.player.fence.leaseStatus(owner: r.player.owner), .another)
    }

    /// The TUI's play lands between the runner's prepare and its play: the
    /// runner's transition is invalidated and plays nothing at all.
    func testTheTUIOverTheRunnerInvalidatesATransitionInFlight() throws {
        let r = rig()
        let tui = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { _ = try tui.begin(.play, owner: "tui") }
            return try base(body)
        }
        XCTAssertEqual(r.runner(queueStore(ids)).run(), .superseded)
        XCTAssertEqual(r.music.count("play"), 0)
        XCTAssertEqual(r.transitions, [.invalidated])
    }

    /// The runner's play supersedes a TUI that held the lease: the TUI's player
    /// is told it may not advance, and a TUI transition that was in flight when
    /// the runner's play came plays nothing.
    func testTheRunnerOverTheTUITakesTheLeaseAndTheTUIStopsAdvancing() throws {
        let dir = OutputLockTestSupport.tempDir()
        let tui = rig(dir, owner: "tui")
        let queue = AppQueue(playlistName: "Mixtape",
                             tracks: (1...3).map { TrackListEntry(index: $0, name: "S\($0)", artist: "A", isCurrent: false) },
                             currentIndex: 1)
        XCTAssertEqual(tui.player.play(playlist: "Mixtape", position: 1, command: .play, isCurrent: { true }), .played)
        XCTAssertTrue(tui.player.mayAdvance(from: queue), "the TUI holds the lease")

        let r = rig(dir)
        XCTAssertEqual(r.runner(queueStore(Array(ids.prefix(1)))).run(), .finished)
        XCTAssertFalse(tui.player.mayAdvance(from: queue), "the runner's play took the lease")
        XCTAssertEqual(tui.player.fence.leaseStatus(owner: tui.player.owner), .another)

        // A TUI transition in flight while the runner plays is invalidated.
        let r2 = rig(dir)
        let runnerFence = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let base = tui.wire.script
        tui.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { _ = try runnerFence.begin(.play, owner: "runner-2") }
            return try base(body)
        }
        let before = tui.music.count("play")
        XCTAssertEqual(tui.player.play(playlist: "Mixtape", position: 2, command: .advance, isCurrent: { true }),
                       .superseded)
        XCTAssertEqual(tui.music.count("play"), before)
        _ = r2
    }

    /// Two runners: the newer play wins and the older one ends, in either
    /// order of starting.
    func testANewerRunnerSupersedesAnOlderRunner() throws {
        let dir = OutputLockTestSupport.tempDir()
        let older = rig(dir, owner: "runner-old")
        let newer = rig(dir, owner: "runner-new")
        var polls = 0
        let store = queueStore(ids)
        let olderRunner = older.runner(store, onSleep: {
            polls += 1
            // The newer play starts while the older one waits on song 1.
            if polls == 1 { _ = newer.runner(self.queueStore([self.ids[2]])).run() }
        })
        XCTAssertEqual(olderRunner.run(), .superseded)
        XCTAssertEqual(older.music.played, [ids[0]])
        XCTAssertEqual(newer.music.played, [ids[2]])
    }

    // MARK: how it ends

    func testTheRunnerEndsWhenTheRouteIsLeftAndPlaysNothingMore() throws {
        let r = rig()
        var polls = 0
        let runner = r.runner(queueStore(ids), onSleep: { polls += 1; if polls == 1 { r.chosen = false } })
        XCTAssertEqual(runner.run(), .routeLeft)
        XCTAssertEqual(r.music.played, [ids[0]], "the song playing finishes; nothing after it")
        // Off from the start: nothing plays at all.
        let r2 = rig()
        r2.chosen = false
        XCTAssertEqual(r2.runner(queueStore(ids)).run(), .routeLeft)
        XCTAssertEqual(r2.music.count("play"), 0)
    }

    func testTheRunnerLeavesTheQueueAloneWhenMusicIsNotItsOwnOrStoppedEarlyOrGone() throws {
        // Another song is current: the person (or another command) took Music.
        do {
            let r = rig()
            r.sim.script["1.2"] = RunQueuePlayback(state: .playing, persistentID: "FFFFFFFFFFFFFFFF", position: 5, duration: 90)
            XCTAssertEqual(r.runner(queueStore(ids)).run(), .takenOver)
            XCTAssertEqual(r.music.played, [ids[0]])
        }
        // Stopped well before the end: the person pressed stop.
        do {
            let r = rig()
            r.sim.script["1.2"] = RunQueuePlayback(state: .stopped, persistentID: ids[0], position: 0, duration: 200)
            XCTAssertEqual(r.runner(queueStore(ids)).run(), .stoppedEarly)
            XCTAssertEqual(r.music.played, [ids[0]])
        }
        // Never started: stopped for the whole grace.
        do {
            let r = rig()
            for poll in 1...3 {
                r.sim.script["1.\(poll)"] = RunQueuePlayback(state: .stopped, persistentID: nil, position: 0, duration: 0)
            }
            XCTAssertEqual(r.runner(queueStore(ids)).run(), .stoppedEarly)
        }
        // Music quit: it is not launched.
        do {
            let r = rig()
            r.sim.running = false
            XCTAssertEqual(r.runner(queueStore(ids)).run(), .musicUnavailable)
            XCTAssertEqual(r.music.played, [ids[0]])
        }
        // Unreadable for too long.
        do {
            let r = rig()
            for poll in 1...3 { r.sim.script["1.\(poll)"] = .some(nil) }
            XCTAssertEqual(r.runner(queueStore(ids)).run(), .musicUnavailable)
        }
    }

    /// One song waited for longer than the lifetime bound ends the runner rather
    /// than leaving it for ever behind a paused song.
    func testAPausedSongIsWaitedForAndNotForEver() throws {
        let r = rig()
        r.sim.live = true
        r.music.state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        let first = ids[0]
        let runner = r.runner(queueStore(ids), maxLifetime: 20, onSleep: {
            if r.music.state.state == .playing { r.music.state = RatePlayerState(state: .paused, persistentID: first, position: 12) }
        })
        XCTAssertEqual(runner.run(), .timedOut)
        XCTAssertEqual(r.music.played, [ids[0]])
    }

    // MARK: never a follower pause

    /// A correction that ran past its window left the runner's own pause. However
    /// the runner ends, it releases that pause (and only it).
    func testTheRunnerNeverLeavesAFollowerPause() throws {
        let r = rig()
        r.wire.script = settlingScript(confirm: "correct")
        r.music.current = nil
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp, body["step"] as? Int == 2 { r.clock.t += 5 }   // too slow to resume
            return try base(body)
        }
        r.sim.live = true
        // Song 1 plays, the correction pauses it and cannot resume; the runner
        // keeps watching the pause until its lifetime bound.
        let runner = r.runner(queueStore(ids), maxLifetime: 30)
        XCTAssertEqual(runner.run(), .timedOut)
        XCTAssertEqual(r.music.count("pause"), 1, "the correction should have paused the song")
        XCTAssertEqual(r.music.count("resume"), 1, "the runner left the follower's pause when it ended")
        XCTAssertEqual(r.music.state.state, .playing)
    }

    /// A pause that is no longer ours (a command moved the fence since) is not
    /// resumed by the runner's exit.
    func testTheRunnerExitResumesNothingThatIsNotItsOwnPause() throws {
        let r = rig()
        let tui = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        let base = settlingScript(confirm: "correct")
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp, body["step"] as? Int == 2 { r.clock.t += 5 }
            return try base(body)
        }
        r.music.current = nil
        r.sim.live = true
        var polls = 0
        let runner = r.runner(queueStore(ids), onSleep: {
            polls += 1
            if polls == 2 { _ = try? tui.begin(.pause, owner: "tui") }   // the person pauses in the TUI
        })
        XCTAssertEqual(runner.run(), .superseded)
        XCTAssertEqual(r.music.count("resume"), 0, "the runner resumed over a newer command's pause")
        XCTAssertEqual(r.music.state.state, .paused)
    }

    // MARK: fix round 1, finding 3: the ordering is reserved by the parent

    /// The parent took the fence and the lease for the runner's owner id before it
    /// released the lock and spawned the child. A newer command that gets in
    /// during the spawn takes the fence: the child revalidates its token before
    /// its first play, finds it stale, and plays NOTHING.
    func testARunnerWhoseReservedTokenWasOvertakenInTheSpawnGapPlaysNothing() throws {
        let dir = OutputLockTestSupport.tempDir()
        let r = rig(dir, owner: "runner-child")
        let parent = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let reserved = try parent.begin(.play, owner: "runner-child")          // under the parent's lock
        let newer = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        _ = try newer.begin(.play, owner: "tui")                               // the gap
        let runner = r.runner(queueStore(ids), firstToken: reserved)
        XCTAssertEqual(runner.run(), .superseded)
        XCTAssertEqual(r.music.played, [], "the delayed child overtook a newer command")
        XCTAssertEqual(try r.fence.current(), reserved.fence + 1, "the child moved the fence over the newer command")
        XCTAssertEqual(r.fence.leaseStatus(owner: "runner-child"), .another)
    }

    /// With nothing in the gap, the reserved token is the first play's own: the
    /// child does not move the fence again before its first song.
    func testARunnerUsesItsReservedTokenForTheFirstPlayOnly() throws {
        let dir = OutputLockTestSupport.tempDir()
        let r = rig(dir, owner: "runner-child")
        let parent = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let reserved = try parent.begin(.play, owner: "runner-child")
        XCTAssertEqual(r.runner(queueStore(ids), firstToken: reserved).run(), .finished)
        XCTAssertEqual(r.music.played, ids)
        let fences = r.transitions.compactMap { result -> Int? in
            if case .played(let p) = result { return p.token.fence } else { return nil }
        }
        XCTAssertEqual(fences, [reserved.fence, reserved.fence + 1, reserved.fence + 2],
                       "first song under the parent's token, each later song under its own")
    }

    func testTheRunnerArgumentsCarryTheReservationBeforeTheQueue() throws {
        let uuid = UUID().uuidString
        let args = try runQueueArguments(label: "-Mix", uuid: uuid, ids: ids,
                                         reservation: RunQueueReservation(fence: 4, owner: "123-ABCD1234"))
        XCTAssertEqual(args, ["__run-queue", uuid, "--label=-Mix", "--fence", "4", "--owner", "123-ABCD1234",
                              "--ids", ids.joined(separator: ",")])
        let parsed = try RunQueue.parse(Array(args.dropFirst()))
        XCTAssertEqual(parsed.reservation, RunQueueReservation(fence: 4, owner: "123-ABCD1234"))
        XCTAssertNil(try RunQueue.parse([uuid, "--ids", ids[0]]).reservation, "no reservation: the child takes its own")
        // Half a reservation, or an owner that is not a plain id, is no reservation.
        XCTAssertNil(try RunQueue.parse([uuid, "--fence", "4", "--ids", ids[0]]).reservation)
        XCTAssertNil(try RunQueue.parse([uuid, "--fence", "4", "--owner", "../x y", "--ids", ids[0]]).reservation)
        XCTAssertNil(try RunQueue.parse([uuid, "--fence", "0", "--owner", "a-1", "--ids", ids[0]]).reservation)
    }

    // MARK: fix round 1, finding 8: the runner tells the Mac screen the truth

    /// The runner's queue entries have no names, so the title, artist and album
    /// come from Music itself (its own read); a pause and the end are reported as
    /// the poller reports them, and quitting says "none".
    func testTheRunnerReportsTheRealSongItsPauseAndItsEndToTheMacScreen() throws {
        let r = rig(withReporter: true)
        func look(_ state: RunQueuePlayback.State, _ position: TimeInterval) -> RunQueuePlayback {
            RunQueuePlayback(state: state, persistentID: ids[0], position: position, duration: 200,
                             title: "Aja", artist: "Steely Dan", album: "Aja")
        }
        r.sim.script["1.1"] = look(.playing, 10)
        r.sim.script["1.2"] = look(.paused, 11)
        r.sim.script["1.3"] = look(.playing, 11)
        r.sim.script["1.4"] = look(.playing, 199)
        r.sim.script["1.5"] = RunQueuePlayback(state: .stopped, persistentID: ids[0], position: 0, duration: 200)
        XCTAssertEqual(r.runner(queueStore([ids[0]])).run(), .finished)
        let reports = r.wire.requests.filter { $0["op"] as? String == sourceNowPlayingOp }
        XCTAssertTrue(reports.contains { $0["title"] as? String == "Aja" && $0["artist"] as? String == "Steely Dan"
                                         && $0["state"] as? String == "playing"
                                         && $0["persistent_id"] as? String == ids[0] },
                      "the report never carried the real song: \(reports)")
        XCTAssertTrue(reports.contains { $0["state"] as? String == "paused" && $0["title"] as? String == "Aja" },
                      "a pause in Music was not reported")
        XCTAssertEqual(reports.suffix(2).map { $0["state"] as? String }, ["stopped", "none"],
                       "the end, then the screen goes idle as the runner quits")
    }

    // MARK: the launch and the arguments

    private func tempDir() -> String { OutputLockTestSupport.tempDir() }

    func testTheRunnerArgumentsCarryTheQueueInOrderInlineOrThroughAnOrderedManifest() throws {
        let uuid = UUID().uuidString
        let small = try runQueueArguments(label: "-Mix", uuid: uuid, ids: ids)
        XCTAssertEqual(small, ["__run-queue", uuid, "--label=-Mix", "--ids", ids.joined(separator: ",")])
        XCTAssertEqual(resolveRunQueueIDs(idsOption: small.last, manifestPath: nil), ids)

        let dir = tempDir()
        let many = (0..<(albumWatcherInlineIDLimit + 5)).map { String(format: "%016llX", UInt64($0 + 1)) }
        let big = try runQueueArguments(label: "L", uuid: uuid, ids: many, manifestDirectory: dir)
        guard let at = big.firstIndex(of: "--manifest") else { return XCTFail("\(big)") }
        let path = big[at + 1]
        XCTAssertEqual(path, runQueueManifestPath(uuid: uuid, directory: dir))
        XCTAssertTrue(path.hasPrefix(dir))
        XCTAssertEqual(resolveRunQueueIDs(idsOption: nil, manifestPath: path), many, "the manifest keeps the play order")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAFailedSpawnRemovesTheManifestItWrote() throws {
        let dir = tempDir()
        let uuid = UUID().uuidString
        let many = (0..<(albumWatcherInlineIDLimit + 1)).map { String(format: "%016llX", UInt64($0 + 1)) }
        var seen: [[String]] = []
        XCTAssertFalse(spawnRunQueue(label: "L", uuid: uuid, ids: many, manifestDirectory: dir,
                                     launch: { _, args in seen.append(args); return false }))
        let path = try XCTUnwrap(runQueueManifestPath(uuid: uuid, directory: dir))
        XCTAssertEqual(seen.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nobody will ever own this file")
    }

    func testTheRunnerRefusesAnythingThatIsNotAUUIDOrAValidQueue() {
        XCTAssertNil(runQueueManifestPath(uuid: "../../etc/passwd"))
        XCTAssertNil(runQueueManifestPath(uuid: "not-a-uuid"))
        XCTAssertNotNil(runQueueManifestPath(uuid: UUID().uuidString))
        XCTAssertNil(resolveRunQueueIDs(idsOption: "", manifestPath: nil))
        XCTAssertNil(resolveRunQueueIDs(idsOption: "XYZ", manifestPath: nil))
        XCTAssertNil(resolveRunQueueIDs(idsOption: ids[0] + ",nope", manifestPath: nil))
        XCTAssertNil(runQueueAppQueue(ids: [], label: "x"))
        let q = runQueueAppQueue(ids: ids, label: "Mixtape")
        XCTAssertEqual(q?.playlistName, persistentIDQueueSource)
        XCTAssertEqual(q?.tracks.map { persistentIDOfQueueEntry($0.index) }, ids)
        XCTAssertEqual(q?.contextLabel, "Mixtape")
        // The command parses the way the launcher builds it.
        let uuid = UUID().uuidString
        XCTAssertNoThrow(try RunQueue.parse([uuid, "--label=-x", "--ids", ids[0]]))
    }

    // MARK: the new AppleScript text

    func testTheNewScriptIsReadOnlyAndUsesSafeVariableNames() {
        let script = RunQueueScripts.readPlayback
        for banned in ["play ", "pause", "set player position", "tell application", "delete", "make new"] {
            XCTAssertFalse(script.contains(banned), "\(banned) in: \(script)")
        }
        for banned in ["active", "left", "right", "top", "bottom", "size", "result", "state", "position", "duration"] {
            XCTAssertFalse(script.contains("set \(banned) "), "\(banned) in: \(script)")
        }
        XCTAssertTrue(script.contains("* 100"), "integer centiseconds, no locale decimal comma")
        let sep = String(asFieldSep)
        XCTAssertEqual(RunQueueScripts.parsePlayback("playing\(sep)abc123\(sep)1050\(sep)20000"),
                       RunQueuePlayback(state: .playing, persistentID: "ABC123", position: 10.5, duration: 200))
        XCTAssertEqual(RunQueueScripts.parsePlayback("stopped\(sep)\(sep)0\(sep)0"),
                       RunQueuePlayback(state: .stopped, persistentID: nil, position: 0, duration: 0))
        XCTAssertNil(RunQueueScripts.parsePlayback("fast forwarding\(sep)x\(sep)0\(sep)0"))
        XCTAssertNil(RunQueueScripts.parsePlayback("playing\(sep)x\(sep)abc\(sep)0"))
        XCTAssertNil(RunQueueScripts.parsePlayback("garbage"))
    }

    /// The read now also carries the song's own words (finding 8); the four-field
    /// shape is still read, and an empty name is no name.
    func testThePlaybackReadCarriesTheSongsOwnWords() {
        let sep = String(asFieldSep)
        XCTAssertEqual(RunQueueScripts.parsePlayback("paused\(sep)abc123\(sep)1050\(sep)20000\(sep)Aja\(sep)Steely Dan\(sep)Aja (Remaster)"),
                       RunQueuePlayback(state: .paused, persistentID: "ABC123", position: 10.5, duration: 200,
                                        title: "Aja", artist: "Steely Dan", album: "Aja (Remaster)"))
        XCTAssertEqual(RunQueueScripts.parsePlayback("playing\(sep)abc123\(sep)1050\(sep)20000\(sep)\(sep)\(sep)")?.title, nil)
        XCTAssertTrue(RunQueueScripts.readPlayback.contains("name of current track"))
    }

    // MARK: the CLI's play

    private let a1 = "596357614188841472", h1 = "0846B01728D34A00"
    private let a2 = "-2898457328848859944", h2 = "D7C69C6A85560CD8"

    private func songRows() -> [MusicRow] {
        [MusicRow(id: "l.1", title: "Angel", artist: "Massive Attack", album: "Mezzanine", kind: .song, alias: a1),
         MusicRow(id: "l.2", title: "Risingson", artist: "Massive Attack", album: "Mezzanine", kind: .song, alias: a2)]
    }

    private func library() -> FakePersistentIDLibrary {
        FakePersistentIDLibrary([
            h1: [HandoffTrackHit(persistentID: h1, inLibrary: true, databaseID: "101", libraryIndex: 11, name: "Angel")],
            h2: [HandoffTrackHit(persistentID: h2, inLibrary: true, databaseID: "102", libraryIndex: 12, name: "Risingson")],
        ])
    }

    private func request(_ h: CLIDataRouteHarness, shuffle: Bool = false, json: Bool = false)
        -> CLIMusicTUILibraryPlayRequest {
        CLIMusicTUILibraryPlayRequest(kind: .album, label: "Mezzanine", rows: songRows(), startAt: 1, shuffle: shuffle,
                                      resultNumber: nil, json: json, selectionAtRead: h.env.routing.selection)
    }

    private func tripwired(_ body: () throws -> Void) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire { do { try body() } catch { thrown = error } }.calls
        return (thrown, calls)
    }

    /// On the route a CLI play launches `__run-queue` with the verified songs in
    /// play order, builds no temporary playlist, sweeps nothing, runs no
    /// AppleScript, and says what it started.
    func testOnTheRouteACLIPlayLaunchesTheRunnerAndBuildsNoTemporaryPlaylist() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        let lib = library()
        let container = CLIContainerRunner(ids: [h1, h2])
        var launched: [(String, [String])] = []
        var shown: [Bool] = []
        let play = PersistentIDCLILibraryPlay(library: lib, run: container.run,
                                              launch: { launched.append(($0, $1)); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { shown.append($0) })
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [], "no real AppleScript, REST or launch")
        XCTAssertEqual(launched.count, 1)
        let args = try XCTUnwrap(launched.first?.1)
        XCTAssertEqual(args.first, "__run-queue")
        XCTAssertEqual(args.last, [h1, h2].joined(separator: ","), "the verified songs, in play order")
        XCTAssertTrue(args.contains("--label=Mezzanine"))
        XCTAssertFalse(args.contains("__watch-container"))
        XCTAssertEqual(container.scripts, [], "no stale sweep, no container built, nothing played by Music")
        XCTAssertEqual(container.builds, [])
        XCTAssertEqual(container.plays, [])
        XCTAssertEqual(shown, [], "the shipped now line waits for a song Music has not been given yet")
        XCTAssertEqual(h.io.out, ["Playing \"Mezzanine\" (2 songs), following each song's sample rate."])
        XCTAssertEqual(lib.reads, [[h1, h2]], "still every song verified by persistent ID first")
    }

    /// Fix round 1, finding 3: the parent moves the fence and takes the lease for
    /// the runner's owner id BEFORE the child is spawned, and hands the token on.
    func testOnTheRouteTheParentReservesTheFenceAndTheLeaseForTheRunnerBeforeItSpawns() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        let fence = RateFence(store: h.env.modeStore)
        var atSpawn: (fence: Int, lease: String?)?
        var launched: [String] = []
        let play = PersistentIDCLILibraryPlay(library: library(), run: { _ in "" },
                                              launch: { _, args in
                                                  launched = args
                                                  atSpawn = (try! fence.current(), try! fence.lock.withLock { try fence.readLeaseHoldingLock() })
                                                  return true
                                              },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertNil(r.error)
        let fenceArg = try XCTUnwrap(launched.firstIndex(of: "--fence").map { launched[$0 + 1] }.flatMap(Int.init))
        let ownerArg = try XCTUnwrap(launched.firstIndex(of: "--owner").map { launched[$0 + 1] })
        XCTAssertEqual(atSpawn?.fence, fenceArg, "the fence had already moved when the child was spawned")
        XCTAssertEqual(atSpawn?.lease, ownerArg, "the lease was already the runner's when the child was spawned")
        XCTAssertGreaterThanOrEqual(fenceArg, 1)
        XCTAssertEqual(launched.last, [h1, h2].joined(separator: ","), "the queue stays the last argument")
    }

    /// Music's own shuffle setting on, no `shuffle` word: on the route the runner
    /// plays one song at a time, so Music never shuffles; the CLI must. Off the
    /// route Music shuffles inside the temporary playlist, as it always has.
    func testOnTheRouteMusicsShuffleSettingShufflesAPlayWithoutTheWord() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        var launched: [[String]] = []
        var asked = 0
        var play = PersistentIDCLILibraryPlay(library: library(), run: { _ in XCTFail("AppleScript on the route"); return "" },
                                              launch: { launched.append($1); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
        play.musicShuffle = { asked += 1; return .songs }
        play.shuffleIDs = { Array($0.reversed()) }
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.calls, [])
        XCTAssertEqual(asked, 1, "Music's setting is read once, on the route")
        XCTAssertEqual(launched.first?.last, [h2, h1].joined(separator: ","), "the runner gets the shuffled order")
    }

    func testOnTheRouteMusicsShuffleSettingOffKeepsTheContainersOrder() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        var launched: [[String]] = []
        var play = PersistentIDCLILibraryPlay(library: library(), run: { _ in XCTFail("AppleScript on the route"); return "" },
                                              launch: { launched.append($1); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
        play.musicShuffle = { nil }
        play.shuffleIDs = { _ in XCTFail("shuffled with Music's shuffle off"); return [] }
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertNil(r.error)
        XCTAssertEqual(launched.first?.last, [h1, h2].joined(separator: ","))
    }

    /// Song and album shuffle are imitated; grouping, off, or a failed or
    /// unreadable read is no shuffle on the route. "true,albums,all" is what
    /// the Studio's Music read on 2026-11-21.
    func testTheRouteImitatesSongAndAlbumShuffleOnly() {
        XCTAssertEqual(macRouteShuffleMode("true,songs,off"), .songs)
        XCTAssertEqual(macRouteShuffleMode(" true, songs, all\n"), .songs)
        XCTAssertEqual(macRouteShuffleMode("true,albums,all"), .albums)
        XCTAssertNil(macRouteShuffleMode("true,groupings,off"))
        XCTAssertNil(macRouteShuffleMode("false,songs,off"))
        XCTAssertNil(macRouteShuffleMode(nil))
        XCTAssertNil(macRouteShuffleMode(""))
        XCTAssertNil(macRouteShuffleMode("true,songs"))
    }

    /// Album shuffle: albums reordered, each album's songs kept in playlist
    /// order, an album's songs kept together even when the playlist splits them,
    /// songs with no album each their own group.
    func testAlbumShuffleReordersAlbumsAndKeepsEachAlbumsSongsInOrder() {
        let tracks: [(id: String, album: String?)] = [("a1", "A"), ("b1", "B"), ("a2", "A"), ("x", nil), ("b2", "B")]
        XCTAssertEqual(albumShuffledIDs(tracks, shuffle: { $0 }), ["a1", "a2", "b1", "b2", "x"])
        XCTAssertEqual(albumShuffledIDs(tracks, shuffle: { Array($0.reversed()) }), ["x", "b1", "b2", "a1", "a2"])
    }

    /// On the route with Music's album shuffle on, the runner gets the albums in
    /// the shuffled order.
    func testOnTheRouteMusicsAlbumShuffleOrdersTheRunnersQueueByAlbum() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        var launched: [[String]] = []
        var play = PersistentIDCLILibraryPlay(library: library(), run: { _ in XCTFail("AppleScript on the route"); return "" },
                                              launch: { launched.append($1); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
        play.musicShuffle = { .albums }
        play.shuffleIDs = { _ in XCTFail("song shuffle under album mode"); return [] }
        play.shuffleAlbums = { Array($0.reversed()) }
        XCTAssertNil(tripwired { try play.play(request(h), env: h.env) }.error)
        let queue = try XCTUnwrap(launched.first?.last)
        XCTAssertEqual(Set(queue.split(separator: ",").map(String.init)), [h1, h2], "every song, nothing added")
    }

    /// The refusal for free words names the form that plays.
    func testTheFreeWordsRefusalNamesThePlaylistForm() {
        XCTAssertTrue(playWordsNeedAKind.contains("music play --playlist \"<name>\""))
        XCTAssertTrue(playWordsNeedAKind.contains("shuffle"))
        XCTAssertNotEqual(playWordsNeedAKind, pickASpanDACOutput)
    }

    /// The typed word already shuffles; Music's setting is not read, and off the
    /// route it is never read at all (Music applies it inside the container).
    func testMusicsShuffleSettingIsReadOnlyOnTheRouteAndOnlyWithoutTheWord() throws {
        do {
            let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
            MacRouteStore(beside: h.env.modeStore).set(true)
            var play = PersistentIDCLILibraryPlay(library: library(), run: { _ in "" },
                                                  launch: { _, _ in true },
                                                  selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
            play.musicShuffle = { XCTFail("read with the shuffle word typed"); return nil }
            XCTAssertNil(tripwired { try play.play(request(h, shuffle: true), env: h.env) }.error)
        }
        do {
            let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
            let container = CLIContainerRunner(ids: [h1, h2])
            var play = PersistentIDCLILibraryPlay(library: library(), run: container.run,
                                                  launch: { _, _ in true },
                                                  selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in })
            play.musicShuffle = { XCTFail("read off the route"); return .songs }
            XCTAssertNil(tripwired { try play.play(request(h), env: h.env) }.error)
        }
    }

    func testOnTheRouteAShuffledPlayHandsTheRunnerTheShuffledOrderAndJSONStaysOneDocument() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        var launched: [[String]] = []
        let play = PersistentIDCLILibraryPlay(library: library(), run: { _ in XCTFail("AppleScript on the route"); return "" },
                                              launch: { launched.append($1); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in XCTFail("now line") })
        let r = tripwired { try play.play(request(h, shuffle: true, json: true), env: h.env) }
        XCTAssertNil(r.error)
        let ids = Set(try XCTUnwrap(launched.first?.last).split(separator: ",").map(String.init))
        XCTAssertEqual(ids, [h1, h2])
        XCTAssertEqual(h.io.out.count, 1)
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(h.io.out.first).utf8)) as? [String: Any])
        XCTAssertEqual(doc["queue"] as? String, "Mezzanine")
        XCTAssertEqual(doc["tracks"] as? Int, 2)
    }

    /// A runner that cannot be started plays nothing and says so.
    func testOnTheRouteAFailedLaunchPlaysNothingAndSaysSo() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        let container = CLIContainerRunner(ids: [h1, h2])
        let play = PersistentIDCLILibraryPlay(library: library(), run: container.run, launch: { _, _ in false },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { _ in XCTFail("now line") })
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertEqual((r.error as? ActionError)?.message, macRouteRunnerNotStartedMessage)
        XCTAssertEqual(container.scripts, [])
        XCTAssertEqual(h.io.out, [])
    }

    /// Off the route (no choice, or a choice turned off) the CLI is what it was:
    /// the sweep, the temporary playlist built from exactly the verified songs,
    /// played, the container watcher launched, the now line shown.
    func testOffTheRouteTheCLIPlayIsTheShippedTemporaryPlaylist() throws {
        for turnedOff in [false, true] {
            let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
            if turnedOff {
                let store = MacRouteStore(beside: h.env.modeStore)
                store.set(true)
                store.set(false)
            }
            let container = CLIContainerRunner(ids: [h1, h2])
            var launched: [[String]] = []
            var shown: [Bool] = []
            let play = PersistentIDCLILibraryPlay(library: library(), run: container.run,
                                                  launch: { launched.append($1); return true },
                                                  selfCheck: LibraryAliasSelfCheck(), afterPlay: { shown.append($0) })
            let r = tripwired { try play.play(request(h), env: h.env) }
            XCTAssertNil(r.error)
            XCTAssertEqual(container.builds, [[11, 12]], "the container is built from the verified songs")
            XCTAssertEqual(container.plays.count, 1)
            XCTAssertEqual(container.scripts.first, albumStaleSweepScript())
            XCTAssertEqual(launched.count, 1)
            XCTAssertEqual(launched.first?.first, "__watch-container", "the shipped cleanup watcher, not a runner")
            XCTAssertEqual(shown, [false])
            XCTAssertFalse(h.io.out.contains { $0.hasPrefix("Playing \"") })
        }
    }

    /// Fix round 2, finding 3: with the ordering impossible to reserve, no runner
    /// is spawned without one. The songs play through the shipped path, and the
    /// line says they are not followed.
    func testOnTheRouteWhenTheOrderingCannotBeReservedTheSongsStillPlayThroughTheShippedPath() throws {
        let h = CLIDataRouteHarness(output: .musicApp, data: .accepted, dataReplies: [:], recordSeams: false)
        MacRouteStore(beside: h.env.modeStore).set(true)
        let fence = RateFence(store: h.env.modeStore)
        try FileManager.default.createDirectory(atPath: fence.fencePath, withIntermediateDirectories: true)
        let container = CLIContainerRunner(ids: [h1, h2])
        var launched: [[String]] = []
        var shown: [Bool] = []
        let play = PersistentIDCLILibraryPlay(library: library(), run: container.run,
                                              launch: { launched.append($1); return true },
                                              selfCheck: LibraryAliasSelfCheck(), afterPlay: { shown.append($0) })
        let r = tripwired { try play.play(request(h), env: h.env) }
        XCTAssertNil(r.error, "the song was refused")
        XCTAssertFalse(launched.contains { $0.first == "__run-queue" }, "a token-less runner was spawned")
        XCTAssertEqual(launched.first?.first, "__watch-container")
        XCTAssertEqual(container.builds, [[11, 12]])
        XCTAssertEqual(container.plays.count, 1)
        XCTAssertEqual(shown, [false])
        XCTAssertTrue(h.io.out.contains(macRouteRateNotFollowedLine), "the line says the rate is not followed")
    }
}

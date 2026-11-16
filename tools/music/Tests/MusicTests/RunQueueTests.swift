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
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        func playTrack(persistentID: String) throws {
            log.append("play")
            if let playError { throw playError }
            played.append(persistentID)
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 0)
            current = RateTrackRead(persistentID: persistentID, databaseID: 1, sampleRateHz: 96000)
        }
        func pause() throws {
            log.append("pause")
            state = RatePlayerState(state: .paused, persistentID: state.persistentID, position: 12)
        }
        func resume() throws {
            log.append("resume")
            state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position)
        }
        func seekToStart() throws { log.append("seek0") }
        func readCurrentTrack() -> RateTrackRead? { current }
        func readPlayerState() -> RatePlayerState? { state }
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

        init(dir: String, owner: String, makeControl: (Wire) -> SourceAppControl) {
            self.dir = dir
            wire = Wire(clock)
            fence = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
            let clock = self.clock, music = self.music
            let controlValue = makeControl(wire)
            player = MacRoutePlayer(
                route: route, outputIsMusicApp: { true }, fence: fence, owner: owner,
                makeMusic: { _ in music },
                resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
                makeFollow: { token in
                    SourceRateFollow(token: token, control: controlValue, offered: true,
                                     now: { clock.t }, sleep: { clock.t += $0 })
                },
                post: { _ in },
                now: { clock.t })
            player.onTransition = { [unowned self] in self.transitions.append($0) }
        }

        func runner(_ queue: AppQueueStore, maxLifetime: TimeInterval = 10_000,
                    onSleep: @escaping () -> Void = {}) -> RunQueueRunner {
            let clock = self.clock
            return RunQueueRunner(queue: queue, player: player, route: route,
                                  routeStillChosen: { [unowned self] in self.chosen }, watcher: sim,
                                  sleep: { clock.t += $0; onSleep() }, now: { clock.t },
                                  pollInterval: 1, startGracePolls: 3, maxUnreadablePolls: 3, maxNotStarted: 3,
                                  maxLifetime: maxLifetime)
        }
    }

    private func rig(_ dir: String? = nil, owner: String = "runner") -> Rig {
        let holder = Rig(dir: dir ?? OutputLockTestSupport.tempDir(), owner: owner,
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
        let busy = MacRoutePlayer(route: r.route, outputIsMusicApp: { true }, fence: RateFence(lock: waiter),
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
}

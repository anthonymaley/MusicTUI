// tools/music/Tests/MusicTests/MacRouteWiringTests.swift
//
// The TUI's wiring of the Mac route (mac-route-plan.md sections 3.1 and 3.3,
// appendix M1 to M5; score step P4): every play on the Mac DAC route goes
// through `RateAwareTransition`, plays off the route are untouched, the poller's
// title fallback is off on the route, the play lease decides who advances, a
// broken state directory still plays the song with a line, a rate failure never
// reaches `AdvanceRetryGate`, and closing the TUI leaves no follower pause.
//
// Fakes only: the real fence files live in a temp directory; SpanDAC is a
// scripted transport with a fake clock; Music.app is `FakeMusic`; the shipped
// (off-route) path and the poller run against a fake `osascript` that records
// the scripts it is given and plays nothing. No audio, no real AppleScript, no
// socket, no keychain, and never `~/.config/music`.
import XCTest
@testable import music

final class MacRouteWiringTests: XCTestCase {

    // MARK: support

    private final class Clock {
        var t: TimeInterval = 0
    }

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

    /// Prepare settles, confirm is `own_rate`, a correction settles.
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
        var scripts: [String] = []
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        var current: RateTrackRead?
        var playError: Error?
        var playScript = ""
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        func playTrack(persistentID: String) throws {
            log.append("play")
            scripts.append(playScript)
            if let playError { throw playError }
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
        func readPlayerState() -> RatePlayerState? {
            let shown = state
            // A playing stream advances between reads (the stream-up proof).
            if state.state == .playing {
                state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position + 0.5)
            }
            return shown
        }
    }

    /// One MusicTUI process composed for the route, over a temp state directory.
    private final class Rig {
        let dir: String
        let clock = Clock()
        let wire: Wire
        let music = FakeMusic()
        let route = MacDACRouteState()
        var outputIsMusicApp = true
        var resolve: (String, Int) -> String? = { _, position in String(format: "%016llX", UInt64(position)) }
        var posts: [String] = []
        var transitions: [RateTransitionResult] = []
        let fence: RateFence
        var player: MacRoutePlayer!

        init(dir: String, owner: String, lockPath: String? = nil, makeControl: (Wire) -> SourceAppControl) {
            self.dir = dir
            wire = Wire(clock)
            fence = RateFence(lock: OutputLock(path: lockPath ?? dir + "/output.lock", pollInterval: 0.001))
            wire.script = { _ in throw SourceAppError.timedOut }
            let clock = self.clock, wire = self.wire, music = self.music
            let controlValue = makeControl(wire)
            player = MacRoutePlayer(
                streamWait: .instant, route: route, outputIsMusicApp: { [unowned self] in self.outputIsMusicApp }, fence: fence, owner: owner,
                makeMusic: { script in music.playScript = script; return music },
                resolvePersistentID: { [unowned self] in self.resolve($0, $1) },
                makeFollow: { token in
                    SourceRateFollow(token: token, control: controlValue, offered: true,
                                     now: { clock.t }, sleep: { clock.t += $0 })
                },
                post: { [unowned self] in self.posts.append($0) },
                now: { clock.t })
            player.onTransition = { [unowned self] in self.transitions.append($0) }
        }
    }

    private func rig(_ dir: String? = nil, owner: String = "tui", on: Bool = true, lockPath: String? = nil) -> Rig {
        let d = dir ?? OutputLockTestSupport.tempDir()
        let holder = Rig(dir: d, owner: owner, lockPath: lockPath, makeControl: { [unowned self] wire in self.control(wire) })
        holder.wire.script = settlingScript()
        holder.route.set(on)
        return holder
    }

    /// A fake `osascript` that records every script it is given. Plays and
    /// polls answer as a stopped player; see `pollingBackend` for the poller.
    private func recordingBackend(_ dir: String) throws -> (AppleScriptBackend, scripts: () -> [String]) {
        let fake = dir + "/osascript"
        let record = dir + "/scripts.txt"
        try "#!/bin/sh\nprintf '%s\\n--END--\\n' \"$2\" >> '\(record)'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return (AppleScriptBackend(executable: fake), {
            ((try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n--END--\n").filter { !$0.isEmpty }
        })
    }

    private func queue(_ tracks: Int = 3, current: Int = 1, source: String = "Mixtape") -> AppQueue {
        AppQueue(playlistName: source,
                 tracks: (1...tracks).map { TrackListEntry(index: $0, name: "Song \($0)", artist: "Artist", isCurrent: false) },
                 currentIndex: current)
    }

    private func storeWithRoute(_ r: Rig, queue q: AppQueue? = nil) -> AppQueueStore {
        let store = AppQueueStore()
        store.macRoute = r.player
        if let q { store.set(q) }
        return store
    }

    // MARK: every play on the route goes through the transition

    /// Every TUI play path: handoff first play, next, previous, Now's jump,
    /// shuffle (both forms), a person's pick. On the route each is one
    /// transition (the fence moved, SpanDAC was asked, Music's own play ran
    /// through the adapter); none reaches the shipped `osascript` play.
    func testEveryPlayPathOnTheRouteGoesThroughTheTransition() throws {
        let paths: [(String, (AppleScriptBackend, AppQueueStore) -> Bool)] = [
            ("handoff first play", { b, s in requestedHandoffPlayFirst(backend: b, appQueue: s)(self.queue(), HandoffPlayReport()) }),
            ("a person's pick", { b, s in playRequestedQueueTrack(backend: b, appQueue: s, playlist: "Mixtape", position: 2, title: "Song 2") }),
            ("next", { b, s in (try? musicTUISkip(1, backend: b, appQueue: s)) != nil }),
            ("previous", { b, s in s.set(self.queue(current: 2)); return (try? musicTUISkip(-1, backend: b, appQueue: s)) != nil }),
            ("jump", { b, s in
                guard let (pl, pos) = s.jump(to: 3) else { return false }
                return playRequestedQueueTrack(backend: b, appQueue: s, playlist: pl, position: pos, title: "Song 3", command: .jump)
            }),
            ("shuffle", { b, s in shufflePlayCurrent(backend: b, appQueue: s) }),
            ("bounded shuffle", { b, s in
                shufflePlayBounded(backend: b, appQueue: s, label: "L", source: "Library", tracks: self.queue().tracks)
            }),
        ]
        for (name, play) in paths {
            let r = rig()
            let (backend, scripts) = try recordingBackend(r.dir)
            let store = storeWithRoute(r, queue: queue())
            XCTAssertTrue(play(backend, store), "\(name) did not play")
            XCTAssertEqual(r.music.count("play"), 1, "\(name) did not go through the transition's Music adapter")
            XCTAssertEqual(scripts(), [], "\(name) ran the shipped script on the route")
            XCTAssertEqual(r.wire.ops.first, sourcePrepareRateOp, "\(name) did not ask SpanDAC to prepare")
            XCTAssertTrue(r.wire.ops.contains(sourceConfirmRateOp), "\(name) did not confirm")
            XCTAssertGreaterThanOrEqual(try r.fence.current(), 1, "\(name) did not move the fence")
        }
    }

    /// A play off the route is the shipped one, byte for byte: the same script,
    /// no fence, nothing sent to SpanDAC.
    func testAPlayOffTheRouteIsTheShippedPlayAndTouchesNothing() throws {
        for (name, configure) in [("route flag off", { (r: Rig) in r.route.set(false) }),
                                  ("output is not MusicTUI", { (r: Rig) in r.outputIsMusicApp = false })] {
            let r = rig()
            configure(r)
            let (backend, scripts) = try recordingBackend(r.dir)
            let store = storeWithRoute(r, queue: queue())
            XCTAssertTrue(playRequestedQueueTrack(backend: backend, appQueue: store, playlist: "Mixtape", position: 2, title: "Song 2"))
            XCTAssertEqual(scripts(), ["tell application \"Music\"\n    play track 2 of playlist \"Mixtape\"\nend tell"], name)
            XCTAssertEqual(r.music.log, [], "\(name): the transition's adapter was used")
            XCTAssertEqual(r.wire.requests.count, 0, "\(name): SpanDAC was asked")
            XCTAssertEqual(try r.fence.current(), 0, "\(name): the fence moved")
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir + "/rate.lease"), name)
        }
        // And with no route player at all (tests, the CLI), exactly as before.
        let dir = OutputLockTestSupport.tempDir()
        let (backend, scripts) = try recordingBackend(dir)
        XCTAssertTrue(playQueueEntry(backend: backend, appQueue: AppQueueStore(), playlist: "Mixtape", position: 1).accepted)
        XCTAssertEqual(scripts().count, 1)
    }

    /// The route is the Mac row AND the MusicTUI output: a network SpanDAC being
    /// the output turns it off without anyone clearing the flag.
    func testTheRouteIsOffWhenTheOutputIsNotMusicTUI() {
        let r = rig()
        XCTAssertTrue(r.player.isOnRoute)
        r.outputIsMusicApp = false
        XCTAssertFalse(r.player.isOnRoute)
        r.outputIsMusicApp = true
        r.route.set(false)
        XCTAssertFalse(r.player.isOnRoute)
    }

    /// An entry addressed by persistent ID plays by that identity and never
    /// reads one; a position entry reads its identity once; one whose identity
    /// cannot be read STILL PLAYS, with no rate work (never refuse).
    func testEntryAddressingAndAnUnreadableIdentityStillPlays() throws {
        let r = rig()
        var resolved: [String] = []
        r.resolve = { pl, pos in resolved.append("\(pl)#\(pos)"); return "00000000000000AB" }
        let id = persistentIDQueueEntry(persistentID: "0123456789ABCDEF", name: "N", artist: "A", album: nil)!
        let byID = AppQueue(playlistName: persistentIDQueueSource, tracks: [id], currentIndex: 1)
        let store = storeWithRoute(r, queue: byID)
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: persistentIDQueueSource, position: id.index), .played)
        XCTAssertEqual(resolved, [], "an identity-addressed entry read an identity")
        XCTAssertTrue(r.music.scripts[0].contains("0123456789ABCDEF"))
        XCTAssertEqual(r.wire.requests.first?["persistent_id"] as? String, "0123456789ABCDEF")

        // A position entry.
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 4), .played)
        XCTAssertEqual(resolved, ["Mixtape#4"])
        XCTAssertEqual(r.music.scripts[1], "play track 4 of playlist \"Mixtape\"")

        // Unreadable identity: plays, no prepare/confirm, the DAC awaited quiet.
        let r2 = rig()
        r2.resolve = { _, _ in nil }
        let store2 = storeWithRoute(r2, queue: queue())
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store2,
                                      playlist: "Mixtape", position: 2), .played)
        XCTAssertEqual(r2.music.count("play"), 1)
        XCTAssertFalse(r2.wire.ops.contains(sourcePrepareRateOp))
        XCTAssertFalse(r2.wire.ops.contains(sourceConfirmRateOp))
    }

    // MARK: lease and supersession

    /// A newer command from another process (the runner) between prepare and
    /// play supersedes this TUI play: nothing plays, the caller is told it was
    /// superseded (accepted, no rollback), and the confirmer is not asked.
    func testANewerOwnerSupersedesAPlayAndPlaysNothing() throws {
        let r = rig()
        let other = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { _ = try other.begin(.next, owner: "runner") }
            return try base(body)
        }
        let store = storeWithRoute(r, queue: queue())
        let outcome = playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                     playlist: "Mixtape", position: 1)
        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(outcome.accepted)
        XCTAssertEqual(r.music.count("play"), 0)
        XCTAssertEqual(r.transitions, [.invalidated])
    }

    /// The queue changing under a play (a newer command in this process stepped
    /// or replaced it) fails the revalidation the same way.
    func testTheQueueMovingUnderAPlaySupersedesIt() {
        let r = rig()
        let store = storeWithRoute(r, queue: queue())
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { _ = store.step(1) }
            return try base(body)
        }
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .superseded)
        XCTAssertEqual(r.music.count("play"), 0)
    }

    func testTheQueueGenerationMovesOnEveryMutation() {
        let s = AppQueueStore()
        var seen = [s.generation]
        s.set(queue()); seen.append(s.generation)
        _ = s.step(1); seen.append(s.generation)
        _ = s.jump(to: 3); seen.append(s.generation)
        s.clear(); seen.append(s.generation)
        XCTAssertEqual(seen, Array(Set(seen)).sorted(), "a mutation left the generation where it was: \(seen)")
        XCTAssertEqual(Set(seen).count, 5)
    }

    /// The lease, both ways: this process advances while it holds it and the
    /// queue's current entry is the one it started; the runner taking it stops
    /// it, and so does a queue that moved without it. A process that has never
    /// played on the route owns nothing to lose.
    func testAnOwnerAdvancesOnlyWhileItHoldsTheLeaseAndTheEntryIsItsOwn() throws {
        let r = rig()
        let q1 = queue(current: 1)
        XCTAssertTrue(r.player.mayAdvance(from: q1), "a process that never played on the route may advance")
        XCTAssertTrue(r.player.mayAdvance(from: nil))
        let store = storeWithRoute(r, queue: q1)
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .played)
        XCTAssertTrue(r.player.mayAdvance(from: q1), "it holds the lease and the entry is its own")
        XCTAssertFalse(r.player.mayAdvance(from: queue(current: 2)), "the queue moved without it")
        XCTAssertFalse(r.player.mayAdvance(from: nil))
        XCTAssertFalse(r.player.mayAdvance(from: queue(source: "Other")))
        // The runner takes the lease.
        let runner = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        _ = try runner.begin(.advance, owner: "runner")
        XCTAssertFalse(r.player.mayAdvance(from: q1), "the runner holds the lease")
        // The TUI plays again and takes it back.
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .played)
        XCTAssertTrue(r.player.mayAdvance(from: q1))
    }

    // MARK: never refuse a song: the state directory

    /// 2026-11-15 ruling: with the fence or lock unusable the song STILL plays,
    /// at the DAC's current rate, with no rate follow, and a line says so. It
    /// is a play for every caller (never a failure, never a skip).
    func testABrokenStateDirectoryStillPlaysTheSongWithALine() throws {
        let dir = OutputLockTestSupport.tempDir()
        FileManager.default.createFile(atPath: dir + "/blocker", contents: Data())
        let r = rig(dir, lockPath: dir + "/blocker/output.lock")
        let store = storeWithRoute(r, queue: queue())
        let outcome = playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                     playlist: "Mixtape", position: 2)
        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(r.music.count("play"), 1, "the song did not play")
        XCTAssertEqual(r.wire.requests.count, 0, "rate follow ran with no fence")
        XCTAssertEqual(r.posts, [macRouteRateNotFollowedLine])
        XCTAssertEqual(r.music.count("pause"), 0)
    }

    /// The same through the person's play, the confirmer included: the play
    /// reports true.
    func testABrokenStateDirectoryIsAPlayForThePersonsKeyToo() throws {
        let dir = OutputLockTestSupport.tempDir()
        FileManager.default.createFile(atPath: dir + "/blocker", contents: Data())
        let r = rig(dir, lockPath: dir + "/blocker/output.lock")
        let store = storeWithRoute(r, queue: queue())
        XCTAssertTrue(playRequestedQueueTrack(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                              playlist: "Mixtape", position: 2, title: "Song 2"))
        XCTAssertEqual(r.music.count("play"), 1)
    }

    /// A busy lock is a route switch in progress: nothing plays, nothing is
    /// said as a failure, and the caller rolls its step back.
    func testABusyLockStartsNothingAndTheCallerRollsBack() throws {
        let dir = OutputLockTestSupport.tempDir()
        var ticks = 0.0
        let waiter = OutputLock(path: dir + "/output.lock", pollInterval: 0.001,
                                clock: { ticks += 40; return Date(timeIntervalSince1970: ticks) }, pause: { _ in })
        // The rig's own fence is on the default lock; build this one by hand.
        let held = OutputLock(path: dir + "/output.lock", pollInterval: 0.001)
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? held.withLock { acquired.signal(); release.wait() } }
        acquired.wait()
        defer { release.signal() }
        let r = Rig(dir: dir, owner: "tui", lockPath: nil, makeControl: { self.control($0) })
        let busy = MacRoutePlayer(streamWait: .instant, route: r.route, outputIsMusicApp: { true }, fence: RateFence(lock: waiter), owner: "tui",
                                  makeMusic: { r.music.playScript = $0; return r.music },
                                  resolvePersistentID: { _, _ in "AAAAAAAAAAAAAAAA" },
                                  makeFollow: { _ in fatalError("rate follow built with the lock busy") }, post: { _ in })
        r.route.set(true)
        let store = AppQueueStore()
        store.macRoute = busy
        store.set(queue())
        let outcome = playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                     playlist: "Mixtape", position: 1)
        guard case .notStarted = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(outcome.accepted)
        XCTAssertEqual(r.music.count("play"), 0)
        // The person's key says so and does not claim a play.
        XCTAssertFalse(playRequestedQueueTrack(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                               playlist: "Mixtape", position: 1, title: "Song 1"))
    }

    // MARK: a rate failure never reaches the gate

    /// Whatever SpanDAC does (silent, refusing, a broken reply, an older one),
    /// the song plays and the outcome is `played`: the one value that resets
    /// the gate. Only Music's own play failing is `failed`.
    func testARateFailureIsAPlayAndOnlyMusicsPlayFailureIsAFailure() throws {
        let failures: [(String, ([String: Any]) throws -> String)] = [
            ("silent", { _ in throw SourceAppError.timedOut }),
            ("not running", { _ in throw SourceAppError.notRunning }),
            ("refused", { _ in throw SourceAppError.refused("unlicensed") }),
            ("older SpanDAC", { _ in throw SourceAppError.unsupported(sourcePrepareRateOp) }),
            ("garbage", { _ in "not json at all" }),
        ]
        for (name, script) in failures {
            let r = rig()
            r.wire.script = script
            let store = storeWithRoute(r, queue: queue())
            var gate = AdvanceRetryGate(maxRetries: 2)
            _ = gate.playFailed()
            let outcome = playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                         playlist: "Mixtape", position: 1)
            XCTAssertEqual(outcome, .played, name)
            XCTAssertEqual(r.music.count("play"), 1, name)
            if outcome == .played { gate.playSucceeded() }
            XCTAssertEqual(gate.failures, 0, "\(name): the gate counted a rate failure")
        }
        let r = rig()
        r.music.playError = ActionError(message: "Music could not play it")
        let store = storeWithRoute(r, queue: queue())
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .failed)
    }

    // MARK: the poller

    /// A fake `osascript` for the poller: the first player read is a song one
    /// second from its end, every later one is stopped; the album read answers
    /// two songs; every play script is recorded.
    private func pollingBackend(_ dir: String) throws -> (AppleScriptBackend, plays: () -> [String]) {
        let fake = dir + "/osascript"
        let record = dir + "/plays.txt"
        let sh = """
        #!/bin/sh
        s="$2"
        case "$s" in
          *"player state as text"*)
            if [ -f '\(dir)/seen' ]; then printf 'STOPPED'; else : > '\(dir)/seen'; printf 'Song 1\\037Artist\\037Album\\037100\\03799\\037playing'; fi ;;
          *"whose album is"*) printf '1\\037Song 1\\037Artist\\037Album\\n2\\037Song 2\\037Artist\\037Album' ;;
          *"play track"*|*"play item 1 of"*) printf '%s\\n--END--\\n' "$s" >> '\(record)'; printf 'PLAYED' ;;
          *) : ;;
        esac
        """
        try sh.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return (AppleScriptBackend(executable: fake), {
            ((try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n--END--\n").filter { !$0.isEmpty }
        })
    }

    private func poller(_ dir: String, backend: AppleScriptBackend, store: AppQueueStore) -> PlaybackPoller {
        PlaybackPoller(store: NowPlayingStore(), backend: backend, appQueue: store,
                       queueStore: QueueStore(path: dir + "/queue.json"))
    }

    /// The natural end of a song on the route: the poller's advance is one
    /// transition (Music's adapter, SpanDAC asked), not the shipped script.
    func testThePollersAdvanceOnTheRouteGoesThroughTheTransition() throws {
        let r = rig()
        let (backend, plays) = try pollingBackend(r.dir)
        let store = storeWithRoute(r, queue: queue(2))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 2)
        XCTAssertEqual(r.music.count("play"), 1)
        XCTAssertEqual(r.music.scripts, ["play track 2 of playlist \"Mixtape\""])
        XCTAssertEqual(plays(), [], "the shipped script played on the route")
        XCTAssertEqual(r.wire.ops.first, sourcePrepareRateOp)
        p.cleanupArtFiles()
    }

    /// Off the route the same advance is the shipped play, untouched.
    func testThePollersAdvanceOffTheRouteIsTheShippedPlay() throws {
        let r = rig(on: false)
        let (backend, plays) = try pollingBackend(r.dir)
        let store = storeWithRoute(r, queue: queue(2))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 2)
        XCTAssertEqual(plays().count, 1)
        XCTAssertTrue(plays()[0].contains("play track 2 of playlist \"Mixtape\""))
        XCTAssertEqual(r.music.log, [])
        XCTAssertEqual(r.wire.requests.count, 0)
        p.cleanupArtFiles()
    }

    /// The play-next-by-name fallback (no app queue, Music's context) runs off
    /// the route and never on it.
    func testThePollersTitleFallbackIsOffOnTheRouteAndOnOffIt() throws {
        for onRoute in [true, false] {
            let r = rig(on: onRoute)
            let (backend, plays) = try pollingBackend(r.dir)
            let store = storeWithRoute(r)                       // no app queue
            let p = poller(r.dir, backend: backend, store: store)
            p.tick(); p.tick()
            if onRoute {
                XCTAssertEqual(plays(), [], "the by-name fallback played on the route")
                XCTAssertEqual(r.music.log, [], "the fallback went through the transition instead of staying off")
            } else {
                XCTAssertEqual(plays().count, 1, "the shipped fallback stopped working off the route")
                XCTAssertTrue(plays()[0].contains("Song 2"))
            }
            p.cleanupArtFiles()
        }
    }

    /// An owner that lost the lease leaves the queue alone: no play, no step,
    /// and the queue is not cleared.
    func testThePollerDoesNotAdvanceAfterTheLeaseMovedOn() throws {
        let r = rig()
        let (backend, plays) = try pollingBackend(r.dir)
        let store = storeWithRoute(r, queue: queue(2))
        // The TUI's own first play takes the lease and records its entry.
        XCTAssertEqual(playQueueEntry(backend: backend, appQueue: store, playlist: "Mixtape", position: 1), .played)
        let runner = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        _ = try runner.begin(.advance, owner: "runner")
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(r.music.count("play"), 1, "only the first play")
        XCTAssertEqual(plays(), [])
        XCTAssertEqual(store.read()?.currentIndex, 1, "the queue stepped without the lease")
        XCTAssertNotNil(store.read(), "the queue was ended by a process that does not own it")
        p.cleanupArtFiles()
    }

    /// Only Music's own play result reaches the gate. On the route: a rate
    /// failure is a played song (the step stands); a superseded play touches
    /// nothing (the newer command's queue is not rolled back); a play that never
    /// started rolls its step back with no gate; Music's own failure retries.
    func testThePollerFeedsTheGateOnlyMusicsPlayResult() throws {
        // A rate failure.
        do {
            let r = rig()
            r.wire.script = { _ in throw SourceAppError.timedOut }
            let (backend, _) = try pollingBackend(r.dir)
            let store = storeWithRoute(r, queue: queue(3))
            let p = poller(r.dir, backend: backend, store: store)
            p.tick(); p.tick()
            XCTAssertEqual(store.read()?.currentIndex, 2, "a rate failure rolled the step back or skipped")
            XCTAssertEqual(r.music.count("play"), 1)
            p.cleanupArtFiles()
        }
        // Superseded.
        do {
            let r = rig()
            let other = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
            let base = r.wire.script
            r.wire.script = { body in
                if body["op"] as? String == sourcePrepareRateOp { _ = try other.begin(.next, owner: "runner") }
                return try base(body)
            }
            let (backend, _) = try pollingBackend(r.dir)
            let store = storeWithRoute(r, queue: queue(3))
            let p = poller(r.dir, backend: backend, store: store)
            p.tick(); p.tick()
            XCTAssertEqual(store.read()?.currentIndex, 2, "a superseded advance rolled the queue back")
            XCTAssertEqual(r.music.count("play"), 0)
            p.cleanupArtFiles()
        }
        // Music's own failure retries: the step is rolled back.
        do {
            let r = rig()
            r.music.playError = ActionError(message: "no")
            let (backend, _) = try pollingBackend(r.dir)
            let store = storeWithRoute(r, queue: queue(3))
            let p = poller(r.dir, backend: backend, store: store)
            p.tick(); p.tick()
            XCTAssertEqual(store.read()?.currentIndex, 1, "Music's own failure was not retried")
            p.cleanupArtFiles()
        }
    }

    // MARK: a refused auto-advance is not retried every tick (round 2, I2)

    private func refusing(_ r: Rig) {
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp {
                let error: [String: Any] = ["kind": "route_output_refused",
                                            "detail": "Couldn't make SSL 2+ the Mac's output; nothing was played."]
                return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error]),
                              as: UTF8.self)
            }
            return self.answer(body["fence"] as? Int ?? 0, "quiet")
        }
    }

    /// The song ended and SpanDAC will not make the DAC the output. The first
    /// tick asks and is refused; the queue stays on the song that ended, and the
    /// ticks after it ask SpanDAC NOTHING (no unbounded IPC, no output write per
    /// tick) until the person acts.
    func testARefusedAutoAdvanceIsNotRetriedOnEveryTick() throws {
        let r = rig()
        refusing(r)
        let (backend, _) = try pollingBackend(r.dir)
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick()                                    // the song, one second from its end
        for _ in 0..<8 { p.tick() }                 // stopped: its natural end
        XCTAssertEqual(r.wire.ops.filter { $0 == sourcePrepareRateOp }.count, 1,
                       "a refusal was asked again: \(r.wire.ops)")
        XCTAssertEqual(store.read()?.currentIndex, 1, "the queue moved past a song that never played")
        XCTAssertNotNil(store.read(), "the queue was ended by a refusal")
        XCTAssertEqual(r.music.count("play"), 0)
        p.cleanupArtFiles()
    }

    /// A person's play or skip (any change of the queue) re-arms the advance: the
    /// next natural end asks again.
    func testAUserActionReArmsARefusedAdvance() throws {
        let r = rig()
        refusing(r)
        let (backend, _) = try pollingBackend(r.dir)
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick()
        for _ in 0..<4 { p.tick() }
        XCTAssertEqual(r.wire.ops.filter { $0 == sourcePrepareRateOp }.count, 1)
        _ = store.jump(to: 1)                       // the person picked a song
        for _ in 0..<4 { p.tick() }
        XCTAssertEqual(r.wire.ops.filter { $0 == sourcePrepareRateOp }.count, 2, "the person's action did not re-arm it")
        XCTAssertEqual(store.read()?.currentIndex, 1)
        p.cleanupArtFiles()
    }

    /// The hold ends on a change of queue, of route or of the selected output, and
    /// on nothing else.
    func testTheRefusalHoldEndsOnAQueueRouteOrOutputChange() {
        let hold = AdvanceRefusalHold(generation: 5, onRoute: true, selection: nil)
        XCTAssertTrue(hold.holds(generation: 5, onRoute: true, selection: nil))
        XCTAssertFalse(hold.holds(generation: 6, onRoute: true, selection: nil), "a queue change")
        XCTAssertFalse(hold.holds(generation: 5, onRoute: false, selection: nil), "the route left")
        let other = EffectiveSelection.outputBlocked(stored: .musicApp)
        XCTAssertFalse(hold.holds(generation: 5, onRoute: true, selection: other), "the output changed")
    }

    // MARK: a repeat-all wrap is the natural end (live check 2026-11-16)

    /// A fake `osascript` for a song that wraps: the first player read is the song
    /// one second from its end, every later one is the same song again from its
    /// start, playing; the song-repeat read answers `repeatMode`; every play script
    /// and every script that WRITES a mode is recorded.
    private func wrappingBackend(_ dir: String, repeatMode: String)
        throws -> (AppleScriptBackend, plays: () -> [String], writes: () -> [String]) {
        let fake = dir + "/osascript"
        let record = dir + "/plays.txt", writesFile = dir + "/writes.txt"
        let sh = """
        #!/bin/sh
        s="$2"
        case "$s" in
          *"set song repeat"*|*"set shuffle"*) printf '%s\\n--END--\\n' "$s" >> '\(writesFile)' ;;
        esac
        case "$s" in
          *"player state as text"*)
            if [ -f '\(dir)/seen' ]; then printf 'Song 1\\037Artist\\037Album\\037100\\0372\\037playing'; else : > '\(dir)/seen'; printf 'Song 1\\037Artist\\037Album\\037100\\03799\\037playing'; fi ;;
          *"song repeat as string"*) printf 'false,songs,\(repeatMode)' ;;
          *"play track"*|*"play item 1 of"*) printf '%s\\n--END--\\n' "$s" >> '\(record)'; printf 'PLAYED' ;;
          *) : ;;
        esac
        """
        try sh.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        func lines(_ path: String) -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n--END--\n").filter { !$0.isEmpty }
        }
        return (AppleScriptBackend(executable: fake), { lines(record) }, { lines(writesFile) })
    }

    /// Music's song repeat is "all": the one-track context loops the song, so no
    /// stop ever comes. The wrap advances the queue through the transition, and the
    /// person's repeat setting is never written.
    func testARepeatAllWrapOnTheRouteIsTheNaturalEndAndAdvancesTheQueue() throws {
        let r = rig()
        let (backend, plays, writes) = try wrappingBackend(r.dir, repeatMode: "all")
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 2, "the looping song was never advanced past")
        XCTAssertEqual(r.music.count("play"), 1)
        XCTAssertEqual(r.music.scripts, ["play track 2 of playlist \"Mixtape\""])
        XCTAssertEqual(plays(), [], "the shipped script played on the route")
        XCTAssertEqual(writes(), [], "the person's repeat or shuffle setting was written")
        p.cleanupArtFiles()
    }

    /// Repeat "one" is the person asking for this song again: it loops, no advance.
    func testARepeatOneWrapIsLeftToLoop() throws {
        let r = rig()
        let (backend, plays, writes) = try wrappingBackend(r.dir, repeatMode: "one")
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 1, "repeat one was advanced past")
        XCTAssertEqual(r.music.count("play"), 0)
        XCTAssertEqual(plays(), [])
        XCTAssertEqual(writes(), [])
        p.cleanupArtFiles()
    }

    /// With repeat off a jump back to the start is a seek, not an end.
    func testAJumpBackWithRepeatOffIsASeekNotAnEnd() throws {
        let r = rig()
        let (backend, _, _) = try wrappingBackend(r.dir, repeatMode: "off")
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 1)
        XCTAssertEqual(r.music.count("play"), 0)
        p.cleanupArtFiles()
    }

    /// Off the route nothing about a wrap changes: no advance, no read of the mode.
    func testAWrapOffTheRouteIsUntouched() throws {
        let r = rig(on: false)
        let (backend, plays, writes) = try wrappingBackend(r.dir, repeatMode: "all")
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(store.read()?.currentIndex, 1)
        XCTAssertEqual(plays(), [])
        XCTAssertEqual(writes(), [])
        XCTAssertEqual(r.music.log, [])
        p.cleanupArtFiles()
    }

    /// A song this process started between two ticks (even one with the same title)
    /// is a new song, not the wrap of the one before it.
    func testASongStartedBetweenTicksIsNotAWrap() throws {
        let r = rig()
        let (backend, _, _) = try wrappingBackend(r.dir, repeatMode: "all")
        let store = storeWithRoute(r, queue: queue(3))
        let p = poller(r.dir, backend: backend, store: store)
        p.tick()                                    // near the end of song 1
        XCTAssertEqual(playQueueEntry(backend: backend, appQueue: store, playlist: "Mixtape", position: 1), .played)
        p.tick()                                    // the same title, from the start: our own start
        XCTAssertEqual(store.read()?.currentIndex, 1, "our own fresh start was taken for a wrap")
        XCTAssertEqual(r.music.count("play"), 1, "only the start we made")
        p.cleanupArtFiles()
    }

    /// Not ours to advance (a newer owner holds the lease): nothing moves.
    func testAWrapDoesNotAdvanceAfterTheLeaseMovedOn() throws {
        let r = rig()
        let (backend, _, _) = try wrappingBackend(r.dir, repeatMode: "all")
        let store = storeWithRoute(r, queue: queue(3))
        XCTAssertEqual(playQueueEntry(backend: backend, appQueue: store, playlist: "Mixtape", position: 1), .played)
        let runner = RateFence(lock: OutputLock(path: r.dir + "/output.lock", pollInterval: 0.001))
        _ = try runner.begin(.advance, owner: "runner")
        let p = poller(r.dir, backend: backend, store: store)
        p.tick(); p.tick()
        XCTAssertEqual(r.music.count("play"), 1, "only the first play")
        XCTAssertEqual(store.read()?.currentIndex, 1)
        p.cleanupArtFiles()
    }

    func testTheWrapRuleIsNearTheEndToNearTheStartOfTheSameSong() {
        let wrap = PlaybackPoller.isNaturalEndWrap
        XCTAssertTrue(wrap(99, 100, 1, 100))
        XCTAssertTrue(wrap(93, 100, 9, 100), "poll latency: a few seconds either side")
        XCTAssertFalse(wrap(50, 100, 1, 100), "a seek from mid-song")
        XCTAssertFalse(wrap(99, 100, 60, 100), "not back at the start")
        XCTAssertFalse(wrap(99, 100, 98, 100), "ordinary playback")
        XCTAssertFalse(wrap(99, 100, 1, 240), "another song of another length")
        XCTAssertFalse(wrap(0, 0, 0, 0), "nothing known")
    }

    // MARK: closing the TUI (D2)

    private func correcting(_ r: Rig, delivered: Int = 44100) {
        // The song comes out at another rate than the DAC: SpanDAC says correct.
        r.wire.script = settlingScript(confirm: "correct")
        r.music.current = nil
    }

    /// Closing while our pause stands (the correction ran past its window, so it
    /// could not resume) releases that pause, and only that: Music still
    /// showing it paused on that track, with no command since.
    func testClosingReleasesAFollowerPauseItStillHolds() throws {
        let r = rig()
        let store = storeWithRoute(r, queue: queue())
        correcting(r)
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp, body["step"] as? Int == 2 { r.clock.t += 5 }   // too slow to resume
            return try base(body)
        }
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .played)
        XCTAssertEqual(r.music.state.state, .paused, "the correction should have left our pause")
        r.player.shutdown(wait: 1)
        XCTAssertEqual(r.music.state.state, .playing, "closing left the follower's pause")
        XCTAssertEqual(r.music.count("resume"), 1)
    }

    /// Closing does not resume a song the person paused or that moved on: no
    /// resume when Music is not paused on that track, or a command moved the
    /// fence since.
    func testClosingResumesNothingThatIsNotOurPause() throws {
        for scenario in ["person resumed", "other track", "a command since"] {
            let r = rig()
            let store = storeWithRoute(r, queue: queue())
            correcting(r)
            let base = r.wire.script
            r.wire.script = { body in
                if body["op"] as? String == sourcePrepareRateOp, body["step"] as? Int == 2 { r.clock.t += 5 }
                return try base(body)
            }
            _ = playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                               playlist: "Mixtape", position: 1)
            XCTAssertEqual(r.music.state.state, .paused)
            switch scenario {
            case "person resumed": r.music.state = RatePlayerState(state: .playing, persistentID: r.music.state.persistentID, position: 13)
            case "other track": r.music.state = RatePlayerState(state: .paused, persistentID: "BBBBBBBBBBBBBBBB", position: 12)
            default: r.player.noteCommand(.pause)
            }
            let resumes = r.music.count("resume")
            r.player.shutdown(wait: 1)
            XCTAssertEqual(r.music.count("resume"), resumes, "\(scenario): closing resumed a pause that was not ours")
        }
    }

    /// Closing while a transition is in flight waits for it and never starts a
    /// correction (which would pause the song with nothing to release it); a
    /// play after closing starts nothing.
    func testClosingMidTransitionNeverStartsACorrectionAndLaterPlaysStartNothing() throws {
        let r = rig()
        let store = storeWithRoute(r, queue: queue())
        correcting(r)
        let base = r.wire.script
        let finished = DispatchSemaphore(value: 0)
        r.wire.script = { body in
            if body["op"] as? String == sourceConfirmRateOp {
                DispatchQueue.global().async { r.player.shutdown(wait: 5); finished.signal() }
                let deadline = Date(timeIntervalSinceNow: 5)
                while !r.player.isClosing, Date() < deadline { usleep(1000) }
            }
            return try base(body)
        }
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .played)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "closing did not finish after the transition")
        XCTAssertEqual(r.music.count("pause"), 0, "a correction paused the song while closing")
        XCTAssertEqual(r.music.state.state, .playing)
        // After closing: nothing starts, and the route is off.
        XCTAssertFalse(r.player.isOnRoute)
        XCTAssertEqual(r.player.play(playlist: "Mixtape", position: 2, command: .play, isCurrent: { true }),
                       .notStarted("MusicTUI is closing"))
        XCTAssertEqual(r.music.count("play"), 1)
    }

    /// A pause the person asks for during a correction moves the fence (M1), so
    /// the follower's resume is cancelled and the person's pause stands.
    func testAPauseDuringACorrectionCancelsTheFollowersResume() throws {
        let r = rig()
        let store = storeWithRoute(r, queue: queue())
        correcting(r)
        let base = r.wire.script
        r.wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp, body["step"] as? Int == 2 { r.player.noteCommand(.pause) }
            return try base(body)
        }
        XCTAssertEqual(playQueueEntry(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                      playlist: "Mixtape", position: 1), .played)
        XCTAssertEqual(r.music.count("resume"), 0, "the follower resumed over the person's pause")
        XCTAssertEqual(r.music.state.state, .paused)
    }

    func testATransportCommandMovesTheFenceOnTheRouteAndNotOffIt() throws {
        let on = rig()
        on.player.noteCommand(.pause)
        XCTAssertEqual(try on.fence.current(), 1)
        let off = rig(on: false)
        off.player.noteCommand(.pause)
        XCTAssertEqual(try off.fence.current(), 0)
    }

    // MARK: the adapter's AppleScript

    func testTheQueueEntryPlayScriptsAreTheShippedOnes() {
        XCTAssertEqual(queueTrackPlayScript(playlist: "My \"Mix\"", position: 7), "play track 7 of playlist \"My \\\"Mix\\\"\"")
        XCTAssertEqual(queueTrackPlayScript(playlist: persistentIDQueueSource, position: Int(Int64(bitPattern: 0xABCDEF0123456789))),
                       persistentIDPlayScript("ABCDEF0123456789"))
    }

    func testTheAdapterParsesItsReadsAndFailsClosed() {
        let us = String(asFieldSep)
        XCTAssertEqual(MacRouteScripts.parseTrackRead("abcdef0123456789\(us)42\(us)96000\n"),
                       RateTrackRead(persistentID: "ABCDEF0123456789", databaseID: 42, sampleRateHz: 96000))
        XCTAssertEqual(MacRouteScripts.parseTrackRead("ABC\(us)42\(us)0")?.sampleRateHz, nil, "a missing rate reads 0, never 0 Hz")
        XCTAssertNil(MacRouteScripts.parseTrackRead(""))
        XCTAssertNil(MacRouteScripts.parseTrackRead("only one field"))
        XCTAssertEqual(MacRouteScripts.parsePlayerState("paused\(us)ab12\(us)1234"),
                       RatePlayerState(state: .paused, persistentID: "AB12", position: 12.34))
        XCTAssertEqual(MacRouteScripts.parsePlayerState("stopped\(us)\(us)0"),
                       RatePlayerState(state: .stopped, persistentID: nil, position: 0))
        XCTAssertNil(MacRouteScripts.parsePlayerState("fast forwarding\(us)AB\(us)1"))
        XCTAssertNil(MacRouteScripts.parsePlayerState("playing\(us)AB\(us)12,5"), "a locale decimal comma must not parse")
    }

    /// New AppleScript text is read-only where it reads, names no variable like
    /// a Music term (`active`, `left`: they break at runtime), and uses the
    /// integer-centisecond position so no locale decimal can reach the parser.
    func testTheNewScriptsAreReadOnlyAndUseSafeVariableNames() {
        let reads = [MacRouteScripts.readCurrentTrack, MacRouteScripts.readPlayerState,
                     MacRouteScripts.resolvePersistentID(playlist: "P", position: 3)]
        for script in reads {
            XCTAssertFalse(script.contains("play "), script)
            XCTAssertFalse(script.contains("set player position"), script)
            for banned in ["active", "left", "right", "top", "bottom", "size", "result"] {
                XCTAssertFalse(script.contains("set \(banned) "), "\(banned) in: \(script)")
            }
        }
        XCTAssertTrue(MacRouteScripts.readPlayerState.contains("* 100"))
        XCTAssertTrue(MacRouteScripts.resolvePersistentID(playlist: "My \"P\"", position: 3)
            .contains("track 3 of playlist \"My \\\"P\\\"\""))
    }

    // MARK: the licence

    /// The rate socket's replies reach the licence cache (the same observation
    /// the Mac's other client makes): an `unlicensed` refusal on a rate op
    /// reads as not serving. With no cache it is `macRate` as it was.
    func testTheRateSocketIsLicenceObserving() throws {
        let cache = SpanDACServingCache()
        var timeouts: [TimeInterval] = []
        let refused = #"{"ok":false,"error":{"kind":"\#(spanDACLicenceRefusalKind)","message":"unlicensed"}}"#
        let control = SourceAppControl.macRate(observing: cache, senderFor: { timeout in
            { _, _ in timeouts.append(timeout); return refused }
        })
        XCTAssertNil(cache.snapshot().serving)
        _ = try? control.rateRequest(SourceAppControl.rateFenceBody(fence: 3), timeout: 1.25)
        XCTAssertEqual(cache.snapshot().serving, false, "the rate reply did not reach the licence cache")
        XCTAssertEqual(timeouts, [1.25], "the rate sender lost its per-exchange timeout")
        XCTAssertNotNil(SourceAppControl.macRate(observing: nil).rateSender)
    }

    // MARK: the Output tab's hook

    func testTheRouteStateIsAThreadSafeFlagOffByDefault() {
        // The route state itself: thread-safe flag, off by default.
        let s = MacDACRouteState()
        XCTAssertFalse(s.isOn)
        s.set(true)
        XCTAssertTrue(s.isOn)
        s.set(false)
        XCTAssertFalse(s.isOn)
    }
}

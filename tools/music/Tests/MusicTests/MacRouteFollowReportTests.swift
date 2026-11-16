// tools/music/Tests/MusicTests/MacRouteFollowReportTests.swift
//
// mac-route S11, MusicTUI's half: tell SpanDAC when the Mac DAC route (rate
// follow) is on or off (`slice.rateFollow`, which feeds SpanDAC's restore of the
// DAC's rate) and what is playing (`slice.nowPlaying`, the Mac screen's source).
// The TUI and the CLI runner both send it; a route left sends off; an older
// SpanDAC answers `unknown_op` and nothing more is sent.
//
// Fakes only: the fence files live in a temp directory; SpanDAC is a scripted
// transport; Music.app is a fake; the reporter's serial queue is replaced by
// running each unit in place. No audio, no AppleScript, no socket, no keychain,
// and never `~/.config/music`.
import XCTest
@testable import music

final class MacRouteFollowReportTests: XCTestCase {

    // MARK: support

    private final class Clock { var t: TimeInterval = 0 }

    private final class Wire {
        let clock: Clock
        var requests: [[String: Any]] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        init(_ clock: Clock = Clock()) { self.clock = clock }
        var ops: [String] { requests.compactMap { $0["op"] as? String } }
        func requests(for op: String) -> [[String: Any]] { requests.filter { ($0["op"] as? String) == op } }
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

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func rateAnswer(_ fence: Int, _ outcome: String, step: Int? = nil, target: Int? = nil) -> String {
        var rate: [String: Any] = ["fence": fence, "outcome": outcome, "rate_seq": 1]
        if let step { rate["step"] = step }
        if let target { rate["target_hz"] = target }
        return json(["ok": true, "rate": rate])
    }

    /// A SpanDAC that serves everything: follow is applied, a report is taken.
    private func fullScript() -> ([String: Any]) throws -> String {
        { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourceRateFollowOp, _):
                return self.json(["ok": true, "rate": ["fence": f, "outcome": "quiet"],
                                  "follow": ["on": body["on"] as? Bool ?? false, "applied": true]])
            case (sourceNowPlayingOp, _):
                return self.json(["ok": true, "now_playing": ["accepted": true, "fence": f]])
            case (sourcePrepareRateOp, 2): return self.rateAnswer(f, "settled", step: 2, target: 96000)
            case (sourcePrepareRateOp, _): return self.rateAnswer(f, "settled", step: 0, target: 96000)
            case (sourceConfirmRateOp, _): return self.rateAnswer(f, "own_rate", step: 1, target: 96000)
            default: return self.rateAnswer(f, "quiet")
            }
        }
    }

    private let unknownOp: ([String: Any]) throws -> String = { body in
        #"{"ok":false,"op":"\#(body["op"] as? String ?? "")","error":{"kind":"unknown_op","detail":"unknown op"}}"#
    }

    private func fenceFor(_ dir: String) -> RateFence {
        RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
    }

    private func reporter(_ wire: Wire) -> MacRouteFollowReporter {
        MacRouteFollowReporter(control: control(wire), schedule: { $0() })
    }

    // MARK: the wire

    func testTheNamesAndBodiesAreTheFixedContract() throws {
        XCTAssertEqual([sourceRateFollowOp, sourceNowPlayingOp], ["slice.rateFollow", "slice.nowPlaying"])
        XCTAssertEqual(Set(SourceAppControl.rateFollowBody(fence: 7, on: true).keys), ["op", "fence", "on"])
        let named = SourceAppControl.rateFollowBody(fence: 7, on: false, dacUID: "ssl")
        XCTAssertEqual(named["dac_uid"] as? String, "ssl")
        XCTAssertEqual(named["on"] as? Bool, false)
        XCTAssertEqual(Set(SourceNowPlayingReport(fence: 7, state: .none).body.keys), ["op", "fence", "state"],
                       "a bare clear carries nothing else")
        var full = SourceNowPlayingReport(fence: 7, state: .playing, persistentID: "AB12CD34EF56AB78", databaseID: 9,
                                          title: "Aja", artist: "Steely Dan", album: "Aja", durationMS: 477_000,
                                          positionMS: 1_200, rateOutcome: "own_rate", targetHz: 96_000,
                                          deliveredHz: 96_000, dacRateHz: 96_000)
        full.priorUnresolved = true
        XCTAssertEqual(Set(full.body.keys), ["op", "fence", "state", "persistent_id", "database_id", "title", "artist",
                                             "album", "duration_ms", "position_ms", "rate_outcome", "target_hz",
                                             "delivered_hz", "dac_rate_hz", "prior_unresolved"])
        XCTAssertEqual(full.body["state"] as? String, "playing")
        var unknown = SourceNowPlayingReport(fence: 1, state: .playing)
        unknown.title = ""
        XCTAssertEqual(Set(unknown.body.keys), ["op", "fence", "state"], "an empty text is unknown, not sent")
    }

    func testTheAckIsFailClosed() throws {
        let ok = try SourceAppControl.rateFollowAck(
            from: ["rate": ["fence": 5, "outcome": "quiet"], "follow": ["on": true, "applied": true, "restore": "restored"]],
            fence: 5)
        XCTAssertTrue(ok.wasApplied)
        XCTAssertEqual(ok.restore, "restored")
        let noDAC = try SourceAppControl.rateFollowAck(
            from: ["rate": ["fence": 5, "outcome": "quiet"], "follow": ["on": true, "applied": false]], fence: 5)
        XCTAssertFalse(noDAC.wasApplied)
        let superseded = try SourceAppControl.rateFollowAck(
            from: ["rate": ["fence": 5, "outcome": "superseded", "highest_fence": 9]], fence: 5)
        XCTAssertFalse(superseded.wasApplied, "a newer command replaced this message")
        XCTAssertThrowsError(try SourceAppControl.rateFollowAck(from: ["ok": true], fence: 5))
        XCTAssertThrowsError(try SourceAppControl.rateFollowAck(
            from: ["rate": ["fence": 4, "outcome": "quiet"]], fence: 5), "a reply for another fence")
    }

    // MARK: route on and off

    func testTheRouteChosenSendsOnUnderANewFenceAndTheRouteLeftSendsOffAndClearsTheScreen() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)

        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertEqual(wire.ops, [sourceRateFollowOp])
        XCTAssertEqual(wire.requests[0]["on"] as? Bool, true)
        XCTAssertEqual(wire.requests[0]["fence"] as? Int, 1)
        XCTAssertEqual(try fence.current(), 1, "a route change is a command: it moved the fence (M1)")
        XCTAssertEqual(r.confirmed, true)
        XCTAssertNil(wire.requests[0]["dac_uid"], "SpanDAC uses the DAC its Output tab chose")

        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertEqual(wire.ops.count, 1, "a confirmed state sends nothing and moves no fence")
        XCTAssertEqual(try fence.current(), 1)

        r.routeChanged(on: false, fence: fence, owner: "tui")
        XCTAssertEqual(wire.ops, [sourceRateFollowOp, sourceRateFollowOp, sourceNowPlayingOp])
        let off = try XCTUnwrap(wire.requests.dropFirst(1).first)
        XCTAssertEqual(off["on"] as? Bool, false)
        XCTAssertEqual(off["fence"] as? Int, 2)
        let cleared = try XCTUnwrap(wire.requests.dropFirst(2).first)
        XCTAssertEqual(cleared["state"] as? String, "none", "leaving the route clears the Mac screen")
        XCTAssertEqual(cleared["fence"] as? Int, 2)
        XCTAssertEqual(r.confirmed, false)

        r.routeChanged(on: false, fence: fence, owner: "tui")
        XCTAssertEqual(wire.ops.count, 3)
        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertEqual(wire.requests.last?["on"] as? Bool, true, "chosen again: on again")
        XCTAssertEqual(wire.requests.last?["fence"] as? Int, 3)
    }

    func testAMessageSpanDACCalledSupersededOrCouldNotApplyIsNotConfirmed() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire()
        wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            return self.json(["ok": true, "rate": ["fence": f, "outcome": "superseded", "highest_fence": f + 5]])
        }
        let r = reporter(wire)
        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertNil(r.confirmed)
        wire.script = fullScript()
        r.ensureOn(fence: 9)
        XCTAssertEqual(r.confirmed, true, "the next play asks again")
        XCTAssertEqual(wire.requests.last?["fence"] as? Int, 9)
        r.ensureOn(fence: 10)
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 2, "confirmed: not asked a third time")
    }

    func testASpanDACThatCannotBeAskedIsAskedAgainByTheNextPlay() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire()   // every request times out
        let r = reporter(wire)
        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertNil(r.confirmed)
        XCTAssertTrue(r.isFollowOffered, "a timeout is not an older SpanDAC")
        wire.script = fullScript()
        r.ensureOn(fence: 4)
        XCTAssertEqual(r.confirmed, true)
    }

    func testAFenceThatCannotMoveReportsNothing() throws {
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)
        let broken = RateFence(lock: OutputLock(path: "/nonexistent-dir-s11/output.lock", pollInterval: 0.001))
        r.routeChanged(on: true, fence: broken, owner: "tui")
        XCTAssertTrue(wire.requests.isEmpty, "no ordering to keep, so nothing is claimed")
        XCTAssertNil(r.confirmed)
    }

    // MARK: older peers

    func testAnOlderSpanDACIsLatchedPerOpAndNothingMoreIsSent() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire()
        wire.script = { body in
            // An older SpanDAC knows the four rate ops and neither new one.
            if [sourceRateFollowOp, sourceNowPlayingOp].contains(body["op"] as? String ?? "") {
                return try self.unknownOp(body)
            }
            return self.rateAnswer(body["fence"] as? Int ?? 0, "quiet")
        }
        let r = reporter(wire)
        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertFalse(r.isFollowOffered)
        XCTAssertTrue(r.isNowPlayingOffered, "each op is latched on its own answer")
        r.ensureOn(fence: 2)
        r.routeChanged(on: true, fence: fence, owner: "tui")
        XCTAssertEqual(wire.ops, [sourceRateFollowOp], "no further follow message")

        r.report(SourceNowPlayingReport(fence: 3, state: .playing, persistentID: "A"))
        XCTAssertFalse(r.isNowPlayingOffered)
        r.report(SourceNowPlayingReport(fence: 4, state: .paused, persistentID: "A"))
        XCTAssertEqual(wire.ops, [sourceRateFollowOp, sourceNowPlayingOp], "and no further report")
    }

    func testAnOlderSpanDACStillPlaysEverySongAndTheFenceStillMoves() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire()
        wire.script = { body in
            if [sourceRateFollowOp, sourceNowPlayingOp].contains(body["op"] as? String ?? "") {
                return try self.unknownOp(body)
            }
            return try self.fullScript()(body)
        }
        let r = reporter(wire)
        let music = FakeMusic()
        let player = player(dir: dir, wire: wire, reporter: r, music: music)
        XCTAssertEqual(playID(player, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(playID(player, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(music.played, ["AAAAAAAAAAAAAAA1", "BBBBBBBBBBBBBBB2"])
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 1, "asked once, then latched")
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, 1)
        XCTAssertEqual(wire.requests(for: sourcePrepareRateOp).count, 2, "the rate ops are untouched")
        XCTAssertEqual(try fence.current(), 2)
    }

    // MARK: a transition and the runner

    private final class FakeMusic: RateMusicControlling {
        var played: [String] = []
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        var current: RateTrackRead?
        func playTrack(persistentID: String) throws {
            played.append(persistentID)
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 0)
            current = RateTrackRead(persistentID: persistentID, databaseID: 7, sampleRateHz: 96000)
        }
        func pause() throws {}
        func resume() throws {}
        func seekToStart() throws {}
        func readCurrentTrack() -> RateTrackRead? { current }
        func readPlayerState() -> RatePlayerState? { state }
    }

    @discardableResult
    private func playID(_ p: MacRoutePlayer, _ id: String, _ command: RateCommand,
                        subject: RouteSubject? = nil) -> QueuePlayOutcome {
        p.play(playlist: persistentIDQueueSource, position: pidIndex(id), command: command, subject: subject,
               isCurrent: { true })
    }

    private func pidIndex(_ id: String) -> Int {
        persistentIDQueueEntry(persistentID: id, name: "", artist: "", album: nil)!.index
    }

    private func player(dir: String, wire: Wire, reporter: MacRouteFollowReporter?, music: FakeMusic,
                        owner: String = "tui", clock: Clock = Clock()) -> MacRoutePlayer {
        let c = control(wire)
        return MacRoutePlayer(
            route: MacDACRouteState(initial: true), outputIsMusicApp: { true }, fence: fenceFor(dir), owner: owner,
            makeMusic: { _ in music },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { token in
                SourceRateFollow(token: token, control: c, offered: true, routeFollow: reporter,
                                 now: { clock.t }, sleep: { clock.t += $0 })
            },
            post: { _ in }, reporter: reporter, now: { clock.t })
    }

    func testTheFirstSoundStartOfARouteTellsSpanDACBeforeItsFirstPrepareAndOnlyOnce() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)
        let p = player(dir: dir, wire: wire, reporter: r, music: FakeMusic())
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(Array(wire.ops.prefix(2)), [sourceRateFollowOp, sourcePrepareRateOp],
                       "the record of the rate before must precede SpanDAC's first write")
        XCTAssertEqual(wire.requests[0]["on"] as? Bool, true)
        XCTAssertEqual(wire.requests[0]["fence"] as? Int, wire.requests[1]["fence"] as? Int,
                       "under the transition's own fence")
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 1, "the second song does not ask again")
    }

    func testATransitionOfAProcessWithNoReporterSendsExactlyWhatItAlwaysSent() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let p = player(dir: dir, wire: wire, reporter: nil, music: FakeMusic())
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(wire.ops, [sourcePrepareRateOp, sourceConfirmRateOp])
    }

    func testAStartReportsTheSongWithItsIdentityAndItsRate() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic())
        _ = playID(p, "AAAAAAAAAAAAAAA1", .play, subject: RouteSubject(title: "Aja", artist: "Steely Dan", album: "Aja", durationMS: 477_000))
        let report = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).first)
        XCTAssertEqual(report["state"] as? String, "playing")
        XCTAssertEqual(report["persistent_id"] as? String, "AAAAAAAAAAAAAAA1")
        XCTAssertEqual(report["database_id"] as? Int, 7)
        XCTAssertEqual(report["title"] as? String, "Aja")
        XCTAssertEqual(report["artist"] as? String, "Steely Dan")
        XCTAssertEqual(report["duration_ms"] as? Int, 477_000)
        XCTAssertEqual(report["position_ms"] as? Int, 0)
        XCTAssertEqual(report["rate_outcome"] as? String, "own_rate")
        XCTAssertEqual(report["delivered_hz"] as? Int, 96_000)
        XCTAssertEqual(report["target_hz"] as? Int, 96_000)
        XCTAssertEqual(report["fence"] as? Int, 1)
    }

    func testTheCLIRunnerSendsOnBeforeItsFirstPrepareAndReportsEachSong() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)
        let clock = Clock()
        let music = FakeMusic()
        let p = player(dir: dir, wire: wire, reporter: r, music: music, owner: "runner", clock: clock)
        let ids = ["AAAAAAAAAAAAAAA1", "BBBBBBBBBBBBBBB2", "CCCCCCCCCCCCCCC3"]
        let store = AppQueueStore()
        store.set(runQueueAppQueue(ids: ids, label: "Mixtape"))
        // Music as the runner's wait reads it: each song playing, then stopped at its end.
        final class Watcher: RunQueueWatching {
            let music: FakeMusic
            var plays = 0, polls = 0
            init(_ music: FakeMusic) { self.music = music }
            func musicIsRunning() -> Bool { true }
            func readPlayback() -> RunQueuePlayback? {
                if music.played.count != plays { plays = music.played.count; polls = 0 }
                polls += 1
                let pid = music.state.persistentID
                switch polls {
                case 1: return RunQueuePlayback(state: .playing, persistentID: pid, position: 10, duration: 200)
                case 2: return RunQueuePlayback(state: .playing, persistentID: pid, position: 199, duration: 200)
                default: return RunQueuePlayback(state: .stopped, persistentID: pid, position: 0, duration: 200)
                }
            }
        }
        let runner = RunQueueRunner(queue: store, player: p, route: MacDACRouteState(initial: true),
                                    routeStillChosen: { true }, watcher: Watcher(music),
                                    sleep: { clock.t += $0 }, now: { clock.t },
                                    pollInterval: 1, startGracePolls: 3, maxUnreadablePolls: 3, maxNotStarted: 3,
                                    maxLifetime: 10_000)
        XCTAssertEqual(runner.run(), .finished)
        XCTAssertEqual(music.played, ids)
        XCTAssertEqual(Array(wire.ops.prefix(2)), [sourceRateFollowOp, sourcePrepareRateOp],
                       "a CLI play on the route records the DAC's rate too")
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 1)
        let reported = wire.requests(for: sourceNowPlayingOp).compactMap { $0["persistent_id"] as? String }
        XCTAssertEqual(reported, ids, "one report per song, in order")
    }

    // MARK: the poller's look at Music

    private func observed(_ p: MacRoutePlayer, _ outcome: PollOutcome) { p.observePlayback(outcome) }

    private func np(_ track: String, state: String = "playing", position: Int, duration: Int = 200) -> PollOutcome {
        .active(NowPlayingState(track: track, artist: "Steely Dan", album: "Aja", duration: duration,
                                position: position, state: state))
    }

    func testThePollerReportsAChangeAndNotATick() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let clock = Clock()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic(), clock: clock)
        _ = playID(p, "AAAAAAAAAAAAAAA1", .play, subject: RouteSubject(title: "Aja"))
        let before = wire.requests(for: sourceNowPlayingOp).count
        XCTAssertEqual(before, 1)

        clock.t += 1; observed(p, np("Aja", position: 1))
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, before,
                       "the song's start was reported by its transition: the first look agrees with it")
        clock.t += 1; observed(p, np("Aja", position: 2))
        clock.t += 1; observed(p, np("Aja", position: 3))
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, before, "ticks change nothing")

        clock.t += 1; observed(p, np("Aja", state: "paused", position: 4))
        var last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["state"] as? String, "paused")
        XCTAssertEqual(last["position_ms"] as? Int, 4_000)
        XCTAssertEqual(last["persistent_id"] as? String, "AAAAAAAAAAAAAAA1", "the transition's identity follows the song")
        XCTAssertEqual(last["delivered_hz"] as? Int, 96_000)

        clock.t += 1; observed(p, np("Aja", state: "playing", position: 4))
        XCTAssertEqual((wire.requests(for: sourceNowPlayingOp).last)?["state"] as? String, "playing", "resumed")

        let count = wire.requests(for: sourceNowPlayingOp).count
        clock.t += 1; observed(p, np("Aja", position: 5))
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, count)
        clock.t += 1; observed(p, np("Aja", position: 150))
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, count + 1, "a seek is reported")
        XCTAssertEqual((wire.requests(for: sourceNowPlayingOp).last)?["position_ms"] as? Int, 150_000)

        clock.t += 1; observed(p, np("Peg", position: 0))
        last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["title"] as? String, "Peg")
        XCTAssertNil(last["persistent_id"], "a song someone else started in Music never inherits the transition's identity")
        XCTAssertNil(last["delivered_hz"])

        clock.t += 1; observed(p, .stopped)
        last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["state"] as? String, "stopped")
        XCTAssertNil(last["title"])
        let n = wire.requests(for: sourceNowPlayingOp).count
        observed(p, .unavailable)
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, n, "an unreadable poll is not a state")
    }

    func testThePollerReportsNothingOffTheRoute() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let off = MacRoutePlayer(
            route: MacDACRouteState(initial: false), outputIsMusicApp: { true }, fence: fenceFor(dir),
            makeMusic: { _ in FakeMusic() }, resolvePersistentID: { _, _ in nil },
            makeFollow: { _ in fatalError("no transition off the route") }, post: { _ in },
            reporter: reporter(wire))
        off.observePlayback(np("Aja", position: 1))
        XCTAssertTrue(wire.requests.isEmpty)
    }

    func testASongStartedWithNoNameTakesTheTitleOfTheFirstLookAndKeepsItsIdentity() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let clock = Clock()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic(), clock: clock)
        _ = playID(p, "AAAAAAAAAAAAAAA1", .play)
        clock.t += 1; observed(p, np("Aja", position: 1))
        var last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["persistent_id"] as? String, "AAAAAAAAAAAAAAA1")
        clock.t += 1; observed(p, np("Aja", state: "paused", position: 2))
        last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["persistent_id"] as? String, "AAAAAAAAAAAAAAA1")
        clock.t += 1; observed(p, np("Other", position: 0))
        last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertNil(last["persistent_id"])
    }

    // MARK: coalescing

    func testASlowSpanDACGetsTheLatestReportNotABacklog() throws {
        let wire = Wire(); wire.script = fullScript()
        var queued: [() -> Void] = []
        let r = MacRouteFollowReporter(control: control(wire), schedule: { queued.append($0) })
        for position in 1...5 {
            r.report(SourceNowPlayingReport(fence: 1, state: .playing, persistentID: "A", positionMS: position))
        }
        XCTAssertEqual(queued.count, 1, "one drain is scheduled while one is waiting")
        queued.removeFirst()()
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).compactMap { $0["position_ms"] as? Int }, [5])
    }

    // MARK: structure

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The Shell, the poller and the runner are not unit-constructible, so their
    /// wiring is pinned by reading: the route chosen, restored and left reach the
    /// reporter; the poller feeds it; the runner's reporter is the transition's.
    func testTheShellThePollerAndTheRunnerAreWiredToTheReporter() throws {
        let shell = try source("Sources/TUI/Shell/Shell.swift")
        XCTAssertTrue(shell.contains("macRouteState.set(true)\n                macRoute.routeChanged(on: true)"),
                      "the Mac row chosen")
        XCTAssertTrue(shell.contains("macRouteState.set(false)\n                macRoute.routeChanged(on: false)"),
                      "every way of leaving the route (the MusicTUI row, a speaker toggle, a network SpanDAC)")
        XCTAssertTrue(shell.contains("if macRouteState.chosen { macRoute.routeChanged(on: true) }"),
                      "a route restored at launch")
        let scene = try source("Sources/TUI/Shell/SpeakersScene.swift")
        XCTAssertTrue(scene.contains("onMacRouteOff?()"), "leaveMacDACRoute is the one place the route is left")
        XCTAssertTrue(try source("Sources/TUI/Shell/PlaybackPoller.swift")
            .contains("appQueue.macRoute?.observePlayback(polled)"))
        let runner = try source("Sources/Commands/RunQueueCommand.swift")
        XCTAssertTrue(runner.contains("routeFollow: reporter"))
        XCTAssertTrue(runner.contains("reporter: reporter)"))
        XCTAssertTrue(try source("Sources/TUI/MacRoutePlayer.swift").contains("routeFollow: reporter"),
                      "the TUI's transition shares the process's reporter")
    }
}

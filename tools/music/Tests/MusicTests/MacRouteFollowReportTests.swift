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
        func readPlayerState() -> RatePlayerState? {
            let shown = state
            // A playing stream advances between reads (the stream-up proof).
            if state.state == .playing {
                state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position + 0.5)
            }
            return shown
        }
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
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true }, fence: fenceFor(dir), owner: owner,
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

    /// Fix round 1, finding 7 (client half): when `slice.rateFollow on` could not be
    /// confirmed, SpanDAC has no recorded rate to restore, so NO rate is written
    /// (no prepare, no correction), but the song still plays (never refused), the
    /// follow is not marked confirmed, and the next play asks again BEFORE its prepare.
    func testAFollowOnThatCouldNotBeConfirmedWritesNoRateButStillPlaysAndIsRetried() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire()
        let full = fullScript()
        wire.script = { body in
            if body["op"] as? String == sourceRateFollowOp { throw SourceAppError.timedOut }
            // The confirm would ask for a correction, which is a rate write too.
            if body["op"] as? String == sourceConfirmRateOp {
                return self.rateAnswer(body["fence"] as? Int ?? 0, "correct", step: 1, target: 96000)
            }
            return try full(body)
        }
        let r = reporter(wire)
        let music = FakeMusic()
        let p = player(dir: dir, wire: wire, reporter: r, music: music)

        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(music.played, ["AAAAAAAAAAAAAAA1"], "the song was refused")
        XCTAssertFalse(wire.ops.contains(sourcePrepareRateOp), "a rate was written with no recorded rate to restore")
        XCTAssertFalse(wire.requests.contains { $0["step"] as? Int == 2 }, "a correction wrote a rate with no recorded rate to restore")
        XCTAssertNil(r.confirmed, "a failed follow-on was marked confirmed")
        XCTAssertEqual(p.evidenceLine, "DAC rate switch unconfirmed \u{00B7} codec unknown",
                       "the line says the switch was not made")

        wire.script = full
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 2, "follow-on was not retried")
        let followAt = try XCTUnwrap(wire.ops.lastIndex(of: sourceRateFollowOp))
        let prepareAt = try XCTUnwrap(wire.ops.firstIndex(of: sourcePrepareRateOp))
        XCTAssertLessThan(followAt, prepareAt, "the retry must precede the next prepare")
        XCTAssertEqual(r.confirmed, true)
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

    // MARK: controller addition: SpanDAC lost its restore record

    private func status(following: Bool?) -> SourceRateFollowStatus {
        SourceRateFollowStatus(fence: 1, dacRateHz: 96000, write: .idle, startedFence: 1, rateSeq: 1, moved: nil,
                               following: following, followedUID: nil, restorable: nil)
    }

    /// A status that says SpanDAC holds no restore record (it restarted, or its
    /// record failed) clears the confirmed-on latch, so the next play re-sends
    /// follow-on BEFORE its prepare. True or unknown (an older SpanDAC) changes nothing.
    func testAStatusSayingNotFollowingReSendsFollowOnBeforeTheNextPrepare() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)
        let p = player(dir: dir, wire: wire, reporter: r, music: FakeMusic())
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(r.confirmed, true)

        p.noteRateStatus(status(following: true))
        p.noteRateStatus(status(following: nil))
        XCTAssertEqual(r.confirmed, true, "true or unknown must change nothing")

        p.noteRateStatus(status(following: false))
        XCTAssertNil(r.confirmed, "SpanDAC holds no record: the latch must clear")

        let before = wire.ops.count
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        let after = Array(wire.ops.dropFirst(before))
        XCTAssertEqual(Array(after.prefix(2)), [sourceRateFollowOp, sourcePrepareRateOp],
                       "follow-on must be re-sent before the next prepare")
        XCTAssertEqual(r.confirmed, true)
    }

    // MARK: fix round 1, finding 8 and S10: the station and the end

    /// A station on the route reports what is playing, like a song does: the Mac
    /// screen must not keep showing the song before it.
    func testAStationOnTheRouteReportsItselfToTheMacScreen() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic())
        let outcome = try p.playStation(start: {}, subject: RouteSubject(title: "Apple Music 1"))
        XCTAssertEqual(outcome, .played(line: "Radio"))
        let report = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(report["state"] as? String, "playing")
        XCTAssertEqual(report["title"] as? String, "Apple Music 1")
        XCTAssertNil(report["persistent_id"], "a station has no song identity")
        XCTAssertEqual(report["rate_outcome"] as? String, "quiet")
        XCTAssertEqual(report["fence"] as? Int, try p.fence.current())
    }

    /// Quitting after playing on the route tells the Mac screen nothing is
    /// playing from here any more (best effort, under the fence the process holds).
    func testQuittingAfterAPlayOnTheRouteSendsNowPlayingNone() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic())
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        p.shutdown(wait: 0)
        let last = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(last["state"] as? String, "none")
        XCTAssertEqual(last["fence"] as? Int, try p.fence.current(), "no fence was taken to say it")
    }

    /// A process that never played on the route, or whose play was overtaken by a
    /// newer command, says nothing on its way out: the screen is the newer one's.
    func testQuittingSaysNothingWhenThisProcessIsNotTheOneBeingShown() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let idle = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic())
        idle.shutdown(wait: 0)
        XCTAssertEqual(wire.requests(for: sourceNowPlayingOp).count, 0, "never played here")

        let first = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic(), owner: "first")
        XCTAssertEqual(playID(first, "AAAAAAAAAAAAAAA1", .play), .played)
        let before = wire.requests(for: sourceNowPlayingOp).count
        let second = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic(), owner: "second")
        XCTAssertEqual(playID(second, "BBBBBBBBBBBBBBB2", .play), .played)     // the newer owner
        first.shutdown(wait: 0)
        let states = wire.requests(for: sourceNowPlayingOp).dropFirst(before).map { $0["state"] as? String }
        XCTAssertEqual(states, ["playing"], "the older process blanked the newer one's screen")
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
            streamWait: .instant, route: MacDACRouteState(initial: false), outputIsMusicApp: { true }, fence: fenceFor(dir),
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

    // MARK: fix round 2, finding 7 (client half): `recorded`

    /// A SpanDAC whose follow ack carries `applied` and, when given, `recorded`.
    private func followScript(applied: Bool, recorded: Bool?) -> ([String: Any]) throws -> String {
        let full = fullScript()
        return { body in
            guard body["op"] as? String == sourceRateFollowOp else { return try full(body) }
            let f = body["fence"] as? Int ?? 0
            var follow: [String: Any] = ["on": body["on"] as? Bool ?? false, "applied": applied]
            if let recorded { follow["recorded"] = recorded }
            return self.json(["ok": true, "rate": ["fence": f, "outcome": "quiet"], "follow": follow])
        }
    }

    /// An ack that applied the follow but did NOT take the record is no permission
    /// to write: the song plays unfollowed ("DAC rate switch unconfirmed"), no
    /// prepare and no correction go out, the latch stays unset, the next play asks again.
    func testAFollowOnThatAppliedButRecordedNothingWritesNoRateAndIsRetried() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire()
        let full = fullScript()
        let notRecorded = followScript(applied: true, recorded: false)
        wire.script = { body in
            if body["op"] as? String == sourceConfirmRateOp {
                return self.rateAnswer(body["fence"] as? Int ?? 0, "correct", step: 1, target: 96000)
            }
            return try notRecorded(body)
        }
        let r = reporter(wire)
        let music = FakeMusic()
        let p = player(dir: dir, wire: wire, reporter: r, music: music)

        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(music.played, ["AAAAAAAAAAAAAAA1"], "the song was refused")
        XCTAssertFalse(wire.ops.contains(sourcePrepareRateOp), "a rate was written with no record taken")
        XCTAssertFalse(wire.requests.contains { $0["step"] as? Int == 2 }, "a correction wrote a rate with no record taken")
        XCTAssertNil(r.confirmed, "an unrecorded follow-on set the latch")
        XCTAssertEqual(p.evidenceLine, "DAC rate switch unconfirmed \u{00B7} codec unknown")

        wire.script = full      // a SpanDAC that records
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 2, "follow-on was not retried")
        let followAt = try XCTUnwrap(wire.ops.lastIndex(of: sourceRateFollowOp))
        let prepareAt = try XCTUnwrap(wire.ops.firstIndex(of: sourcePrepareRateOp))
        XCTAssertLessThan(followAt, prepareAt)
        XCTAssertEqual(r.confirmed, true)
    }

    func testRecordedTrueConfirmsAndAnOlderAckWithoutTheFieldReadsAsApplied() throws {
        for (applied, recorded, expected) in [(true, true, true), (true, nil, true), (false, nil, false),
                                              (false, false, false)] as [(Bool, Bool?, Bool)] {
            let wire = Wire(); wire.script = followScript(applied: applied, recorded: recorded)
            let r = reporter(wire)
            r.ensureOn(fence: 3)
            XCTAssertEqual(r.confirmed == true, expected, "applied \(applied), recorded \(String(describing: recorded))")
        }
    }

    func testTheAckCarriesRecordedAndDecidesFollowOnByIt() throws {
        func ack(_ follow: [String: Any]?, outcome: String = "quiet") throws -> SourceRateFollowAck {
            var reply: [String: Any] = ["rate": ["fence": 5, "outcome": outcome]]
            if let follow { reply["follow"] = follow }
            return try SourceAppControl.rateFollowAck(from: reply, fence: 5)
        }
        XCTAssertEqual(try ack(["on": true, "applied": true, "recorded": true]).recorded, true)
        XCTAssertTrue(try ack(["on": true, "applied": true, "recorded": true]).confirmsFollowOn)
        XCTAssertFalse(try ack(["on": true, "applied": true, "recorded": false]).confirmsFollowOn)
        XCTAssertTrue(try ack(["on": true, "applied": true, "recorded": false]).wasApplied,
                      "applied is still applied; only the follow-on's confirmation needs the record")
        XCTAssertTrue(try ack(["on": true, "applied": true]).confirmsFollowOn, "an older SpanDAC: as before")
        XCTAssertFalse(try ack(["on": true, "applied": false]).confirmsFollowOn)
        XCTAssertFalse(try ack(["on": true, "applied": false, "recorded": true]).confirmsFollowOn)
        XCTAssertFalse(try ack(nil).confirmsFollowOn)
        XCTAssertFalse(try ack(["on": true, "applied": true, "recorded": true], outcome: "superseded").confirmsFollowOn)
    }

    /// Turning follow OFF records nothing: an off that SpanDAC applied is confirmed
    /// whatever `recorded` says.
    func testAnOffIsConfirmedWhateverRecordedSays() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire(); wire.script = followScript(applied: true, recorded: false)
        let r = reporter(wire)
        r.routeChanged(on: false, fence: fence, owner: "tui")
        XCTAssertEqual(r.confirmed, false)
    }

    // MARK: fix round 2, finding 4 (client half): status before the first prepare

    /// SpanDAC restarted after the route was chosen (its restore record is gone)
    /// but this process still holds the confirmed-on latch. The status is read
    /// BEFORE the first prepare of the route session, so follow-on is re-sent
    /// before any rate write, not on a later poll.
    func testTheStatusIsReadBeforeTheFirstPrepareSoARestartedSpanDACGetsFollowOnFirst() throws {
        let dir = OutputLockTestSupport.tempDir(), fence = fenceFor(dir)
        let wire = Wire(); wire.script = fullScript()
        let r = reporter(wire)
        let p = player(dir: dir, wire: wire, reporter: r, music: FakeMusic())
        var readAt: [Int] = []
        p.readRateStatus = { readAt.append(wire.requests.count); return self.status(following: false) }

        r.routeChanged(on: true, fence: fence, owner: "tui")     // route chosen; SpanDAC then "restarts"
        XCTAssertEqual(r.confirmed, true)
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)

        XCTAssertEqual(readAt, [1], "the status was not read once, before the first prepare")
        XCTAssertEqual(wire.requests(for: sourceRateFollowOp).count, 2, "follow-on was not re-sent")
        let secondFollow = try XCTUnwrap(wire.ops.lastIndex(of: sourceRateFollowOp))
        let prepare = try XCTUnwrap(wire.ops.firstIndex(of: sourcePrepareRateOp))
        XCTAssertLessThan(secondFollow, prepare, "follow-on must precede the first rate write")

        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(readAt.count, 1, "only the first prepare of a session reads status first")

        p.routeChanged(on: false)     // a new route session
        p.routeChanged(on: true)
        XCTAssertEqual(playID(p, "CCCCCCCCCCCCCCC3", .advance), .played)
        XCTAssertEqual(readAt.count, 2, "a new route session reads status again before its first prepare")
    }

    /// A status that could not be read tells nothing: the play goes on, and the
    /// next one tries again.
    func testAStatusThatCannotBeReadDoesNotBlockThePlayAndIsTriedAgain() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let p = player(dir: dir, wire: wire, reporter: reporter(wire), music: FakeMusic())
        var reads = 0
        p.readRateStatus = { reads += 1; return nil }
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)
        XCTAssertEqual(reads, 2)
    }

    /// The CLI runner is given the same status reader (it had none), and keeps
    /// looking while it waits, as the poller does.
    func testTheCLIRunnerIsGivenTheStatusReader() throws {
        let runner = try source("Sources/Commands/RunQueueCommand.swift")
        XCTAssertTrue(runner.contains("player.readRateStatus ="), "the runner's player never reads SpanDAC's status")
        XCTAssertTrue(runner.contains("player.refreshRateStatus()"), "the runner's wait never refreshes it")
    }

    // MARK: fix round 2: the departing process and a newer owner

    /// A newer play takes the lease between the ownership check and the fence
    /// read: the old code sent `none` under the NEWER fence and blanked the new
    /// owner's screen. The check and the read are one lock span, so the report
    /// is never sent under a fence this process does not hold.
    func testShutdownNeverSendsNoneUnderANewerOwnersFence() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = fullScript()
        let newer = fenceFor(dir)
        var armed = false
        var acquisitions = 0
        let clock = Clock()
        let racing = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001, clock: {
            // Runs once per uncontended acquisition, before the lock is taken.
            if armed {
                acquisitions += 1
                if acquisitions == 2 { _ = try? newer.begin(.play, owner: "newer") }
            }
            return Date()
        }))
        let c = control(wire)
        let reporter = MacRouteFollowReporter(control: c, schedule: { $0() })
        let p = MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true }, fence: racing, owner: "older",
            makeMusic: { _ in FakeMusic() },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { token in
                SourceRateFollow(token: token, control: c, offered: true, routeFollow: reporter,
                                 now: { clock.t }, sleep: { clock.t += $0 })
            },
            post: { _ in }, reporter: reporter, now: { clock.t })
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .play), .played)
        let ours = try racing.current()
        armed = true
        p.shutdown(wait: 0)
        let none = wire.requests(for: sourceNowPlayingOp).filter { $0["state"] as? String == "none" }
        XCTAssertFalse(none.contains { ($0["fence"] as? Int ?? 0) > ours },
                       "the departing process cleared a newer owner's screen: \(none)")
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

    // MARK: a jump to a hi-res song after a 44.1 kHz one (live check 2026-11-16)

    /// Music right after the jump, as measured: the PREVIOUS stream's rate and a
    /// refused position until the new stream is up.
    private final class JumpMusic: RateMusicControlling {
        var log: [String] = []
        let refusedReads: Int
        private var reads = 0
        private var id: String?
        private var playing = false
        private var pausedAt: TimeInterval?
        init(refusedReads: Int) { self.refusedReads = refusedReads }
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        private var streamUp: Bool { reads > refusedReads }
        func playTrack(persistentID: String) throws { log.append("play"); id = persistentID; playing = true; pausedAt = nil; reads = 0 }
        func pause() throws { log.append("pause"); playing = false; pausedAt = 12 }
        func resume() throws { log.append("resume"); playing = true; pausedAt = nil }
        func seekToStart() throws { log.append("seek0") }
        func readCurrentTrack() -> RateTrackRead? {
            id.map { RateTrackRead(persistentID: $0, databaseID: 7, sampleRateHz: streamUp ? 96000 : 44100) }
        }
        func readPlayerState() -> RatePlayerState? {
            guard let id else { return RatePlayerState(state: .stopped, persistentID: nil, position: 0) }
            if let pausedAt { return RatePlayerState(state: .paused, persistentID: id, position: pausedAt) }
            reads += 1
            return RatePlayerState(state: .playing, persistentID: id,
                                   position: streamUp ? Double(reads - refusedReads) * 0.5 : 0)
        }
    }

    /// The live failure end to end: the DAC is at 44100, the hi-res song's stream
    /// is not up for a long while, and the old single read said 44100 for it, so
    /// SpanDAC said `own_rate` and the line said "44.1 kHz · own rate" over a
    /// 96 kHz song. Now: nothing is claimed that was not measured, the follow-up
    /// confirms the real 96000, SpanDAC asks for a correction, the correction runs
    /// once, and the line and the report carry the song's own rate.
    func testAJumpToAHiResSongNeverKeepsThePreviousStreamsRateOnTheLineOrInTheReport() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(clock)
        var dacHz = 44100
        wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourceRateFollowOp, _):
                return self.json(["ok": true, "rate": ["fence": f, "outcome": "quiet"],
                                  "follow": ["on": body["on"] as? Bool ?? false, "applied": true, "recorded": true]])
            case (sourceNowPlayingOp, _):
                return self.json(["ok": true, "now_playing": ["accepted": true, "fence": f]])
            case (sourcePrepareRateOp, 2):
                dacHz = body["rate_hz"] as? Int ?? dacHz
                return self.rateAnswer(f, "settled", step: 2, target: dacHz)
            case (sourcePrepareRateOp, _):
                return self.rateAnswer(f, "unknown_rate", step: 0)       // an uncached hi-res song
            case (sourceConfirmRateOp, _):
                let delivered = body["delivered_hz"] as? Int
                var rate: [String: Any] = ["fence": f, "rate_seq": 1, "step": 1, "dac_rate_hz": dacHz,
                                           "outcome": delivered == dacHz ? "own_rate" : "correct"]
                if let delivered { rate["target_hz"] = delivered }
                return self.json(["ok": true, "rate": rate])
            default: return self.rateAnswer(f, "quiet")
            }
        }
        let r = reporter(wire)
        let music = JumpMusic(refusedReads: 40)       // outlasts the first confirm, not the follow-up
        let c = control(wire)
        let p = MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true },
            fence: fenceFor(dir), owner: "tui", makeMusic: { _ in music },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { token in
                SourceRateFollow(token: token, control: c, offered: true, routeFollow: r,
                                 now: { clock.t }, sleep: { clock.t += $0 })
            },
            post: { _ in }, reporter: r, now: { clock.t })
        var pending: (() -> Void)?
        p.runFollowUp = { pending = $0 }

        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .jump, subject: RouteSubject(title: "Time Moves Slow")), .played)
        let line = try XCTUnwrap(p.evidenceLine)
        XCTAssertFalse(line.contains("44.1"), "the previous stream's rate is on the line: \(line)")
        XCTAssertTrue(line.contains("rate unknown"), line)
        XCTAssertEqual(wire.requests(for: sourceConfirmRateOp).count, 0, "a rate nobody measured for this song was sent")
        let started = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertNil(started["delivered_hz"], "the start's report claims a rate")
        XCTAssertNotNil(pending, "no follow-up was scheduled")

        pending?()
        let confirms = wire.requests(for: sourceConfirmRateOp).map { $0["delivered_hz"] as? Int }
        XCTAssertEqual(confirms.first, 96000, "the follow-up confirmed another stream's rate")
        XCTAssertEqual(music.count("pause"), 1)
        XCTAssertEqual(music.count("resume"), 1)
        XCTAssertEqual(wire.requests(for: sourcePrepareRateOp).filter { $0["step"] as? Int == 2 }.count, 1)
        let after = try XCTUnwrap(p.evidenceLine)
        XCTAssertFalse(after.contains("44.1"), after)
        XCTAssertTrue(after.contains("96") && after.contains("own rate"), after)

        // The poller's next look reports the song with its own rate.
        p.observePlayback(.active(NowPlayingState(track: "Time Moves Slow", artist: "", album: "", duration: 200,
                                                  position: 15, state: "playing")))
        let report = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(report["delivered_hz"] as? Int, 96000)
        XCTAssertEqual(report["rate_outcome"] as? String, "corrected")
    }

    /// Music on the CLI jump of the 2026-11-17 live check: playing and advancing at
    /// once (the stream proof passes), the previous song's rate for `staleFor`
    /// seconds more, then the rate of the stream the decoder opened.
    private final class LateJumpMusic: RateMusicControlling {
        var log: [String] = []
        let now: () -> TimeInterval
        let staleFor: TimeInterval
        private var id: String?
        private var startedAt: TimeInterval = 0
        private var pausedAt: TimeInterval?
        init(now: @escaping () -> TimeInterval, staleFor: TimeInterval = 1) { self.now = now; self.staleFor = staleFor }
        func count(_ s: String) -> Int { log.filter { $0 == s }.count }
        func playTrack(persistentID: String) throws { log.append("play"); id = persistentID; startedAt = now(); pausedAt = nil }
        func pause() throws { log.append("pause"); pausedAt = now() - startedAt }
        func resume() throws {
            log.append("resume")
            if let pausedAt { startedAt = now() - pausedAt }
            pausedAt = nil
        }
        func seekToStart() throws { log.append("seek0"); startedAt = now() }
        func readCurrentTrack() -> RateTrackRead? {
            id.map { RateTrackRead(persistentID: $0, databaseID: 7, sampleRateHz: now() - startedAt >= staleFor ? 96000 : 44100) }
        }
        func readPlayerState() -> RatePlayerState? {
            guard let id else { return RatePlayerState(state: .stopped, persistentID: nil, position: 0) }
            if let pausedAt { return RatePlayerState(state: .paused, persistentID: id, position: pausedAt) }
            return RatePlayerState(state: .playing, persistentID: id, position: now() - startedAt)
        }
    }

    /// Finding 3, end to end through the player both the TUI and the CLI runner
    /// use: the stream proof passes at once (position advancing), the first read is
    /// the previous song's 44100 and SpanDAC says `own_rate` for it; Music opens the
    /// 96000 stream a moment later. The settle re-read (the follow-up the player
    /// schedules for every start) confirms the real rate, the correction runs once,
    /// and the line and the report carry 96 kHz.
    func testAJumpWhoseStreamLooksUpBeforeItsRateIsReadIsCorrectedByTheSettleReRead() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(clock)
        var dacHz = 44100
        wire.script = { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourceRateFollowOp, _):
                return self.json(["ok": true, "rate": ["fence": f, "outcome": "quiet"],
                                  "follow": ["on": body["on"] as? Bool ?? false, "applied": true, "recorded": true]])
            case (sourceNowPlayingOp, _):
                return self.json(["ok": true, "now_playing": ["accepted": true, "fence": f]])
            case (sourcePrepareRateOp, 2):
                dacHz = body["rate_hz"] as? Int ?? dacHz
                return self.rateAnswer(f, "settled", step: 2, target: dacHz)
            case (sourcePrepareRateOp, _):
                return self.rateAnswer(f, "same_rate", step: 0, target: 44100)
            case (sourceConfirmRateOp, _):
                let delivered = body["delivered_hz"] as? Int
                var rate: [String: Any] = ["fence": f, "rate_seq": 1, "step": 1, "dac_rate_hz": dacHz,
                                           "outcome": delivered == dacHz ? "own_rate" : "correct"]
                if let delivered { rate["target_hz"] = delivered }
                return self.json(["ok": true, "rate": rate])
            default: return self.rateAnswer(f, "quiet")
            }
        }
        let r = reporter(wire)
        let music = LateJumpMusic(now: { clock.t })
        let c = control(wire)
        let p = MacRoutePlayer(
            streamWait: RateStreamWait(verifyReads: 3, sleep: { clock.t += $0 }),
            route: MacDACRouteState(initial: true), outputIsMusicApp: { true },
            fence: fenceFor(dir), owner: "tui", makeMusic: { _ in music },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { token in
                SourceRateFollow(token: token, control: c, offered: true, routeFollow: r,
                                 now: { clock.t }, sleep: { clock.t += $0 })
            },
            post: { _ in }, reporter: r, now: { clock.t })
        var pending: (() -> Void)?
        p.runFollowUp = { pending = $0 }

        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .jump, subject: RouteSubject(title: "Time Moves Slow")), .played)
        XCTAssertEqual(wire.requests(for: sourceConfirmRateOp).map { $0["delivered_hz"] as? Int }, [44100],
                       "the first read is the previous stream's, as measured")
        XCTAssertNotNil(pending, "a start whose rate was read from a stream only judged up has no follow-up")

        pending?()
        XCTAssertEqual(wire.requests(for: sourceConfirmRateOp).map { $0["delivered_hz"] as? Int }.dropFirst().first, 96000,
                       "the rate Music opened was never confirmed")
        XCTAssertEqual(dacHz, 96000, "the DAC stayed under the song")
        XCTAssertEqual(music.count("pause"), 1)
        XCTAssertEqual(music.count("resume"), 1)
        XCTAssertEqual(wire.requests(for: sourcePrepareRateOp).filter { $0["step"] as? Int == 2 }.count, 1)
        let after = try XCTUnwrap(p.evidenceLine)
        XCTAssertFalse(after.contains("44.1"), after)
        XCTAssertTrue(after.contains("96") && after.contains("own rate"), after)

        p.observePlayback(.active(NowPlayingState(track: "Time Moves Slow", artist: "", album: "", duration: 200,
                                                  position: 15, state: "playing")))
        let report = try XCTUnwrap(wire.requests(for: sourceNowPlayingOp).last)
        XCTAssertEqual(report["delivered_hz"] as? Int, 96000)
        XCTAssertEqual(report["rate_outcome"] as? String, "corrected")
    }

    /// The follow-up's answer belongs to the song it was made for: a newer start
    /// keeps its own line.
    func testAFollowUpForAnOlderStartNeverOverwritesANewerSongsLine() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(clock)
        wire.script = fullScript()
        let r = reporter(wire)
        let music = JumpMusic(refusedReads: 40)
        let c = control(wire)
        let p = MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true },
            fence: fenceFor(dir), owner: "tui", makeMusic: { _ in music },
            resolvePersistentID: { _, position in String(format: "%016llX", UInt64(position)) },
            makeFollow: { token in
                SourceRateFollow(token: token, control: c, offered: true, routeFollow: r,
                                 now: { clock.t }, sleep: { clock.t += $0 })
            },
            post: { _ in }, reporter: r, now: { clock.t })
        var pending: [() -> Void] = []
        p.runFollowUp = { pending.append($0) }
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1", .jump), .played)
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .next), .played)
        let before = p.evidenceLine
        let confirmsBefore = wire.requests(for: sourceConfirmRateOp).count
        XCTAssertEqual(pending.count, 2)
        pending[0]()                    // the OLDER start's follow-up, its fence long moved
        XCTAssertEqual(p.evidenceLine, before, "an older song's re-check changed the line of the newer one")
        XCTAssertEqual(wire.requests(for: sourceConfirmRateOp).count, confirmsBefore,
                       "a re-check for a superseded start sent a confirm")
        pending[1]()                    // the newer one's own follow-up still runs
        XCTAssertEqual(wire.requests(for: sourceConfirmRateOp).count, confirmsBefore + 1)
    }
}

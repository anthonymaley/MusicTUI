// tools/music/Tests/MusicTests/RateAwareTransitionTests.swift
//
// The per-track transition (mac-route-plan.md section 3.3 and the "Appendix:
// rate transaction protocol", M1 to M5; score step P3), against the real fence
// files in a temp directory, a fixture SpanDAC with a fake clock, and a fake
// Music.app. Two `RateFence` instances stand in for two processes (the TUI and
// the CLI runner); a newer command is injected at the exact point a test names
// (inside a SpanDAC reply, inside the correction), so every ordering is
// deterministic and nothing sleeps.
//
// No audio, no AppleScript, no socket, no keychain, and never `~/.config/music`.
import XCTest
@testable import music

final class RateAwareTransitionTests: XCTestCase {

    // MARK: support

    private final class Clock {
        var t: TimeInterval = 0
        var sleeps: [TimeInterval] = []
    }

    /// The one scripted SpanDAC, with a record of each request and of the
    /// timeout each was sent with (the Mac's rate sender is the only transport
    /// that honours one).
    private final class Wire {
        let clock: Clock
        var requests: [(at: TimeInterval, body: [String: Any], timeout: TimeInterval?)] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        /// What a request that times out costs the clock; nil is the timeout the
        /// request was sent with (2.5 s where none was).
        var timeoutCost: TimeInterval?
        /// Events shared with the fake Music, in order.
        var events: Events?
        init(_ clock: Clock) { self.clock = clock }
        var ops: [String] { requests.compactMap { $0.body["op"] as? String } }
    }

    private final class Events { var log: [String] = [] }

    private func control(_ wire: Wire) -> SourceAppControl {
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                wire.requests.append((wire.clock.t, body, timeout))
                wire.events?.log.append("spandac:\(Self.label(body))")
                do { return try wire.script(body) } catch SourceAppError.timedOut {
                    wire.clock.t += wire.timeoutCost ?? timeout ?? 2.5
                    throw SourceAppError.timedOut
                }
            }
        }
        var c = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        c.rateSender = { transport($0) }
        return c
    }

    private static func label(_ body: [String: Any]) -> String {
        let op = (body["op"] as? String ?? "?").replacingOccurrences(of: "slice.", with: "")
        if let step = body["step"] as? Int { return "\(op)\(step)" }
        return op
    }

    private func answer(_ fence: Int, _ outcome: String, seq: Int? = 1, prior: Bool = false,
                        step: Int? = nil, target: Int? = nil) -> String {
        var rate: [String: Any] = ["fence": fence, "outcome": outcome]
        if let seq { rate["rate_seq"] = seq }
        if prior { rate["prior_unresolved"] = true }
        if let step { rate["step"] = step }
        if let target { rate["target_hz"] = target }
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "rate": rate])
        return String(decoding: data, as: UTF8.self)
    }

    /// Music.app, faked. Every call is logged with the events of the wire.
    private final class FakeMusic: RateMusicControlling {
        let events: Events
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        var track: RateTrackRead?
        var deliveredHz: Int? = 96000
        var playError: Error?
        var pauseError: Error?
        var resumeError: Error?
        var seekError: Error?
        /// A pause that Music does not show (another player took over first).
        var pauseDoesNotStick = false
        var stateUnreadable = false
        var position: TimeInterval = 12.0
        init(_ events: Events) { self.events = events }

        var log: [String] { events.log.filter { $0.hasPrefix("music:") } }
        func count(_ name: String) -> Int { log.filter { $0 == "music:" + name }.count }

        func playTrack(persistentID: String) throws {
            events.log.append("music:play")
            if let playError { throw playError }
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 0)
            track = RateTrackRead(persistentID: persistentID, databaseID: 7, sampleRateHz: deliveredHz)
        }
        func pause() throws {
            events.log.append("music:pause")
            if let pauseError { throw pauseError }
            if !pauseDoesNotStick { state = RatePlayerState(state: .paused, persistentID: state.persistentID, position: position) }
        }
        func resume() throws {
            events.log.append("music:resume")
            if let resumeError { throw resumeError }
            state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: state.position)
        }
        func seekToStart() throws {
            events.log.append("music:seek0")
            if let seekError { throw seekError }
            state = RatePlayerState(state: state.state, persistentID: state.persistentID, position: 0)
        }
        func readCurrentTrack() -> RateTrackRead? {
            events.log.append("music:readTrack")
            return track
        }
        func readPlayerState() -> RatePlayerState? {
            events.log.append("music:readState")
            return stateUnreadable ? nil : state
        }
    }

    /// One process: a fence on `dir`, its own owner and wire, a transition.
    private struct Process {
        let fence: RateFence
        let owner: String
        let wire: Wire
        let music: FakeMusic
        let transition: RateAwareTransition
    }

    private func process(_ dir: String, owner: String, clock: Clock = Clock(), events: Events = Events(),
                         music sharedMusic: FakeMusic? = nil, offered: Bool = true) -> Process {
        let fence = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let wire = Wire(clock)
        wire.events = events
        let music = sharedMusic ?? FakeMusic(events)
        let transition = RateAwareTransition(
            fence: fence, owner: owner, music: music,
            makeFollow: { token in
                SourceRateFollow(token: token, control: self.control(wire), offered: offered,
                                 now: { clock.t },
                                 sleep: { clock.sleeps.append($0); clock.t += $0 })
            },
            now: { clock.t })
        return Process(fence: fence, owner: owner, wire: wire, music: music, transition: transition)
    }

    private func song(_ id: String = "AAA", command: RateCommand = .advance,
                      isCurrent: @escaping () -> Bool = { true }) -> RateTransitionPlan {
        RateTransitionPlan(command: command, sound: .track(persistentID: id, catalogID: nil),
                           dacUID: "ssl", isCurrent: isCurrent)
    }

    /// The common SpanDAC: settles a prepare, answers a confirm as told, and
    /// answers a correction as told.
    private func standardScript(_ wire: Wire, prepare: String = "settled", confirm: String = "own_rate",
                                correction: String = "settled", target: Int? = 96000,
                                fence: @escaping () -> Int) -> ([String: Any]) throws -> String {
        { body in
            let f = body["fence"] as? Int ?? fence()
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2): return self.answer(f, correction, step: 2, target: target)
            case (sourcePrepareRateOp, _): return self.answer(f, prepare, step: 0, target: target)
            case (sourceConfirmRateOp, _): return self.answer(f, confirm, step: 1, target: target)
            default: return self.answer(f, "quiet")
            }
        }
    }

    private func played(_ result: RateTransitionResult, file: StaticString = #filePath, line: UInt = #line) -> RateTransitionPlayed? {
        guard case .played(let p) = result else { XCTFail("not played: \(result)", file: file, line: line); return nil }
        return p
    }

    private func tempDir() -> String { OutputLockTestSupport.tempDir() }

    // MARK: invalidated plays nothing

    /// A newer command takes the fence while the prepare is out: this transition
    /// revalidates, fails, and plays NOTHING (not even a confirm), and its
    /// result touches no gate.
    func testANewerCommandDuringThePrepareInvalidatesAndPlaysNothing() throws {
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        let other = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        p.wire.script = { body in
            _ = try other.begin(.next, owner: "runner")          // a newer command, mid-prepare
            return self.answer(body["fence"] as? Int ?? 0, "settled", step: 0)
        }
        let result = p.transition.run(song())
        XCTAssertEqual(result, .invalidated)
        XCTAssertNil(result.playOutcome)
        XCTAssertEqual(p.music.count("play"), 0, "an invalidated transition played")
        XCTAssertEqual(p.wire.ops, [sourcePrepareRateOp], "nothing was confirmed after an invalidation")
    }

    /// The rest of the token (generation, index, current track, state) is
    /// checked under the lock too.
    func testTheCallersOwnChecksInvalidateAndPlayNothing() {
        let p = process(tempDir(), owner: "tui")
        var current = true
        let plan = song(isCurrent: { current })
        p.wire.script = { body in current = false; return self.answer(1, "settled", step: 0) }   // the queue moved
        XCTAssertEqual(p.transition.run(plan), .invalidated)
        XCTAssertEqual(p.music.count("play"), 0)
    }

    /// SpanDAC says `superseded` because a newer command's fence reached it, and
    /// the file holds that newer fence: a newer command owns the player, the
    /// answer is not a regression, and nothing plays.
    func testASupersededAnswerWhileANewerFenceHoldsTheFilePlaysNothing() throws {
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        let other = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        p.wire.script = { body in
            _ = try other.begin(.jump, owner: "runner")
            return self.answer(body["fence"] as? Int ?? 0, "superseded", step: 0)
        }
        XCTAssertEqual(p.transition.run(song()), .invalidated)
        XCTAssertEqual(p.music.count("play"), 0)
    }

    // MARK: failed-current plays at the DAC's rate, and the line says why

    /// Every way the rate work can fail while the request is still current: the
    /// song PLAYS, once, and the start line carries the reason. The same table
    /// is the gate test's input.
    private struct FailedCase {
        let name: String
        let offered: Bool
        let script: ([String: Any], Int) throws -> String
        let line: SourceRateStartLine
    }

    private func failedCases() -> [FailedCase] {
        func prepareOnly(_ outcome: String, prior: Bool = false) -> ([String: Any], Int) throws -> String {
            { body, fence in
                self.answer(fence, outcome, prior: prior, step: body["step"] as? Int)
            }
        }
        return [
            FailedCase(name: "not running", offered: true, script: { _, _ in throw SourceAppError.notRunning },
                       line: .unavailable(.notRunning)),
            FailedCase(name: "older SpanDAC (not offered)", offered: false, script: { _, _ in throw SourceAppError.notRunning },
                       line: .notOffered),
            FailedCase(name: "unknown_op", offered: true, script: { _, _ in throw SourceAppError.unsupported(sourcePrepareRateOp) },
                       line: .notOffered),
            FailedCase(name: "not licensed", offered: true, script: { _, _ in throw SourceAppError.unlicensed("no licence") },
                       line: .unavailable(.unlicensed("no licence"))),
            FailedCase(name: "dac_limit", offered: true, script: prepareOnly("dac_limit"), line: .dacLimit),
            FailedCase(name: "unknown_rate", offered: true, script: prepareOnly("unknown_rate"), line: .unknownRate),
            FailedCase(name: "no_dac", offered: true, script: prepareOnly("no_dac"), line: .noDAC),
            FailedCase(name: "unresolved", offered: true, script: prepareOnly("unresolved", prior: true), line: .unconfirmed),
            FailedCase(name: "in_flight to the cap", offered: true, script: prepareOnly("in_flight"), line: .unconfirmed),
            FailedCase(name: "a word from a newer SpanDAC", offered: true, script: prepareOnly("brand_new_word"), line: .unconfirmed),
            FailedCase(name: "silent to the cap", offered: true, script: { _, _ in throw SourceAppError.timedOut }, line: .unconfirmed),
            FailedCase(name: "settled with an older write unproven", offered: true,
                       script: prepareOnly("settled", prior: true), line: .ownRatePriorPending),
            // M4: `superseded` while the file still holds our fence is a lost
            // fence file, not a newer command.
            FailedCase(name: "fence regressed", offered: true, script: prepareOnly("superseded"), line: .regressed),
        ]
    }

    func testEveryFailedButCurrentRequestPlaysOnceAndSaysWhy() throws {
        for c in failedCases() {
            let p = process(tempDir(), owner: "tui", offered: c.offered)
            p.wire.script = { body in try c.script(body, body["fence"] as? Int ?? 1) }
            let result = p.transition.run(song("PID"))
            guard let out = played(result) else { return XCTFail(c.name) }
            XCTAssertEqual(out.startLine, c.line, c.name)
            XCTAssertEqual(p.music.count("play"), 1, "\(c.name): the song must play exactly once")
            XCTAssertEqual(result.playOutcome, true, c.name)
            XCTAssertEqual(out.correction, .notNeeded, "\(c.name): a failed rate never pauses the song")
            XCTAssertEqual(p.music.count("pause"), 0, c.name)
            if !c.offered { XCTAssertEqual(p.wire.requests.count, 0, "\(c.name): nothing is sent to an older SpanDAC") }
        }
    }

    /// The fence file lost (the plan's regression case) on the real files: the
    /// file is gone before this transition begins, so its fence is below
    /// SpanDAC's highest; SpanDAC answers `superseded` and the song plays.
    func testALostFenceFilePlaysAtTheDACsRate() throws {
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        _ = try p.fence.begin(.play, owner: "tui")
        _ = try p.fence.begin(.play, owner: "tui")
        try FileManager.default.removeItem(atPath: dir + "/rate.fence")            // lost
        p.wire.script = { body in self.answer(body["fence"] as? Int ?? 0, "superseded", step: 0) }
        let result = p.transition.run(song())
        XCTAssertEqual(played(result)?.token.fence, 1, "the lost file restarts at 1")
        XCTAssertEqual(played(result)?.startLine, .regressed)
        XCTAssertEqual(p.music.count("play"), 1)
    }

    /// A playing song with no answer ever has no baseline: "unconfirmed" stands
    /// for the whole song (M2).
    func testNoAnswerAtAllMeansNoBaseline() {
        let p = process(tempDir(), owner: "tui")                // every request times out
        let out = played(p.transition.run(song()))
        XCTAssertNil(out?.baseline)
        XCTAssertEqual(out?.startLine, .unconfirmed)
    }

    func testTheBaselineIsTheLastAnswersRateSeqBeforeSound() {
        let p = process(tempDir(), owner: "tui")
        p.wire.script = { body in
            if body["op"] as? String == sourceConfirmRateOp { return self.answer(1, "own_rate", seq: 99, step: 1) }
            return self.answer(1, "settled", seq: 5, step: 0)
        }
        XCTAssertEqual(played(p.transition.run(song()))?.baseline, 5, "a confirm never moves the baseline")
    }

    // MARK: timeout, then rateSettle

    /// The write completes after the caller's 2.5 s: the prepare times out, a
    /// `rateSettle` poll finds `in_flight` and then `settled`, and the song plays
    /// only after that.
    func testATimedOutPrepareIsFollowedByRateSettleAndPlaysAfterSettled() {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        var polls = 0
        p.wire.script = { body in
            switch body["op"] as? String {
            case sourcePrepareRateOp: throw SourceAppError.timedOut
            case sourceRateSettleOp:
                polls += 1
                return self.answer(1, polls < 3 ? "in_flight" : "settled", seq: 8, step: 0)
            default: return self.answer(1, "own_rate", seq: 9, step: 1)
            }
        }
        let out = played(p.transition.run(song()))
        XCTAssertEqual(out?.startLine, .ownRate)
        XCTAssertEqual(events.log, ["spandac:prepareRate0", "spandac:rateSettle0", "spandac:rateSettle0",
                                    "spandac:rateSettle0", "music:play", "music:readTrack", "spandac:confirmRate1"])
        XCTAssertEqual(p.wire.requests[1].at, 2.5, "the first poll follows the 2.5 s reply wait")
    }

    /// Still in flight at the cap: the song plays, at the cap and not after it,
    /// with the unconfirmed line; the confirm that follows may say `correct`.
    func testStillInFlightAtTheCapPlaysAtTheCap() {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = { body in
            switch body["op"] as? String {
            case sourcePrepareRateOp: throw SourceAppError.timedOut
            case sourceRateSettleOp: return self.answer(1, "in_flight", seq: 3, prior: true, step: 0)
            default: return self.answer(1, "own_rate", seq: 3, step: 1)
            }
        }
        let out = played(p.transition.run(song()))
        XCTAssertEqual(out?.startLine, .unconfirmed)
        let playedAt = p.wire.requests.last(where: { $0.body["op"] as? String == sourceRateSettleOp })!
        XCTAssertLessThanOrEqual(playedAt.at, SourceRateFollow.cap)
        let preceding = events.log.prefix(while: { $0 != "music:play" })
        XCTAssertTrue(preceding.allSatisfy { $0.hasPrefix("spandac:") })
    }

    /// The transport is asked for 2.5 s on the prepare and never for longer than
    /// what is left of the 4.5 s cap on a poll, so a silent SpanDAC cannot hold
    /// a sound start past it (the 10 s command transport would).
    func testRateRepliesAreWaitedForNoLongerThanTheCapAllows() {
        let p = process(tempDir(), owner: "tui")                    // silent: each request costs its timeout
        _ = p.transition.run(song())
        let waits = p.wire.requests.prefix(while: { $0.body["op"] as? String != sourceConfirmRateOp })
        XCTAssertEqual(waits.first?.timeout, SourceRateFollow.prepareReplyWait)
        for request in waits {
            XCTAssertLessThanOrEqual(request.at + (request.timeout ?? 99), SourceRateFollow.cap + 0.0001,
                                     "a reply wait ran past the 4.5 s cap")
        }
        XCTAssertTrue(waits.dropFirst().allSatisfy { ($0.timeout ?? 99) <= SourceRateFollow.pollReplyWait })
    }

    func testTheSocketTimeoutIsFractionalAndNeverZero() {
        let t = SourceAppStationSearch.socketTimeval(2.5)
        XCTAssertEqual(t.tv_sec, 2)
        XCTAssertEqual(t.tv_usec, 500_000)
        let zero = SourceAppStationSearch.socketTimeval(0)
        XCTAssertGreaterThan(Double(zero.tv_sec) + Double(zero.tv_usec) / 1e6, 0, "zero means wait forever")
        XCTAssertEqual(SourceRateFollow.replyTimeout(1.0, left: 0.75), 0.75)
        XCTAssertEqual(SourceRateFollow.replyTimeout(1.0, left: -3), 0)
    }

    /// A station (no rate work) announces, waits for quiet, then starts, and
    /// confirms and corrects nothing.
    func testAStartWithNoRateWorkAnnouncesWaitsForQuietThenStarts() {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = { body in
            self.answer(body["fence"] as? Int ?? 0, "quiet", seq: 2)
        }
        let plan = RateTransitionPlan(command: .station, sound: .other(start: { events.log.append("music:station") }))
        let out = played(p.transition.run(plan))
        XCTAssertEqual(events.log, ["spandac:rateFence", "spandac:rateSettle", "music:station"])
        XCTAssertEqual(out?.startLine, .quiet)
        XCTAssertNil(out?.confirm)
        XCTAssertEqual(out?.correction, .notNeeded)
    }

    // MARK: supersession, TUI over runner and runner over TUI

    /// `first` starts a transition and, while its prepare is out, `second` (a
    /// whole other process) begins and plays its own song. Only `second` plays,
    /// `first` is invalidated, and the fences are in order.
    private func supersede(first: String, second: String) throws {
        let dir = tempDir()
        let events = Events()
        let music = FakeMusic(events)
        let a = process(dir, owner: first, events: events, music: music)
        let b = process(dir, owner: second, events: events, music: music)
        var superseded = false
        a.wire.script = { _ in
            if !superseded {
                superseded = true
                _ = self.played(b.transition.run(self.song("SECOND", command: .jump)))
            }
            throw SourceAppError.timedOut
        }
        b.wire.script = standardScript(b.wire, fence: { 2 })

        let older = a.transition.run(self.song("FIRST"))
        XCTAssertEqual(older, .invalidated, "\(first) kept playing over \(second)")
        XCTAssertEqual(music.count("play"), 1)
        XCTAssertEqual(music.state.persistentID, "SECOND")
        XCTAssertEqual(try a.fence.current(), 2)
        XCTAssertEqual(try String(contentsOfFile: dir + "/rate.lease", encoding: .utf8), second)
        // `first` made no confirm: its last SpanDAC message was the prepare it sent
        // (and the polls the cap allows), never a confirm.
        XCTAssertFalse(a.wire.ops.contains(sourceConfirmRateOp))
    }

    func testTheTUISupersedesTheRunner() throws { try supersede(first: "runner", second: "tui") }
    func testTheRunnerSupersedesTheTUI() throws { try supersede(first: "tui", second: "runner") }

    /// A newer command arriving after the play is not this transition's to stop:
    /// it replaces the sound, correctly, as the newer command.
    func testACommandAfterThePlayReplacesItAndTheOlderTransitionStillReportsItsPlay() throws {
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        let other = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        p.wire.script = { body in
            if body["op"] as? String == sourceConfirmRateOp { _ = try other.begin(.next, owner: "runner") }
            return self.answer(body["fence"] as? Int ?? 0, body["op"] as? String == sourceConfirmRateOp ? "own_rate" : "settled")
        }
        let out = played(p.transition.run(song()))
        XCTAssertNotNil(out?.confirm)
        XCTAssertEqual(p.music.count("play"), 1)
    }

    // MARK: confirm: one identity-checked read

    /// The read is discarded when Music's current track is not the transition's
    /// own (the track moved between the play and the read): no confirm goes out
    /// and nothing is corrected.
    func testAConfirmIsNeverSentForATrackThatIsNotTheTransitionsOwn() {
        let events = Events()
        let music = FakeMusic(events)
        let p = process(tempDir(), owner: "tui", events: events, music: music)
        p.wire.script = standardScript(p.wire, confirm: "correct", fence: { 1 })
        // `playTrack` leaves the fake showing OUR track; make the read show another.
        let reader = ReadOverride(music)
        let q = RateAwareTransition(fence: p.fence, owner: "tui", music: reader,
                                    makeFollow: { SourceRateFollow(token: $0, control: self.control(p.wire), offered: true,
                                                                   now: { 0 }, sleep: { _ in }) },
                                    now: { 0 })
        reader.read = RateTrackRead(persistentID: "ANOTHER", databaseID: 3, sampleRateHz: 192000)
        let out = played(q.run(song("AAA")))
        XCTAssertNil(out?.delivered)
        XCTAssertNil(out?.confirm)
        XCTAssertEqual(out?.correction, .notNeeded)
        XCTAssertFalse(p.wire.ops.contains(sourceConfirmRateOp), "a read for another track must be discarded")
        XCTAssertEqual(music.count("pause"), 0)
    }

    /// Music not readable (Automation off): the song plays, nothing is confirmed.
    func testAnUnreadableMusicPlaysAndConfirmsNothing() {
        let p = process(tempDir(), owner: "tui")
        p.wire.script = standardScript(p.wire, fence: { 1 })
        p.music.track = nil
        let reader = ReadOverride(p.music)
        reader.read = nil
        let q = RateAwareTransition(fence: p.fence, owner: "tui", music: reader,
                                    makeFollow: { SourceRateFollow(token: $0, control: self.control(p.wire), offered: true,
                                                                   now: { 0 }, sleep: { _ in }) },
                                    now: { 0 })
        let result = q.run(song())
        XCTAssertEqual(played(result)?.confirm, nil)
        XCTAssertEqual(result.playOutcome, true)
        XCTAssertFalse(p.wire.ops.contains(sourceConfirmRateOp))
    }

    /// Wraps a fake so only the track read is overridden.
    private final class ReadOverride: RateMusicControlling {
        let inner: FakeMusic
        var read: RateTrackRead?
        init(_ inner: FakeMusic) { self.inner = inner }
        func playTrack(persistentID: String) throws { try inner.playTrack(persistentID: persistentID) }
        func pause() throws { try inner.pause() }
        func resume() throws { try inner.resume() }
        func seekToStart() throws { try inner.seekToStart() }
        func readCurrentTrack() -> RateTrackRead? { inner.events.log.append("music:readTrack"); return read }
        func readPlayerState() -> RatePlayerState? { inner.readPlayerState() }
    }

    func testAConfirmThatIsNotACorrectionNeverPausesTheSong() {
        for outcome in ["own_rate", "converted", "delivered_unknown"] {
            let p = process(tempDir(), owner: "tui")
            p.wire.script = standardScript(p.wire, confirm: outcome, fence: { 1 })
            let out = played(p.transition.run(song()))
            XCTAssertEqual(out?.correction, .notNeeded, outcome)
            XCTAssertEqual(p.music.count("pause"), 0, outcome)
            XCTAssertEqual(p.wire.ops.filter { $0 == sourceConfirmRateOp }.count, 1, outcome)
        }
    }

    // MARK: correction and the pause guarantee

    /// A correction setup: the confirm asks for one; `during` runs inside the
    /// correction's own SpanDAC exchange, where a seek, a skip, a play or a
    /// newer command can happen.
    private func correcting(correction: String = "settled", during: @escaping (Process) throws -> Void = { _ in })
        throws -> (Process, Events, RateTransitionResult) {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = { body in
            let fence = body["fence"] as? Int ?? 1
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2):
                try during(p)
                return self.answer(fence, correction, seq: 20, step: 2, target: 96000)
            case (sourcePrepareRateOp, _): return self.answer(fence, "settled", seq: 10, step: 0)
            default: return self.answer(fence, "correct", seq: 11, step: 1, target: 96000)
            }
        }
        let result = p.transition.run(song("AAA"))
        return (p, events, result)
    }

    func testACorrectionPausesCorrectsRestartsFromZeroAndResumesItsOwnPause() throws {
        let (p, events, result) = try correcting()
        let out = played(result)
        XCTAssertEqual(events.log, [
            "spandac:prepareRate0", "music:play", "music:readTrack", "spandac:confirmRate1",
            "music:pause", "music:readState",
            "spandac:prepareRate2",
            "music:readState", "music:seek0", "music:resume",
            "music:readTrack", "spandac:confirmRate1",
        ])
        guard case .resumed(let restarted, _)? = out?.correction else { return XCTFail("\(String(describing: out?.correction))") }
        XCTAssertTrue(restarted)
        XCTAssertEqual(p.music.state.state, .playing)
        XCTAssertEqual(p.music.state.position, 0)
        XCTAssertEqual(out?.baseline, 20, "for a correction the baseline is the correction's answer")
        XCTAssertEqual(p.wire.requests.first(where: { $0.body["step"] as? Int == 2 })?.body["rate_hz"] as? Int, 96000)
    }

    /// A seek seen in Music.app during the correction cancels the resume.
    func testASeekDuringTheCorrectionCancelsTheResume() throws {
        let (p, _, result) = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .paused, persistentID: "AAA", position: p.music.position + 30)
        })
        guard case .stopped(let why, _)? = played(result)?.correction else { return XCTFail("\(result)") }
        XCTAssertEqual(why, .musicSeeked)
        XCTAssertEqual(p.music.count("resume"), 0)
        XCTAssertEqual(p.music.count("seek0"), 0, "a cancelled correction must not move the position either")
    }

    /// A skip seen in Music.app (the paused track is no longer ours).
    func testASkipDuringTheCorrectionCancelsTheResume() throws {
        let (p, _, result) = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .paused, persistentID: "NEXT-SONG", position: 0)
        })
        guard case .stopped(let why, _)? = played(result)?.correction else { return XCTFail("\(result)") }
        XCTAssertEqual(why, .musicSkipped)
        XCTAssertFalse(why.leavesOurPause)
        XCTAssertEqual(p.music.count("resume"), 0)
        XCTAssertEqual(p.music.count("seek0"), 0)
    }

    /// A play pressed in Music.app: it is already playing, there is nothing of
    /// ours to resume, and the follower must not seek it back to 0.
    func testAPlayDuringTheCorrectionCancelsTheResumeAndTheSeek() throws {
        let (p, _, result) = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .playing, persistentID: "AAA", position: p.music.position + 1)
        })
        guard case .stopped(let why, _)? = played(result)?.correction else { return XCTFail("\(result)") }
        XCTAssertEqual(why, .musicPlayed)
        XCTAssertEqual(p.music.count("resume"), 0)
        XCTAssertEqual(p.music.count("seek0"), 0, "the follower dragged a song the person restarted back to 0")
    }

    /// A MusicTUI command (any one moves the fence) during the correction.
    func testACommandDuringTheCorrectionCancelsTheResume() throws {
        var other: RateFence?
        let dir = tempDir()
        let events = Events()
        let p = process(dir, owner: "tui", events: events)
        other = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        p.wire.script = { body in
            let fence = body["fence"] as? Int ?? 1
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2):
                _ = try other!.begin(.pause, owner: "runner")
                return self.answer(fence, "superseded", step: 2)
            case (sourcePrepareRateOp, _): return self.answer(fence, "settled", step: 0)
            default: return self.answer(fence, "correct", step: 1, target: 96000)
            }
        }
        let out = played(p.transition.run(song("AAA")))
        guard case .stopped(let why, _)? = out?.correction else { return XCTFail("\(String(describing: out))") }
        XCTAssertEqual(why, .newerCommand)
        XCTAssertEqual(p.music.count("resume"), 0)
        XCTAssertEqual(p.music.count("seek0"), 0)
    }

    func testTheCallersChecksChangingDuringTheCorrectionCancelTheResume() throws {
        var current = true
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = { body in
            let fence = body["fence"] as? Int ?? 1
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2): current = false; return self.answer(fence, "settled", step: 2)
            case (sourcePrepareRateOp, _): return self.answer(fence, "settled", step: 0)
            default: return self.answer(fence, "correct", step: 1, target: 96000)
            }
        }
        let out = played(p.transition.run(song("AAA", isCurrent: { current })))
        guard case .stopped(let why, _)? = out?.correction else { return XCTFail("\(String(describing: out))") }
        XCTAssertEqual(why, .newerCommand)
        XCTAssertEqual(p.music.count("resume"), 0)
    }

    /// A correction that ended after the 3 s window is not resumed: our pause
    /// stands, and the line says so.
    func testACorrectionThatTakesLongerThanThreeSecondsIsNotResumed() throws {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = { body in
            let fence = body["fence"] as? Int ?? 1
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2): p.wire.clock.t += 3.5; return self.answer(fence, "settled", step: 2)
            case (sourcePrepareRateOp, _): return self.answer(fence, "settled", step: 0)
            default: return self.answer(fence, "correct", step: 1, target: 96000)
            }
        }
        let out = played(p.transition.run(song("AAA")))
        guard case .stopped(let why, _)? = out?.correction else { return XCTFail("\(String(describing: out))") }
        XCTAssertEqual(why, .tooSlow)
        XCTAssertTrue(why.leavesOurPause)
        XCTAssertEqual(p.music.count("resume"), 0)
        XCTAssertEqual(p.music.state.state, .paused)
    }

    /// Inside the window the position may drift by 0.5 s (the clock of the
    /// pause itself); beyond it, it is a seek.
    func testThePositionToleranceIsHalfASecond() throws {
        let inside = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .paused, persistentID: "AAA", position: p.music.position + 0.4)
        })
        XCTAssertEqual(inside.0.music.count("resume"), 1)
        let outside = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .paused, persistentID: "AAA", position: p.music.position + 0.6)
        })
        XCTAssertEqual(outside.0.music.count("resume"), 0)
    }

    /// The follower resumes only its OWN pause: if the pause did not stick (or
    /// the pause call failed) there is nothing to resume and no correction.
    func testAPauseThatFailsOrDoesNotStickIsNeverResumedAndNothingIsCorrected() throws {
        for failing in ["throws", "does not stick"] {
            let events = Events()
            let p = process(tempDir(), owner: "tui", events: events)
            if failing == "throws" { p.music.pauseError = ActionError(message: "no") } else { p.music.pauseDoesNotStick = true }
            p.wire.script = standardScript(p.wire, confirm: "correct", fence: { 1 })
            let result = p.transition.run(song("AAA"))
            guard case .notAttempted? = played(result)?.correction else { return XCTFail("\(failing): \(result)") }
            XCTAssertEqual(p.music.count("resume"), 0, failing)
            XCTAssertEqual(p.music.count("seek0"), 0, failing)
            XCTAssertFalse(p.wire.requests.contains { $0.body["step"] as? Int == 2 }, "\(failing): the rate was corrected with nothing paused")
            XCTAssertEqual(result.playOutcome, true, failing)
        }
    }

    func testAnUnreadablePlayerAfterOurPauseIsNotResumedBlind() throws {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.wire.script = standardScript(p.wire, confirm: "correct", fence: { 1 })
        let wrapped = StateUnreadableAfterPause(p.music)
        let q = RateAwareTransition(fence: p.fence, owner: "tui", music: wrapped,
                                    makeFollow: { SourceRateFollow(token: $0, control: self.control(p.wire), offered: true,
                                                                   now: { 0 }, sleep: { _ in }) },
                                    now: { 0 })
        let out = played(q.run(song("AAA")))
        guard case .stopped(let why, _)? = out?.correction else { return XCTFail("\(String(describing: out))") }
        XCTAssertEqual(why, .stateUnreadable)
        XCTAssertEqual(p.music.count("resume"), 0)
    }

    private final class StateUnreadableAfterPause: RateMusicControlling {
        let inner: FakeMusic
        var paused = false
        init(_ inner: FakeMusic) { self.inner = inner }
        func playTrack(persistentID: String) throws { try inner.playTrack(persistentID: persistentID) }
        func pause() throws { try inner.pause(); paused = true }
        func resume() throws { try inner.resume() }
        func seekToStart() throws { try inner.seekToStart() }
        func readCurrentTrack() -> RateTrackRead? { inner.readCurrentTrack() }
        func readPlayerState() -> RatePlayerState? { paused ? nil : inner.readPlayerState() }
    }

    /// A rate failure during the correction never leaves the song paused: our
    /// pause is resumed at whatever rate the DAC holds.
    func testACorrectionThatFailsAtTheRateStillResumesItsOwnPause() throws {
        for outcome in ["dac_limit", "unresolved", "no_dac"] {
            let (p, _, result) = try correcting(correction: outcome)
            guard case .resumed? = played(result)?.correction else { return XCTFail("\(outcome): \(result)") }
            XCTAssertEqual(p.music.count("resume"), 1, outcome)
        }
        // SpanDAC gone mid-correction.
        let p = process(tempDir(), owner: "tui")
        p.wire.script = { body in
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourcePrepareRateOp, 2): throw SourceAppError.notRunning
            case (sourcePrepareRateOp, _): return self.answer(body["fence"] as? Int ?? 1, "settled", step: 0)
            default: return self.answer(body["fence"] as? Int ?? 1, "correct", step: 1, target: 96000)
            }
        }
        guard case .resumed? = played(p.transition.run(song("AAA")))?.correction else { return XCTFail("not resumed") }
        XCTAssertEqual(p.music.count("resume"), 1)
    }

    func testARefusedResumeLeavesOurPauseAndSaysSo() throws {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.music.resumeError = ActionError(message: "Music said no")
        p.wire.script = standardScript(p.wire, confirm: "correct", fence: { 1 })
        let out = played(p.transition.run(song("AAA")))
        guard case .stopped(let why, _)? = out?.correction else { return XCTFail("\(String(describing: out))") }
        XCTAssertEqual(why, .resumeFailed("Music said no"))
        XCTAssertTrue(why.leavesOurPause)
        XCTAssertEqual(p.music.count("play"), 1, "a failed resume is not a failed play")
    }

    /// If Music refuses only the seek, the song still resumes (a pause is never
    /// left held for a seek), and the result says it did not restart.
    func testARefusedSeekStillResumes() throws {
        let events = Events()
        let p = process(tempDir(), owner: "tui", events: events)
        p.music.seekError = ActionError(message: "no seek")
        p.wire.script = standardScript(p.wire, confirm: "correct", fence: { 1 })
        guard case .resumed(let restarted, _)? = played(p.transition.run(song("AAA")))?.correction else { return XCTFail("no resume") }
        XCTAssertFalse(restarted)
        XCTAssertEqual(p.music.count("resume"), 1)
    }

    // MARK: a rate failure never reaches AdvanceRetryGate

    /// Fed the way the poller feeds its gate, every rate failure (and an
    /// invalidation) leaves the gate exactly where it was, so no rate trouble
    /// can ever count toward skipping a song. Only Music's own `play` failing
    /// does.
    func testNoRateFailureEverReachesTheAdvanceRetryGate() throws {
        var gate = AdvanceRetryGate(maxRetries: 3)
        _ = gate.playFailed()
        _ = gate.playFailed()                                  // one failure from a skip
        XCTAssertEqual(gate.failures, 2)
        func feed(_ result: RateTransitionResult) -> AdvanceAction? {
            guard let ok = result.playOutcome else { return nil }
            if ok { gate.playSucceeded(); return nil }
            return gate.playFailed()
        }
        for c in failedCases() {
            let p = process(tempDir(), owner: "tui", offered: c.offered)
            p.wire.script = { body in try c.script(body, body["fence"] as? Int ?? 1) }
            let action = feed(p.transition.run(song()))
            XCTAssertNil(action, "\(c.name) reached the retry gate as a failure")
            XCTAssertEqual(gate.failures, 0, "\(c.name): a played song resets the gate, a rate failure never adds to it")
            _ = gate.playFailed(); _ = gate.playFailed()
        }
        // A correction that fails at the rate, and one that stops: the song played.
        let (_, _, corrected) = try correcting(correction: "dac_limit")
        XCTAssertNil(feed(corrected))
        let (_, _, stopped) = try correcting(during: { p in
            p.music.state = RatePlayerState(state: .playing, persistentID: "AAA", position: 1)
        })
        XCTAssertNil(feed(stopped))
        XCTAssertEqual(gate.failures, 0)
        // An invalidated transition touches nothing.
        _ = gate.playFailed()
        XCTAssertNil(feed(.invalidated))
        XCTAssertNil(feed(.notStarted("busy")))
        XCTAssertEqual(gate.failures, 1)
    }

    /// Music's own `play` failing is the one failure: it plays nothing, feeds
    /// the gate as a failure, and is retried and finally skipped by it.
    func testMusicsPlayFailureIsTheOnlyThingTheGateSees() {
        let p = process(tempDir(), owner: "tui")
        p.wire.script = standardScript(p.wire, fence: { 1 })
        p.music.playError = ActionError(message: "Music could not play it")
        var gate = AdvanceRetryGate(maxRetries: 2)
        let result = p.transition.run(song())
        XCTAssertEqual(result, .playFailed("Music could not play it"))
        XCTAssertEqual(result.playOutcome, false)
        XCTAssertEqual(gate.playFailed(), .retry)
        XCTAssertFalse(p.wire.ops.contains(sourceConfirmRateOp), "nothing to confirm when Music did not play")
        XCTAssertEqual(p.transition.run(song()).playOutcome, false)
        XCTAssertEqual(gate.playFailed(), .skip)
    }

    /// A fence that cannot move plays nothing, as `RateFence` says, and touches
    /// no gate (not a rate failure and not a Music failure).
    func testAnUnwritableFenceFileStartsNothing() throws {
        guard geteuid() != 0 else { return }
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        _ = try p.fence.begin(.play, owner: "tui")
        XCTAssertEqual(chmod(dir + "/rate.fence", 0o444), 0)
        defer { _ = chmod(dir + "/rate.fence", 0o644) }
        let result = p.transition.run(song())
        guard case .notStarted = result else { return XCTFail("\(result)") }
        XCTAssertNil(result.playOutcome)
        XCTAssertEqual(p.music.count("play"), 0)
        XCTAssertTrue(p.wire.requests.isEmpty)
    }

    /// A token the command already took (M1 at command time) is used as given:
    /// the fence does not move again, and a newer command since makes it stale.
    func testAGivenTokenIsUsedAsTakenAndCanAlreadyBeStale() throws {
        let dir = tempDir()
        let p = process(dir, owner: "tui")
        p.wire.script = standardScript(p.wire, fence: { 1 })
        let token = try p.fence.begin(.next, owner: "tui")
        XCTAssertEqual(played(p.transition.run(song(), token: token))?.token, token)
        XCTAssertEqual(try p.fence.current(), 1, "the transition took a second fence for a command that had one")
        _ = try p.fence.begin(.pause, owner: "tui")
        XCTAssertEqual(p.transition.run(song(), token: token), .invalidated)
    }
}

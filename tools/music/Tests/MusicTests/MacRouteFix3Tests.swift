// tools/music/Tests/MusicTests/MacRouteFix3Tests.swift
//
// Mac route fix round 3 (after Codex's whole-build round 3), MusicTUI's half:
//   A. every `slice.prepareRate` (and the correction's step 2) on the Mac route
//      carries `follow: true`, so SpanDAC records the DAC's baseline itself
//      before any write;
//   B. the ordering (the fence) is reserved BEFORE the pre-play status read, so
//      a blocked read can never let an older command replace a newer one, for
//      stations and for tracks;
//   C. shutdown resumes only inside ONE output-lock span: the fence check, the
//      Music state check and the resume;
//   D. an older SpanDAC that ignores unknown fields is unharmed by `follow`.
//
// Fakes only: the fence files are in a temp directory, SpanDAC is a scripted
// transport, Music.app is a fake. No audio, no AppleScript, no socket, no
// keychain, and never `~/.config/music`.
import XCTest
@testable import music

final class MacRouteFix3Tests: XCTestCase {

    // MARK: support

    private final class Clock { var t: TimeInterval = 0 }

    private final class Wire {
        private let lock = NSLock()
        private var all: [[String: Any]] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        func append(_ body: [String: Any]) { lock.lock(); all.append(body); lock.unlock() }
        var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return all }
        func requests(for op: String) -> [[String: Any]] { requests.filter { ($0["op"] as? String) == op } }
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                wire.append(body)
                return try wire.script(body)
            }
        }
        var c = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        c.rateSender = { transport($0) }
        return c
    }

    private func rate(_ fence: Int, _ outcome: String, step: Int? = nil, target: Int? = nil) -> String {
        var rate: [String: Any] = ["fence": fence, "outcome": outcome, "rate_seq": 1]
        if let step { rate["step"] = step }
        if let target { rate["target_hz"] = target }
        return json(["ok": true, "rate": rate])
    }

    /// A SpanDAC that serves everything. `confirm` is the outcome of the confirm.
    private func script(confirm: String = "own_rate", slowCorrectionBy clock: Clock? = nil)
        -> ([String: Any]) throws -> String {
        { body in
            let f = body["fence"] as? Int ?? 0
            switch (body["op"] as? String, body["step"] as? Int) {
            case (sourceRateFollowOp, _):
                return self.json(["ok": true, "rate": ["fence": f, "outcome": "quiet"],
                                  "follow": ["on": body["on"] as? Bool ?? false, "applied": true, "recorded": true]])
            case (sourceNowPlayingOp, _):
                return self.json(["ok": true, "now_playing": ["accepted": true, "fence": f]])
            case (sourcePrepareRateOp, 2):
                clock?.t += 5                                   // too slow to resume: our pause stands
                return self.rate(f, "settled", step: 2, target: 96000)
            case (sourcePrepareRateOp, _): return self.rate(f, "settled", step: 0, target: 96000)
            case (sourceConfirmRateOp, _): return self.rate(f, confirm, step: 1, target: 96000)
            default: return self.rate(f, "quiet")
            }
        }
    }

    private final class FakeMusic: RateMusicControlling {
        private let lock = NSLock()
        private var _played: [String] = []
        var played: [String] { lock.lock(); defer { lock.unlock() }; return _played }
        var state = RatePlayerState(state: .stopped, persistentID: nil, position: 0)
        var current: RateTrackRead?
        /// Runs at the start of every player-state read (the seam of finding C).
        var onStateRead: (() -> Void)?
        var onResume: (() -> Void)?
        func playTrack(persistentID: String) throws {
            lock.lock(); _played.append(persistentID); lock.unlock()
            state = RatePlayerState(state: .playing, persistentID: persistentID, position: 12)
            current = RateTrackRead(persistentID: persistentID, databaseID: 7, sampleRateHz: 44100)
        }
        func pause() throws { state = RatePlayerState(state: .paused, persistentID: state.persistentID, position: 12) }
        func resume() throws {
            onResume?()
            state = RatePlayerState(state: .playing, persistentID: state.persistentID, position: 12)
        }
        func seekToStart() throws {}
        func readCurrentTrack() -> RateTrackRead? { current }
        func readPlayerState() -> RatePlayerState? { onStateRead?(); return state }
    }

    private func fenceFor(_ dir: String) -> RateFence {
        RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
    }

    private func pidIndex(_ id: String) -> Int {
        persistentIDQueueEntry(persistentID: id, name: "", artist: "", album: nil)!.index
    }

    private func makePlayer(dir: String, wire: Wire, music: FakeMusic, reporter: MacRouteFollowReporter?,
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

    @discardableResult
    private func playID(_ p: MacRoutePlayer, _ id: String, _ command: RateCommand = .play) -> QueuePlayOutcome {
        p.play(playlist: persistentIDQueueSource, position: pidIndex(id), command: command, isCurrent: { true })
    }

    private func status() -> SourceRateFollowStatus {
        SourceRateFollowStatus(fence: 1, dacRateHz: 96000, write: .idle, startedFence: 1, rateSeq: 1, moved: nil,
                               following: true, followedUID: nil, restorable: nil)
    }

    // MARK: A. follow: true on every prepare on the Mac route

    func testEveryPrepareAndTheCorrectionCarryFollowTrueOnTheMacRoute() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(); wire.script = script(confirm: "correct")
        let music = FakeMusic()
        let reporter = MacRouteFollowReporter(control: control(wire), schedule: { $0() })
        let p = makePlayer(dir: dir, wire: wire, music: music, reporter: reporter, clock: clock)
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .played)
        XCTAssertEqual(playID(p, "BBBBBBBBBBBBBBB2", .advance), .played)

        let prepares = wire.requests(for: sourcePrepareRateOp)
        XCTAssertTrue(prepares.contains { $0["step"] as? Int == 0 }, "no step 0 prepare was sent")
        XCTAssertTrue(prepares.contains { $0["step"] as? Int == 2 }, "no correction was sent")
        for body in prepares {
            XCTAssertEqual(body["follow"] as? Bool, true, "a prepare without follow: \(body)")
        }
    }

    /// Off the Mac route (no route reporter: Bridge, tests that predate the route)
    /// the body is exactly what it always was.
    func testNoFollowKeyWithoutTheMacRoute() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = script(confirm: "correct")
        let p = makePlayer(dir: dir, wire: wire, music: FakeMusic(), reporter: nil, clock: Clock())
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .played)
        let prepares = wire.requests(for: sourcePrepareRateOp)
        XCTAssertFalse(prepares.isEmpty)
        for body in prepares { XCTAssertNil(body["follow"], "\(body)") }
        XCTAssertEqual(Set(SourceAppControl.prepareRateBody(fence: 1, dacUID: nil, persistentID: "A", catalogID: nil).keys),
                       ["op", "fence", "step", "persistent_id"], "the default body changed")
    }

    // MARK: D. an older SpanDAC ignores the unknown field

    /// An older SpanDAC reads only the fields it knows. The play, the rate answer
    /// and the line are what they were with no `follow` key.
    func testAnOlderSpanDACThatIgnoresUnknownFieldsIsUnharmedByFollowOnAPrepare() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire()
        let known: Set<String> = ["op", "fence", "step", "dac_uid", "persistent_id", "catalog_id", "rate_hz"]
        var seen: [[String: Any]] = []
        wire.script = { body in
            // Everything outside the older contract is dropped before it decides.
            let heard = body.filter { known.contains($0.key) }
            seen.append(heard)
            let f = heard["fence"] as? Int ?? 0
            switch (heard["op"] as? String, heard["step"] as? Int) {
            case (sourceRateFollowOp, _), (sourceNowPlayingOp, _):
                return #"{"ok":false,"error":{"kind":"unknown_op","detail":"unknown op"}}"#
            case (sourcePrepareRateOp, _): return self.rate(f, "settled", step: 0, target: 96000)
            case (sourceConfirmRateOp, _): return self.rate(f, "own_rate", step: 1, target: 96000)
            default: return self.rate(f, "quiet")
            }
        }
        let reporter = MacRouteFollowReporter(control: control(wire), schedule: { $0() })
        let p = makePlayer(dir: dir, wire: wire, music: FakeMusic(), reporter: reporter)
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .played)
        let prepare = try XCTUnwrap(seen.first { $0["op"] as? String == sourcePrepareRateOp })
        XCTAssertEqual(prepare["persistent_id"] as? String, "AAAAAAAAAAAAAAA1")
        XCTAssertNotNil(p.evidence.line)
        XCTAssertEqual(wire.requests(for: sourcePrepareRateOp).count, 1)
    }

    // MARK: B. the ordering is reserved before the status read

    /// A newer CLI play takes its fence while the older TUI station is blocked in
    /// its status read: the station opens NOTHING.
    func testAStationBlockedInItsStatusReadNeverReplacesANewerCommand() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = script()
        let p = makePlayer(dir: dir, wire: wire, music: FakeMusic(), reporter: nil)
        let newer = fenceFor(dir)
        var newerToken: RateToken?
        p.readRateStatus = {
            newerToken = try? newer.begin(.play, owner: "cli")     // the newer command, during the read
            return self.status()
        }
        var opened = 0
        let outcome = try p.playStation(start: { opened += 1 })
        XCTAssertEqual(outcome, .superseded, "the older station replaced the newer command")
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(try newer.current(), newerToken?.fence, "the older request moved the fence past the newer one")
        XCTAssertEqual(newer.leaseStatus(owner: "cli"), .ours)
    }

    func testATrackPlayBlockedInItsStatusReadNeverReplacesANewerCommand() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = script()
        let music = FakeMusic()
        let p = makePlayer(dir: dir, wire: wire, music: music, reporter: nil)
        let newer = fenceFor(dir)
        var newerToken: RateToken?
        p.readRateStatus = {
            newerToken = try? newer.begin(.play, owner: "cli")
            return self.status()
        }
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .superseded)
        XCTAssertEqual(music.played, [], "the older track played over the newer command")
        XCTAssertEqual(try newer.current(), newerToken?.fence)
        XCTAssertEqual(newer.leaseStatus(owner: "cli"), .ours)
    }

    /// Two station requests of one process: the second arrives while the first is
    /// blocked in its read. The second (newer) plays; the first plays nothing.
    func testTheNewerOfTwoStationRequestsWinsWhateverOrderTheirReadsReturnIn() throws {
        let dir = OutputLockTestSupport.tempDir()
        let wire = Wire(); wire.script = script()
        let p = makePlayer(dir: dir, wire: wire, music: FakeMusic(), reporter: nil)
        let inFirstRead = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let calls = NSLock(); var count = 0
        p.readRateStatus = {
            calls.lock(); count += 1; let mine = count; calls.unlock()
            if mine == 1 { inFirstRead.signal(); _ = releaseFirst.wait(timeout: .now() + 10) }
            return nil                                           // unreadable: tells nothing
        }
        let opened = NSLock(); var openedBy: [String] = []
        let done = DispatchSemaphore(value: 0)
        var firstOutcome: StationRouteOutcome?
        DispatchQueue.global().async {
            firstOutcome = try? p.playStation(start: { opened.lock(); openedBy.append("first"); opened.unlock() })
            done.signal()
        }
        XCTAssertEqual(inFirstRead.wait(timeout: .now() + 5), .success)
        let second = try p.playStation(start: { opened.lock(); openedBy.append("second"); opened.unlock() })
        releaseFirst.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(second, .played(line: stationRateLine(dacRateHz: nil, deliveredHz: nil)))
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(openedBy, ["second"])
    }

    /// A request that took no fence of its own because the fence could not move
    /// still plays (never refuse a song): a broken state directory.
    func testABrokenStateDirectoryStillPlaysTheStationAfterTheReadSkip() throws {
        let wire = Wire(); wire.script = script()
        let c = control(wire)
        let broken = RateFence(lock: OutputLock(path: "/nonexistent-dir-fix3/output.lock", pollInterval: 0.001))
        var reads = 0
        let p = MacRoutePlayer(
            route: MacDACRouteState(initial: true), outputIsMusicApp: { true }, fence: broken, owner: "tui",
            makeMusic: { _ in FakeMusic() }, resolvePersistentID: { _, _ in nil },
            makeFollow: { SourceRateFollow(token: $0, control: c, offered: true) }, post: { _ in })
        p.readRateStatus = { reads += 1; return nil }
        var opened = 0
        XCTAssertEqual(try p.playStation(start: { opened += 1 }), .played(line: nil))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(reads, 0, "no fence, so no ordering to protect and nothing to read first")
    }

    // MARK: C. shutdown resumes inside one lock span

    /// While shutdown reads Music's state, a newer command tries to take the
    /// fence: it must wait for the lock, so it lands AFTER our resume, never
    /// between the state read and the resume.
    func testShutdownChecksTheFenceReadsMusicAndResumesInOneLockSpan() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(); wire.script = script(confirm: "correct", slowCorrectionBy: clock)
        let music = FakeMusic()
        let p = makePlayer(dir: dir, wire: wire, music: music, reporter: nil, clock: clock)
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .played)
        XCTAssertEqual(music.state.state, .paused, "the correction should have left our pause")

        let events = NSLock(); var order: [String] = []
        func note(_ e: String) { events.lock(); order.append(e); events.unlock() }
        let newer = fenceFor(dir)
        let newerDone = DispatchSemaphore(value: 0)
        var started = false
        music.onStateRead = {
            guard !started else { return }
            started = true
            DispatchQueue.global().async {                       // a newer command, mid-shutdown
                _ = try? newer.begin(.pause, owner: "cli")
                note("newer fence")
                newerDone.signal()
            }
            usleep(200_000)                                      // long enough for it to win if it can
        }
        music.onResume = { note("resume") }
        p.shutdown(wait: 1)
        XCTAssertEqual(newerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(order, ["resume", "newer fence"],
                       "a newer command took the fence between shutdown's checks and its resume")
    }

    /// A newer command that already moved the fence: nothing resumes (kept).
    func testShutdownResumesNothingAfterANewerFence() throws {
        let dir = OutputLockTestSupport.tempDir()
        let clock = Clock()
        let wire = Wire(); wire.script = script(confirm: "correct", slowCorrectionBy: clock)
        let music = FakeMusic()
        let p = makePlayer(dir: dir, wire: wire, music: music, reporter: nil, clock: clock)
        XCTAssertEqual(playID(p, "AAAAAAAAAAAAAAA1"), .played)
        _ = try fenceFor(dir).begin(.pause, owner: "cli")
        var resumed = false
        music.onResume = { resumed = true }
        p.shutdown(wait: 0)
        XCTAssertFalse(resumed)
    }
}

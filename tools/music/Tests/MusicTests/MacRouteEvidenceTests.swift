// tools/music/Tests/MusicTests/MacRouteEvidenceTests.swift
//
// The evidence line of the Mac DAC route (mac-route-plan.md, step P6; appendix
// M4 start lines and M5 warning): what is playing and why, on Now and on the
// Output tab's Mac row. Stubs only: results are built by hand, the player is
// never asked to play, the scenes draw from temp stores with `/usr/bin/true`
// as the backend. No audio, no AppleScript, no socket, never ~/.config/music.
import XCTest
@testable import music

final class MacRouteEvidenceTests: XCTestCase {

    // MARK: support

    private let token = RateToken(fence: 7, owner: "tui", command: .advance)

    private func answer(_ outcome: SourceRateAnswer.Outcome, target: Int? = nil, dac: Int? = nil,
                        prior: Bool = false, seq: Int? = 3, restorable: Bool? = nil) -> SourceRateAnswer {
        SourceRateAnswer(fence: 7, outcome: outcome, targetHz: target, dacRateHz: dac,
                         priorUnresolved: prior, rateSeq: seq, restorable: restorable)
    }

    private func played(_ outcome: SourceRateOutcome, delivered: Int? = nil, confirm: SourceRateOutcome? = nil,
                        correction: RateCorrection = .notNeeded, baseline: Int? = 3) -> RateTransitionPlayed {
        RateTransitionPlayed(
            token: token, startLine: SourceRateStartLine.line(for: outcome), rateOutcome: outcome,
            delivered: delivered.map { RateTrackRead(persistentID: "A", databaseID: 1, sampleRateHz: $0) },
            confirm: confirm, correction: correction, baseline: baseline)
    }

    private func status(seq: Int, moved: SourceRateFollowStatus.Moved? = nil, dac: Int? = 96000) -> SourceRateFollowStatus {
        SourceRateFollowStatus(fence: 7, dacRateHz: dac, write: .idle, startedFence: 7, rateSeq: seq, moved: moved)
    }

    private func line(_ p: RateTransitionPlayed, _ s: SourceRateFollowStatus? = nil) -> String? {
        macRouteEvidenceText(for: p, status: s)
    }

    // MARK: M4 start lines

    func testOwnRate() {
        XCTAssertEqual(line(played(.answered(answer(.settled, target: 96000, dac: 96000)))),
                       "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
        XCTAssertEqual(line(played(.answered(answer(.sameRate, target: 44100)))),
                       "44.1 kHz \u{00B7} own rate \u{00B7} codec unknown")
    }

    func testOwnRateWithAnOlderWriteUnprovenSaysMayChange() {
        XCTAssertEqual(line(played(.answered(answer(.settled, target: 96000, prior: true)))),
                       "96 kHz \u{00B7} own rate \u{00B7} may change \u{00B7} codec unknown")
    }

    func testOwnRateWithNoRateKnownIsNotInvented() {
        XCTAssertEqual(line(played(.answered(answer(.settled)))), "rate unknown \u{00B7} codec unknown")
    }

    func testDACLimit() {
        XCTAssertEqual(line(played(.answered(answer(.dacLimit, target: 192000, dac: 96000)))),
                       "converted to 96 kHz: DAC limit \u{00B7} codec unknown")
        XCTAssertEqual(line(played(.answered(answer(.dacLimit, target: 192000)))),
                       "converted: DAC limit \u{00B7} codec unknown")
    }

    func testUnconfirmedSwitch() {
        XCTAssertEqual(line(played(.unsettled(last: answer(.queued, target: 96000, dac: 44100)))),
                       "96 kHz song, DAC at 44.1 kHz: DAC rate switch unconfirmed \u{00B7} codec unknown")
        XCTAssertEqual(line(played(.answered(answer(.unresolved, target: 96000, dac: 44100)))),
                       "96 kHz song, DAC at 44.1 kHz: DAC rate switch unconfirmed \u{00B7} codec unknown")
        // SpanDAC never answered: nothing to state but the fact.
        XCTAssertEqual(line(played(.unsettled(last: nil))),
                       "DAC rate switch unconfirmed \u{00B7} codec unknown")
    }

    func testUnconfirmedWithAnOlderWriteSaysMayChange() {
        XCTAssertEqual(line(played(.answered(answer(.quiet, prior: true)))),
                       "DAC rate switch unconfirmed \u{00B7} may change \u{00B7} codec unknown")
    }

    func testUnknownRateAndUnreachable() {
        XCTAssertEqual(line(played(.answered(answer(.unknownRate)))), "rate unknown \u{00B7} codec unknown")
        XCTAssertEqual(line(played(.failed(.notRunning))), "rate unknown \u{00B7} codec unknown")
    }

    func testNoDACStatesTheSongRateAndThatTheDACIsUnknown() {
        XCTAssertEqual(line(played(.answered(answer(.noDAC, target: 96000)))),
                       "96 kHz \u{00B7} DAC rate unknown \u{00B7} codec unknown")
    }

    func testAnOlderSpanDACGetsTheUpdateSentenceAlone() {
        XCTAssertEqual(line(played(.notOffered)), sourceRateFollowUpdateSentence)
    }

    func testAStationOrResumeStatesNothingNew() {
        XCTAssertNil(line(played(.answered(answer(.quiet, dac: 96000)))))
    }

    func testARegressedFenceSaysTheSwitchIsUnconfirmed() {
        XCTAssertEqual(line(played(.answered(answer(.superseded, target: 96000, dac: 44100)))),
                       "96 kHz song, DAC at 44.1 kHz: DAC rate switch unconfirmed \u{00B7} codec unknown")
    }

    // MARK: the delivered rate is evidence

    func testTheConfirmedReadOutranksThePrediction() {
        let settled = SourceRateOutcome.answered(answer(.settled, target: 96000))
        XCTAssertEqual(line(played(settled, delivered: 96000, confirm: .answered(answer(.ownRate)))),
                       "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
        XCTAssertEqual(line(played(settled, delivered: 48000, confirm: .answered(answer(.converted, target: 48000, dac: 44100)))),
                       "converted to 44.1 kHz: DAC limit \u{00B7} codec unknown")
        XCTAssertEqual(line(played(settled, delivered: nil, confirm: .answered(answer(.deliveredUnknown)))),
                       "96 kHz \u{00B7} DAC rate unknown \u{00B7} codec unknown")
    }

    /// Fix round 1, finding 5: "converted to X" names the rate the DAC is AT
    /// (the answer's `dac_rate_hz`), never the song's own: a 192 kHz song on a
    /// 96 kHz DAC is converted to 96 kHz. With no DAC rate in the answer the line
    /// claims no rate at all.
    func testAConvertedLineNamesTheDACsRateNotTheSongs() {
        let settled = SourceRateOutcome.answered(answer(.settled, target: 192000))
        XCTAssertEqual(line(played(settled, delivered: 192000, confirm: .answered(answer(.converted, target: 192000, dac: 96000)))),
                       "converted to 96 kHz: DAC limit \u{00B7} codec unknown")
        XCTAssertEqual(line(played(settled, delivered: 192000, confirm: .answered(answer(.converted, target: 192000)))),
                       "converted: DAC limit \u{00B7} codec unknown",
                       "no DAC rate in the answer: say nothing about a rate rather than the song's")
    }

    // MARK: controller addition: a DAC whose rate will not be put back

    private func restorableStatus(_ restorable: Bool?, following: Bool? = nil) -> SourceRateFollowStatus {
        SourceRateFollowStatus(fence: 7, dacRateHz: 96000, write: .idle, startedFence: 7, rateSeq: 3, moved: nil,
                               following: following, followedUID: nil, restorable: restorable)
    }

    func testARateThatWillNotBeRestoredSaysSoRightAfterTheRate() {
        let p = played(.answered(answer(.settled, target: 96000, dac: 96000)))
        XCTAssertEqual(line(p, restorableStatus(false)),
                       "96 kHz \u{00B7} own rate \u{00B7} rate won't be restored \u{00B7} codec unknown",
                       "second, so a narrow screen drops the tail first and keeps it")
        // From an answer (SpanDAC may say it on the prepare or the confirm).
        let fromAnswer = played(.answered(answer(.settled, target: 96000, restorable: false)))
        XCTAssertEqual(line(fromAnswer), "96 kHz \u{00B7} own rate \u{00B7} rate won't be restored \u{00B7} codec unknown")
        let fromConfirm = played(.answered(answer(.settled, target: 96000)), delivered: 96000,
                                 confirm: .answered(answer(.ownRate, restorable: false)))
        XCTAssertEqual(line(fromConfirm), "96 kHz \u{00B7} own rate \u{00B7} rate won't be restored \u{00B7} codec unknown")
    }

    /// An older SpanDAC omits the field: unknown, nothing changes. True says nothing either.
    func testAnUnknownOrTrueRestorableChangesNothing() {
        let p = played(.answered(answer(.settled, target: 96000, dac: 96000)))
        let plain = "96 kHz \u{00B7} own rate \u{00B7} codec unknown"
        XCTAssertEqual(line(p, restorableStatus(nil)), plain)
        XCTAssertEqual(line(p, restorableStatus(true)), plain)
        XCTAssertEqual(line(p), plain)
    }

    func testTheStatusReadsFollowingFollowedUIDAndRestorableAndOlderOnesLeaveThemUnknown() throws {
        let full = SourceRateFollowStatus(status: ["rate": ["write": "idle", "rate_seq": 2, "following": false,
                                                            "followed_uid": "ssl-1", "restorable": false]])
        XCTAssertEqual(full?.following, false)
        XCTAssertEqual(full?.followedUID, "ssl-1")
        XCTAssertEqual(full?.restorable, false)
        let older = SourceRateFollowStatus(status: ["rate": ["write": "idle", "rate_seq": 2]])
        XCTAssertNil(older?.following); XCTAssertNil(older?.followedUID); XCTAssertNil(older?.restorable)
    }

    func testNoLineEverClaimsLossless() {
        let outcomes: [SourceRateOutcome] = [
            .answered(answer(.settled, target: 96000)), .answered(answer(.dacLimit, dac: 48000)),
            .unsettled(last: nil), .answered(answer(.unknownRate)), .notOffered, .failed(.notRunning),
            .answered(answer(.noDAC, target: 44100)),
        ]
        for o in outcomes { XCTAssertFalse((line(played(o)) ?? "").lowercased().contains("lossless")) }
    }

    func testACorrectionThatStoppedLeavingOurPauseSaysSo() {
        let p = played(.answered(answer(.settled, target: 96000)),
                       correction: .stopped(.tooSlow, rateOutcome: nil))
        XCTAssertEqual(line(p), "96 kHz \u{00B7} own rate \u{00B7} paused to switch the DAC rate, press play \u{00B7} codec unknown")
        // The lock-unavailable sentence is P4's, not repeated here.
        let locked = played(.answered(answer(.settled, target: 96000)),
                            correction: .stopped(.lockUnavailable("x"), rateOutcome: nil))
        XCTAssertFalse(line(locked)!.contains("press play"))
    }

    func testACorrectionThatResumedUsesTheCorrectionsAnswer() {
        let p = played(.answered(answer(.settled, target: 44100)),
                       correction: .resumed(restartedFromStart: true,
                                            rateOutcome: .answered(answer(.settled, target: 96000))))
        XCTAssertEqual(line(p), "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
    }

    // MARK: M5 late switch

    func testALateSwitchShowsOnTheLine() {
        let moved = SourceRateFollowStatus.Moved(fence: 7, toHz: 44100, cause: .lateSwitch, seq: 5)
        let p = played(.answered(answer(.settled, target: 96000)))
        XCTAssertEqual(line(p, status(seq: 5, moved: moved)),
                       "96 kHz \u{00B7} own rate \u{00B7} late switch to 44.1 kHz \u{00B7} codec unknown \u{00B7} the next song sets it")
    }

    func testAChangeFromOutsideAndAChangeWithNoCause() {
        let p = played(.answered(answer(.settled, target: 96000)))
        let outside = SourceRateFollowStatus.Moved(fence: 7, toHz: 48000, cause: .outside, seq: 4)
        XCTAssertTrue(line(p, status(seq: 4, moved: outside))!.contains("DAC rate changed to 48 kHz outside MusicTUI"))
        XCTAssertTrue(line(p, status(seq: 4, dac: 48000))!.contains("DAC rate changed to 48 kHz \u{00B7} codec unknown \u{00B7} the next song sets it"))
    }

    func testNoWarningWhileTheRateSeqIsTheBaseline() {
        let p = played(.answered(answer(.settled, target: 96000)))
        XCTAssertEqual(line(p, status(seq: 3)), "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
        // A move counted at or below the baseline is an older one.
        let old = SourceRateFollowStatus.Moved(fence: 7, toHz: 44100, cause: .lateSwitch, seq: 3)
        XCTAssertEqual(line(p, status(seq: 3, moved: old)), "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
    }

    func testWithNoBaselineTheUnconfirmedLineAloneStands() {
        let p = played(.unsettled(last: nil), baseline: nil)
        XCTAssertEqual(line(p, status(seq: 9)), "DAC rate switch unconfirmed \u{00B7} codec unknown")
    }

    // MARK: the holder and the player

    private func player(on: Bool) -> MacRoutePlayer {
        let dir = NSTemporaryDirectory() + "macroute-p6-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: on), outputIsMusicApp: { true },
            fence: RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001)),
            makeMusic: { _ in fatalError("never asked to play") },
            resolvePersistentID: { _, _ in nil },
            makeFollow: { _ in fatalError("never asked to play") }, post: { _ in })
    }

    func testOffTheRouteNothingNewRenders() {
        let p = player(on: false)
        p.evidence.record(.played(played(.answered(answer(.settled, target: 96000)))))
        XCTAssertNil(p.evidenceLine)
        XCTAssertNotNil(p.evidence.line, "recorded, but the route is off")
    }

    func testOnTheRouteTheLatestPlayReplacesTheLineAndAStationClearsIt() {
        let p = player(on: true)
        XCTAssertNil(p.evidenceLine)
        p.evidence.record(.played(played(.answered(answer(.settled, target: 96000)))))
        XCTAssertEqual(p.evidenceLine, "96 kHz \u{00B7} own rate \u{00B7} codec unknown")
        p.evidence.record(.invalidated)
        XCTAssertNotNil(p.evidenceLine, "a play that never started leaves the line")
        p.evidence.record(.played(played(.answered(answer(.quiet)))))
        XCTAssertNil(p.evidenceLine, "a station: nothing was converted, nothing is claimed")
    }

    func testAPlayWithNoRateFollowSaysRateUnknown() {
        let p = player(on: true)
        p.evidence.record(.playedUnfollowed(reason: "x"))
        XCTAssertEqual(p.evidenceLine, "rate unknown \u{00B7} codec unknown")
    }

    func testALateStatusReachesTheLine() {
        let p = player(on: true)
        p.evidence.record(.played(played(.answered(answer(.settled, target: 96000)))))
        p.evidence.noteStatus(status(seq: 6, moved: .init(fence: 7, toHz: 48000, cause: .lateSwitch, seq: 6)))
        XCTAssertTrue(p.evidenceLine!.contains("late switch to 48 kHz"))
        p.evidence.record(.played(played(.answered(answer(.settled, target: 48000)))))
        XCTAssertFalse(p.evidenceLine!.contains("late switch"), "a new song starts clean")
    }

    // MARK: Now and Output

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func nowScreen(_ p: MacRoutePlayer?, width: Int) -> [String] {
        let store = AppQueueStore()
        store.macRoute = p
        let status = StatusStore()
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                    status: status, actions: ActionRunner(status: status), routing: rig.coordinator())
        var np = NowPlayingState()
        np.track = "Strobe"; np.artist = "deadmau5"; np.album = "For Lack of a Better Name"
        np.state = "playing"; np.duration = 600; np.position = 30
        let snap = NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])
        _ = scene.tick(snapshot: snap)
        let frame = shellLayout(width: width, height: 40)
        return screenText(scene.render(frame: frame, snapshot: snap), width: width, height: 40)
    }

    func testNowDrawsTheLineUnderTheAlbumAndWithinTheWidth() {
        let p = player(on: true)
        p.evidence.record(.played(played(.answered(answer(.settled, target: 96000, prior: true)))))
        for width in [60, 92, 120] {
            let rows = nowScreen(p, width: width)
            guard let i = rows.firstIndex(where: { $0.contains("For Lack of a Better Name") }) else {
                return XCTFail("no album row at \(width)")
            }
            let text = rows[i + 1]
            XCTAssertTrue(text.contains("96 kHz"), "width \(width): \(text)")
            XCTAssertTrue(text.contains("may change"), "width \(width): \(text)")
            XCTAssertLessThanOrEqual(text.count, width)
        }
    }

    func testNowDrawsNothingOffTheRoute() {
        let off = player(on: false)
        off.evidence.record(.played(played(.answered(answer(.settled, target: 96000)))))
        for p in [off, nil] {
            XCTAssertFalse(nowScreen(p, width: 120).joined().contains("own rate"))
        }
    }

    private func macRowScreen(on: Bool, evidence: String?) throws -> [String] {
        let dir = NSTemporaryDirectory() + "macroute-p6-out-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        if on { MacRouteStore(path: dir + "/mac-route.json").set(true) }
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: FakeSpanDACOutputs(), speakers: [])
        settleOutputTab(s, speakers: 0)
        s.macRouteEvidenceLine = { evidence }
        _ = s.tick(snapshot: outputTabSnapshot())
        return screenText(s.render(frame: shellLayout(width: 110, height: 30), snapshot: outputTabSnapshot()),
                          width: 110, height: 30)
    }

    func testTheMacRowCarriesTheLineWhileTheRouteIsChosen() throws {
        let text = "96 kHz \u{00B7} own rate \u{00B7} may change"
        let rows = try macRowScreen(on: true, evidence: text)
        let i = try XCTUnwrap(rows.firstIndex { $0.contains("Studio Mac") })
        XCTAssertTrue(rows[i + 1].contains("96 kHz"), rows[i + 1])
        XCTAssertTrue(rows.allSatisfy { $0.count <= 110 }, rows.filter { $0.count > 110 }.map { "\($0.count): \($0)" }.joined(separator: "\n"))
    }

    func testTheMacRowShowsNothingNewOffTheRoute() throws {
        let rows = try macRowScreen(on: false, evidence: "96 kHz \u{00B7} own rate")
        XCTAssertFalse(rows.joined().contains("own rate"))
    }
}

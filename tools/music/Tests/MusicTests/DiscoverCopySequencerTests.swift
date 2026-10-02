import XCTest
@testable import music

/// S5-S14 (score step C3, items 2, 2a, 2b, 3a and the gates): nothing plays
/// unless the current track was verified to be the chosen one by exact
/// persistent ID in the right playlist; every paused skip is polled to a
/// bound; any mismatch stops and refuses.
///
/// Fakes only: a model player, a fake clock (`now` and `sleep` advance one
/// shared instant) and `FakeDiscoverCopyGate`. No script runs here.
final class DiscoverCopySequencerTests: XCTestCase {

    // MARK: - Harness

    private static let copyHex = "AAAAAAAAAAAAAAAA"
    private static let otherHex = "BBBBBBBBBBBBBBBB"

    private static func trackID(_ n: Int) -> String { String(format: "%016X", n) }

    private final class Harness {
        let rows: [DiscoverItem]
        let selected: Int
        let player: FakeDiscoverCopyPlayer
        let gate: FakeDiscoverCopyGate
        var instant = Date(timeIntervalSince1970: 1_000_000)
        var sleeps: [TimeInterval] = []
        var modesResult = true
        var stages: [DiscoverCopyStage] = []
        /// Player calls and seam calls in one order, each with whether a gate body was running.
        var events: [(name: String, gated: Bool)] = []
        private var inGate = false

        init(n: Int = 5, k: Int, gate scripted: [Int: DiscoverCopyGateResult] = [:]) {
            rows = dfhRows(Array(repeating: .milliseconds(200_000), count: n))
            selected = k - 1
            player = FakeDiscoverCopyPlayer(
                hex: DiscoverCopySequencerTests.copyHex,
                ids: (1...n).map(DiscoverCopySequencerTests.trackID),
                trackK: DiscoverCopyTrack(title: "Song \(k)", artist: "Artist", durationMS: 200_400))
            gate = FakeDiscoverCopyGate(scripted: scripted)
            player.onCall = { [unowned self] name in self.events.append((name, self.inGate)) }
        }

        var title: String { rows[selected].name }
        func id(_ n: Int) -> String { DiscoverCopySequencerTests.trackID(n) }

        private func note(_ name: String) { events.append((name, inGate)) }

        func run() -> DiscoverCopyPlayResult {
            let fake = gate.gate
            let seams = DiscoverCopySequencer.Seams(
                now: { [unowned self] in self.instant },
                sleep: { [unowned self] seconds in
                    self.sleeps.append(seconds)
                    self.instant = self.instant.addingTimeInterval(seconds)
                },
                gate: { [unowned self] body in
                    fake {
                        self.inGate = true
                        body()
                        self.inGate = false
                    }
                },
                switchModesOff: { [unowned self] in self.note("switchModesOff"); return self.modesResult },
                restoreModes: { [unowned self] in self.note("restoreModes") },
                deleteIfOwned: { [unowned self] in self.note("deleteIfOwned") },
                commitListening: { [unowned self] in self.note("commitListening") },
                progress: { [unowned self] stage in self.stages.append(stage) },
                log: { _ in })
            let request = DiscoverCopyRequest(playlistID: "pl.test", playlistTitle: "Playlist",
                                              rows: rows, selected: selected)
            return DiscoverCopySequencer(player: player, seams: seams)
                .run(hex: DiscoverCopySequencerTests.copyHex, request: request)
        }

        func count(_ name: String) -> Int { events.filter { $0.name == name }.count }
        var names: [String] { events.map { $0.name } }
        var gatedNames: [String] { events.filter { $0.gated }.map { $0.name } }
        var ungatedNames: [String] { events.filter { !$0.gated }.map { $0.name } }
        var elapsed: TimeInterval { instant.timeIntervalSince(Date(timeIntervalSince1970: 1_000_000)) }
    }

    /// No path waits a fixed time: every sleep is one of the two cadences.
    private func assertOnlyCadenceSleeps(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let allowed = [DiscoverCopyTiming.pollCadence, DiscoverCopyTiming.readinessCadence]
        XCTAssertTrue(h.sleeps.allSatisfy(allowed.contains), "sleeps: \(h.sleeps)", file: file, line: line)
    }

    /// Nothing is commanded after the abort's own silence.
    private func assertNoCommandAfter(_ last: String, _ h: Harness,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.player.commands.last, last, "commands: \(h.player.commands)", file: file, line: line)
        XCTAssertEqual(h.player.commands.filter { $0 == last }.count, 1, file: file, line: line)
    }

    // MARK: - Item 2: the happy paths

    func testKEqualsOneSendsNoPauseAndConfirmsTheFirstSong() {
        let h = Harness(k: 1)
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.player.commands, ["playCopy"])
        XCTAssertEqual(h.player.calls, ["trackCount", "trackCount", "read:1", "playCopy",
                                        "confirm:\(h.id(1))", "confirm:\(h.id(1))"])
        XCTAssertEqual(h.gate.calls, [.ran, .ran, .ran])
        XCTAssertEqual(h.stages, [.waitingForCopy, .ready, .positioning])
        XCTAssertEqual(h.count("commitListening"), 1)
        XCTAssertEqual(h.count("restoreModes"), 0)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
        assertOnlyCadenceSleeps(h)
    }

    func testKEqualsFiveRecordsExactlyPlayPauseFourLandedSkipsThenPlay() {
        let h = Harness(k: 5)
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.player.commands,
                       ["playCopy", "pause", "nextTrack", "nextTrack", "nextTrack", "nextTrack", "play"])
        var expected = ["trackCount", "trackCount", "read:5", "switchModesOff", "playCopy",
                        "firstPlay:\(h.id(1))", "pause", "landing:\(h.id(1)):\(h.id(1)):true"]
        for i in 2...5 {
            expected += ["nextTrack", "landing:\(h.id(i)):\(h.id(i - 1)):false"]
        }
        expected += ["play", "confirm:\(h.id(5))", "confirm:\(h.id(5))", "commitListening"]
        XCTAssertEqual(h.names, expected)
        XCTAssertEqual(h.player.state, .playing)
        XCTAssertEqual(h.player.currentIndex, 4)
        XCTAssertEqual(h.stages, [.waitingForCopy, .ready, .positioning])
        assertOnlyCadenceSleeps(h)
    }

    func testKEqualsNOfALongerPlaylistWalksEverySkip() {
        let h = Harness(n: 12, k: 12)
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.count("nextTrack"), 11)
        XCTAssertEqual(h.player.currentIndex, 11)
    }

    // MARK: - S5 and S6 (CH4)

    func testReadyOnlyAfterTwoReadsInARowAtTheFullCount() {
        let h = Harness(k: 1)
        h.player.trackCounts = [0, 3, 5, nil, 5, 5]
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.count("trackCount"), 6)
        XCTAssertEqual(Array(h.sleeps.prefix(5)), Array(repeating: DiscoverCopyTiming.readinessCadence, count: 5))
    }

    func testTwoReadsInARowAboveTheCountRefuseAtOnceAsChanged() {
        let h = Harness(k: 3)
        h.player.trackCounts = [6]
        XCTAssertEqual(h.run(), .refused(.countChanged))
        XCTAssertEqual(h.names, ["trackCount", "trackCount", "deleteIfOwned"])
        XCTAssertEqual(h.sleeps, [DiscoverCopyTiming.readinessCadence])
        XCTAssertTrue(h.gate.calls.isEmpty)
    }

    func testAStableSmallerCountPollsToTheBoundThenRefusesAsChanged() {
        let h = Harness(k: 3)
        h.player.trackCounts = [4]
        XCTAssertEqual(h.run(), .refused(.countChanged))
        XCTAssertGreaterThan(h.elapsed, DiscoverCopyTiming.readinessBound - 2 * DiscoverCopyTiming.readinessCadence)
        XCTAssertLessThanOrEqual(h.elapsed, DiscoverCopyTiming.readinessBound + 0.001)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("read:3"), 0)
        XCTAssertTrue(h.gate.calls.isEmpty)
        assertOnlyCadenceSleeps(h)
    }

    func testAStableZeroAtTheBoundIsNotReadyRatherThanChanged() {
        // A copy that never loaded: nothing says he changed the playlist.
        let h = Harness(k: 3)
        h.player.trackCounts = [0]
        XCTAssertEqual(h.run(), .refused(.notReady))
        XCTAssertGreaterThan(h.elapsed, DiscoverCopyTiming.readinessBound - 2 * DiscoverCopyTiming.readinessCadence)
        XCTAssertLessThanOrEqual(h.elapsed, DiscoverCopyTiming.readinessBound + 0.001)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("read:3"), 0)
        XCTAssertEqual(h.count("restoreModes"), 0)
        XCTAssertTrue(h.player.commands.isEmpty)
        XCTAssertTrue(h.gate.calls.isEmpty)
        assertOnlyCadenceSleeps(h)
    }

    func testAnUnreadableCountAtTheBoundIsNotReady() {
        let h = Harness(k: 3)
        h.player.trackCounts = [nil]
        XCTAssertEqual(h.run(), .refused(.notReady))
        XCTAssertLessThanOrEqual(h.elapsed, DiscoverCopyTiming.readinessBound + 0.001)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 0)
        XCTAssertTrue(h.player.commands.isEmpty)
    }

    func testACountStillMovingAtTheBoundIsNotReady() {
        let h = Harness(k: 3)
        var next = 0
        h.player.trackCounts = [0]
        h.player.onCall = { [unowned h] name in
            guard name == "trackCount" else { return }
            next = next == 3 ? 4 : 3          // 3, 4, 3, 4, ... never two alike
            h.player.trackCounts = [next]
        }
        XCTAssertEqual(h.run(), .refused(.notReady))
        XCTAssertTrue(h.player.commands.isEmpty)
    }

    // MARK: - S7 and S8

    func testAnUnreadableCopyIsUnconfirmedAndNothingIsCommanded() {
        let h = Harness(k: 3)
        h.player.readFails = true
        XCTAssertEqual(h.run(), .refused(.unconfirmed(title: "Song 3")))
        XCTAssertEqual(h.count("read:3"), 1, "S7 is one read")
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 0)
        XCTAssertTrue(h.player.commands.isEmpty)
        XCTAssertTrue(h.gate.calls.isEmpty)
    }

    func testAStartRefusalIsUnconfirmedAndNothingIsCommanded() {
        let h = Harness(k: 3)
        h.player.trackK = DiscoverCopyTrack(title: "Song 2", artist: "Artist", durationMS: 200_000)
        XCTAssertEqual(h.run(), .refused(.unconfirmed(title: "Song 3")))
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 0)
        XCTAssertTrue(h.player.commands.isEmpty)
        XCTAssertTrue(h.gate.calls.isEmpty)
    }

    func testTheReadDisagreeingWithTheCountIsChanged() {
        let h = Harness(k: 3)
        h.player.trackCounts = [5]
        h.player.ids.append(Self.trackID(6))
        XCTAssertEqual(h.run(), .refused(.countChanged))
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertTrue(h.player.commands.isEmpty)
    }

    // MARK: - S10 (item 3a, the ordering half)

    func testModesAreSwitchedOffInsideTheFirstGateAndBeforePlayCopy() {
        let h = Harness(k: 5)
        XCTAssertEqual(h.run(), .listening)
        let modes = h.events.firstIndex { $0.name == "switchModesOff" }!
        let play = h.events.firstIndex { $0.name == "playCopy" }!
        XCTAssertLessThan(modes, play)
        XCTAssertTrue(h.events[modes].gated)
        XCTAssertEqual(h.gatedNames.first, "switchModesOff")
        XCTAssertEqual(h.count("switchModesOff"), 1)
    }

    func testModesThatWillNotSwitchRefuseWithNoPlayAndNoRestore() {
        let h = Harness(k: 5)
        h.modesResult = false
        XCTAssertEqual(h.run(), .refused(.modes))
        XCTAssertTrue(h.player.commands.isEmpty)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 0, "the mode guard has already put back what it changed")
        XCTAssertEqual(h.gate.calls, [.ran])
        XCTAssertEqual(h.stages, [.waitingForCopy])
    }

    // MARK: - S11

    func testAPlayCopyThatFailsStopsRestoresAndLeavesTheCopy() {
        let h = Harness(k: 5)
        h.player.playCopyResult = false
        XCTAssertEqual(h.run(), .refused(.firstPlayUnconfirmed))
        XCTAssertEqual(h.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)

        let one = Harness(k: 1)
        one.player.playCopyResult = false
        XCTAssertEqual(one.run(), .refused(.wontPlay(title: "Song 1")))
        XCTAssertEqual(one.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(one.count("restoreModes"), 1)
        XCTAssertEqual(one.count("deleteIfOwned"), 0)
    }

    func testAFirstSongThatNeverStartsIsUnconfirmedAtTheBoundWithNoPause() {
        let h = Harness(k: 4)
        h.player.onFirstPlay = { _ in .notYet }
        XCTAssertEqual(h.run(), .refused(.firstPlayUnconfirmed))
        XCTAssertEqual(h.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
        assertOnlyCadenceSleeps(h)
    }

    func testAnotherSongStartingFirstIsUnconfirmed() {
        let h = Harness(k: 4)
        h.player.onFirstPlay = { _ in .wrongTrack }
        XCTAssertEqual(h.run(), .refused(.firstPlayUnconfirmed))
        XCTAssertEqual(h.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(h.count("firstPlay:\(h.id(1))"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
    }

    func testAPauseThatNeverSettlesIsUnconfirmedAndSendsNoSkip() {
        let h = Harness(k: 4)
        h.player.onLanding = { _, _, settling in settling ? .notYet : nil }
        XCTAssertEqual(h.run(), .refused(.firstPlayUnconfirmed))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "stop"])
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)

        let failed = Harness(k: 4)
        failed.player.pauseResult = false
        XCTAssertEqual(failed.run(), .refused(.firstPlayUnconfirmed))
        XCTAssertEqual(failed.player.commands, ["playCopy", "pause", "stop"])
    }

    func testAPauseThatSettlesLateStillPasses() {
        let h = Harness(k: 2)
        var polls = 0
        h.player.onLanding = { _, _, settling in
            guard settling else { return nil }
            polls += 1
            return polls < 6 ? .notYet : nil
        }
        XCTAssertEqual(h.run(), .listening)
        assertOnlyCadenceSleeps(h)
    }

    // MARK: - S12 (items 2 and 2a)

    func testAMismatchAtASkipStopsWithNoPlayAndDeletesOnce() {
        let h = Harness(k: 5)
        var skips = 0
        h.player.afterNextTrack = { [unowned h] in
            skips += 1
            if skips == 3 { h.player.currentIndex! += 1 }     // lands one too far
        }
        XCTAssertEqual(h.run(), .refused(.landing(title: "Song 5")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "nextTrack", "stop"])
        XCTAssertEqual(h.count("play"), 0)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("commitListening"), 0)
    }

    func testStateLeavingPausedMidSkipAborts() {
        let h = Harness(k: 5)
        var skips = 0
        h.player.afterNextTrack = { [unowned h] in
            skips += 1
            if skips == 2 { h.player.state = .playing }
        }
        XCTAssertEqual(h.run(), .refused(.landing(title: "Song 5")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "stop"])
        XCTAssertEqual(h.count("play"), 0)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 1)
    }

    /// The right track ID in ANOTHER playlist is not a landing: Music.app gave
    /// one song the same persistent ID in two copies.
    func testThePlaylistChangingMidSkipAbortsEvenOnTheRightTrackID() {
        let h = Harness(k: 5)
        var skips = 0
        h.player.afterNextTrack = { [unowned h] in
            skips += 1
            if skips == 2 { h.player.currentPlaylist = DiscoverCopySequencerTests.otherHex }
        }
        XCTAssertEqual(h.run(), .refused(.landing(title: "Song 5")))
        XCTAssertEqual(h.player.currentIndex, 2, "the model IS on the expected track ID")
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "stop"])
        XCTAssertEqual(h.count("play"), 0)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
    }

    func testASkipThatFailsToSendAborts() {
        let h = Harness(k: 3)
        h.player.nextTrackResult = false
        XCTAssertEqual(h.run(), .refused(.landing(title: "Song 3")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "stop"])
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 1)
    }

    func testALandingAppearingAtPointEightSecondsPasses() {
        let h = Harness(k: 3)
        var skippedAt = h.instant
        h.player.afterNextTrack = { [unowned h] in skippedAt = h.instant }
        var slowest: TimeInterval = 0
        h.player.onLanding = { [unowned h] _, _, settling in
            guard !settling else { return nil }
            let waited = h.instant.timeIntervalSince(skippedAt)
            if waited < 0.75 { return .notYet }
            slowest = max(slowest, waited)
            return nil
        }
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(slowest, 0.8, accuracy: 0.01)
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "play"])
        assertOnlyCadenceSleeps(h)
    }

    func testStillOnThePreviousTrackAtThreeSecondsStopsAndRefuses() {
        let h = Harness(k: 4)
        var skippedAt = h.instant
        var lastPollAfter: TimeInterval = 0
        h.player.afterNextTrack = { [unowned h] in skippedAt = h.instant }
        h.player.onLanding = { [unowned h] expected, _, settling in
            guard !settling, expected == h.id(3) else { return nil }
            lastPollAfter = h.instant.timeIntervalSince(skippedAt)
            return .notYet                                   // still on P[2]
        }
        XCTAssertEqual(h.run(), .refused(.landing(title: "Song 4")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "stop"])
        XCTAssertEqual(h.count("play"), 0)
        XCTAssertLessThanOrEqual(lastPollAfter, DiscoverCopyTiming.landingBound + 0.001)
        XCTAssertGreaterThan(lastPollAfter, DiscoverCopyTiming.landingBound - 2 * DiscoverCopyTiming.pollCadence)
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertEqual(h.count("restoreModes"), 1)
        assertOnlyCadenceSleeps(h)
    }

    // MARK: - S13 (item 2b)

    func testAnotherTrackAfterPlayStopsAndWontPlayWithNoFurtherCommand() {
        let h = Harness(k: 3)
        h.player.afterPlay = { [unowned h] in h.player.currentIndex! += 1 }      // P[k+1]
        XCTAssertEqual(h.run(), .refused(.wontPlay(title: "Song 3")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "play", "stop"])
        assertNoCommandAfter("stop", h)
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0, "the copy is left protected")
        XCTAssertEqual(h.count("commitListening"), 0)
    }

    func testAPositionStuckAtZeroToTheBoundWontPlayAndDoesNotDelete() {
        let h = Harness(k: 3)
        h.player.positionStepMS = 0
        var playedAt = h.instant
        h.player.afterPlay = { [unowned h] in playedAt = h.instant }
        XCTAssertEqual(h.run(), .refused(.wontPlay(title: "Song 3")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "play", "stop"])
        assertNoCommandAfter("stop", h)
        let waited = h.instant.timeIntervalSince(playedAt)
        XCTAssertLessThanOrEqual(waited, DiscoverCopyTiming.confirmBound + 0.001)
        XCTAssertGreaterThan(waited, DiscoverCopyTiming.confirmBound - 2 * DiscoverCopyTiming.pollCadence)
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
        XCTAssertEqual(h.count("commitListening"), 0)
        assertOnlyCadenceSleeps(h)
    }

    func testAnAdvancingPositionIsListening() {
        let h = Harness(k: 3)
        var answers: [DiscoverCopyConfirm] = [.notYet, .onTrack(positionMS: 0), .onTrack(positionMS: 0),
                                              .notYet, .onTrack(positionMS: 180)]
        h.player.onConfirm = { _ in answers.isEmpty ? .notYet : answers.removeFirst() }
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.count("confirm:\(h.id(3))"), 5)
        XCTAssertEqual(h.count("commitListening"), 1)
    }

    func testOneReadingOnTheTrackIsNotConfirmation() {
        let h = Harness(k: 3)
        var answers: [DiscoverCopyConfirm] = [.onTrack(positionMS: 5_000)]
        h.player.onConfirm = { _ in answers.isEmpty ? .notYet : answers.removeFirst() }
        XCTAssertEqual(h.run(), .refused(.wontPlay(title: "Song 3")))
        XCTAssertEqual(h.count("commitListening"), 0)
    }

    func testAForeignPlaylistAtConfirmationWontPlay() {
        let h = Harness(k: 3)
        h.player.afterPlay = { [unowned h] in h.player.currentPlaylist = DiscoverCopySequencerTests.otherHex }
        XCTAssertEqual(h.run(), .refused(.wontPlay(title: "Song 3")))
        assertNoCommandAfter("stop", h)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
    }

    func testAPlayThatFailsToSendWontPlay() {
        let h = Harness(k: 3)
        h.player.playResult = false
        XCTAssertEqual(h.run(), .refused(.wontPlay(title: "Song 3")))
        XCTAssertEqual(h.player.commands, ["playCopy", "pause", "nextTrack", "nextTrack", "play", "stop"])
        XCTAssertEqual(h.count("restoreModes"), 1)
        XCTAssertEqual(h.count("deleteIfOwned"), 0)
    }

    func testKEqualsOneConfirmationFailuresWontPlay() {
        let wrong = Harness(k: 1)
        wrong.player.onConfirm = { _ in .wrongTrack }
        XCTAssertEqual(wrong.run(), .refused(.wontPlay(title: "Song 1")))
        XCTAssertEqual(wrong.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(wrong.count("restoreModes"), 1)
        XCTAssertEqual(wrong.count("deleteIfOwned"), 0)

        let stuck = Harness(k: 1)
        stuck.player.positionStepMS = 0
        XCTAssertEqual(stuck.run(), .refused(.wontPlay(title: "Song 1")))
        XCTAssertEqual(stuck.player.commands, ["playCopy", "stop"])
        XCTAssertEqual(stuck.count("deleteIfOwned"), 0)
        assertOnlyCadenceSleeps(stuck)
    }

    // MARK: - Item 3a: restoreModes on every refusal after S10 and on none before

    func testRestoreModesIsCalledOnNoRefusalBeforeS10() {
        let notReady = Harness(k: 3); notReady.player.trackCounts = [nil]
        let changed = Harness(k: 3); changed.player.trackCounts = [6]
        let unread = Harness(k: 3); unread.player.readFails = true
        let mismatch = Harness(k: 3)
        mismatch.player.trackK = DiscoverCopyTrack(title: "Other", artist: "Artist", durationMS: 200_000)
        let movedAtModes = Harness(k: 3, gate: [1: .sourceChanged])
        let modes = Harness(k: 3); modes.modesResult = false
        for h in [notReady, changed, unread, mismatch, movedAtModes, modes] {
            guard case .refused = h.run() else { return XCTFail("expected a refusal") }
            XCTAssertEqual(h.count("restoreModes"), 0)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
            XCTAssertTrue(h.player.commands.isEmpty)
        }
    }

    // MARK: - Gates

    func testTheHappyPathForFiveMakesExactlyEightGateCallsAndOnlyTheFourCommandsRunInside() {
        let h = Harness(k: 5)
        XCTAssertEqual(h.run(), .listening)
        XCTAssertEqual(h.gate.calls.count, 1 + 1 + 4 + 1 + 1)
        XCTAssertEqual(h.gatedNames, ["switchModesOff", "playCopy", "nextTrack", "nextTrack", "nextTrack",
                                      "nextTrack", "play", "commitListening"])
        let gatedOnly: Set<String> = ["switchModesOff", "playCopy", "nextTrack", "play", "commitListening"]
        XCTAssertTrue(h.ungatedNames.allSatisfy { !gatedOnly.contains($0) }, "\(h.ungatedNames)")
        XCTAssertTrue(h.ungatedNames.contains("pause"))
    }

    /// Across every failure path: the player-changing commands run only inside
    /// a gate, and no read, poll, pause, stop or cleanup ever does.
    func testNothingButTheGatedCommandsEverRunsInsideAGate() {
        let gatedOnly: Set<String> = ["switchModesOff", "playCopy", "nextTrack", "play", "commitListening"]
        var harnesses: [Harness] = []
        for call in 1...8 {
            harnesses.append(Harness(k: 5, gate: [call: .sourceChanged]))
            harnesses.append(Harness(k: 5, gate: [call: .superseded]))
        }
        let mismatch = Harness(k: 5); mismatch.player.afterNextTrack = { [unowned mismatch] in mismatch.player.state = .playing }
        let stuck = Harness(k: 5); stuck.player.positionStepMS = 0
        let noStart = Harness(k: 5); noStart.player.playCopyResult = false
        harnesses += [mismatch, stuck, noStart]
        for h in harnesses {
            _ = h.run()
            XCTAssertTrue(h.gatedNames.allSatisfy(gatedOnly.contains), "\(h.gatedNames)")
            XCTAssertTrue(h.ungatedNames.allSatisfy { !gatedOnly.contains($0) }, "\(h.ungatedNames)")
        }
    }

    private func forBothMoves(_ call: Int, k: Int = 5, _ check: (Harness, DiscoverCopyPlayResult) -> Void) {
        for (answer, refusal) in [(DiscoverCopyGateResult.sourceChanged, DiscoverCopyRefusal.sourceChanged),
                                  (.superseded, .superseded)] {
            let h = Harness(k: k, gate: [call: answer])
            let result = h.run()
            XCTAssertEqual(result, .refused(refusal), "gate call \(call)")
            XCTAssertEqual(h.gate.calls.count, call, "no gate is asked after the one that moved")
            XCTAssertEqual(h.gate.calls.last, answer)
            check(h, result)
        }
    }

    /// The stamp moved between the phases.
    func testMovedAtTheModesGatePlaysNothingAndDeletes() {
        forBothMoves(1) { h, _ in
            XCTAssertEqual(h.count("switchModesOff"), 0)
            XCTAssertEqual(h.count("playCopy"), 0)
            XCTAssertTrue(h.player.commands.isEmpty)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
            XCTAssertEqual(h.count("restoreModes"), 0)
        }
    }

    func testMovedAtThePlayCopyGateRestoresAndDeletesWithNoStop() {
        forBothMoves(2) { h, _ in
            XCTAssertEqual(h.count("playCopy"), 0)
            XCTAssertTrue(h.player.commands.isEmpty, "nothing of ours started, so no stop")
            XCTAssertEqual(h.count("restoreModes"), 1)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
        }
    }

    func testMovedAtASkipGateStopsOnlyIfCurrentThenCleansUp() {
        for call in [3, 5, 6] {
            forBothMoves(call) { h, _ in
                XCTAssertEqual(h.count("nextTrack"), call - 3)
                XCTAssertEqual(h.count("stop"), 0, "never the plain stop")
                XCTAssertEqual(h.count("play"), 0)
                assertNoCommandAfter("stopIfCurrent", h)
                XCTAssertEqual(h.count("restoreModes"), 1)
                XCTAssertEqual(h.count("deleteIfOwned"), 1)
                XCTAssertEqual(h.count("commitListening"), 0)
            }
        }
    }

    func testMovedAtThePlayGateStopsOnlyIfCurrentThenCleansUp() {
        forBothMoves(7) { h, _ in
            XCTAssertEqual(h.count("nextTrack"), 4)
            XCTAssertEqual(h.count("play"), 0)
            XCTAssertEqual(h.count("stop"), 0)
            assertNoCommandAfter("stopIfCurrent", h)
            XCTAssertEqual(h.count("restoreModes"), 1)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
            XCTAssertEqual(h.count("commitListening"), 0)
        }
    }

    func testMovedAtTheCommitGateAfterAConfirmedPlayIsARefusalNotListening() {
        forBothMoves(8) { h, result in
            XCTAssertNotEqual(result, .listening)
            XCTAssertEqual(h.count("play"), 1)
            XCTAssertEqual(h.count("commitListening"), 0)
            XCTAssertEqual(h.count("stop"), 0)
            assertNoCommandAfter("stopIfCurrent", h)
            XCTAssertEqual(h.player.state, .stopped)
            XCTAssertEqual(h.count("restoreModes"), 1)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
        }
    }

    func testMovedAtTheCommitGateForKEqualsOne() {
        forBothMoves(3, k: 1) { h, _ in
            XCTAssertEqual(h.player.commands, ["playCopy", "stopIfCurrent"])
            XCTAssertEqual(h.count("commitListening"), 0)
            XCTAssertEqual(h.count("restoreModes"), 1)
            XCTAssertEqual(h.count("deleteIfOwned"), 1)
        }
    }

    // MARK: - A request that is not a row

    func testASelectionOutsideTheRowsIsRefusedWithNoReadAndNoCommand() {
        let h = Harness(k: 6)                                  // selected = 5 of 5 rows
        XCTAssertEqual(h.run(), .refused(.unconfirmed(title: "")))
        XCTAssertEqual(h.count("deleteIfOwned"), 1)
        XCTAssertTrue(h.player.commands.isEmpty)
        XCTAssertTrue(h.gate.calls.isEmpty)
    }
}

import XCTest
@testable import music

/// Score step C5, section 9 item 4: the end watcher's truth table. Fakes and a
/// fake clock only; nothing here reaches Music.app.
final class DiscoverCopyWatcherTests: XCTestCase {
    private let hex = "00112233AABBCCDD"
    private let other = "FFEEDDCC00112233"
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func read(_ state: String, _ playlist: String?, _ track: String? = "T1") -> DiscoverCopyPlayerRead {
        DiscoverCopyPlayerRead(state: state, playlistID: playlist, trackID: track)
    }

    /// A watcher over a scripted read, a settable clock and a recording end queue.
    private final class Rig {
        var next: DiscoverCopyPlayerRead?
        var now: Date
        var reads = 0
        var ended: [String] = []
        private(set) var watcher: DiscoverCopyWatcher!

        init(now: Date) {
            self.now = now
            watcher = DiscoverCopyWatcher(seams: .init(
                read: { [unowned self] in reads += 1; return next },
                now: { [unowned self] in self.now },
                enqueueEnd: { [unowned self] txn in ended.append(txn) }))
        }

        /// Sets the read, moves the clock to `at` seconds after the start, ticks.
        func tick(_ read: DiscoverCopyPlayerRead?, at seconds: TimeInterval, from start: Date) {
            next = read
            now = start.addingTimeInterval(seconds)
            watcher.tick()
        }
    }

    // MARK: discoverCopyObservation

    func testObservationTable() {
        XCTAssertEqual(discoverCopyObservation(nil, hex: hex), .unreadable)
        XCTAssertEqual(discoverCopyObservation(read("", hex), hex: hex), .unreadable)
        XCTAssertEqual(discoverCopyObservation(read("something else", hex), hex: hex), .unreadable)
        XCTAssertEqual(discoverCopyObservation(read("stopped", nil, nil), hex: hex), .stopped)
        XCTAssertEqual(discoverCopyObservation(read("stopped", hex), hex: hex), .stopped)
        XCTAssertEqual(discoverCopyObservation(read("playing", hex), hex: hex), .inOurCopy)
        XCTAssertEqual(discoverCopyObservation(read("paused", hex, "T9"), hex: hex), .inOurCopy)
        XCTAssertEqual(discoverCopyObservation(read("paused", hex, nil), hex: hex), .inOurCopy)
        XCTAssertEqual(discoverCopyObservation(read("playing", other), hex: hex), .foreign)
        XCTAssertEqual(discoverCopyObservation(read("paused", other), hex: hex), .foreign)
        XCTAssertEqual(discoverCopyObservation(read("playing", nil), hex: hex), .unreadable)
        XCTAssertEqual(discoverCopyObservation(read("paused", nil), hex: hex), .unreadable)
        XCTAssertEqual(discoverCopyObservation(read("playing", ""), hex: hex), .unreadable)
    }

    func testObservationReadsALowercaseIDAsOurCopy() {
        XCTAssertEqual(discoverCopyObservation(read("playing", hex.lowercased()), hex: hex), .inOurCopy)
    }

    // MARK: discoverCopyEndStep

    func testInOurCopyClearsTheEvidence() {
        let old = DiscoverCopyEndEvidence(kind: .stopped, at: t0)
        let step = discoverCopyEndStep(evidence: old, observation: .inOurCopy, now: t0.addingTimeInterval(10))
        XCTAssertNil(step.evidence)
        XCTAssertFalse(step.ended)
    }

    func testUnreadableChangesNothing() {
        let old = DiscoverCopyEndEvidence(kind: .foreign, at: t0)
        let step = discoverCopyEndStep(evidence: old, observation: .unreadable, now: t0.addingTimeInterval(10))
        XCTAssertEqual(step.evidence, old)
        XCTAssertFalse(step.ended)
        let none = discoverCopyEndStep(evidence: nil, observation: .unreadable, now: t0)
        XCTAssertNil(none.evidence)
        XCTAssertFalse(none.ended)
    }

    func testAFirstStoppedOrForeignIsOnlyRecorded() {
        for kind in [DiscoverCopyObservation.stopped, .foreign] {
            let step = discoverCopyEndStep(evidence: nil, observation: kind, now: t0)
            XCTAssertEqual(step.evidence, DiscoverCopyEndEvidence(kind: kind, at: t0))
            XCTAssertFalse(step.ended)
        }
    }

    func testTheSameKindAtTheGapEndsAndJustUnderItDoesNot() {
        for kind in [DiscoverCopyObservation.stopped, .foreign] {
            let first = DiscoverCopyEndEvidence(kind: kind, at: t0)
            let under = discoverCopyEndStep(evidence: first, observation: kind, now: t0.addingTimeInterval(2.9))
            XCTAssertFalse(under.ended)
            XCTAssertEqual(under.evidence, first, "a young repeat keeps the first observation's time")
            let at = discoverCopyEndStep(evidence: first, observation: kind, now: t0.addingTimeInterval(3))
            XCTAssertTrue(at.ended)
        }
    }

    func testTheOtherKindReplacesTheEvidenceAndDoesNotEnd() {
        let first = DiscoverCopyEndEvidence(kind: .stopped, at: t0)
        let later = t0.addingTimeInterval(60)
        let step = discoverCopyEndStep(evidence: first, observation: .foreign, now: later)
        XCTAssertFalse(step.ended)
        XCTAssertEqual(step.evidence, DiscoverCopyEndEvidence(kind: .foreign, at: later))
    }

    // MARK: The watcher

    func testNothingWatchedRunsNoRead() {
        let rig = Rig(now: t0)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        rig.tick(read("stopped", nil), at: 10, from: t0)
        XCTAssertEqual(rig.reads, 0)
        XCTAssertEqual(rig.ended, [])
    }

    func testPausedInOurCopyForALongTimeNeverEnds() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        for second in 0..<3_600 { rig.tick(read("paused", hex), at: TimeInterval(second), from: t0) }
        XCTAssertEqual(rig.ended, [])
        XCTAssertEqual(rig.reads, 3_600)
    }

    func testNextAndPreviousInsideOurCopyNeverEnd() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        let tracks = ["T1", "T2", "T3", "T2", "T1", "T2", "T3", "T4"]
        for (second, track) in tracks.enumerated() {
            rig.tick(read("playing", hex, track), at: TimeInterval(second * 2), from: t0)
        }
        XCTAssertEqual(rig.ended, [])
    }

    func testOneUnreadableReadDoesNotEndAndDoesNotClearEarlierEvidence() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(nil, at: 0, from: t0)
        rig.tick(nil, at: 10, from: t0)
        XCTAssertEqual(rig.ended, [], "unreadable reads are never evidence")

        rig.tick(read("stopped", nil), at: 20, from: t0)
        rig.tick(nil, at: 21, from: t0)
        XCTAssertEqual(rig.ended, [])
        rig.tick(read("stopped", nil), at: 23, from: t0)
        XCTAssertEqual(rig.ended, ["A"], "the stopped read at 20 s survived the bad read at 21 s")
    }

    func testOneForeignReadDoesNotEnd() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("playing", other), at: 0, from: t0)
        XCTAssertEqual(rig.ended, [])
        rig.tick(read("playing", hex), at: 5, from: t0)
        rig.tick(read("playing", hex), at: 50, from: t0)
        XCTAssertEqual(rig.ended, [])
    }

    func testStoppedTwiceThreeSecondsApartEnds() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        XCTAssertEqual(rig.ended, [])
        rig.tick(read("stopped", nil), at: 3, from: t0)
        XCTAssertEqual(rig.ended, ["A"])
    }

    func testStoppedTwiceJustUnderThreeSecondsApartHasNotEndedYet() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        rig.tick(read("stopped", nil), at: 2.9, from: t0)
        XCTAssertEqual(rig.ended, [])
        rig.tick(read("stopped", nil), at: 3.1, from: t0)
        XCTAssertEqual(rig.ended, ["A"], "the gap is measured from the first observation")
    }

    func testForeignTwiceThreeSecondsApartEnds() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("playing", other), at: 0, from: t0)
        rig.tick(read("paused", other), at: 3, from: t0)
        XCTAssertEqual(rig.ended, ["A"])
    }

    func testStoppedThenForeignDoesNotEnd() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        rig.tick(read("playing", other), at: 3, from: t0)
        XCTAssertEqual(rig.ended, [], "the kinds differ")
        rig.tick(read("playing", other), at: 5.9, from: t0)
        XCTAssertEqual(rig.ended, [], "the foreign evidence dates from 3 s")
        rig.tick(read("playing", other), at: 6, from: t0)
        XCTAssertEqual(rig.ended, ["A"])
    }

    func testPlayingWithAnUnreadablePlaylistNeverEnds() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        for second in 0..<600 { rig.tick(read("playing", nil, nil), at: TimeInterval(second), from: t0) }
        for second in 600..<1_200 { rig.tick(read("paused", nil, nil), at: TimeInterval(second), from: t0) }
        XCTAssertEqual(rig.ended, [])
    }

    func testEnqueueEndFiresOnceAndTheCopyIsNoLongerWatched() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        rig.tick(read("stopped", nil), at: 3, from: t0)
        XCTAssertEqual(rig.ended, ["A"])
        let readsAtEnd = rig.reads
        for second in 4..<20 { rig.tick(read("stopped", nil), at: TimeInterval(second), from: t0) }
        XCTAssertEqual(rig.ended, ["A"])
        XCTAssertEqual(rig.reads, readsAtEnd, "nothing is watched any more, so no script runs")
    }

    func testTwoWatchedCopiesAreJudgedSeparatelyFromOneRead() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.watcher.adopt(txn: "B", hex: other)
        rig.tick(read("playing", other), at: 0, from: t0)
        rig.tick(read("playing", other), at: 3, from: t0)
        XCTAssertEqual(rig.ended, ["A"], "B's copy is the one playing")
        XCTAssertEqual(rig.reads, 2, "one read per tick, however many are watched")
    }

    // MARK: The same copy replayed

    func testTheSameCopyReplayedNeverEnds() {
        var evidence: DiscoverCopyEndEvidence?
        let k = 6
        var sequence: [DiscoverCopyPlayerRead] = [read("playing", hex, "T4"), read("paused", hex, "T1")]
        sequence += (2...k).map { read("paused", hex, "T\($0)") }
        sequence.append(read("playing", hex, "T\(k)"))

        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        for (index, one) in sequence.enumerated() {
            let now = t0.addingTimeInterval(TimeInterval(index))
            let step = discoverCopyEndStep(evidence: evidence,
                                           observation: discoverCopyObservation(one, hex: hex), now: now)
            XCTAssertNil(step.evidence, "evidence stays nil throughout")
            XCTAssertFalse(step.ended)
            evidence = step.evidence
            rig.tick(one, at: TimeInterval(index), from: t0)
        }
        XCTAssertGreaterThan(TimeInterval(sequence.count - 1), DiscoverCopyTiming.endEvidenceGap)
        XCTAssertEqual(rig.ended, [])
    }

    func testReadoptingAWatchedTxnClearsPendingEvidenceAndKeepsOneEntry() {
        let rig = Rig(now: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 0, from: t0)
        rig.watcher.adopt(txn: "A", hex: hex)
        rig.tick(read("stopped", nil), at: 3, from: t0)
        XCTAssertEqual(rig.ended, [], "the stopped read at 0 s was cleared by the re-adopt")
        rig.tick(read("stopped", nil), at: 6, from: t0)
        XCTAssertEqual(rig.ended, ["A"], "one watched entry, so one end")
        rig.tick(read("stopped", nil), at: 9, from: t0)
        rig.tick(read("stopped", nil), at: 12, from: t0)
        XCTAssertEqual(rig.ended, ["A"])
    }

    // MARK: The end is handed on, never run by the watcher

    func testADeleteWaitsOnTheQueueWhileAPlayMutationIsInFlight() throws {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [
            DiscoverCopyEntry(txn: "A", playlistID: "pl.one", title: "Morning Mix", state: .listening,
                              hex: hex, copiesRead: 0, watching: true, copySeen: false, toldAtLaunch: false,
                              priorShuffle: nil, priorRepeat: nil, createdAt: 1, updatedAt: 1),
        ])
        var scripts: [String] = []
        let deleter = DiscoverCopyDeleter(journal: journal, run: { scripts.append($0); return "deleted" })
        var restored: [String] = []
        var queue: [() -> Void] = []        // stands for the action queue, busy with a play

        var clock = t0
        var next: DiscoverCopyPlayerRead? = read("stopped", nil)
        let watcher = DiscoverCopyWatcher(seams: .init(
            read: { next },
            now: { clock },
            enqueueEnd: { txn in
                queue.append {
                    discoverCopyHandleEnd(txn: txn, deleter: deleter, journal: journal,
                                          restoreModes: { restored.append($0) },
                                          readopt: { _, _ in XCTFail("not spared") })
                }
            }))
        watcher.adopt(txn: "A", hex: hex)
        watcher.tick()
        clock = t0.addingTimeInterval(3)
        next = read("stopped", nil)
        watcher.tick()

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(scripts, [], "no delete script runs until the queue releases it")
        XCTAssertEqual(journal.stored[0].state, .listening)

        queue.removeFirst()()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("delete pl"))
        XCTAssertEqual(journal.stored[0].state, .closed)
        XCTAssertFalse(journal.stored[0].watching)
        XCTAssertEqual(restored, ["A"])
    }

    // MARK: The watcher's script and its parser

    func testTheObservationScriptReadsThreeThingsEachInItsOwnTry() {
        let script = discoverCopyObservationScript
        XCTAssertTrue(script.contains("player state as text"))
        XCTAssertTrue(script.contains("persistent ID of current playlist"))
        XCTAssertTrue(script.contains("persistent ID of current track"))
        XCTAssertEqual(script.components(separatedBy: "end try").count - 1, 3)
        for verb in ["delete", "play ", "pause", "stop\n", "next track", "set shuffle", "name of"] {
            XCTAssertFalse(script.contains(verb), "the read changes nothing and reads no name: \(verb)")
        }
    }

    func testTheObservationOutputParses() {
        XCTAssertNil(discoverCopyPlayerRead(fromScriptOutput: nil))
        XCTAssertNil(discoverCopyPlayerRead(fromScriptOutput: "playing"))
        XCTAssertNil(discoverCopyPlayerRead(fromScriptOutput: "a|b|c|d"))
        XCTAssertEqual(discoverCopyPlayerRead(fromScriptOutput: "playing|\(hex)|T1\n"),
                       DiscoverCopyPlayerRead(state: "playing", playlistID: hex, trackID: "T1"))
        XCTAssertEqual(discoverCopyPlayerRead(fromScriptOutput: "stopped||"),
                       DiscoverCopyPlayerRead(state: "stopped", playlistID: nil, trackID: nil))
        XCTAssertEqual(discoverCopyPlayerRead(fromScriptOutput: "||"),
                       DiscoverCopyPlayerRead(state: "", playlistID: nil, trackID: nil))
        XCTAssertEqual(discoverCopyObservation(discoverCopyPlayerRead(fromScriptOutput: "||"), hex: hex),
                       .unreadable)
        XCTAssertEqual(discoverCopyObservation(discoverCopyPlayerRead(fromScriptOutput: "playing||"), hex: hex),
                       .unreadable, "a station: playing with no readable playlist")
    }
}

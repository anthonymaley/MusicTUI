import XCTest
@testable import music

// Album-cleanup step A3: the proof collector over fakes and a fake clock. The
// action queue is a list the test drains; no thread, socket, file or script.
// Fixtures (`a3Entry`, `a3GoodRead`, …) live in DiscoverAlbumProofTests.swift.

private final class A3CollectorHarness {
    var clock: Date
    var queue: [() -> Void] = []
    var spandac = true
    var readAnswers: [String: DiscoverAlbumEntryRead?] = [:]
    private(set) var reads: [String] = []
    private(set) var ownedAfterEnd: [String] = []
    private(set) var settled: [String] = []
    private(set) var logs: [String] = []
    let journal: InMemoryDiscoverCopyJournalStore
    let before: InMemoryBeforeSetStore
    let relations: FakeLibraryRelations
    private(set) var collector: DiscoverAlbumProofCollector!

    init(entry: DiscoverCopyEntry, before: Set<String> = [albumTestHex(42)], at offset: Double = 40) {
        clock = Date(timeIntervalSince1970: a3Sent + offset)
        journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
        self.before = InMemoryBeforeSetStore(files: ["before-\(entry.txn).json": before])
        relations = FakeLibraryRelations()
        collector = DiscoverAlbumProofCollector(seams: .init(
            journal: journal,
            beforeSet: self.before,
            relations: { [unowned self] in self.relations },
            readEntry: { [unowned self] hex in
                self.reads.append(hex)
                if let answer = self.readAnswers[hex] { return answer }
                guard let position = (1...100).first(where: { a3EntryHex($0) == hex }) else { return nil }
                return a3GoodRead(position)
            },
            spandacDataSelected: { [unowned self] in self.spandac },
            now: { [unowned self] in self.clock },
            enqueue: { [unowned self] item in self.queue.append(item) },
            ownedAfterEnd: { [unowned self] txn, position in self.ownedAfterEnd.append("\(txn)#\(position)") },
            settled: { [unowned self] txn in self.settled.append(txn) },
            log: { [unowned self] line in self.logs.append(line) }))
    }

    func drain() { while !queue.isEmpty { queue.removeFirst()() } }

    /// Moves the clock by `seconds`, ticks once and runs everything queued.
    func step(_ seconds: Double = 0) {
        clock = clock.addingTimeInterval(seconds)
        collector.tick()
        drain()
    }

    var entry: DiscoverCopyEntry { journal.stored[0] }
    func song(_ position: Int) -> DiscoverAlbumSong { entry.songs![position - 1] }

    /// Every relations call answers each listed song with one relation to its own e_i.
    func answerOwnRelations(_ positions: [Int]) {
        var answer: [String: [String?]] = [:]
        for position in positions { answer[albumTestCatalogueID(position)] = [a3Alias(position)] }
        relations.results = [.success(answer)]
    }
}

final class DiscoverAlbumCollectorTests: XCTestCase {

    // MARK: Cadence and bookkeeping

    func testNothingAdoptedDoesNothing() {
        let harness = A3CollectorHarness(entry: a3Entry())
        harness.collector.tick()
        XCTAssertTrue(harness.queue.isEmpty)
        XCTAssertTrue(harness.journal.events.isEmpty)
    }

    func testOneItemPerEntryAndNoneWhileOneIsOutstanding() {
        let harness = A3CollectorHarness(entry: a3Entry())
        harness.collector.adopt(txn: albumTestTxn)
        harness.collector.tick()
        harness.collector.tick()
        XCTAssertEqual(harness.queue.count, 1, "an outstanding item blocks the next")
        harness.drain()
        harness.clock = Date(timeIntervalSince1970: a3Sent + 44.9)
        harness.collector.tick()
        XCTAssertTrue(harness.queue.isEmpty, "the last read is under collectorCadence old")
        harness.clock = Date(timeIntervalSince1970: a3Sent + 45)
        harness.collector.tick()
        XCTAssertEqual(harness.queue.count, 1)
    }

    func testAdoptIsThreadSafe() {
        let harness = A3CollectorHarness(entry: a3Entry())
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            harness.collector.adopt(txn: "T\(index % 50)")
        }
        XCTAssertEqual(harness.collector.adoptedTxns.count, 50)
    }

    // MARK: Proving a song

    func testTwoReadsFiveSecondsApartThenThePReadMakeItOwned() throws {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.answerOwnRelations([1])
        harness.collector.adopt(txn: albumTestTxn)

        harness.step()
        XCTAssertEqual(harness.song(1).state, .pending, "one read alone stays pending")
        XCTAssertEqual(harness.song(1).p4FirstSeenAt, a3Sent + 40)
        XCTAssertTrue(harness.reads.isEmpty)

        harness.step(5)
        let song = harness.song(1)
        XCTAssertEqual(song.state, .owned)
        XCTAssertEqual(song.alias, a3Alias(1))
        XCTAssertEqual(song.cloudStatus, "subscription")
        XCTAssertEqual(harness.reads, [a3EntryHex(1)], "one P-read, of e_i")
        XCTAssertTrue(discoverCopyEntryHoldsInvariants(harness.entry), "the owned-song invariant holds")
        XCTAssertEqual(harness.relations.calls, [[albumTestCatalogueID(1)], [albumTestCatalogueID(1)]])
        XCTAssertEqual(harness.settled, [albumTestTxn])
        XCTAssertTrue(harness.ownedAfterEnd.isEmpty, "the container is not gone")
        XCTAssertTrue(harness.collector.adoptedTxns.isEmpty, "no pending song left: dropped")

        harness.step(5)
        XCTAssertEqual(harness.relations.calls.count, 2, "a dropped entry is not read again")
    }

    func testRelationsAreReadForEveryPendingSongInOneCall() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 3))
        harness.answerOwnRelations([1, 2, 3])
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.relations.calls, [(1...3).map(albumTestCatalogueID)])
        harness.step(5)
        XCTAssertEqual((1...3).map { harness.song($0).state }, [.owned, .owned, .owned])
        XCTAssertEqual(harness.reads, (1...3).map(a3EntryHex), "one P-read item per song, in album order")
    }

    func testANullRelationKeepsItPendingAndRestartsTheStreak() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        let id = albumTestCatalogueID(1)
        harness.relations.results = [.success([id: [a3Alias(1)]]), .success([id: [nil]]),
                                     .success([id: [a3Alias(1)]]), .success([id: [a3Alias(1)]])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.song(1).p4FirstSeenAt, a3Sent + 40)
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .pending, "CH11")
        XCTAssertNil(harness.song(1).p4FirstSeenAt)
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .pending)
        XCTAssertEqual(harness.song(1).p4FirstSeenAt, a3Sent + 50)
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .owned)
    }

    func testTwoRelationsAreUncertainAndSettled() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.relations.results = [.success([albumTestCatalogueID(1): [a3Alias(1), "77"]])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.song(1).uncertainReason, "p4_several_relations")
        XCTAssertEqual(harness.settled, [albumTestTxn])
        XCTAssertTrue(harness.reads.isEmpty)
    }

    func testAnAliasForAnotherRowIsUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.relations.results = [.success([albumTestCatalogueID(1): [a3Alias(2)]])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.song(1).uncertainReason, "p4_other_row")
    }

    func testAnUnreadableRelationsReplyMakesEveryAskedSongUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2))
        harness.relations.results = [.failure(SpanDACLibraryOpError.failed("socket"))]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual([harness.song(1).state, harness.song(2).state], [.uncertain, .uncertain], "CH12")
        XCTAssertEqual(harness.song(1).uncertainReason, "p4_unreadable")
        XCTAssertEqual(harness.settled, [albumTestTxn])
    }

    func testAReplyThatLeavesASongOutIsUnreadableForThatSong() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2))
        harness.relations.results = [.success([albumTestCatalogueID(1): []])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.song(1).state, .pending)
        XCTAssertEqual(harness.song(2).state, .uncertain)
        XCTAssertEqual(harness.song(2).uncertainReason, "p4_unreadable")
    }

    func testAnUnreadablePReadIsUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.answerOwnRelations([1])
        harness.readAnswers[a3EntryHex(1)] = .some(nil)
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.song(1).uncertainReason, "p3_unreadable")
        XCTAssertEqual(harness.settled, [albumTestTxn])
    }

    func testAP7FailureRecordsTheStatusReadAndIsUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.answerOwnRelations([1])
        harness.readAnswers[a3EntryHex(1)] = a3GoodRead(1, cloudStatus: "matched")
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.song(1).cloudStatus, "matched")
    }

    // MARK: The no-read verdicts

    func testP1AndP6DecideWithoutARelationsRead() {
        let songs = [a3PendingSong(1, relationsBefore: [1, 0]), a3PendingSong(2)]
        let harness = A3CollectorHarness(entry: a3Entry(songs: songs), before: [a3EntryHex(2)])
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual([harness.song(1).state, harness.song(2).state], [.preexisting, .preexisting])
        XCTAssertTrue(harness.relations.calls.isEmpty)
        XCTAssertEqual(harness.before.calls, ["read:before-\(albumTestTxn).json"], "B read once, only for song 2")
        XCTAssertEqual(harness.settled, [albumTestTxn])
        XCTAssertTrue(harness.collector.adoptedTxns.isEmpty)
    }

    func testAnUnreadableBeforeSetIsUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2))
        harness.before.failReads = true
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual([harness.song(1).state, harness.song(2).state], [.uncertain, .uncertain])
        XCTAssertEqual(harness.song(1).uncertainReason, "p6_unreadable")
        XCTAssertEqual(harness.before.calls.count, 1, "B is read at most once per item")
    }

    // MARK: The window

    func testTheWindowClosingWithoutP4IsUncertain() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1), at: 170)
        harness.relations.results = [.success([albumTestCatalogueID(1): []])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .pending)
        harness.step(5)   // a3Sent + 180: still inside, inclusive
        XCTAssertEqual(harness.song(1).state, .pending)
        harness.step(5)   // a3Sent + 185
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.song(1).uncertainReason, "window_closed")
        XCTAssertEqual(harness.relations.calls.count, 3, "no relations read once the window has closed")
        XCTAssertEqual(harness.settled, [albumTestTxn])
    }

    func testNoRelationsAreReadWhileSpanDACDataIsNotSelectedAndTheWindowStillCloses() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2))
        harness.spandac = false
        harness.answerOwnRelations([1, 2])
        harness.collector.adopt(txn: albumTestTxn)
        for _ in 0..<40 { harness.step(5) }   // to a3Sent + 240
        XCTAssertTrue(harness.relations.calls.isEmpty)
        XCTAssertEqual([harness.song(1).state, harness.song(2).state], [.uncertain, .uncertain])
        XCTAssertEqual(harness.song(1).uncertainReason, "window_closed")
        XCTAssertEqual(harness.settled, [albumTestTxn])
        XCTAssertTrue(harness.collector.adoptedTxns.isEmpty)
    }

    // MARK: Design test 14, collector half

    func testASongProvenAfterTheContainerIsGoneIsHandedToTheGuardOnce() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2, containerGone: true))
        harness.relations.results = [.success([albumTestCatalogueID(1): [a3Alias(1)], albumTestCatalogueID(2): []])]
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .owned)
        XCTAssertEqual(harness.ownedAfterEnd, ["\(albumTestTxn)#1"])
        XCTAssertEqual(harness.settled, [albumTestTxn])
        harness.step(5)
        harness.step(5)
        XCTAssertEqual(harness.ownedAfterEnd, ["\(albumTestTxn)#1"], "once")
        XCTAssertEqual(harness.reads, [a3EntryHex(1)])
    }

    func testASongWhoseWindowClosesFirstIsUncertainAndSettled() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1, containerGone: true), at: 178)
        harness.answerOwnRelations([1])
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()        // +178: first sighting
        harness.step(5)       // +183: the window closed before the second read
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.song(1).uncertainReason, "window_closed")
        XCTAssertEqual(harness.settled, [albumTestTxn])
        XCTAssertTrue(harness.ownedAfterEnd.isEmpty)
        XCTAssertTrue(harness.reads.isEmpty)
    }

    // MARK: Robustness

    func testAHeldSongFromBeforeACrashGoesStraightToItsPRead() {
        var song = a3PendingSong(1)
        song.alias = a3Alias(1)
        song.p4FirstSeenAt = a3Sent + 40
        let harness = A3CollectorHarness(entry: a3Entry(songs: [song]), at: 300)
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertTrue(harness.relations.calls.isEmpty, "P4 already held; the window does not apply")
        XCTAssertEqual(harness.song(1).state, .owned)
    }

    func testAFailedWriteChangesNothingAndIsRetried() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 1))
        harness.relations.results = [.success([albumTestCatalogueID(1): [a3Alias(1), "9"]])]
        var failing = true
        harness.journal.failWrites = { _ in failing }
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        XCTAssertEqual(harness.song(1).state, .pending)
        XCTAssertTrue(harness.settled.isEmpty)
        XCTAssertEqual(harness.collector.adoptedTxns, [albumTestTxn])
        failing = false
        harness.step(5)
        XCTAssertEqual(harness.song(1).state, .uncertain)
        XCTAssertEqual(harness.settled, [albumTestTxn])
    }

    func testAnEntryWithNoPendingSongOrNoAlbumIsDropped() {
        let harness = A3CollectorHarness(entry: albumTestEntry(state: .owned, hex: albumTestHex(900), songState: .intent))
        harness.collector.adopt(txn: albumTestTxn)
        harness.collector.adopt(txn: "NOT-IN-THE-JOURNAL")
        harness.step()
        XCTAssertTrue(harness.collector.adoptedTxns.isEmpty)
        XCTAssertTrue(harness.relations.calls.isEmpty)
        XCTAssertTrue(harness.settled.isEmpty)
    }

    func testTheCollectorNeverDeletesAndOnlyWritesTheJournal() {
        let harness = A3CollectorHarness(entry: a3Entry(count: 2, containerGone: true))
        harness.answerOwnRelations([1, 2])
        harness.collector.adopt(txn: albumTestTxn)
        harness.step()
        harness.step(5)
        XCTAssertEqual(harness.entry.state, .owned, "the entry's own state is not the collector's")
        XCTAssertEqual(harness.entry.containerGone, true)
        XCTAssertFalse(harness.before.calls.contains { $0.hasPrefix("delete:") || $0.hasPrefix("write:") })
        XCTAssertEqual(harness.ownedAfterEnd, ["\(albumTestTxn)#1", "\(albumTestTxn)#2"])
    }
}

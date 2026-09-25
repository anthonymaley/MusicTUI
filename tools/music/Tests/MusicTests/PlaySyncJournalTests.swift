import Darwin
import XCTest
@testable import music

/// The journal file: its shape on disk, what counts as readable, and how it is
/// written.
final class PlaySyncJournalTests: XCTestCase {

    private var directory: URL!
    private var journalURL: URL { directory.appendingPathComponent("journal.json") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playsync-journal-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entry(_ seq: Int, _ status: EntryState, phase: WritePhase = .countAndDate,
                       process: MusicProcess = MusicProcess(pid: 60641, startedAt: 1_790_200_000.25)) -> PlaySyncEntry {
        let planned = status == .unresolved || status == .writing
        return PlaySyncEntry(
            ledgerID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", seq: seq,
            playID: "7D444840-9DC0-11D1-B245-5FFDCE74FAD2-\(seq)",
            alias: "596357614188841472", persistentID: "0846B01728D34A00",
            title: "Are You Awake? - Kevin Shields", artist: "Lost In Translation OST",
            completedAt: 1_790_300_187, state: status, phase: phase,
            before: planned ? TrackPlayState(count: 27, date: 1_790_000_000) : nil,
            target: planned ? TrackPlayState(count: 28, date: 1_790_300_187) : nil,
            attempt: planned ? WriteAttempt(phase: phase, process: process, startedAt: 1_790_300_200) : nil,
            observed: nil, barrierReplans: 0, reason: nil, reconciled: false, reported: true)
    }

    private func sample() -> PlaySyncJournal {
        PlaySyncJournal(ledgerID: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", consumedThrough: 2,
                        entries: [entry(1, .done), entry(2, .unresolved, phase: .dateOnly)],
                        retiredLedgers: [RetiredLedger(ledgerID: "OLD", consumedThrough: 7, retiredAt: 1_790_300_000)])
    }

    // MARK: Shape

    func testJournalUsesSnakeCaseKeysAndRoundTrips() throws {
        let journal = sample()
        let data = try journal.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "ledger_id", "consumed_through", "entries", "retired_ledgers"])
        XCTAssertEqual(object["format"] as? Int, 1)
        let retired = try XCTUnwrap((object["retired_ledgers"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(retired.keys), ["ledger_id", "consumed_through", "retired_at"])
        XCTAssertEqual(PlaySyncJournal.decode(data), .loaded(journal))
    }

    func testSavedJournalLoadsBackEqual() throws {
        try sample().save(to: journalURL)
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .loaded(sample()))
    }

    /// The barrier compares start times exactly, so a saved attempt must come
    /// back with the very same value.
    func testStartTimesSurviveSaveAndLoadExactly() throws {
        var starts: [Double] = []
        if case .success(let own) = processStartTime(pid: getpid()) { starts.append(own) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let seconds = Int.random(in: 1_600_000_000...1_900_000_000, using: &generator)
            let micros = Int.random(in: 0...999_999, using: &generator)
            starts.append(Double(seconds) + Double(micros) / 1_000_000)
        }
        let entries = starts.enumerated().map { index, start in
            entry(index + 1, .unresolved, process: MusicProcess(pid: Int32(100 + index), startedAt: start))
        }
        let journal = PlaySyncJournal(ledgerID: "L", consumedThrough: entries.count, entries: entries, retiredLedgers: [])
        try journal.save(to: journalURL)

        guard case .loaded(let loaded) = PlaySyncJournal.load(from: journalURL) else { return XCTFail("unreadable") }
        XCTAssertEqual(loaded.entries.map { $0.attempt?.process.startedAt }, starts)
        XCTAssertEqual(loaded, journal)
    }

    // MARK: Reading: missing is empty, nothing else is

    func testMissingFileIsAnEmptyJournal() {
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .loaded(.empty))
        XCTAssertEqual(PlaySyncJournal.empty.consumedThrough, 0)
        XCTAssertNil(PlaySyncJournal.empty.ledgerID)
    }

    func testUnreadableBytesAreNeverEmpty() throws {
        let samples = ["", "null", "[]", "{}", "{\"format\":1", "not json",
                       "{\"format\":1,\"consumed_through\":0,\"retired_ledgers\":[]}",
                       "{\"format\":\"1\",\"consumed_through\":0,\"entries\":[],\"retired_ledgers\":[]}"]
        for text in samples {
            XCTAssertEqual(PlaySyncJournal.decode(Data(text.utf8)), .unreadable, text)
        }
        try Data("{\"format\":1".utf8).write(to: journalURL)
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .unreadable)
    }

    func testFormatsOtherThanOne() {
        XCTAssertEqual(PlaySyncJournal.decode(Data("{\"format\":2}".utf8)), .tooNew)
        XCTAssertEqual(PlaySyncJournal.decode(Data("{\"format\":7,\"entries\":\"anything\"}".utf8)), .tooNew)
        XCTAssertEqual(PlaySyncJournal.decode(
            Data("{\"format\":0,\"consumed_through\":0,\"entries\":[],\"retired_ledgers\":[]}".utf8)), .unreadable)
    }

    func testEntriesThatBreakTheRulesAreUnreadable() throws {
        var noAttempt = entry(1, .unresolved)
        noAttempt.attempt = nil
        var dateOnlyWithoutTarget = entry(2, .pending, phase: .dateOnly)
        dateOnlyWithoutTarget.target = nil
        var targetWithoutBefore = entry(3, .pending)
        targetWithoutBefore.target = TrackPlayState(count: 1, date: 1)
        var writingWithoutTarget = entry(4, .writing)
        writingWithoutTarget.target = nil

        for broken in [noAttempt, dateOnlyWithoutTarget, targetWithoutBefore, writingWithoutTarget] {
            let journal = PlaySyncJournal(ledgerID: "L", consumedThrough: 4, entries: [broken], retiredLedgers: [])
            XCTAssertEqual(PlaySyncJournal.decode(try journal.encoded()), .unreadable, "\(broken.seq)")
        }
        let cursorWithoutLedger = PlaySyncJournal(ledgerID: nil, consumedThrough: 3, entries: [], retiredLedgers: [])
        XCTAssertEqual(PlaySyncJournal.decode(try cursorWithoutLedger.encoded()), .unreadable)
        let negative = PlaySyncJournal(ledgerID: "L", consumedThrough: -1, entries: [], retiredLedgers: [])
        XCTAssertEqual(PlaySyncJournal.decode(try negative.encoded()), .unreadable)
    }

    func testSymlinkOrFolderInPlaceOfTheJournalIsUnreadable() throws {
        let real = directory.appendingPathComponent("real.json")
        try sample().save(to: real)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: real)
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .unreadable)

        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .unreadable)
    }

    // MARK: Writing

    func testSaveIsPrivateAndLeavesNoTemporaryFile() throws {
        try sample().save(to: journalURL)
        var shorter = sample()
        shorter.entries = []
        try shorter.save(to: journalURL)

        let mode = try FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["journal.json"])
        XCTAssertEqual(PlaySyncJournal.load(from: journalURL), .loaded(shorter))
    }

    func testFailedSaveLeavesTheOldFileWhole() throws {
        try sample().save(to: journalURL)
        let before = try Data(contentsOf: journalURL)
        chmod(directory.path, 0o500)
        defer { chmod(directory.path, 0o700) }

        XCTAssertThrowsError(try PlaySyncJournal.empty.save(to: journalURL)) { error in
            XCTAssertEqual((error as? DurableFileError)?.step, "create")
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), before)
    }

    // MARK: Recovery and compaction

    func testInterruptedWriteBecomesUnresolvedWithEverythingKept() {
        var journal = sample()
        var interrupted = entry(3, .writing, phase: .dateOnly)
        interrupted.reported = true
        journal.entries.append(interrupted)

        journal.recoverInterruptedWrites()

        let recovered = journal.entries[2]
        XCTAssertEqual(recovered.state, .unresolved)
        XCTAssertEqual(recovered.phase, .dateOnly)
        XCTAssertEqual(recovered.target, interrupted.target)
        XCTAssertEqual(recovered.before, interrupted.before)
        XCTAssertEqual(recovered.attempt, interrupted.attempt)
        XCTAssertFalse(recovered.reported, "newly unconfirmed, so reported once")
        XCTAssertEqual(journal.entries[0].state, .done)
    }

    func testCompactionDropsOnlyTheOldestRecordedEntries() {
        var journal = PlaySyncJournal.empty
        journal.entries = [entry(1, .done), entry(2, .unmatched), entry(3, .done), entry(4, .conflict),
                           entry(5, .done), entry(6, .unresolved), entry(7, .pending), entry(8, .done)]
        journal.compact(keepingDone: 2)
        XCTAssertEqual(journal.entries.map(\.seq), [2, 4, 5, 6, 7, 8])

        journal.compact(keepingDone: 10)
        XCTAssertEqual(journal.entries.map(\.seq), [2, 4, 5, 6, 7, 8])
    }

    // MARK: The folder

    func testPrivateFolderRules() throws {
        let fresh = directory.appendingPathComponent("a/b/playsync")
        XCTAssertTrue(PrivateDirectory.prepare(fresh))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertTrue(PrivateDirectory.prepare(fresh), "an existing private folder is accepted")

        let open = directory.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o750])
        XCTAssertFalse(PrivateDirectory.prepare(open))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: open.path)[.posixPermissions] as? Int, 0o750)

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
        XCTAssertFalse(PrivateDirectory.prepare(link))
    }
}

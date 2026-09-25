import Darwin
import XCTest
@testable import music

// MARK: - Fixtures (real values where the record has them)

/// Music.app persistent IDs for the aliases Bridge reports, as recorded.
private enum Song {
    static let awakeAlias = "596357614188841472"
    static let awake = "0846B01728D34A00"          // Are You Awake?
    static let donorAlias = "-2898457328848859944"
    static let donor = "D7C69C6A85560CD8"          // Organ Donor
    static let spontAlias = "854956139719541203"
    static let spont = "0BDD6A144E85C1D3"          // Spontaneous
    static let tranzAlias = "-2643396558234642425"
    static let tranz = "DB50C4D5E9EF1807"          // Tranz
}

/// Completion times, epoch seconds, from the recorded plays.
private enum At {
    static let first = 1_790_300_187    // 2026-09-25T01:36:27.496Z
    static let second = 1_790_300_335   // 2026-09-25T01:38:55.091Z
    static let third = 1_790_300_448    // 2026-09-25T01:40:48.411Z
    static let fourth = 1_790_300_600   // 2026-09-25T01:43:20.407Z
    static let earlier = 1_790_000_000  // a last-played date before any of them
    static let native = 1_790_300_879   // a native Music.app play after all of them
}

private let P1 = MusicProcess(pid: 4413, startedAt: 1_790_200_000.250_001)
private let P2 = MusicProcess(pid: 5120, startedAt: 1_790_310_000.654_321)
private let P3 = MusicProcess(pid: 6001, startedAt: 1_790_320_000.000_007)
private let P4 = MusicProcess(pid: 6002, startedAt: 1_790_330_000.5)

private func state(_ count: Int, _ date: Int?) -> TrackPlayState { TrackPlayState(count: count, date: date) }

// MARK: - Fakes

private final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

private struct FeedRequest: Equatable {
    let ledgerID: String?
    let after: Int
    let limit: Int
}

/// Bridge's play record, in memory.
private final class FakeFeed: CompletedPlaysReading {
    var ledgerID: String
    var plays: [CompletedPlayRecord] = []
    /// Thrown by the request with this index (0-based, counted over the feed's life).
    var errors: [Int: SourceAppError] = [:]
    /// Replaces the normal answer entirely.
    var override: ((String?, Int, Int) throws -> CompletedPlaysPage)?
    private(set) var requests: [FeedRequest] = []
    /// Runs once, at the start of the very first request.
    var beforeFetch: (() -> Void)?

    init(ledgerID: String = "L1") { self.ledgerID = ledgerID }

    @discardableResult
    func add(_ alias: String?, _ title: String, at completedAt: Int) -> Int {
        let seq = plays.count + 1
        plays.append(CompletedPlayRecord(
            seq: seq, playID: "\(ledgerID)-play-\(seq)", alias: alias, libraryID: "i.test\(seq)",
            title: title, artist: "Artist", completedAt: Date(timeIntervalSince1970: TimeInterval(completedAt) + 0.496),
            end: "advance"))
        return seq
    }

    func replaceLedger(with id: String) {
        ledgerID = id
        plays = []
    }

    func completedPlays(ledgerID requested: String?, after: Int, limit: Int) throws -> CompletedPlaysPage {
        if requests.isEmpty { beforeFetch?() }
        let index = requests.count
        requests.append(FeedRequest(ledgerID: requested, after: after, limit: limit))
        if let error = errors[index] { throw error }
        if let override { return try override(requested, after, limit) }
        if let requested, requested != ledgerID {
            throw SourceAppError.ledgerChanged("Bridge's play record was replaced; read it again from the start.")
        }
        let page = Array(plays.filter { $0.seq > after }.prefix(limit))
        let next = page.last?.seq ?? after
        return CompletedPlaysPage(ledgerID: ledgerID, latestSeq: plays.count, nextAfter: next,
                                  more: next < plays.count, plays: page)
    }
}

private enum WriterCall: Equatable {
    case read(pid: String, process: MusicProcess)
    case write(pid: String, process: MusicProcess, expect: TrackPlayState, target: TrackPlayState)
    case writeDate(pid: String, process: MusicProcess, expect: TrackPlayState, date: Int)

    var isSet: Bool {
        if case .read = self { return false }
        return true
    }

    var pid: String {
        switch self {
        case .read(let pid, _), .write(let pid, _, _, _), .writeDate(let pid, _, _, _): return pid
        }
    }
}

/// What the next write or writeDate does, after the process check.
private enum WriteScript {
    /// Behaves as Music.app does: recheck, set, read back.
    case normal
    /// A native change lands before the recheck; then as `normal`.
    case nativeChange(TrackPlayState)
    /// The call leaves and nothing lands yet; `landLate()` lands it.
    case unknownNotApplied
    /// Everything lands; the reply is lost.
    case unknownApplied
    /// The count lands; the date set is held for `landLate()`.
    case countAppliedDateUnknown
    /// The count lands, the date never does, and the reply is lost.
    case countOnlyThenUnknown
    /// Every set returns, and the readback shows something else changed too.
    case appliedButReadback(TrackPlayState)
    /// Returned as is; nothing changes.
    case outcome(WriteOutcome)
}

/// Music.app's library, in memory, behaving as the writer's contract says.
private final class FakeWriter: PlayCountWriting {
    var library: [String: TrackPlayState] = [:]
    var process: MusicProcess? = P1
    var ambiguous: Set<String> = []
    /// Reported with a not-found answer; nil means the library's size.
    var libraryTrackCount: Int?
    /// Thrown by the next reads, in order.
    var readErrors: [MusicAccessError] = []
    /// Consumed by write and writeDate, in order; empty means `normal`.
    var scripts: [WriteScript] = []
    private(set) var calls: [WriterCall] = []
    private(set) var musicProcessCalls = 0
    var events: [String] = []
    private var late: [(pid: String, land: (TrackPlayState) -> TrackPlayState)] = []
    /// Runs at the start of every write and writeDate, before anything changes.
    var beforeSet: ((WriterCall) -> Void)?
    var beforeRead: ((String) -> Void)?
    /// Runs at every lookup of the Music.app process: the first Music.app access of a pass.
    var beforeMusicProcess: (() -> Void)?

    var setCalls: [WriterCall] { calls.filter(\.isSet) }

    func setCalls(_ pid: String) -> [WriterCall] { setCalls.filter { $0.pid == pid } }

    /// Lands every held effect, oldest first.
    func landLate() {
        for effect in late {
            if let current = library[effect.pid] { library[effect.pid] = effect.land(current) }
        }
        late = []
    }

    func musicProcess() -> MusicProcess? {
        musicProcessCalls += 1
        beforeMusicProcess?()
        return process
    }

    func read(_ process: MusicProcess, persistentID: String) throws -> TrackLookup {
        calls.append(.read(pid: persistentID, process: process))
        events.append("read \(persistentID)")
        beforeRead?(persistentID)
        guard process == self.process else { throw MusicAccessError.notRunning }
        if !readErrors.isEmpty { throw readErrors.removeFirst() }
        if ambiguous.contains(persistentID) { return .ambiguous(matches: 2) }
        guard let found = library[persistentID] else {
            return .notFound(libraryTrackCount: libraryTrackCount ?? library.count)
        }
        return .found(found)
    }

    func write(_ process: MusicProcess, persistentID: String,
               expect: TrackPlayState, target: TrackPlayState) -> WriteOutcome {
        let call = WriterCall.write(pid: persistentID, process: process, expect: expect, target: target)
        calls.append(call)
        beforeSet?(call)
        return perform(process, persistentID, expect: expect,
                       apply: { _ in target },
                       countOnly: { current in state(target.count, current.date) },
                       dateOnly: { current in state(current.count, target.date) },
                       isDateOnly: false)
    }

    func writeDate(_ process: MusicProcess, persistentID: String,
                   expect: TrackPlayState, date: Int) -> WriteOutcome {
        let call = WriterCall.writeDate(pid: persistentID, process: process, expect: expect, date: date)
        calls.append(call)
        beforeSet?(call)
        return perform(process, persistentID, expect: expect,
                       apply: { current in state(current.count, date) },
                       countOnly: { current in current },
                       dateOnly: { current in state(current.count, date) },
                       isDateOnly: true)
    }

    private func perform(_ process: MusicProcess, _ pid: String, expect: TrackPlayState,
                         apply: @escaping (TrackPlayState) -> TrackPlayState,
                         countOnly: (TrackPlayState) -> TrackPlayState,
                         dateOnly: @escaping (TrackPlayState) -> TrackPlayState,
                         isDateOnly: Bool) -> WriteOutcome {
        let script = scripts.isEmpty ? .normal : scripts.removeFirst()
        guard process == self.process else { return .notSent(current: nil, reason: "not running") }
        if case .outcome(let outcome) = script { return outcome }
        if case .nativeChange(let changed) = script { library[pid] = changed }
        if ambiguous.contains(pid) { return .notSent(current: nil, reason: "matches=2") }
        guard let current = library[pid] else { return .notSent(current: nil, reason: "no match") }
        guard current == expect else { return .notSent(current: current, reason: "changed") }

        switch script {
        case .normal, .nativeChange:
            library[pid] = apply(current)
            return .applied(library[pid]!)
        case .unknownNotApplied:
            late.append((pid, apply))
            return .unknown("timed out")
        case .unknownApplied:
            library[pid] = apply(current)
            return .unknown("timed out")
        case .countAppliedDateUnknown:
            library[pid] = countOnly(current)
            late.append((pid, dateOnly))
            return isDateOnly ? .unknown("timed out") : .countAppliedDateUnknown("timed out")
        case .countOnlyThenUnknown:
            library[pid] = countOnly(current)
            return .unknown("timed out")
        case .appliedButReadback(let readback):
            library[pid] = readback
            return .applied(readback)
        case .outcome:
            fatalError("handled above")
        }
    }
}

/// Answers from a script per Music.app instance; alive unless told otherwise.
private final class FakeInspector: MusicInstanceInspecting {
    private var states: [(MusicProcess, MusicInstanceState)] = []
    private(set) var asked: [MusicProcess] = []
    var onAsk: ((MusicProcess) -> Void)?

    func set(_ process: MusicProcess, _ state: MusicInstanceState) { states.append((process, state)) }

    func state(of process: MusicProcess) -> MusicInstanceState {
        asked.append(process)
        onAsk?(process)
        return states.last(where: { $0.0 == process })?.1 ?? .alive
    }
}

/// The real classification over a scripted process table.
private struct ProcessTableInspector: MusicInstanceInspecting {
    var table: [Int32: Result<Double, ProcessInspectionErrno>]
    func state(of process: MusicProcess) -> MusicInstanceState {
        classifyInstance(table[process.pid] ?? .failure(ProcessInspectionErrno(code: ESRCH)),
                         expectedStart: process.startedAt)
    }
}

// MARK: - Harness

private final class Harness {
    let root: URL
    let paths: PlaySyncPaths
    let feed = FakeFeed()
    let writer = FakeWriter()
    let inspector = FakeInspector()
    var clock = Date(timeIntervalSince1970: TimeInterval(At.fourth + 60))

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("playsync-engine-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = PlaySyncPaths(directory: root.appendingPathComponent("playsync"))
        writer.library = [
            Song.awake: state(27, At.earlier),
            Song.donor: state(5, At.earlier),
            Song.spont: state(0, nil),
        ]
    }

    func cleanUp() {
        chmod(paths.directory.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    func engine(feed: CompletedPlaysReading? = nil, useFeed: Bool = true,
                inspector: MusicInstanceInspecting? = nil,
                lockWait: TimeInterval = 20,
                hook: ((PlaySyncPassStage) -> Void)? = nil) -> PlaySyncEngine {
        PlaySyncEngine(paths: paths,
                       feed: useFeed ? (feed ?? self.feed) : nil,
                       writer: writer,
                       inspector: inspector ?? self.inspector,
                       now: { [unowned self] in self.clock },
                       explicitLockWait: lockWait,
                       stageHook: hook)
    }

    @discardableResult
    func pass(_ trigger: PlaySyncTrigger = .explicit, inspector: MusicInstanceInspecting? = nil) -> PlaySyncResult {
        engine(inspector: inspector).pass(trigger)
    }

    func journal(file: StaticString = #filePath, line: UInt = #line) -> PlaySyncJournal {
        guard case .loaded(let journal) = PlaySyncJournal.load(from: paths.journal) else {
            XCTFail("the journal on disk is not loadable", file: file, line: line)
            return .empty
        }
        return journal
    }

    func entry(_ seq: Int, ledger: String = "L1", file: StaticString = #filePath, line: UInt = #line) -> PlaySyncEntry? {
        journal(file: file, line: line).entries.first { $0.ledgerID == ledger && $0.seq == seq }
    }

    /// Makes the play-sync folder as a pass would, so a test can place a file in it.
    func prepareDirectory() {
        XCTAssertTrue(PrivateDirectory.prepare(paths.directory))
    }

    func journalBytes() -> Data? { try? Data(contentsOf: paths.journal) }

    /// Puts the journal file back to exactly these bytes, as if nothing after
    /// they were written had reached the disk.
    func restoreJournal(_ bytes: Data) {
        XCTAssertNoThrow(try DurableFile.replace(paths.journal, with: bytes))
    }
}

// MARK: - Tests

final class PlaySyncEngineTests: XCTestCase {

    private var h: Harness!

    override func setUp() {
        super.setUp()
        h = Harness()
    }

    override func tearDown() {
        h.cleanUp()
        h = nil
        super.tearDown()
    }

    // 1. Happy path (blocker 5: the journal says `writing` before the set call).
    func testHappyPathSavesWritingBeforeTheSetCallThenRecords() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        var seenOnDisk: PlaySyncEntry?
        h.writer.beforeSet = { [h] _ in seenOnDisk = h!.entry(1) }

        let result = h.pass()

        let expectedTarget = state(28, At.first)
        XCTAssertEqual(seenOnDisk?.state, .writing)
        XCTAssertEqual(seenOnDisk?.phase, .countAndDate)
        XCTAssertEqual(seenOnDisk?.before, state(27, At.earlier))
        XCTAssertEqual(seenOnDisk?.target, expectedTarget)
        XCTAssertEqual(seenOnDisk?.attempt,
                       WriteAttempt(phase: .countAndDate, process: P1, startedAt: At.fourth + 60))

        XCTAssertEqual(h.writer.library[Song.awake], expectedTarget)
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reconciled, false)
        XCTAssertNil(h.entry(1)?.attempt)
        XCTAssertEqual(result.fetch, .ok(newPlays: 1))
        XCTAssertTrue(result.musicRunning)
        XCTAssertEqual(result.recorded.map(\.seq), [1])
        XCTAssertEqual(result.newProblems, [])
        XCTAssertEqual(result.waiting, 0)
        XCTAssertEqual(h.journal().consumedThrough, 1)
        XCTAssertEqual(h.journal().ledgerID, "L1")
    }

    func testCompletedAtIsFlooredToWholeSeconds() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)   // .496 past the second
        h.writer.process = nil
        h.pass()
        XCTAssertEqual(h.entry(1)?.completedAt, At.first)
        XCTAssertEqual(h.entry(1)?.persistentID, Song.awake)
        XCTAssertEqual(h.entry(1)?.alias, Song.awakeAlias)
    }

    // 2. Capture before cursor.
    func testEachPageIsSavedWithItsCursorBeforeTheNextRequest() {
        for index in 0..<250 { h.feed.add(Song.awakeAlias, "Play \(index)", at: At.first + index) }
        h.feed.errors[1] = .notRunning       // the second page fails
        h.writer.process = nil
        var onDiskBeforeMusicApp: PlaySyncJournal?
        h.writer.beforeMusicProcess = { [h] in onDiskBeforeMusicApp = h!.journal() }

        let first = h.pass()
        XCTAssertEqual(onDiskBeforeMusicApp?.consumedThrough, 200, "captured before Music.app is touched")
        XCTAssertEqual(onDiskBeforeMusicApp?.entries.count, 200)
        h.writer.beforeMusicProcess = nil
        XCTAssertEqual(first.fetch, .bridgeNotRunning)
        XCTAssertEqual(h.journal().consumedThrough, 200)
        XCTAssertEqual(h.journal().entries.count, 200)
        XCTAssertTrue(h.journal().entries.allSatisfy { $0.state == .pending && $0.phase == .countAndDate })

        let second = h.pass()     // a new engine, reading the same folder
        XCTAssertEqual(second.fetch, .ok(newPlays: 50))
        XCTAssertEqual(h.feed.requests, [
            FeedRequest(ledgerID: nil, after: 0, limit: 200),
            FeedRequest(ledgerID: "L1", after: 200, limit: 200),
            FeedRequest(ledgerID: "L1", after: 200, limit: 200),
        ])
        let seqs = h.journal().entries.map(\.seq)
        XCTAssertEqual(seqs, Array(1...250))
        XCTAssertEqual(h.journal().consumedThrough, 250)
        XCTAssertEqual(second.waiting, 250)
    }

    // 3. A decode failure is not empty; the file is kept.
    func testUnreadableJournalBlocksTouchesNothingAndIsKept() throws {
        h.prepareDirectory()
        let garbage = Data("{\"format\":1,\"entries\":[{\"seq\":".utf8)
        try garbage.write(to: h.paths.journal)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)

        let result = h.pass()

        XCTAssertEqual(result.blocked, .journalUnreadable(path: h.paths.journal.path))
        XCTAssertEqual(h.feed.requests, [])
        XCTAssertEqual(h.writer.calls, [])
        XCTAssertEqual(h.writer.musicProcessCalls, 0)
        XCTAssertEqual(h.journalBytes(), garbage)
        XCTAssertEqual(h.pass(.background).blocked, .journalUnreadable(path: h.paths.journal.path))
        XCTAssertEqual(h.journalBytes(), garbage)
    }

    func testJournalFromANewerFormatBlocksAsTooNew() throws {
        h.prepareDirectory()
        let newer = Data("{\"format\":2,\"something\":\"else\"}".utf8)
        try newer.write(to: h.paths.journal)

        let result = h.pass()

        XCTAssertEqual(result.blocked, .journalTooNew)
        XCTAssertEqual(h.feed.requests, [])
        XCTAssertEqual(h.writer.calls, [])
        XCTAssertEqual(h.journalBytes(), newer)
    }

    // 4. A lost reply.
    func testLostReplyIsResolvedByObservingTheTarget() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.unknownApplied]

        let first = h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(first.unconfirmed.map(\.seq), [1])
        XCTAssertEqual(first.newProblems.map(\.seq), [1])

        let second = h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reconciled, true)
        XCTAssertEqual(second.recorded.map(\.seq), [1])
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.first))
        XCTAssertEqual(h.writer.setCalls.count, 1)
    }

    // 5. Unknown is never retried by age (Blocking 1).
    func testUnknownWriteIsNeverRetriedByAge() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)    // E2, the same song
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.third)        // another song
        let start = h.clock
        for elapsed: TimeInterval in [60, 601, 86_400] {
            h.clock = start.addingTimeInterval(elapsed)
            let result = h.pass()
            XCTAssertEqual(h.entry(1)?.state, .unresolved, "at +\(elapsed) s")
            XCTAssertEqual(h.entry(2)?.state, .pending, "at +\(elapsed) s")
            XCTAssertEqual(h.entry(3)?.state, .done, "at +\(elapsed) s")
            XCTAssertEqual(result.unconfirmed.map(\.seq), [1])
            XCTAssertEqual(result.waiting, 1)
        }
        XCTAssertEqual(h.writer.setCalls(Song.awake).count, 1)
        XCTAssertEqual(h.writer.setCalls(Song.donor).count, 1)
        XCTAssertEqual(h.writer.library[Song.awake], state(27, At.earlier))
        XCTAssertEqual(h.entry(1)?.target, state(28, At.first))
    }

    // 6. A delayed setter (Blocking 1).
    func testDelayedSetterIsObservedBeforeTheNextPlayOfTheSongIsPlanned() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.pass()
        XCTAssertEqual(h.entry(2)?.state, .pending)
        XCTAssertEqual(h.writer.setCalls.count, 1, "E2 is not planned while E1 may still land")

        h.writer.landLate()
        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reconciled, true)
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(h.entry(2)?.before, state(28, At.first))
        XCTAssertEqual(result.recorded.map(\.seq), [1, 2])
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P1, expect: state(28, At.first), target: state(29, At.second)),
        ])
    }

    // 7. The process barrier (Q4).

    /// E1's write left for P1 and never landed; E2 is the same song.
    private func unresolvedE1WithE2Behind(e2: Bool = true) {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.attempt?.process, P1)
        if e2 { h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second) }
    }

    private func assertEveryE1WriteKeepsTheOriginalTarget(file: StaticString = #filePath, line: UInt = #line) {
        for call in h.writer.setCalls(Song.awake) {
            guard case .write(_, _, let expect, let target) = call else {
                XCTFail("unexpected date-only write \(call)", file: file, line: line)
                continue
            }
            if target.count == 28 {
                XCTAssertEqual(expect, state(27, At.earlier), file: file, line: line)
                XCTAssertEqual(target, state(28, At.first), file: file, line: line)
            }
        }
    }

    func testVerifiedExitRetriesTheOriginalTargetThenTheNextPlay() {
        unresolvedE1WithE2Behind()
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.inspector.onAsk = { [h] process in h!.writer.events.append("inspect \(process.pid)") }
        h.writer.events = []

        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.barrierReplans, 1)
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(result.recorded.map(\.seq), [1, 2])
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P2, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P2, expect: state(28, At.first), target: state(29, At.second)),
        ])
        // The exit is established before the read that releases anything.
        XCTAssertEqual(Array(h.writer.events.prefix(2)), ["inspect 4413", "read \(Song.awake)"])
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
    }

    func testReusedPidWithANewStartTimeIsAVerifiedExit() {
        unresolvedE1WithE2Behind()
        let reused = MusicProcess(pid: P1.pid, startedAt: P1.startedAt + 1)
        h.writer.process = reused

        // The same pid still reporting the original start time is the same instance.
        h.pass(inspector: ProcessTableInspector(table: [P1.pid: .success(P1.startedAt)]))
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.writer.setCalls.count, 1)

        // The pid now belongs to a process that started later: a different instance.
        h.pass(inspector: ProcessTableInspector(table: [P1.pid: .success(reused.startedAt)]))
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(2)?.state, .done)
        assertEveryE1WriteKeepsTheOriginalTarget()
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
    }

    func testOtherMusicProcessWhileTheOriginalLivesReleasesNothing() {
        unresolvedE1WithE2Behind()
        h.writer.process = P2
        h.inspector.set(P1, .alive)

        let result = h.pass()

        XCTAssertEqual(h.inspector.asked, [P1])
        XCTAssertEqual(h.writer.setCalls.count, 1)
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(2)?.state, .pending)
        XCTAssertEqual(result.unconfirmed.map(\.seq), [1])
        XCTAssertEqual(result.waiting, 1)
    }

    func testFailedInspectionReleasesNothing() {
        unresolvedE1WithE2Behind()
        h.writer.process = P2
        h.inspector.set(P1, .unknown)

        h.pass()
        // The same through the real classification: EPERM is not an exit.
        h.pass(inspector: ProcessTableInspector(table: [P1.pid: .failure(ProcessInspectionErrno(code: EPERM))]))

        XCTAssertEqual(h.writer.setCalls.count, 1)
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(2)?.state, .pending)
    }

    func testNoSuccessfulReadFromTheReplacementReleasesNothing() {
        unresolvedE1WithE2Behind()
        h.writer.process = P2
        h.inspector.set(P1, .exited)

        h.writer.readErrors = [.timedOut]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.writer.readErrors = [.failed("Music.app error -10000")]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.writer.process = nil
        let notRunning = h.pass()
        XCTAssertFalse(notRunning.musicRunning)
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        // A read that does not find the track is not an observation of it.
        h.writer.process = P2
        let saved = h.writer.library.removeValue(forKey: Song.awake)
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        h.writer.library[Song.awake] = saved

        XCTAssertEqual(h.writer.setCalls.count, 1)
        XCTAssertEqual(h.entry(2)?.state, .pending)
    }

    func testChangeAfterTheRestartReadIsAConflictAndNeverANewTarget() {
        unresolvedE1WithE2Behind(e2: false)
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.nativeChange(state(28, At.native))]

        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.observed, state(28, At.native))
        XCTAssertEqual(h.entry(1)?.target, state(28, At.first), "the target is preserved")
        XCTAssertEqual(result.newProblems.map(\.seq), [1], "the conflict is reported")
        XCTAssertEqual(result.outstanding.map(\.seq), [1])
        XCTAssertEqual(h.writer.setCalls.count, 2)
        assertEveryE1WriteKeepsTheOriginalTarget()
        XCTAssertFalse(h.writer.setCalls.contains {
            if case .write(_, _, _, let target) = $0 { return target.count == 29 }
            return false
        })
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.native))
    }

    /// A retained plan whose retry was positively not sent stays retained: a
    /// later pass writes the original target again, never a fresh read and
    /// increment.
    func testRetainedPlanLeftPendingIsRetriedWithTheOriginalTarget() {
        unresolvedE1WithE2Behind()
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.outcome(.notSent(current: nil, reason: "not running"))]
        let released = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .pending)
        XCTAssertEqual(h.entry(1)?.target, state(28, At.first))
        XCTAssertEqual(h.entry(1)?.before, state(27, At.earlier))
        XCTAssertNil(h.entry(1)?.attempt)
        XCTAssertEqual(h.entry(2)?.state, .pending, "held behind E1")
        XCTAssertEqual(released.waiting, 2)

        // A native play lands before the next pass. A fresh plan would aim at
        // 29; the retained one is sent as it was and meets the change.
        h.writer.library[Song.awake] = state(28, At.native)
        let readsBefore = h.writer.calls.filter { !$0.isSet }.count
        h.pass()

        XCTAssertEqual(h.writer.calls.filter { !$0.isSet && $0.pid == Song.awake }.count - readsBefore, 1,
                       "only E2's plan reads; E1 is not re-planned")
        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.target, state(28, At.first))
        assertEveryE1WriteKeepsTheOriginalTarget()
        XCTAssertEqual(Array(h.writer.setCalls.suffix(2)), [
            .write(pid: Song.awake, process: P2, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P2, expect: state(28, At.native), target: state(29, At.native)),
        ])
    }

    func testChangeAfterTheRestartReadToExactlyTheTargetIsReconciled() {
        unresolvedE1WithE2Behind(e2: false)
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.nativeChange(state(28, At.first))]

        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reconciled, true)
        XCTAssertEqual(result.recorded.map(\.seq), [1])
        assertEveryE1WriteKeepsTheOriginalTarget()
    }

    func testBarrierWithTheCountConfirmedRepairsOnlyTheDate() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.countOnlyThenUnknown]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.phase, .countAndDate)
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.earlier))

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.phase, .dateOnly)
        XCTAssertEqual(h.entry(1)?.barrierReplans, 0)
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.first))
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .writeDate(pid: Song.awake, process: P2, expect: state(28, At.earlier), date: At.first),
        ])
    }

    func testBarrierWithAnyOtherStateIsAConflictAndReleasesTheSong() {
        unresolvedE1WithE2Behind()
        h.writer.library[Song.awake] = state(30, At.native)
        h.writer.process = P2
        h.inspector.set(P1, .exited)

        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.observed, state(30, At.native))
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(h.entry(2)?.before, state(30, At.native))
        XCTAssertEqual(h.writer.library[Song.awake], state(31, At.native))
        XCTAssertEqual(result.newProblems.map(\.seq), [1])
        assertEveryE1WriteKeepsTheOriginalTarget()
    }

    func testThirdBarrierReleaseIsAConflict() {
        unresolvedE1WithE2Behind(e2: false)

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.barrierReplans, 1)
        XCTAssertEqual(h.entry(1)?.attempt?.process, P2)

        h.writer.process = P3
        h.inspector.set(P2, .exited)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.barrierReplans, 2)

        h.writer.process = P4
        h.inspector.set(P3, .exited)
        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.barrierReplans, 3)
        XCTAssertEqual(result.newProblems.map(\.seq), [1])
        XCTAssertEqual(h.writer.setCalls.count, 3)
        assertEveryE1WriteKeepsTheOriginalTarget()
        XCTAssertEqual(h.writer.library[Song.awake], state(27, At.earlier))
    }

    // 8. Crash windows.
    func testCrashBeforeTheCountSetterLeavesAnUnresolvedAttemptThatSurvivesReload() throws {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        var atTheSetCall: Data?
        h.writer.beforeSet = { [h] _ in atTheSetCall = h!.journalBytes() }
        h.writer.scripts = [.outcome(.unknown("the process ended"))]   // the set never ran
        h.pass()
        h.writer.beforeSet = nil
        let crashed = try XCTUnwrap(atTheSetCall)
        h.restoreJournal(crashed)   // nothing after the `writing` save reached the disk

        guard case .loaded(let onDisk) = PlaySyncJournal.decode(crashed) else { return XCTFail("unreadable") }
        XCTAssertEqual(onDisk.entries.first?.state, .writing)

        // A new engine, the instance alive, the track still at `before`.
        let callsBefore = h.writer.setCalls.count
        let reloaded = h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.attempt?.process, P1, "pid and start time survive the reload exactly")
        XCTAssertEqual(h.entry(1)?.target, state(28, At.first))
        XCTAssertEqual(h.entry(2)?.state, .pending)
        XCTAssertEqual(h.writer.setCalls.count, callsBefore)
        XCTAssertEqual(reloaded.unconfirmed.map(\.seq), [1])

        // Only a verified exit releases it, and only to the retained target.
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(2)?.state, .done)
        assertEveryE1WriteKeepsTheOriginalTarget()
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
    }

    func testCrashBeforeTheDateOnlySetterLeavesAnUnresolvedDateOnlyAttempt() throws {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.writer.scripts = [.countAppliedDateUnknown]      // E1: the count lands, the date is held
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.phase, .dateOnly)

        // P1 exits; P2 reads the confirmed count with the old date and starts the date repair.
        h.writer.process = P2
        h.inspector.set(P1, .exited)
        var atTheSetCall: Data?
        h.writer.beforeSet = { [h] _ in atTheSetCall = h!.journalBytes() }
        h.writer.scripts = [.outcome(.unknown("the process ended"))]
        h.pass()
        h.writer.beforeSet = nil
        h.restoreJournal(try XCTUnwrap(atTheSetCall))

        let callsBefore = h.writer.setCalls.count
        h.pass()     // a new engine; P2 alive
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.phase, .dateOnly)
        XCTAssertEqual(h.entry(1)?.attempt?.process, P2)
        XCTAssertEqual(h.entry(2)?.state, .pending)
        XCTAssertEqual(h.writer.setCalls.count, callsBefore)

        h.writer.process = P3
        h.inspector.set(P2, .exited)
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
        XCTAssertEqual(h.writer.setCalls(Song.awake).filter {
            if case .write(_, _, _, let target) = $0 { return target.count == 28 }
            return false
        }.count, 1, "the count is never written twice for E1")
    }

    // 9 and 11. The E1 counterexample and the date-only precondition mismatch (Blocking 2).
    func testCountAppliedThenNativePlayIsNeverCountedAgain() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.countAppliedDateUnknown]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.phase, .dateOnly)
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.earlier))

        h.writer.library[Song.awake] = state(29, At.native)    // a native play

        h.pass()                                                // the same instance
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reason, "superseded")
        XCTAssertEqual(h.entry(1)?.reconciled, true)
        XCTAssertEqual(result.recorded.map(\.seq), [1])
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.native), "29, never 30")
        XCTAssertEqual(h.writer.setCalls.count, 1, "no write for E1 after the first")
    }

    func testDateOnlyRepairFindingALaterDateIsSuperseded() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.countAppliedDateUnknown]
        h.pass()

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.nativeChange(state(29, At.native))]    // lands between the read and the recheck
        h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reason, "superseded")
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.native))
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .writeDate(pid: Song.awake, process: P2, expect: state(28, At.earlier), date: At.first),
        ])
    }

    func testDateOnlyRepairFindingAnEarlierDateIsAConflict() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.countAppliedDateUnknown]
        h.pass()

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.nativeChange(state(29, At.first - 100))]
        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.observed, state(29, At.first - 100))
        XCTAssertEqual(result.newProblems.map(\.seq), [1])
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.first - 100))
        XCTAssertEqual(h.writer.setCalls.filter {
            if case .write = $0 { return true }
            return false
        }.count, 1, "never re-planned as a count write")
    }

    // 10. A lost date-only reply.
    func testLostDateOnlyReplyIsResolvedByObservingTheTarget() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.countAppliedDateUnknown]
        h.pass()

        h.writer.process = P2
        h.inspector.set(P1, .exited)
        h.writer.scripts = [.unknownApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)
        XCTAssertEqual(h.entry(1)?.phase, .dateOnly)

        let result = h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.reconciled, true)
        XCTAssertEqual(result.recorded.map(\.seq), [1])
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.first))
        XCTAssertEqual(h.writer.setCalls.count, 2)
    }

    // 12. A native change before the count setter, on a fresh plan only.
    func testNativeChangeBeforeAFreshSetterIsPlannedAgainFromWhatIsThere() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.nativeChange(state(28, At.earlier + 50))]

        h.pass()

        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.before, state(28, At.earlier + 50))
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.first))
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P1, expect: state(28, At.earlier + 50), target: state(29, At.first)),
        ])
    }

    func testFreshReplansAreBoundedPerPass() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.third)
        h.writer.scripts = (1...4).map { .nativeChange(state(27 + $0, At.earlier + $0)) }

        let result = h.pass()

        XCTAssertEqual(h.writer.setCalls(Song.awake).count, 4, "one plan and three re-plans")
        XCTAssertEqual(h.entry(1)?.state, .pending)
        XCTAssertNil(h.entry(1)?.target)
        XCTAssertNil(h.entry(1)?.before)
        XCTAssertEqual(h.entry(2)?.state, .pending, "held behind E1")
        XCTAssertEqual(h.entry(3)?.state, .done, "other songs continue")
        XCTAssertEqual(result.waiting, 2)

        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(h.writer.library[Song.awake], state(33, At.second))
    }

    // 13. An old pending play followed by another of the same song.
    func testOlderPendingPlayIsWrittenBeforeTheLaterOne() {
        h.writer.process = nil
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.pass()
        XCTAssertEqual(h.journal().entries.map(\.state), [.pending, .pending])

        h.writer.process = P1
        let result = h.pass()

        XCTAssertEqual(result.recorded.map(\.seq), [1, 2])
        XCTAssertEqual(h.writer.setCalls, [
            .write(pid: Song.awake, process: P1, expect: state(27, At.earlier), target: state(28, At.first)),
            .write(pid: Song.awake, process: P1, expect: state(28, At.first), target: state(29, At.second)),
        ])
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
    }

    // 14. Unmatched, and a conflict, followed by other plays.
    func testUnmatchedPlaysNeverHoldOtherSongsAndSurviveReload() {
        h.writer.ambiguous = [Song.spont]
        h.feed.add(nil, "No alias", at: At.first)
        h.feed.add("12abc", "Bad alias", at: At.first)
        h.feed.add(Song.tranzAlias, "Tranz", at: At.first)             // not in the library
        h.feed.add(Song.spontAlias, "Spontaneous", at: At.second)      // two matches
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.third)

        let first = h.pass()

        XCTAssertEqual(h.entry(5)?.state, .done)
        XCTAssertEqual(h.journal().entries.prefix(4).map(\.state), Array(repeating: .unmatched, count: 4))
        XCTAssertEqual(h.journal().entries.prefix(4).map(\.reason), ["no_alias", "bad_alias", "not_found", "ambiguous"])
        XCTAssertEqual(first.newProblems.map(\.seq), [1, 2, 3, 4])
        XCTAssertTrue(h.journal().entries.prefix(4).allSatisfy(\.reported))

        let second = h.pass()     // a new engine over the same folder
        XCTAssertEqual(second.outstanding.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(second.newProblems, [])
        XCTAssertEqual(h.writer.setCalls.map(\.pid), [Song.donor])
    }

    func testConflictReleasesTheNextPlayOfTheSameSong() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.writer.scripts = [.appliedButReadback(state(30, At.native))]

        let result = h.pass()

        XCTAssertEqual(h.entry(1)?.state, .conflict)
        XCTAssertEqual(h.entry(1)?.reason, "conflict")
        XCTAssertEqual(h.entry(2)?.state, .done)
        XCTAssertEqual(h.writer.library[Song.awake], state(31, At.native))
        XCTAssertEqual(result.newProblems.map(\.seq), [1])
        XCTAssertEqual(result.recorded.map(\.seq), [2])
    }

    // 15. Max date.
    func testLaterExistingDateIsKept() {
        h.writer.library[Song.awake] = state(27, At.native)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)

        h.pass()

        XCTAssertEqual(h.entry(1)?.target, state(28, At.native))
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.native))
    }

    func testNeverPlayedTrackGetsTheCompletionDate() {
        h.feed.add(Song.spontAlias, "Spontaneous", at: At.second)
        h.pass()
        XCTAssertEqual(h.writer.library[Song.spont], state(1, At.second))
    }

    /// Same play as above, but decoded from a wire reply carrying `origin`
    /// and `catalog_id` (test-only: the public half of catalogue plays). The
    /// journal only ever sees a `CompletedPlayRecord`, which has no origin
    /// field, so a catalogue-origin play must be synced exactly like a
    /// library one.
    func testACatalogueOriginPlayIsSyncedExactlyLikeALibraryPlay() throws {
        let reply = """
        {"ok":true,"ledger_id":"L1","latest_seq":1,"next_after":1,"more":false,
         "plays":[{"alias":"\(Song.spontAlias)","artist":"Artist","catalog_id":"1458871225",
         "completed_at":"2026-09-25T01:38:55.091Z","duration_s":128.647,"end":"advance",
         "library_id":"i.qlWqltep4qY5","origin":"catalogue","play_id":"PLAY-C",
         "position_s":127.82,"seq":1,"title":"Spontaneous"}]}
        """
        let body = try JSONSerialization.jsonObject(with: reply.data(using: .utf8)!) as! [String: Any]
        let decoded = try SourceAppControl.completedPlaysPage(from: body, ledgerID: nil, after: 0, limit: 200)
        h.feed.override = { _, _, _ in decoded }

        h.pass()

        XCTAssertEqual(h.writer.library[Song.spont], state(1, At.second))
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.entry(1)?.alias, Song.spontAlias)
        XCTAssertEqual(h.journal().consumedThrough, 1)
    }

    // 16. The library is not ready.
    func testEmptyLibraryLeavesPlaysPendingAndStopsTheApply() {
        h.writer.library = [:]
        h.writer.libraryTrackCount = 0
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.second)

        let result = h.pass()

        XCTAssertEqual(h.journal().entries.map(\.state), [.pending, .pending])
        XCTAssertEqual(h.writer.calls, [.read(pid: Song.awake, process: P1)])
        XCTAssertEqual(result.waiting, 2)
        XCTAssertEqual(result.newProblems, [])
    }

    /// An empty library is not a silent `.stop`: the pass says why the play is
    /// still waiting, instead of falling through to "Nothing new to record."
    func testEmptyLibraryNotesTheLibraryNotLoadedAccessFailure() {
        h.writer.library = [:]
        h.writer.libraryTrackCount = 0
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)

        let result = h.pass()

        XCTAssertEqual(result.musicAccess, .failed(MusicAccessSentence.libraryNotLoaded))
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(h.journal().entries.map(\.state), [.pending])
    }

    func testReadFailureOnAPendingPlayStopsTheApply() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.second)
        h.writer.readErrors = [.timedOut]

        let result = h.pass()

        XCTAssertEqual(h.writer.calls.count, 1)
        XCTAssertEqual(result.waiting, 2)
        h.pass()
        XCTAssertEqual(h.journal().entries.map(\.state), [.done, .done])
    }

    // 17. Duplicate delivery.
    func testRedeliveredPlayIsSkippedAndAChangedIdentityStopsTheFetch() {
        h.writer.process = nil
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.second)
        h.pass()
        XCTAssertEqual(h.journal().consumedThrough, 2)

        let again = h.feed.plays[1]
        let third = CompletedPlayRecord(seq: 3, playID: "L1-play-3", alias: Song.spontAlias, libraryID: "i.3",
                                        title: "Spontaneous", artist: "Artist",
                                        completedAt: Date(timeIntervalSince1970: TimeInterval(At.third)), end: "advance")
        h.feed.override = { _, _, _ in
            CompletedPlaysPage(ledgerID: "L1", latestSeq: 3, nextAfter: 3, more: false, plays: [again, third])
        }
        let overlap = h.pass()
        XCTAssertEqual(overlap.fetch, .ok(newPlays: 1))
        XCTAssertEqual(h.journal().entries.map(\.seq), [1, 2, 3])
        XCTAssertEqual(h.journal().consumedThrough, 3)

        let impostor = CompletedPlayRecord(seq: 3, playID: "someone-else", alias: Song.awakeAlias, libraryID: "i.x",
                                           title: "Other", artist: "Artist",
                                           completedAt: Date(timeIntervalSince1970: TimeInterval(At.fourth)), end: "advance")
        let fourth = CompletedPlayRecord(seq: 4, playID: "L1-play-4", alias: Song.awakeAlias, libraryID: "i.4",
                                         title: "Four", artist: "Artist",
                                         completedAt: Date(timeIntervalSince1970: TimeInterval(At.fourth)), end: "advance")
        h.feed.override = { _, _, _ in
            CompletedPlaysPage(ledgerID: "L1", latestSeq: 4, nextAfter: 4, more: false, plays: [impostor, fourth])
        }
        let before = h.journalBytes()
        let corrupt = h.pass()
        guard case .failed(let why) = corrupt.fetch else { return XCTFail("expected a failed fetch, got \(corrupt.fetch)") }
        XCTAssertTrue(why.contains("3"), why)
        XCTAssertEqual(h.journalBytes(), before, "nothing from that page is captured")
        XCTAssertEqual(h.journal().entries.first { $0.seq == 3 }?.playID, "L1-play-3")
    }

    // 18. Ledger replacement.
    func testReplacedLedgerRetiresTheCursorAndOldEntriesKeepTheirRules() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.writer.scripts = [.unknownNotApplied]
        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .unresolved)

        h.feed.replaceLedger(with: "L2")
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.third)
        let clock = h.clock
        let result = h.pass()

        XCTAssertEqual(result.fetch, .ledgerReplaced)
        XCTAssertEqual(Array(h.feed.requests.suffix(2)), [
            FeedRequest(ledgerID: "L1", after: 1, limit: 200),
            FeedRequest(ledgerID: nil, after: 0, limit: 200),
        ])
        let journal = h.journal()
        XCTAssertEqual(journal.ledgerID, "L2")
        XCTAssertEqual(journal.consumedThrough, 2)
        XCTAssertEqual(journal.retiredLedgers, [
            RetiredLedger(ledgerID: "L1", consumedThrough: 1, retiredAt: Int(clock.timeIntervalSince1970)),
        ])
        XCTAssertEqual(h.entry(1, ledger: "L1")?.state, .unresolved)
        XCTAssertEqual(h.entry(1, ledger: "L2")?.state, .pending, "held behind the old unresolved write")
        XCTAssertEqual(h.entry(2, ledger: "L2")?.state, .done)

        h.writer.landLate()
        h.pass()
        XCTAssertEqual(h.entry(1, ledger: "L1")?.state, .done)
        XCTAssertEqual(h.entry(1, ledger: "L2")?.state, .done)
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.second))
    }

    func testLedgerReplacedTwiceInOnePassEndsTheFetch() {
        h.writer.process = nil
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.pass()
        h.feed.override = { _, _, _ in throw SourceAppError.ledgerChanged("replaced") }

        let result = h.pass()

        guard case .failed = result.fetch else { return XCTFail("expected a failed fetch, got \(result.fetch)") }
        XCTAssertEqual(Array(h.feed.requests.suffix(2)), [
            FeedRequest(ledgerID: "L1", after: 1, limit: 200),
            FeedRequest(ledgerID: nil, after: 0, limit: 200),
        ])
        XCTAssertEqual(h.feed.requests.count, 3, "asked again once, not more")
        XCTAssertNil(h.journal().ledgerID)
        XCTAssertEqual(h.journal().consumedThrough, 0)
        XCTAssertEqual(h.journal().retiredLedgers.map(\.ledgerID), ["L1"])
        XCTAssertEqual(h.entry(1)?.state, .pending)
    }

    func testFeedErrorsAreReportedAndApplyStillRuns() {
        h.writer.process = nil
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.pass()
        h.writer.process = P1

        h.feed.errors[1] = .unsupported("slice.completedPlays")
        XCTAssertEqual(h.pass().fetch, .bridgeTooOld)
        XCTAssertEqual(h.entry(1)?.state, .done, "apply continues after a failed fetch")

        h.feed.errors[2] = .malformedReply("Bridge's play record page is missing plays")
        XCTAssertEqual(h.pass().fetch, .failed("Bridge's play record page is missing plays"))
        XCTAssertEqual(h.pass(inspector: nil).fetch, .ok(newPlays: 0))
        XCTAssertEqual(h.engine(useFeed: false).pass(.explicit).fetch, .skipped)
    }

    // 19. Two writers, and reporting interleaved with an explicit pass (Blocking 5).
    func testHeldLockMakesAnotherEngineBusy() {
        let other = h.engine(lockWait: 0.5)
        var background: PlaySyncResult?
        var explicit: PlaySyncResult?
        var waited: TimeInterval = 0
        let holder = h.engine(hook: { stage in
            guard stage == .locked else { return }
            background = other.pass(.background)
            let start = ProcessInfo.processInfo.systemUptime
            explicit = other.pass(.explicit)
            waited = ProcessInfo.processInfo.systemUptime - start
        })

        XCTAssertNil(holder.pass(.background).blocked)
        XCTAssertEqual(background?.blocked, .lockBusy)
        XCTAssertEqual(explicit?.blocked, .lockBusy)
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        XCTAssertLessThan(waited, 5)
        XCTAssertNil(other.pass(.background).blocked, "free once the holder is done")
    }

    func testBackgroundReportingInterleavedWithAnExplicitPassLosesNothing() {
        h.feed.add(nil, "No alias", at: At.first)                        // a new problem
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.second)
        let explicitEngine = h.engine()
        let explicitResult = Locked<PlaySyncResult?>(nil)
        let explicitFinished = expectation(description: "explicit pass finished")

        let backgroundEngine = h.engine(hook: { [h] stage in
            guard stage == .beforeFinalSave else { return }
            // The background pass has marked its problem reported and not yet
            // saved. A new play arrives and an explicit pass starts.
            h!.feed.add(Song.donorAlias, "Organ Donor", at: At.third)
            let started = DispatchSemaphore(value: 0)
            Thread {
                started.signal()
                explicitResult.set(explicitEngine.pass(.explicit))
                explicitFinished.fulfill()
            }.start()
            started.wait()
            usleep(300_000)
            XCTAssertNil(explicitResult.get(), "the explicit pass waits for the lock")
        })

        let background = backgroundEngine.pass(.background)
        wait(for: [explicitFinished], timeout: 10)
        let explicit = try? XCTUnwrap(explicitResult.get())

        let journal = h.journal()
        XCTAssertEqual(journal.consumedThrough, 3)
        XCTAssertEqual(journal.entries.map(\.seq), [1, 2, 3])
        XCTAssertEqual(journal.entries.map(\.state), [.unmatched, .done, .done])
        XCTAssertEqual(h.entry(1)?.reported, true)
        let appearances = background.newProblems.filter { $0.seq == 1 }.count
            + (explicit?.newProblems.filter { $0.seq == 1 }.count ?? 0)
        XCTAssertEqual(appearances, 1)
        XCTAssertEqual(background.newProblems.map(\.seq), [1])
        XCTAssertEqual(explicit?.newProblems, [])
        XCTAssertEqual(explicit?.recorded.map(\.seq), [3])
        XCTAssertEqual(explicit?.outstanding.map(\.seq), [1])
    }

    func testTwoConcurrentPassesRecordEveryPlayExactlyOnce() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.second)
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.third)
        h.feed.add(Song.spontAlias, "Spontaneous", at: At.fourth)
        let engines = [h.engine(), h.engine()]
        let results = Locked<[PlaySyncResult]>([])

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = engines[index].pass(.explicit)
            results.mutate { $0.append(result) }
        }

        let all = results.get()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.blocked == nil })
        XCTAssertEqual(all.flatMap(\.recorded).map(\.seq).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(h.journal().entries.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(h.journal().entries.map(\.state), [.done, .done, .done, .done])
        XCTAssertEqual(h.writer.setCalls.count, 4)
        XCTAssertEqual(h.writer.library[Song.awake], state(29, At.third))
        XCTAssertEqual(h.writer.library[Song.donor], state(6, At.second))
        XCTAssertEqual(h.writer.library[Song.spont], state(1, At.fourth))
    }

    // 20. Music.app is not running.
    func testMusicNotRunningCapturesAndWaits() {
        h.writer.process = nil
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.feed.add(Song.donorAlias, "Organ Donor", at: At.second)
        h.feed.add(nil, "No alias", at: At.third)

        let result = h.pass()

        XCTAssertFalse(result.musicRunning)
        XCTAssertEqual(result.waiting, 3)
        XCTAssertEqual(result.fetch, .ok(newPlays: 3))
        XCTAssertEqual(h.writer.calls, [])
        XCTAssertEqual(h.journal().entries.map(\.state), [.pending, .pending, .pending])
    }

    // 21. An unsafe folder.
    func testFolderThatIsNotPrivateIsRefusedWithNothingWritten() throws {
        try FileManager.default.createDirectory(at: h.paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)

        let result = h.pass()

        XCTAssertEqual(result.blocked, .directoryUnsafe(path: h.paths.directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.paths.directory.path), [])
        XCTAssertEqual(h.feed.requests, [])
        XCTAssertEqual(h.writer.calls, [])
        let mode = try FileManager.default.attributesOfItem(atPath: h.paths.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, "refused, not repaired")
    }

    func testSymlinkedFolderIsRefusedWithNothingWritten() throws {
        let real = h.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: h.paths.directory, withDestinationURL: real)

        let result = h.pass()

        XCTAssertEqual(result.blocked, .directoryUnsafe(path: h.paths.directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), [])
        XCTAssertEqual(h.feed.requests, [])
    }

    func testFileInPlaceOfTheFolderIsRefused() throws {
        try Data("x".utf8).write(to: h.paths.directory)
        XCTAssertEqual(h.pass().blocked, .directoryUnsafe(path: h.paths.directory.path))
    }

    func testMissingFolderIsCreatedPrivate() throws {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        XCTAssertNil(h.pass().blocked)
        let attributes = try FileManager.default.attributesOfItem(atPath: h.paths.directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        let journalMode = try FileManager.default.attributesOfItem(atPath: h.paths.journal.path)[.posixPermissions] as? Int
        XCTAssertEqual(journalMode, 0o600)
        let lockMode = try FileManager.default.attributesOfItem(atPath: h.paths.lock.path)[.posixPermissions] as? Int
        XCTAssertEqual(lockMode, 0o600)
    }

    // 22. Compaction.
    func testCompactionKeepsTheNewest500RecordedAndEveryOtherEntry() throws {
        func entry(_ seq: Int, _ status: EntryState) -> PlaySyncEntry {
            let unresolved = status == .unresolved
            return PlaySyncEntry(
                ledgerID: "L1", seq: seq, playID: "p\(seq)", alias: Song.awakeAlias, persistentID: Song.awake,
                title: "t", artist: "a", completedAt: At.first, state: status, phase: .countAndDate,
                before: unresolved ? state(27, At.earlier) : nil,
                target: unresolved ? state(28, At.first) : nil,
                attempt: unresolved ? WriteAttempt(phase: .countAndDate, process: P1, startedAt: At.first) : nil,
                observed: nil, barrierReplans: 0, reason: nil, reconciled: false, reported: true)
        }
        var entries = [entry(1, .unmatched), entry(2, .unresolved), entry(3, .conflict)]
        entries += (4...603).map { entry($0, .done) }
        h.prepareDirectory()
        try PlaySyncJournal(ledgerID: "L1", consumedThrough: 603, entries: entries, retiredLedgers: [])
            .save(to: h.paths.journal)
        h.writer.process = nil

        let result = h.engine(useFeed: false).pass(.explicit)

        let kept = h.journal().entries
        XCTAssertEqual(kept.filter { $0.state == .done }.map(\.seq), Array(104...603))
        XCTAssertEqual(kept.prefix(3).map(\.state), [.unmatched, .unresolved, .conflict])
        XCTAssertEqual(kept.count, 503)
        XCTAssertEqual(result.outstanding.map(\.seq), [1, 3])
        XCTAssertEqual(result.unconfirmed.map(\.seq), [2])
    }

    // The journal is saved before every set call; when it cannot be, none is made.
    func testJournalThatCannotBeSavedBeforeASetCallStopsThePass() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        let directory = h.paths.directory.path
        h.writer.beforeRead = { _ in chmod(directory, 0o500) }

        let result = h.pass()
        chmod(directory, 0o700)
        h.writer.beforeRead = nil

        XCTAssertEqual(result.blocked, .journalNotSaved(path: h.paths.journal.path))
        XCTAssertEqual(h.writer.setCalls, [])
        XCTAssertEqual(h.entry(1)?.state, .pending, "the page was saved; the plan was not")

        h.pass()
        XCTAssertEqual(h.entry(1)?.state, .done)
        XCTAssertEqual(h.writer.library[Song.awake], state(28, At.first))
    }

    /// C5's exact shape: the save that fails is the per-page save inside
    /// `fetchPages`, before `fetchStatus` is ever assigned. A heuristic based
    /// on `fetch`/`musicRunning` would misread this as "could not be read".
    func testJournalThatCannotBeSavedDuringTheFirstFetchIsAlsoNotSaved() {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        let directory = h.paths.directory.path
        h.feed.beforeFetch = { chmod(directory, 0o500) }

        let result = h.pass()
        chmod(directory, 0o700)
        h.feed.beforeFetch = nil

        XCTAssertEqual(result.blocked, .journalNotSaved(path: h.paths.journal.path))
        XCTAssertEqual(result.fetch, .skipped)
        XCTAssertEqual(h.writer.calls, [])
    }

    func testAnUnchangedJournalIsNotRewritten() throws {
        h.feed.add(Song.awakeAlias, "Are You Awake?", at: At.first)
        h.pass()
        let first = try FileManager.default.attributesOfItem(atPath: h.paths.journal.path)[.systemFileNumber] as? Int
        h.pass()
        let second = try FileManager.default.attributesOfItem(atPath: h.paths.journal.path)[.systemFileNumber] as? Int
        XCTAssertEqual(first, second, "a pass with nothing new leaves the file alone")
    }

    func testPassWithNothingToDoCreatesNoJournal() {
        let result = h.engine(useFeed: false).pass(.explicit)
        XCTAssertNil(result.blocked)
        XCTAssertEqual(result.fetch, .skipped)
        XCTAssertTrue(result.musicRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.journal.path))
    }
}

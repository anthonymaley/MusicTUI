import XCTest
@testable import music

// When Music.app is found running but cannot be read or written, the plays
// involved stay waiting, and the pass says why: `music sync-plays` names the
// reason and exits 1, and the TUI says it once per distinct reason. Every test
// here runs the real engine on a temporary folder with an injected writer; the
// command tests render what that engine returned.

private let P1 = MusicProcess(pid: 4413, startedAt: 1_790_200_000.250_001)
private let P2 = MusicProcess(pid: 5120, startedAt: 1_790_310_000.654_321)
private let awakeAlias = "596357614188841472"
private let awake = "0846B01728D34A00"
private let donorAlias = "-2898457328848859944"
private let donor = "D7C69C6A85560CD8"
private let completed = 1_790_300_187
private let earlier = 1_790_000_000
private let denied = MusicAccessSentence.automationNotPermitted

private func state(_ count: Int, _ date: Int?) -> TrackPlayState { TrackPlayState(count: count, date: date) }

private final class Feed: CompletedPlaysReading {
    var plays: [CompletedPlayRecord] = []

    func add(_ alias: String, _ title: String) {
        let seq = plays.count + 1
        plays.append(CompletedPlayRecord(
            seq: seq, playID: "play-\(seq)", alias: alias, libraryID: "i.\(seq)",
            title: title, artist: "Artist",
            completedAt: Date(timeIntervalSince1970: TimeInterval(completed + seq)), end: "advance"))
    }

    func completedPlays(ledgerID: String?, after: Int, limit: Int) throws -> CompletedPlaysPage {
        let page = plays.filter { $0.seq > after }
        let next = page.last?.seq ?? after
        return CompletedPlaysPage(ledgerID: "L1", latestSeq: plays.count, nextAfter: next, more: false, plays: page)
    }
}

/// Music.app as a script: each read and each write answers from its queue, or
/// from the library when the queue is empty.
private final class Writer: PlayCountWriting {
    var process: MusicProcess? = P1
    var library: [String: TrackPlayState] = [awake: state(27, earlier), donor: state(5, earlier)]
    var reads: [Result<TrackLookup, MusicAccessError>] = []
    var writes: [WriteOutcome] = []
    var dateWrites: [WriteOutcome] = []
    private(set) var setCalls = 0

    func musicProcess() -> MusicProcess? { process }

    func read(_ process: MusicProcess, persistentID: String) throws -> TrackLookup {
        if !reads.isEmpty { return try reads.removeFirst().get() }
        guard let found = library[persistentID] else { return .notFound(libraryTrackCount: library.count) }
        return .found(found)
    }

    func write(_ process: MusicProcess, persistentID: String,
               expect: TrackPlayState, target: TrackPlayState) -> WriteOutcome {
        setCalls += 1
        if !writes.isEmpty { return writes.removeFirst() }
        library[persistentID] = target
        return .applied(target)
    }

    func writeDate(_ process: MusicProcess, persistentID: String,
                   expect: TrackPlayState, date: Int) -> WriteOutcome {
        setCalls += 1
        if !dateWrites.isEmpty { return dateWrites.removeFirst() }
        let current = library[persistentID]!
        library[persistentID] = state(current.count, date)
        return .applied(library[persistentID]!)
    }
}

private final class Inspector: MusicInstanceInspecting {
    var exited: Set<Int32> = []
    func state(of process: MusicProcess) -> MusicInstanceState { exited.contains(process.pid) ? .exited : .alive }
}

private final class Harness {
    let root: URL
    let paths: PlaySyncPaths
    let feed = Feed()
    let writer = Writer()
    let inspector = Inspector()

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("playsync-access-\(UUID().uuidString)")
        paths = PlaySyncPaths(directory: root.appendingPathComponent("playsync"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    var engine: PlaySyncEngine {
        PlaySyncEngine(paths: paths, feed: feed, writer: writer, inspector: inspector,
                       now: { Date(timeIntervalSince1970: TimeInterval(completed + 600)) })
    }

    func entries(file: StaticString = #filePath, line: UInt = #line) -> [PlaySyncEntry] {
        guard case .loaded(let journal) = PlaySyncJournal.load(from: paths.journal) else {
            XCTFail("the journal on disk is not loadable", file: file, line: line)
            return []
        }
        return journal.entries
    }
}

final class PlaySyncMusicAccessTests: XCTestCase {

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

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: Reads

    func testReadDeniedKeepsThePlayWaitingAndTheCommandSaysWhyAndFails() throws {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.reads = [.failure(.failed(denied))]

        let result = h.engine.pass(.explicit)

        XCTAssertNil(result.blocked)
        XCTAssertTrue(result.musicRunning)
        XCTAssertEqual(result.musicAccess, .failed(denied))
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(result.newProblems, [])
        XCTAssertEqual(result.outstanding, [])
        XCTAssertEqual(h.writer.setCalls, 0)
        XCTAssertEqual(h.entries().map(\.state), [.pending])
        XCTAssertEqual(h.entries().map(\.reason), [nil])

        let out = renderSyncPlays(result, json: false)
        XCTAssertEqual(out.text,
            "1 play waiting: Music.app could not be accessed "
            + "(Music.app automation is not permitted for this terminal). Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)

        let body = try json(renderSyncPlays(result, json: true).text)
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertEqual(body["waiting"] as? Int, 1)
        XCTAssertEqual(body["music_running"] as? Bool, true)
        XCTAssertEqual(body["error"] as? String, out.text)
    }

    func testReadDeniedThroughTheCommandsOwnPass() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.feed.add(donorAlias, "Organ Donor")
        h.writer.reads = [.failure(.failed(denied))]

        let out = SyncPlays.perform(h.engine, json: false)

        XCTAssertEqual(out.text,
            "2 plays waiting: Music.app could not be accessed "
            + "(Music.app automation is not permitted for this terminal). Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
        XCTAssertEqual(h.entries().map(\.state), [.pending, .pending])
    }

    func testReadTimeoutKeepsThePlayWaitingAndTheCommandSaysWhyAndFails() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.reads = [.failure(.timedOut)]

        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .timedOut)
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(h.entries().map(\.state), [.pending])
        let out = renderSyncPlays(result, json: false)
        XCTAssertEqual(out.text, "1 play waiting: Music.app did not answer in time. Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testMusicQuittingAfterItWasFoundKeepsThePlayWaitingAndTheCommandSaysWhyAndFails() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.reads = [.failure(.notRunning)]

        let result = h.engine.pass(.explicit)

        XCTAssertTrue(result.musicRunning)
        XCTAssertEqual(result.musicAccess, .notRunning)
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(h.entries().map(\.state), [.pending])
        let out = renderSyncPlays(result, json: false)
        XCTAssertEqual(out.text,
            "1 play waiting: Music.app quit while plays were being recorded. "
            + "Open Music.app and run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testMusicQuittingWhileAnUnconfirmedWriteIsCheckedSaysWhyAndFails() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = [.unknown("timed out")]
        let first = h.engine.pass(.explicit)
        XCTAssertEqual(first.unconfirmed.count, 1)
        XCTAssertNil(first.musicAccess)

        h.writer.reads = [.failure(.notRunning)]
        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .notRunning)
        XCTAssertEqual(result.waiting, 0)
        XCTAssertEqual(h.entries().map(\.state), [.unresolved])
        let out = renderSyncPlays(result, json: false)
        XCTAssertEqual(out.text, """
            Music.app quit while plays were being recorded. Open Music.app and run music sync-plays again.
            Waiting for Music.app to confirm (1):
              Are You Awake? — Artist
              These, and later plays of the same songs, are checked again on every sync.
            """)
        XCTAssertEqual(out.exit, 1)
    }

    // MARK: Writes refused before any set call

    func testWriteRefusedBeforeTheSetCallKeepsThePlayWaitingAndNeverUnmatched() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = Array(repeating: .notSent(current: nil, reason: denied), count: 4)

        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .failed(denied))
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(result.newProblems, [])
        let entry = h.entries().first
        XCTAssertEqual(entry?.state, .pending)
        XCTAssertNil(entry?.target)
        XCTAssertNil(entry?.reason)
        let out = renderSyncPlays(result, json: false)
        XCTAssertEqual(out.text,
            "1 play waiting: Music.app could not be accessed "
            + "(Music.app automation is not permitted for this terminal). Run music sync-plays again.")
        XCTAssertEqual(out.exit, 1)
    }

    func testWriteTimingOutBeforeTheSetCallIsReportedAsATimeout() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = Array(repeating: .notSent(current: nil, reason: MusicAccessSentence.timedOut), count: 4)

        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .timedOut)
        XCTAssertEqual(h.entries().map(\.state), [.pending])
        XCTAssertEqual(renderSyncPlays(result, json: false).text,
                       "1 play waiting: Music.app did not answer in time. Run music sync-plays again.")
    }

    func testRetainedWriteRefusedBeforeTheSetCallKeepsItsTargetAndSaysWhy() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = [.unknown("timed out")]
        h.engine.pass(.explicit)
        let target = h.entries().first?.target

        // The instance that received the write has exited; the replacement is
        // read, then refuses the retry before any set call.
        h.inspector.exited = [P1.pid]
        h.writer.process = P2
        h.writer.writes = [.notSent(current: nil, reason: denied)]
        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .failed(denied))
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(h.entries().first?.state, .pending)
        XCTAssertEqual(h.entries().first?.target, target)
        XCTAssertEqual(renderSyncPlays(result, json: false).exit, 1)
    }

    func testDateRepairRefusedBeforeTheSetCallKeepsItsTargetAndSaysWhy() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = [.countAppliedDateUnknown("timed out")]
        h.engine.pass(.explicit)
        h.writer.library[awake] = state(28, earlier)   // the count landed, the date did not
        XCTAssertEqual(h.entries().first?.phase, .dateOnly)

        h.inspector.exited = [P1.pid]
        h.writer.process = P2
        h.writer.dateWrites = [.notSent(current: nil, reason: MusicAccessSentence.timedOut)]
        let result = h.engine.pass(.explicit)

        XCTAssertEqual(result.musicAccess, .timedOut)
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(h.entries().first?.state, .pending)
        XCTAssertEqual(h.entries().first?.phase, .dateOnly)
        XCTAssertEqual(renderSyncPlays(result, json: false).text,
                       "1 play waiting: Music.app did not answer in time. Run music sync-plays again.")
    }

    // MARK: Nothing failed

    func testANativeChangeThatIsPlannedAgainAndRecordedIsNotAFailure() {
        h.feed.add(awakeAlias, "Are You Awake?")
        h.writer.writes = [.notSent(current: state(28, completed), reason: MusicAccessSentence.changed)]

        let result = h.engine.pass(.explicit)

        XCTAssertNil(result.musicAccess)
        XCTAssertEqual(result.recorded.count, 1)
        XCTAssertEqual(renderSyncPlays(result, json: false).exit, 0)
    }

    func testAPassThatRecordsEverythingReportsNoFailure() {
        h.feed.add(awakeAlias, "Are You Awake?")
        let result = h.engine.pass(.explicit)
        XCTAssertNil(result.musicAccess)
        XCTAssertEqual(result.recorded.count, 1)
    }
}

// MARK: - The TUI says it once per distinct reason

private final class ScriptedRunner: PlaySyncRunning {
    var results: [PlaySyncResult] = []
    func pass(_ trigger: PlaySyncTrigger) -> PlaySyncResult { results.removeFirst() }
}

private struct Toast: Equatable {
    let text: String
    let error: Bool
    let ttl: TimeInterval
}

final class PlaySyncWorkerMusicAccessTests: XCTestCase {

    private func result(musicRunning: Bool = true, access: MusicAccessError? = nil,
                        blocked: PlaySyncBlock? = nil, waiting: Int = 1) -> PlaySyncResult {
        var result = PlaySyncResult(blocked: blocked, fetch: .ok(newPlays: 0), musicRunning: musicRunning,
                                    recorded: [], newProblems: [], outstanding: [], unconfirmed: [],
                                    waiting: waiting)
        result.musicAccess = access
        return result
    }

    private func run(_ results: [PlaySyncResult]) -> [Toast] {
        let runner = ScriptedRunner()
        runner.results = results
        var toasts: [Toast] = []
        let worker = PlaySyncWorker(isBridgeSelected: { true }, runner: runner,
                                    post: { toasts.append(Toast(text: $0, error: $1, ttl: $2)) })
        for _ in results { worker.tickOnce() }
        return toasts
    }

    private let deniedToast = Toast(
        text: "Plays waiting: Music.app could not be accessed "
            + "(Music.app automation is not permitted for this terminal) \u{2014} run music sync-plays",
        error: true, ttl: PlaySyncWorker.problemTTL)

    func testTheSameFailureOnEveryTickIsSaidOnce() {
        let denial = result(access: .failed(denied))
        XCTAssertEqual(run([denial, denial, denial]), [deniedToast])
    }

    func testEachWordingOfTheReason() {
        XCTAssertEqual(run([result(access: .timedOut)]).map(\.text),
                       ["Plays waiting: Music.app did not answer in time \u{2014} run music sync-plays"])
        XCTAssertEqual(run([result(access: .notRunning)]).map(\.text),
                       ["Plays waiting: Music.app quit while plays were being recorded \u{2014} run music sync-plays"])
    }

    func testADifferentReasonIsSaidAgain() {
        let toasts = run([result(access: .failed(denied)), result(access: .timedOut),
                          result(access: .timedOut)])
        XCTAssertEqual(toasts.map(\.text), [
            deniedToast.text,
            "Plays waiting: Music.app did not answer in time \u{2014} run music sync-plays",
        ])
    }

    func testTheSameReasonAfterMusicWorkedAgainIsSaidAgain() {
        let denial = result(access: .failed(denied))
        XCTAssertEqual(run([denial, result(access: nil), denial]), [deniedToast, deniedToast])
    }

    func testPassesThatNeverReachedMusicDoNotRepeatIt() {
        let denial = result(access: .failed(denied))
        let toasts = run([denial,
                          result(musicRunning: false),
                          result(musicRunning: false, blocked: .lockBusy, waiting: 0),
                          denial])
        XCTAssertEqual(toasts, [deniedToast])
    }
}

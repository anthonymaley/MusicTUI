import XCTest
@testable import music

/// A coordinator wired for play-from-here with fakes only (score step C2): a
/// journal at a temporary directory (or an in-memory one), scripted SpanDAC
/// ops, a scripted gate, and recorded seams. Nothing here reaches Music.app, a
/// socket or `~/.config/music`.
final class DFHC2Fixture {
    typealias Sequence = (_ hex: String, _ txn: String, _ request: DiscoverCopyRequest,
                          _ gate: @escaping DiscoverCopyGate,
                          _ progress: @escaping (DiscoverCopyStage) -> Void,
                          _ commitListening: @escaping () -> Void) -> DiscoverCopyPlayResult

    static let hexA = "0000000000001234"     // alias "4660"
    static let copyA = CatalogPlaylistCopy(alias: "4660")
    static let copyB = CatalogPlaylistCopy(alias: "4661")
    static let playlistID = "pl.mix"
    static let title = "Mix"

    let root: URL
    let paths: DiscoverCopyPaths
    let journal: DiscoverCopyJournalStore
    let ops = FakeCatalogPlaylistOps()
    let gate = FakeDiscoverCopyGate()

    var spandacSelected = true
    var deleteResult: (String) -> DiscoverCopyDeleteResult = { _ in .kept }
    var onAdmissionWait: (() -> Void)?
    var onRestore: ((String) -> Void)?
    /// Nil runs the launch sweep body at once; otherwise the test holds it.
    var heldLaunchBody: (() -> Void)?
    var holdLaunch = false
    /// The whole happy path by default: waiting, ready, positioning, G-f, listening.
    lazy var sequenceBody: Sequence = { _, _, _, gate, progress, commit in
        progress(.waitingForCopy)
        progress(.ready)
        progress(.positioning)
        return gate { commit() } == .ran ? .listening : .refused(.sourceChanged)
    }

    private let lock = NSLock()
    private var _events: [String] = []
    private var _toasts: [DiscoverToast] = []
    private var _states: [DiscoverTransactionState] = []
    private(set) var sequenceCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var restoreCalls: [String] = []
    private(set) var adoptCalls: [String] = []
    private(set) var logs: [String] = []

    private(set) var coordinator: DiscoverLifecycleCoordinator!

    init(journal injected: DiscoverCopyJournalStore? = nil, wired: Bool = true) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dfh-c2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DiscoverCopyPaths(directory: root.appendingPathComponent("discover-copies"))
        journal = injected ?? FileDiscoverCopyJournalStore(paths: paths)
        var seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { [self] _ in record("sweep") },
            create: { _, _ in },
            readCount: { _ in 1 },
            play: { _ in },
            confirmRead: { _ in discoverConfirmedToken },
            post: { [self] toast in post(toast) },
            scheduler: DiscoverScheduler(now: Date.init,
                                         deadline: { _ in Date().addingTimeInterval(10) },
                                         delay: { _ in }),
            onTransition: { [self] _, state in
                lock.lock(); _states.append(state); lock.unlock()
                record("state:\(Self.label(state))")
            },
            onAdmissionWait: { [self] in onAdmissionWait?() },
            launchExecutor: { [self] body in
                if holdLaunch { heldLaunchBody = body } else { body() }
            })
        if wired { seams.copy = copySeams }
        coordinator = DiscoverLifecycleCoordinator(seams: seams)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var copySeams: DiscoverCopySeams {
        DiscoverCopySeams(
            ops: { [self] in ops },
            journal: journal,
            sequence: { [self] hex, txn, request, gate, progress, commit in
                sequenceCalls.append("\(txn):\(hex)")
                record("sequence")
                return sequenceBody(hex, txn, request, gate, progress, commit)
            },
            deleteIfOwned: { [self] txn in
                deleteCalls.append(txn)
                return deleteResult(txn)
            },
            restoreModes: { [self] txn in
                restoreCalls.append(txn)
                onRestore?(txn)
            },
            adopt: { [self] txn, hex in adoptCalls.append("\(txn):\(hex)") },
            spandacDataSelected: { [self] in spandacSelected },
            now: Date.init,
            log: { [self] line in logs.append(line) })
    }

    func post(_ toast: DiscoverToast) {
        lock.lock(); _toasts.append(toast); lock.unlock()
        record("toast")
    }

    private func record(_ event: String) { lock.lock(); _events.append(event); lock.unlock() }

    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    var toasts: [DiscoverToast] { lock.lock(); defer { lock.unlock() }; return _toasts }
    var states: [String] { lock.lock(); defer { lock.unlock() }; return _states.map(Self.label) }
    var stateValues: [DiscoverTransactionState] { lock.lock(); defer { lock.unlock() }; return _states }

    /// What is on the disk now, through a store of its own.
    func onDisk() throws -> [DiscoverCopyEntry] { try FileDiscoverCopyJournalStore(paths: paths).entries() }
    var journalFileExists: Bool { FileManager.default.fileExists(atPath: paths.journal.path) }

    func request(_ lengths: [RowLength] = [.milliseconds(1000), .milliseconds(2000), .milliseconds(3000)],
                 selected: Int = 1) -> DiscoverCopyRequest {
        DiscoverCopyRequest(playlistID: Self.playlistID, playlistTitle: Self.title,
                            rows: dfhRows(lengths), selected: selected)
    }

    /// Phase A then phase B on this thread, with the launch sweep finished.
    @discardableResult
    func play(_ request: DiscoverCopyRequest? = nil, file: StaticString = #filePath,
              line: UInt = #line) -> DiscoverPlayRequestOutcome {
        coordinator.startLaunchSweep()
        guard case .reserved(let reservation) = coordinator.reserveCopyPlay(request ?? self.request()) else {
            XCTFail("not reserved", file: file, line: line)
            return .refused(.busy)
        }
        return coordinator.runCopyPlay(reservation, gate: gate.gate)
    }

    func refused(_ text: String) -> DiscoverToast { .outcome(.refused(text), title: Self.title) }

    static func entry(_ txn: String, _ state: DiscoverCopyState, hex: String? = nil,
                      copySeen: Bool = false, told: Bool = false, watching: Bool = false,
                      priorShuffle: Bool? = nil, priorRepeat: String? = nil,
                      title: String = DFHC2Fixture.title) -> DiscoverCopyEntry {
        DiscoverCopyEntry(txn: txn, playlistID: playlistID, title: title, state: state, hex: hex,
                          copiesRead: 0, watching: watching, copySeen: copySeen, toldAtLaunch: told,
                          priorShuffle: priorShuffle, priorRepeat: priorRepeat, createdAt: 5, updatedAt: 5)
    }

    static func label(_ state: DiscoverTransactionState) -> String {
        switch state {
        case .minted: return "minted"
        case .created: return "created"
        case .ready: return "ready"
        case .playIssued: return "playIssued"
        case .unconfirmed: return "unconfirmed"
        case .playAmbiguous: return "playAmbiguous"
        case .confirmedPlaying: return "confirmedPlaying"
        case .failedBeforePlay(_, let stage): return "failedBeforePlay(\(stage))"
        case .unknownOutcome: return "unknownOutcome"
        case .positioning: return "positioning"
        case .listening: return "listening"
        }
    }
}

final class DiscoverCopyTransactionTests: XCTestCase {
    private typealias F = DFHC2Fixture

    private func completed(_ outcome: DiscoverPlayRequestOutcome, file: StaticString = #filePath,
                           line: UInt = #line) -> String {
        guard case .completed(let state) = outcome else {
            XCTFail("not completed: \(outcome)", file: file, line: line)
            return ""
        }
        XCTAssertTrue(state.name.hasPrefix("copy:"), file: file, line: line)
        XCTAssertFalse(state.name.contains("__discover__"), file: file, line: line)
        return F.label(state)
    }

    // MARK: The record is on disk before each risky step

    func testTheIntentIsOnDiskBeforeTheAddAndOwnedBeforeTheSequencer() throws {
        let f = F()
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])
        var atAdd: [DiscoverCopyEntry] = []
        var atSequence: [DiscoverCopyEntry] = []
        var gateCallsAtSequence = -1
        f.ops.onAdd = { atAdd = (try? f.onDisk()) ?? [] }
        f.sequenceBody = { _, _, _, gate, progress, commit in
            atSequence = (try? f.onDisk()) ?? []
            gateCallsAtSequence = f.gate.calls.count
            progress(.waitingForCopy); progress(.ready); progress(.positioning)
            _ = gate { commit() }
            return .listening
        }

        XCTAssertEqual(completed(f.play()), "listening")

        XCTAssertEqual(atAdd.count, 1)
        XCTAssertEqual(atAdd.first?.state, .intent)
        XCTAssertNil(atAdd.first?.hex)
        XCTAssertEqual(atAdd.first?.copiesRead, 0)
        XCTAssertEqual(atAdd.first?.playlistID, F.playlistID)
        XCTAssertEqual(atAdd.first?.title, F.title)
        XCTAssertEqual(atAdd.first?.isDeletable, false)

        // `owned` + hex is on the disk before the first Music.app command, and
        // that write went through no gate: only G-a had been asked.
        XCTAssertEqual(atSequence.map(\.state), [.owned])
        XCTAssertEqual(atSequence.first?.hex, F.hexA)
        XCTAssertEqual(atSequence.first?.isDeletable, true)
        XCTAssertEqual(gateCallsAtSequence, 1)
    }

    func testDeletableOnlyAfterNoCopyAnAddThatSucceededAndExactlyOneCopy() throws {
        let f = F()
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])

        XCTAssertEqual(completed(f.play()), "listening")

        let entries = try f.onDisk()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .listening)
        XCTAssertEqual(entry.hex, F.hexA)
        XCTAssertTrue(entry.watching)
        XCTAssertTrue(entry.isDeletable)
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix", "add:pl.mix"])
        XCTAssertEqual(f.sequenceCalls, ["\(entry.txn):\(F.hexA)"])
        XCTAssertEqual(f.adoptCalls, ["\(entry.txn):\(F.hexA)"])
        XCTAssertEqual(f.deleteCalls, [])
        XCTAssertEqual(f.states, ["minted", "created", "ready", "positioning", "listening"])
        XCTAssertEqual(f.stateValues.first?.name, "copy:\(entry.txn)")
        XCTAssertEqual(f.toasts, [
            .progress(discoverAddingText(playlist: F.title)),
            .progress(discoverWaitingText(playlist: F.title)),
            .progress(discoverPositioningText(title: "Song 2")),
            .outcome(.playing(title: F.title), title: F.title),
        ])
        XCTAssertEqual(f.gate.calls, [.ran, .ran])
        XCTAssertTrue(f.coordinator.transactions.values.allSatisfy { !$0.isProtected })
        XCTAssertFalse(f.logs.filter { $0.contains("S1 copies") }.isEmpty)
        XCTAssertFalse(f.logs.filter { $0.contains("S3 add") }.isEmpty)
        XCTAssertFalse(f.logs.filter { $0.contains("S4 owned") }.isEmpty)
        XCTAssertFalse(f.logs.filter { $0.contains("S5-S14 sequence") }.isEmpty)
    }

    // MARK: Never deletable

    func testACopyThatWasAlreadyThereIsPreexistingAndNeverDeletable() throws {
        let f = F()
        f.ops.copiesResults = [.success([F.copyA])]

        XCTAssertEqual(completed(f.play()), "listening")

        let entry = try XCTUnwrap(try f.onDisk().first)
        XCTAssertEqual(try f.onDisk().count, 1)
        XCTAssertEqual(entry.state, .preexisting)      // S14 leaves it preexisting
        XCTAssertEqual(entry.hex, F.hexA)
        XCTAssertEqual(entry.copiesRead, 1)
        XCTAssertTrue(entry.watching)
        XCTAssertFalse(entry.isDeletable)
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])           // no add
        XCTAssertEqual(f.sequenceCalls, ["\(entry.txn):\(F.hexA)"])
        XCTAssertEqual(f.deleteCalls, [])
    }

    func testAnUnknownOutcomeIsUncertainAndTheCopyFoundAtTheNextEnterIsPreexisting() throws {
        let f = F()
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .outcomeUnknown("timed out")

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        var entries = try f.onDisk()
        XCTAssertEqual(entries.map(\.state), [.uncertain])
        XCTAssertEqual(entries.first?.copySeen, false)
        XCTAssertNil(entries.first?.hex)
        XCTAssertEqual(f.toasts.last, f.refused(discoverCopyMaybeAddedText(playlist: F.title)))
        XCTAssertEqual(f.sequenceCalls, [])
        let uncertain = try XCTUnwrap(entries.first)

        // The next Enter finds the copy the lost add may have made.
        f.ops.copiesResults = [.success([F.copyA])]
        XCTAssertEqual(completed(f.play()), "listening")
        entries = try f.onDisk()
        XCTAssertEqual(entries.map(\.state), [.uncertain, .preexisting])
        XCTAssertEqual(entries.first, uncertain)                  // untouched
        XCTAssertEqual(entries.last?.hex, F.hexA)
        XCTAssertTrue(entries.allSatisfy { !$0.isDeletable })
        XCTAssertEqual(f.ops.calls.filter { $0.hasPrefix("add:") }.count, 1)
        // Reconcile asked the guard about nothing: neither entry was ever ours.
        XCTAssertEqual(f.deleteCalls, [])
    }

    func testOutcomesThatProveNothingAreUncertainAndNothingPlays() throws {
        let noAlias = CatalogPlaylistCopy(alias: nil)
        let cases: [(String, CatalogPlaylistAddOutcome, Bool)] = [
            ("copy_appeared", .copyAppeared, true),
            ("two copies after success", .added(copies: [F.copyA, F.copyB]), true),
            ("zero copies after success", .added(copies: []), false),
            ("one copy with no id after success", .added(copies: [noAlias]), true),
        ]
        for (name, outcome, seen) in cases {
            let f = F()
            f.ops.copiesResults = [.success([])]
            f.ops.addOutcome = outcome

            XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)", name)

            let entries = try f.onDisk()
            XCTAssertEqual(entries.map(\.state), [.uncertain], name)
            XCTAssertEqual(entries.first?.copySeen, seen, name)
            XCTAssertNil(entries.first?.hex, name)
            XCTAssertEqual(entries.first?.isDeletable, false, name)
            let text = seen ? discoverCopyLeftText(playlist: F.title) : discoverCopyMaybeAddedText(playlist: F.title)
            XCTAssertEqual(f.toasts, [.progress(discoverAddingText(playlist: F.title)), f.refused(text)], name)
            XCTAssertEqual(f.sequenceCalls, [], name)
            XCTAssertEqual(f.deleteCalls, [], name)
            XCTAssertEqual(f.adoptCalls, [], name)
            XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld, name)
        }
    }

    func testAnOwnedWriteThatFailsLeavesTheCopyUncertainAndNothingPlays() throws {
        let journal = InMemoryDiscoverCopyJournalStore()
        journal.failWrites = { $0.hasSuffix(":owned") }
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")

        XCTAssertEqual(journal.stored.map(\.state), [.uncertain])
        XCTAssertEqual(journal.stored.first?.copySeen, true)
        XCTAssertNil(journal.stored.first?.hex)
        XCTAssertEqual(journal.stored.first?.isDeletable, false)
        XCTAssertEqual(f.toasts.last, f.refused(discoverCopyLeftText(playlist: F.title)))
        XCTAssertEqual(f.sequenceCalls, [])
        XCTAssertEqual(f.deleteCalls, [])
    }

    func testAnOwnedWriteAndItsUncertainFallbackBothFailingStillLeavesNothingDeletable() throws {
        let journal = InMemoryDiscoverCopyJournalStore()
        journal.failWrites = { $0.hasPrefix("update:") }
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")

        XCTAssertEqual(journal.stored.map(\.state), [.intent])     // no hex: not deletable
        XCTAssertEqual(journal.stored.first?.isDeletable, false)
        XCTAssertEqual(f.sequenceCalls, [])
        XCTAssertEqual(f.deleteCalls, [])
    }

    func testAnEntryNoLongerIntentIsNotPromotedToOwned() throws {
        // Another process closed the intent while the add was in flight.
        let journal = InMemoryDiscoverCopyJournalStore()
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])
        f.ops.onAdd = {
            let txn = journal.stored[0].txn
            _ = try? journal.update(txn: txn) { $0.state = .closed }
        }

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")

        XCTAssertEqual(journal.stored.map(\.state), [.uncertain])
        XCTAssertEqual(journal.stored.first?.isDeletable, false)
        XCTAssertEqual(f.sequenceCalls, [])
    }

    // MARK: Refusals before anything is added

    func testARefusedAddClosesTheEntry() throws {
        let cases: [(CatalogPlaylistAddOutcome, String)] = [
            (.refused("no"), discoverAddRefusedText(playlist: F.title)),
            (.notOffered, updateSpanDACToPlayOnMusicTUI),
        ]
        for (outcome, text) in cases {
            let f = F()
            f.ops.copiesResults = [.success([])]
            f.ops.addOutcome = outcome
            XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
            XCTAssertEqual(try f.onDisk().map(\.state), [.closed])
            XCTAssertEqual(f.toasts.last, f.refused(text))
            XCTAssertEqual(f.sequenceCalls, [])
        }
    }

    func testAFailedCopiesReadAddsNothingAndWritesNothing() {
        let f = F()
        f.ops.copiesResults = [.failure(SpanDACLibraryOpError.failed("socket closed"))]
        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        XCTAssertEqual(f.toasts, [.outcome(.createFailed("socket closed"), title: F.title)])
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertFalse(f.journalFileExists)
        XCTAssertEqual(f.gate.calls, [])
    }

    func testSeveralCopiesOrACopyWithNoIDRefuseWithNoRecordAndNoAdd() {
        let cases: [([CatalogPlaylistCopy], String)] = [
            ([F.copyA, F.copyB], discoverSeveralCopiesText(playlist: F.title)),
            ([CatalogPlaylistCopy(alias: nil)], discoverCopyNoIDText(playlist: F.title)),
            ([CatalogPlaylistCopy(alias: "not a number")], discoverCopyNoIDText(playlist: F.title)),
        ]
        for (copies, text) in cases {
            let f = F()
            f.ops.copiesResults = [.success(copies)]
            XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
            XCTAssertEqual(f.toasts, [f.refused(text)])
            XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
            XCTAssertFalse(f.journalFileExists)
            XCTAssertEqual(f.gate.calls, [])
            XCTAssertEqual(f.sequenceCalls, [])
        }
    }

    func testAnIntentThatCannotBeWrittenMeansTheAddIsNotCalled() {
        let journal = InMemoryDiscoverCopyJournalStore()
        journal.failWrites = { $0.hasPrefix("insert:") }
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        XCTAssertEqual(f.toasts, [f.refused(discoverJournalUnwritableText(playlist: F.title))])
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertEqual(journal.stored, [])

        // The same for a copy that was already there: no record, no play.
        f.ops.copiesResults = [.success([F.copyA])]
        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        XCTAssertEqual(f.toasts.last, f.refused(discoverJournalUnwritableText(playlist: F.title)))
        XCTAssertEqual(f.sequenceCalls, [])
    }

    func testAnUnreadableJournalRefusesACopyThatIsAlreadyThere() throws {
        let f = F()
        try FileManager.default.createDirectory(at: f.paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = Data("garbage".utf8)
        try bytes.write(to: f.paths.journal)
        f.ops.copiesResults = [.success([F.copyA])]

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        XCTAssertEqual(f.toasts, [f.refused(discoverJournalUnwritableText(playlist: F.title))])
        XCTAssertEqual(f.sequenceCalls, [])
        XCTAssertEqual(f.gate.calls, [])
        XCTAssertEqual(try Data(contentsOf: f.paths.journal), bytes)

        // And with no copy: the intent cannot be written, so nothing is added.
        f.ops.copiesResults = [.success([])]
        XCTAssertEqual(completed(f.play()), "failedBeforePlay(create)")
        XCTAssertEqual(f.ops.calls.filter { $0.hasPrefix("add:") }, [])
        XCTAssertEqual(try Data(contentsOf: f.paths.journal), bytes)
    }

    // MARK: Reusing a copy this journal proves MusicTUI made

    func testACopyWithADeletableEntryIsReusedUnderItsOwnTxn() throws {
        let f = F()
        try f.journal.insert(F.entry("T0", .listening, hex: F.hexA, watching: true))
        f.ops.copiesResults = [.success([F.copyA])]
        f.deleteResult = { _ in .spared }       // it is what is playing now

        XCTAssertEqual(completed(f.play()), "listening")

        XCTAssertEqual(try f.onDisk().map(\.txn), ["T0"])           // still one entry
        XCTAssertEqual(try f.onDisk().first?.state, .listening)
        XCTAssertEqual(f.sequenceCalls, ["T0:\(F.hexA)"])
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertEqual(f.gate.calls, [.ran, .ran])                   // G-a (empty body), G-f
        XCTAssertEqual(f.adoptCalls.last, "T0:\(F.hexA)")
    }

    // MARK: Item 6a: a failed preflight sends nothing and writes nothing

    func testEveryPreflightRefusalSendsNoOpAndWritesNoJournal() {
        let ms = RowLength.milliseconds(1000)
        struct Case { let name: String; let offers: Bool; let lengths: [RowLength]; let selected: Int
                      let refusal: DiscoverRefusal; let text: String }
        let cases = [
            Case(name: "capability", offers: false, lengths: [ms, ms], selected: 0,
                 refusal: .libraryOpsNotOffered, text: updateSpanDACToPlayOnMusicTUI),
            Case(name: "absent", offers: true, lengths: [ms, .absent], selected: 0,
                 refusal: .libraryOpsNotOffered, text: updateSpanDACToPlayOnMusicTUI),
            Case(name: "malformed", offers: true, lengths: [ms, .malformed], selected: 0,
                 refusal: .preflight, text: discoverMalformedLengthText),
            Case(name: "null", offers: true, lengths: [.null, ms], selected: 1,
                 refusal: .preflight, text: discoverNoLengthText(title: "Song 1")),
            Case(name: "range", offers: true, lengths: [ms, ms], selected: 2,
                 refusal: .preflight, text: discoverCopyChangedText(playlist: F.title)),
        ]
        for c in cases {
            let f = F()
            f.ops.offers = c.offers
            let outcome = f.play(f.request(c.lengths, selected: c.selected))
            XCTAssertEqual(outcome, .refused(c.refusal), c.name)
            XCTAssertEqual(f.toasts, [f.refused(c.text)], c.name)
            XCTAssertEqual(f.ops.calls, [], c.name)
            XCTAssertFalse(f.journalFileExists, c.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.directory.path), c.name)
            XCTAssertEqual(f.coordinator.transactions.count, 0, c.name)   // nothing minted
            XCTAssertEqual(f.gate.calls, [], c.name)
            XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld, c.name)
        }
    }

    func testANullLengthAfterTheChosenRowDoesNotRefuse() {
        let f = F()
        f.ops.copiesResults = [.success([F.copyA])]
        let outcome = f.play(f.request([.milliseconds(1), .milliseconds(2), .null], selected: 1))
        XCTAssertEqual(completed(outcome), "listening")
    }

    // MARK: Gate G-a

    func testGateGaFindingTheSourceMovedAddsNothingAndRecordsNothing() {
        let f = F()
        f.ops.copiesResults = [.success([])]
        f.gate.scripted = [1: .sourceChanged]

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(selectionChanged)")
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertFalse(f.journalFileExists)
        XCTAssertEqual(f.toasts, [f.refused(sourceChangedNothingPlayed)])
        XCTAssertEqual(f.sequenceCalls, [])
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    func testGateGaFindingALaterPlayAddsNothingAndPostsNothing() {
        let f = F()
        f.ops.copiesResults = [.success([])]
        f.gate.scripted = [1: .superseded]

        XCTAssertEqual(completed(f.play()), "failedBeforePlay(superseded)")
        XCTAssertEqual(f.ops.calls, ["copies:pl.mix"])
        XCTAssertFalse(f.journalFileExists)
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(f.sequenceCalls, [])
    }

    func testGateGaMovedBeforeReusingOrRecordingAnExistingCopy() throws {
        for (answer, state) in [(DiscoverCopyGateResult.sourceChanged, "failedBeforePlay(selectionChanged)"),
                                (.superseded, "failedBeforePlay(superseded)")] {
            let f = F()
            f.ops.copiesResults = [.success([F.copyA])]
            f.gate.scripted = [1: answer]
            XCTAssertEqual(completed(f.play()), state)
            XCTAssertFalse(f.journalFileExists)
            XCTAssertEqual(f.sequenceCalls, [])
        }
    }

    // MARK: What the sequencer answers (items 7 and 9)

    func testEverySequencerRefusalMapsToItsStateAndItsSentence() throws {
        struct Case { let refusal: DiscoverCopyRefusal; let reach: [DiscoverCopyStage]; let state: String }
        let all: [DiscoverCopyStage] = [.waitingForCopy, .ready, .positioning]
        let cases = [
            Case(refusal: .notReady, reach: [.waitingForCopy], state: "failedBeforePlay(readiness)"),
            Case(refusal: .countChanged, reach: [.waitingForCopy], state: "failedBeforePlay(identity)"),
            Case(refusal: .unconfirmed(title: "Song 2"), reach: [.waitingForCopy], state: "failedBeforePlay(identity)"),
            Case(refusal: .modes, reach: [.waitingForCopy], state: "failedBeforePlay(modes)"),
            Case(refusal: .sourceChanged, reach: [.waitingForCopy], state: "failedBeforePlay(selectionChanged)"),
            Case(refusal: .sourceChanged, reach: [.waitingForCopy, .ready], state: "failedBeforePlay(selectionChanged)"),
            Case(refusal: .sourceChanged, reach: all, state: "failedBeforePlay(selectionChanged)"),
            Case(refusal: .superseded, reach: [.waitingForCopy], state: "failedBeforePlay(superseded)"),
            Case(refusal: .superseded, reach: [.waitingForCopy, .ready], state: "failedBeforePlay(superseded)"),
            Case(refusal: .superseded, reach: all, state: "failedBeforePlay(superseded)"),
            Case(refusal: .landing(title: "Song 2"), reach: all, state: "failedBeforePlay(positioning)"),
            Case(refusal: .firstPlayUnconfirmed, reach: all, state: "unconfirmed"),
            Case(refusal: .wontPlay(title: "Song 2"), reach: all, state: "unconfirmed"),
            Case(refusal: .wontPlay(title: "Song 1"), reach: [.waitingForCopy, .ready], state: "playAmbiguous"),
            Case(refusal: .firstPlayUnconfirmed, reach: [.waitingForCopy, .ready], state: "playAmbiguous"),
        ]
        for c in cases {
            let f = F()
            f.ops.copiesResults = [.success([])]
            f.ops.addOutcome = .added(copies: [F.copyA])
            f.sequenceBody = { _, _, _, _, progress, _ in
                c.reach.forEach(progress)
                return .refused(c.refusal)
            }
            let name = "\(c.refusal) after \(c.reach)"

            XCTAssertEqual(completed(f.play()), c.state, name)

            let last = f.toasts.last
            if let text = discoverCopyRefusalText(c.refusal, playlist: F.title) {
                XCTAssertEqual(last, f.refused(text), name)
            } else {
                // Superseded: nothing is posted for the refusal itself.
                XCTAssertFalse(f.toasts.contains { if case .outcome = $0 { return true } else { return false } }, name)
            }
            // The transaction itself deletes nothing and adopts nothing.
            XCTAssertEqual(f.deleteCalls, [], name)
            XCTAssertEqual(f.adoptCalls, [], name)
            // The entry is still the owned one: cleanup is the sequencer's.
            XCTAssertEqual(try f.onDisk().map(\.state), [.owned], name)
            // The slot is free again.
            XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld, name)
            guard case .reserved(let again) = f.coordinator.reserveCopyPlay(f.request()) else {
                return XCTFail("slot not free after \(name)")
            }
            f.coordinator.cancelCopyPlay(again)
        }
    }

    func testProtectedStatesAreProtectedOnlyWhileTheyShouldBe() {
        let f = F()
        f.ops.copiesResults = [.success([F.copyA])]
        var duringPositioning: [String] = []
        f.sequenceBody = { _, _, _, _, progress, _ in
            progress(.ready); progress(.ready); progress(.positioning)
            duringPositioning = f.coordinator.protectedNames
            return .refused(.firstPlayUnconfirmed)
        }
        XCTAssertEqual(completed(f.play()), "unconfirmed")
        XCTAssertEqual(duringPositioning.count, 1)
        XCTAssertTrue(duringPositioning[0].hasPrefix("copy:"))
        XCTAssertEqual(f.states, ["minted", "created", "ready", "positioning", "unconfirmed"])
        XCTAssertEqual(f.coordinator.protectedNames, duringPositioning)   // left protected
    }

    func testAListeningWriteThatFailsStillAdoptsAndStillReportsListening() {
        let journal = InMemoryDiscoverCopyJournalStore()
        journal.failWrites = { $0.hasSuffix(":listening") }
        let f = F(journal: journal)
        f.ops.copiesResults = [.success([])]
        f.ops.addOutcome = .added(copies: [F.copyA])

        XCTAssertEqual(completed(f.play()), "listening")
        XCTAssertEqual(journal.stored.map(\.state), [.owned])
        XCTAssertEqual(f.adoptCalls.count, 1)
        XCTAssertEqual(f.toasts.last, .outcome(.playing(title: F.title), title: F.title))
        XCTAssertTrue(f.logs.contains { $0.contains("S14") })
    }

    // MARK: Two phases

    func testReservingDuringTheLaunchSweepIsImmediateAndPhaseBWaitsForSweepAndReconcile() throws {
        let f = F()
        try f.journal.insert(F.entry("U", .uncertain, copySeen: true))
        f.ops.copiesResults = [.success([F.copyA])]
        f.holdLaunch = true
        f.coordinator.startLaunchSweep()
        XCTAssertTrue(f.coordinator.launchSweep.isRunning)

        // Phase A: at once, and nothing in the transaction table (Rule 1's lemma).
        guard case .reserved(let reservation) = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("not reserved")
        }
        XCTAssertEqual(f.coordinator.transactions.count, 0)
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .busy)

        // Phase B waits in Rule 1.
        let waiting = DispatchSemaphore(value: 0)
        var signalled = false
        f.onAdmissionWait = { if !signalled { signalled = true; waiting.signal() } }
        let done = DispatchSemaphore(value: 0)
        var outcome: DiscoverPlayRequestOutcome?
        Thread.detachNewThread {
            outcome = f.coordinator.runCopyPlay(reservation, gate: f.gate.gate)
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.coordinator.transactions.count, 0)
        XCTAssertEqual(f.ops.calls, [])
        XCTAssertNil(outcome)

        // The sweep finishes: the launch reconcile runs, then admission, then the mint.
        try XCTUnwrap(f.heldLaunchBody)()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(outcome.map { completed($0) }, "listening")
        let events = f.events
        let sweep = try XCTUnwrap(events.firstIndex(of: "sweep"))
        let told = try XCTUnwrap(events.firstIndex(of: "toast"))
        let minted = try XCTUnwrap(events.firstIndex(of: "state:minted"))
        XCTAssertLessThan(sweep, told)
        XCTAssertLessThan(told, minted)
        XCTAssertEqual(f.toasts.first, f.refused(discoverCopyLeftText(playlist: F.title)))
        XCTAssertEqual(try f.onDisk().first?.toldAtLaunch, true)
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    func testTheSlotIsOneAtATimeAndCancelFreesIt() {
        let f = F()
        guard case .reserved(let first) = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("not reserved")
        }
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .busy)
        XCTAssertEqual(f.coordinator.transactions.count, 0)
        XCTAssertFalse(f.journalFileExists)
        XCTAssertEqual(f.ops.calls, [])

        f.coordinator.cancelCopyPlay(first)
        guard case .reserved(let second) = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("not reserved after cancel")
        }
        XCTAssertNotEqual(first.slot, second.slot)
        XCTAssertEqual(second.request, f.request())

        // A stale reservation neither frees the slot nor runs.
        f.coordinator.cancelCopyPlay(first)
        XCTAssertTrue(f.coordinator.copyPlaySlotIsHeld)
        f.coordinator.startLaunchSweep()
        XCTAssertEqual(f.coordinator.runCopyPlay(first, gate: f.gate.gate), .refused(.busy))
        XCTAssertTrue(f.coordinator.copyPlaySlotIsHeld)
        XCTAssertEqual(f.ops.calls, [])
    }

    func testTheSlotIsFreeAfterASuccessfulPlay() {
        let f = F()
        f.ops.copiesResults = [.success([F.copyA])]
        XCTAssertEqual(completed(f.play()), "listening")
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
        XCTAssertEqual(completed(f.play()), "listening")
    }

    func testNotWiredWithoutCopySeams() {
        let f = F(wired: false)
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .notWired)
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
    }

    func testClosingAdmissionRefusesNewReservationsAndWakesAWaitingPhaseB() {
        let f = F()
        f.ops.copiesResults = [.success([F.copyA])]
        f.holdLaunch = true
        f.coordinator.startLaunchSweep()
        guard case .reserved(let reservation) = f.coordinator.reserveCopyPlay(f.request()) else {
            return XCTFail("not reserved")
        }
        let waiting = DispatchSemaphore(value: 0)
        var signalled = false
        f.onAdmissionWait = { if !signalled { signalled = true; waiting.signal() } }
        let done = DispatchSemaphore(value: 0)
        var outcome: DiscoverPlayRequestOutcome?
        Thread.detachNewThread {
            outcome = f.coordinator.runCopyPlay(reservation, gate: f.gate.gate)
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)

        f.coordinator.closeAdmission()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(outcome, .refused(.exiting))
        XCTAssertFalse(f.coordinator.copyPlaySlotIsHeld)
        XCTAssertEqual(f.coordinator.transactions.count, 0)
        XCTAssertEqual(f.ops.calls, [])
        XCTAssertFalse(f.journalFileExists)
        XCTAssertEqual(f.coordinator.reserveCopyPlay(f.request()), .exiting)
    }

    // MARK: The pure pieces

    func testTheNewStatesAndTransitions() {
        let n = "copy:X"
        XCTAssertTrue(DiscoverTransactionState.positioning(n).isProtected)
        XCTAssertFalse(DiscoverTransactionState.positioning(n).isTerminal)
        XCTAssertFalse(DiscoverTransactionState.listening(n).isProtected)
        XCTAssertTrue(DiscoverTransactionState.listening(n).isTerminal)
        XCTAssertEqual(DiscoverTransactionState.listening(n).name, n)
        XCTAssertEqual(DiscoverTransactionState.positioning(n).name, n)

        let legal: [(DiscoverTransactionState, DiscoverTransactionState)] = [
            (.minted(n), .failedBeforePlay(n, .selectionChanged)), (.minted(n), .failedBeforePlay(n, .superseded)),
            (.created(n), .failedBeforePlay(n, .modes)), (.created(n), .failedBeforePlay(n, .superseded)),
            (.ready(n), .positioning(n)),
            (.ready(n), .failedBeforePlay(n, .selectionChanged)), (.ready(n), .failedBeforePlay(n, .superseded)),
            (.positioning(n), .listening(n)), (.positioning(n), .unconfirmed(n)),
            (.positioning(n), .failedBeforePlay(n, .positioning)),
            (.positioning(n), .failedBeforePlay(n, .selectionChanged)),
            (.positioning(n), .failedBeforePlay(n, .superseded)),
        ]
        for (from, to) in legal {
            XCTAssertTrue(discoverTransitionIsLegal(from: from, to: to), "\(from) -> \(to)")
        }
        let illegal: [(DiscoverTransactionState, DiscoverTransactionState)] = [
            (.listening(n), .positioning(n)), (.ready(n), .listening(n)), (.created(n), .positioning(n)),
            (.minted(n), .failedBeforePlay(n, .modes)), (.positioning(n), .playIssued(n)),
            (.positioning(n), .listening("copy:Y")),
        ]
        for (from, to) in illegal {
            XCTAssertFalse(discoverTransitionIsLegal(from: from, to: to), "\(from) -> \(to)")
        }
    }

    func testTheTokenIsNeverAContainerName() {
        let token = discoverCopyToken(UUID())
        XCTAssertTrue(token.hasPrefix("copy:"))
        XCTAssertFalse(token.hasPrefix(discoverPlaylistPrefix))
    }
}

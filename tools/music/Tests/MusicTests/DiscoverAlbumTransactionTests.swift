import XCTest
@testable import music

// Album-cleanup step A2: the album transaction (S0a-S14), S7's recorder and
// the B-script. Fakes only: no Music.app, no osascript, no socket, no
// ~/.config/music. The sequencer is the REAL `DiscoverCopySequencer`, over the
// shipped `FakeDiscoverCopyPlayer` behind `DiscoverAlbumEntryRecorder`, on a
// fake clock.

/// A clock the sequencer's polls and the coordinator's alias wait advance.
final class A2Clock {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ seconds: TimeInterval) { lock.lock(); t = t.addingTimeInterval(seconds); lock.unlock() }
    func advance(to instant: Date) { lock.lock(); if instant > t { t = instant }; lock.unlock() }
}

/// A journal that forwards to `inner` and records each SUCCESSFUL write in
/// the fixture's ordered log: `"insert"`, `"update"`, or `"update(sent)"` for
/// the update that first records `writeSentAt`.
final class A2LoggingJournal: DiscoverCopyJournalStore {
    let inner: DiscoverCopyJournalStore
    let log: (String) -> Void
    init(_ inner: DiscoverCopyJournalStore, log: @escaping (String) -> Void) { self.inner = inner; self.log = log }

    func entries() throws -> [DiscoverCopyEntry] { try inner.entries() }

    func insert(_ entry: DiscoverCopyEntry) throws {
        try inner.insert(entry)
        log("insert")
    }

    @discardableResult
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        let before = try? inner.entries().first(where: { $0.txn == txn })
        let after = try inner.update(txn: txn, change)
        log(before?.writeSentAt == nil && after.writeSentAt != nil ? "update(sent)" : "update")
        return after
    }
}

/// Forwards to the shared fake and records `"relations"` in the ordered log.
final class A2LoggingRelations: SpanDACLibraryRelationsReading {
    let fake: FakeLibraryRelations
    let log: (String) -> Void
    init(_ fake: FakeLibraryRelations, log: @escaping (String) -> Void) { self.fake = fake; self.log = log }
    var offersAlbumCleanup: Bool { fake.offersAlbumCleanup }
    func relations(catalogueIDs: [String]) throws -> [String: [String?]] {
        log("relations")
        return try fake.relations(catalogueIDs: catalogueIDs)
    }
}

/// A coordinator wired for album plays with fakes only.
final class A2Fixture {
    static let containerAlias = "4660"
    static let containerHex = "0000000000001234"
    static let beforeIDs = ["00000000000000AA", "00000000000000AB"]

    let clock = A2Clock()
    let root: URL
    let memory: InMemoryDiscoverCopyJournalStore?
    let journal: A2LoggingJournal
    let beforeSet: DiscoverBeforeSetStore
    let relationsFake = FakeLibraryRelations()
    lazy var relations = A2LoggingRelations(relationsFake, log: { [unowned self] in record($0) })
    let library = FakeAlbumLibrary(ensureResults: [.success((created: true, id: "p.album", alias: A2Fixture.containerAlias))])
    let ops = FakeCatalogPlaylistOps()
    let gate = FakeDiscoverCopyGate()
    var player: FakeDiscoverCopyPlayer

    var beforeResult: [String]? = A2Fixture.beforeIDs
    /// Seconds the B read takes on the fake clock.
    var beforeTakes: TimeInterval = 0
    /// Set by a test to replace the album's sequence (default: the real sequencer).
    /// `.ready` and `.positioning` are reported before it runs.
    var albumSequenceOverride: ((_ commit: @escaping () -> Void, _ gate: @escaping DiscoverCopyGate) -> DiscoverCopyPlayResult)?

    private(set) var log: [String] = []
    private(set) var toasts: [DiscoverToast] = []
    private(set) var states: [DiscoverTransactionState] = []
    private(set) var deleteIfOwnedCount = 0
    private(set) var proofCalls: [String] = []
    private(set) var replayCalls: [(txn: String, atLaunch: Bool)] = []
    private(set) var adoptCalls: [String] = []
    private(set) var sequenceTxns: [String] = []
    private(set) var coordinator: DiscoverLifecycleCoordinator!

    /// `fileBacked`: the real journal and before-set store in a temporary
    /// directory (their invariants are enforced on every write).
    init(fileBacked: Bool = false, albumWired: Bool = true, entries: [DiscoverCopyEntry] = []) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dfh-a2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store: DiscoverCopyJournalStore
        if fileBacked {
            let file = FileDiscoverCopyJournalStore(paths: DiscoverCopyPaths(directory: root.appendingPathComponent("discover-copies")))
            for entry in entries { try? file.insert(entry) }
            store = file
            beforeSet = file
            memory = nil
        } else {
            let mem = InMemoryDiscoverCopyJournalStore(entries: entries)
            store = mem
            beforeSet = InMemoryBeforeSetStore()
            memory = mem
        }
        player = FakeDiscoverCopyPlayer(hex: Self.containerHex, ids: [],
                                        trackK: DiscoverCopyTrack(title: "", artist: "", durationMS: nil))
        var logSink: (String) -> Void = { _ in }
        journal = A2LoggingJournal(store, log: { logSink($0) })
        logSink = { [unowned self] in record($0) }
        library.onEnsure = { [unowned self] in record("ensure") }
        player.onCall = { [unowned self] in record("player:\($0)") }

        let clock = self.clock
        var seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in },
            create: { _, _ in },
            readCount: { _ in 1 },
            play: { _ in },
            confirmRead: { _ in discoverConfirmedToken },
            post: { [unowned self] toast in toasts.append(toast); record("toast") },
            scheduler: DiscoverScheduler(now: { clock.now },
                                         deadline: { _ in clock.now.addingTimeInterval(10) },
                                         delay: { clock.advance(to: $0) }),
            onTransition: { [unowned self] _, state in states.append(state) },
            launchExecutor: { $0() })
        seams.copy = copySeams
        if albumWired { seams.album = albumSeams }
        coordinator = DiscoverLifecycleCoordinator(seams: seams)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func record(_ event: String) { log.append(event) }

    var copySeams: DiscoverCopySeams {
        let clock = self.clock
        return DiscoverCopySeams(
            ops: { [unowned self] in ops },
            journal: journal,
            sequence: { _, _, _, gate, progress, commit in
                progress(.ready); progress(.positioning)
                return gate { commit() } == .ran ? .listening : .refused(.sourceChanged)
            },
            deleteIfOwned: { _ in .kept },
            restoreModes: { _ in },
            adopt: { [unowned self] txn, hex in adoptCalls.append("\(txn):\(hex)") },
            spandacDataSelected: { true },
            now: { clock.now },
            log: { _ in })
    }

    var albumSeams: DiscoverAlbumSeams {
        let clock = self.clock
        return DiscoverAlbumSeams(
            library: { [unowned self] in library },
            relations: { [unowned self] in relations },
            beforeSet: beforeSet,
            readBeforeSet: { [unowned self] in
                record("B")
                clock.advance(beforeTakes)
                return beforeResult
            },
            sequence: { [unowned self] hex, txn, request, gate, progress, commit in
                sequenceTxns.append(txn)
                if let albumSequenceOverride {
                    // As the real sequencer reports a play that reaches S14.
                    progress(.ready); progress(.positioning)
                    return albumSequenceOverride(commit, gate)
                }
                let recorder = DiscoverAlbumEntryRecorder(player: player, journal: journal, txn: txn)
                return DiscoverCopySequencer(player: recorder, seams: DiscoverCopySequencer.Seams(
                    now: { clock.now },
                    sleep: { clock.advance($0) },
                    gate: gate,
                    switchModesOff: { true },
                    restoreModes: {},
                    deleteIfOwned: { [unowned self] in deleteIfOwnedCount += 1; record("deleteIfOwned") },
                    commitListening: commit,
                    progress: progress,
                    log: { _ in })).run(hex: hex, request: request)
            },
            startProof: { [unowned self] txn in proofCalls.append(txn); record("startProof") },
            replay: { [unowned self] entry, atLaunch in replayCalls.append((entry.txn, atLaunch)) })
    }

    /// Rows of `count` songs, ids `albumTestCatalogueID(n)`, song n `1000 * n` ms long.
    func request(count: Int = 3, selected: Int = 0, lengths: [RowLength]? = nil,
                 rows: [DiscoverItem]? = nil) -> DiscoverCopyRequest {
        let shown = rows ?? albumTestRows(lengths ?? (1...count).map { .milliseconds(1000 * $0) })
        return DiscoverCopyRequest(playlistID: albumTestAlbumID, playlistTitle: albumTestAlbum,
                                   rows: shown, selected: selected, kind: .albumContainer)
    }

    /// Makes the fake player hold the request's slice, one entry ID per song.
    func stagePlayer(for request: DiscoverCopyRequest) {
        let slice = Array(request.rows[request.selected...])
        player.ids = slice.indices.map { albumTestHex(101 + $0) }
        var ms: Int?
        if case .milliseconds(let n) = slice[0].length { ms = n }
        player.trackK = DiscoverCopyTrack(title: slice[0].name, artist: slice[0].subtitle ?? "", durationMS: ms)
    }

    /// Phase A then phase B on this thread, with the launch sweep finished.
    @discardableResult
    func play(_ request: DiscoverCopyRequest? = nil, file: StaticString = #filePath,
              line: UInt = #line) -> DiscoverPlayRequestOutcome {
        let request = request ?? self.request()
        if player.ids.isEmpty { stagePlayer(for: request) }
        coordinator.startLaunchSweep()
        guard case .reserved(let reservation) = coordinator.reserveCopyPlay(request) else {
            XCTFail("not reserved", file: file, line: line)
            return .refused(.busy)
        }
        return coordinator.runCopyPlay(reservation, gate: gate.gate)
    }

    func stored() -> [DiscoverCopyEntry] { (try? journal.inner.entries()) ?? [] }
    var entry: DiscoverCopyEntry? { stored().last }

    func refused(_ text: String) -> DiscoverToast { .outcome(.refused(text), title: albumTestAlbum) }

    /// The minted name, from the first transition.
    var name: String? { states.first?.name }

    /// True when `events` appear in `log` in this order (not necessarily adjacent).
    func logHasInOrder(_ events: [String]) -> Bool {
        var rest = events[...]
        for event in log where event == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }
}

final class DiscoverAlbumTransactionTests: XCTestCase {
    private typealias F = A2Fixture

    private func state(_ outcome: DiscoverPlayRequestOutcome, file: StaticString = #filePath,
                       line: UInt = #line) -> DiscoverTransactionState? {
        guard case .completed(let state) = outcome else {
            XCTFail("not completed: \(outcome)", file: file, line: line)
            return nil
        }
        return state
    }

    // MARK: The B-script and its parser

    func testTheBeforeSetScriptAssignsOnlyAllowedNames() {
        let names = appleScriptAssignedNames(discoverAlbumBeforeSetScript)
        XCTAssertEqual(names, ["beforeIDList", "beforeIDText"])
        XCTAssertTrue(names.isSubset(of: discoverAlbumScriptVariables))
        XCTAssertTrue(names.isDisjoint(with: discoverAppleScriptReservedNames))
    }

    func testTheBeforeSetScriptIsTheScoreText() {
        let lines = discoverAlbumBeforeSetScript.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(lines, [
            "set beforeIDList to persistent ID of every track of library playlist 1",
            "set AppleScript's text item delimiters to linefeed",
            "set beforeIDText to beforeIDList as text",
            "set AppleScript's text item delimiters to \"\"",
            "return beforeIDText",
        ])
    }

    func testTheBeforeSetParserReadsEmptyAsNoSongsAndNilAsUnreadable() {
        XCTAssertNil(parseDiscoverAlbumBeforeSet(nil))
        XCTAssertEqual(parseDiscoverAlbumBeforeSet(""), [])
        XCTAssertEqual(parseDiscoverAlbumBeforeSet("\n  \n"), [])
    }

    func testTheBeforeSetParserRefusesAnyMalformedToken() {
        XCTAssertNil(parseDiscoverAlbumBeforeSet("00000000000000AA\n00000000000000ab"))   // lowercase
        XCTAssertNil(parseDiscoverAlbumBeforeSet("00000000000000AA\n0000000000000AB"))    // fifteen
        XCTAssertNil(parseDiscoverAlbumBeforeSet("00000000000000AA 00000000000000AB"))    // two on a line
        XCTAssertNil(parseDiscoverAlbumBeforeSet("missing value"))
    }

    func testTheBeforeSetParserReadsWellFormedLines() {
        XCTAssertEqual(parseDiscoverAlbumBeforeSet(" 00000000000000AA \r\n\n00000000000000AB\n"),
                       ["00000000000000AA", "00000000000000AB"])
    }

    // MARK: S7's recorder

    private func recorderFixture(songs: Int = 3, ids: Int = 3)
        -> (InMemoryDiscoverCopyJournalStore, FakeDiscoverCopyPlayer, DiscoverAlbumEntryRecorder) {
        let journal = InMemoryDiscoverCopyJournalStore(entries: [albumTestEntry(state: .owned, hex: F.containerHex,
                                                                                songCount: songs, songState: .pending)])
        let player = FakeDiscoverCopyPlayer(hex: F.containerHex, ids: (1...ids).map { albumTestHex(200 + $0) },
                                            trackK: DiscoverCopyTrack(title: "Track 1", artist: "Album Artist", durationMS: 1000))
        return (journal, player, DiscoverAlbumEntryRecorder(player: player, journal: journal, txn: albumTestTxn))
    }

    func testTheRecorderWritesEAndEveryEntryHexInOneUpdateBeforeReturning() {
        let (journal, player, recorder) = recorderFixture()
        let read = recorder.read(hex: F.containerHex, k: 1)
        let eventsAtReturn = journal.events
        XCTAssertEqual(read?.ids, player.ids)
        XCTAssertEqual(eventsAtReturn, ["update:\(albumTestTxn)"])
        let entry = journal.stored[0]
        XCTAssertEqual(entry.entryIDs, player.ids)
        XCTAssertEqual(entry.songs?.map(\.entryHex), player.ids.map(Optional.some))
    }

    func testTheRecorderWritesEOnlyWhenItsCountDiffersFromTheSongs() {
        let (journal, player, recorder) = recorderFixture(songs: 3, ids: 4)
        XCTAssertNotNil(recorder.read(hex: F.containerHex, k: 1))
        let entry = journal.stored[0]
        XCTAssertEqual(entry.entryIDs, player.ids)
        XCTAssertEqual(entry.songs?.compactMap(\.entryHex), [])
    }

    func testAFailedRecorderWriteReturnsNil() {
        let (journal, _, recorder) = recorderFixture()
        journal.failWrites = { _ in true }
        XCTAssertNil(recorder.read(hex: F.containerHex, k: 1))
        XCTAssertNil(journal.stored[0].entryIDs)
    }

    func testAFailedReadWritesNothing() {
        let (journal, player, recorder) = recorderFixture()
        player.readFails = true
        XCTAssertNil(recorder.read(hex: F.containerHex, k: 1))
        XCTAssertEqual(journal.events, [])
    }

    func testTheRecorderForwardsEveryOtherCallUnchanged() {
        let (journal, player, recorder) = recorderFixture()
        let hex = F.containerHex
        XCTAssertEqual(recorder.trackCount(hex: hex), 3)
        XCTAssertTrue(recorder.playCopy(hex: hex))
        XCTAssertEqual(recorder.firstPlay(hex: hex, track: player.ids[0]), .landed)
        XCTAssertEqual(recorder.confirm(hex: hex, track: player.ids[0]), .onTrack(positionMS: 0))
        XCTAssertTrue(recorder.pause())
        XCTAssertEqual(recorder.landing(hex: hex, expected: player.ids[0], previous: player.ids[0], settling: true), .landed)
        XCTAssertTrue(recorder.nextTrack())
        XCTAssertTrue(recorder.play())
        XCTAssertTrue(recorder.stopIfCurrent(hex: hex))
        XCTAssertTrue(recorder.stop())
        XCTAssertEqual(player.calls, ["trackCount", "playCopy", "firstPlay:\(player.ids[0])", "confirm:\(player.ids[0])",
                                      "pause", "landing:\(player.ids[0]):\(player.ids[0]):true", "nextTrack", "play",
                                      "stopIfCurrent", "stop"])
        XCTAssertEqual(journal.events, [])
    }

    // MARK: The whole play, on the real journal

    func testAPlayRecordsEverythingTheProofNeedsAndReachesListening() throws {
        let f = F(fileBacked: true)
        let outcome = f.play()
        let ended = try XCTUnwrap(state(outcome))
        let name = try XCTUnwrap(f.name)
        XCTAssertEqual(ended, .listening(name))
        let entry = try XCTUnwrap(f.entry)
        XCTAssertTrue(name.hasPrefix(discoverPlaylistPrefix + entry.txn + discoverPlaylistNameSeparator))
        XCTAssertTrue(name.hasSuffix(albumTestAlbum))
        XCTAssertEqual(entry.kind, .albumContainer)
        XCTAssertEqual(entry.containerName, name)
        XCTAssertEqual(entry.state, .listening)
        XCTAssertTrue(entry.watching)
        XCTAssertEqual(entry.hex, F.containerHex)
        XCTAssertEqual(entry.playlistID, albumTestAlbumID)
        XCTAssertEqual(entry.title, albumTestAlbum)
        XCTAssertEqual(entry.copiesRead, 0)
        XCTAssertNotNil(entry.writeSentAt)
        XCTAssertEqual(entry.entryIDs, f.player.ids)
        XCTAssertEqual(entry.beforeFile, "before-\(entry.txn).json")
        XCTAssertEqual(try f.beforeSet.readBeforeSet(file: entry.beforeFile!), Set(F.beforeIDs))
        let songs = try XCTUnwrap(entry.songs)
        XCTAssertEqual(songs.map(\.position), [1, 2, 3])
        XCTAssertEqual(songs.map(\.catalogueID), (1...3).map(albumTestCatalogueID))
        XCTAssertEqual(songs.map(\.title), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(songs.map(\.artist), ["Album Artist", "Album Artist", "Album Artist"])
        XCTAssertEqual(songs.map(\.durationMS), [1000, 2000, 3000])
        XCTAssertEqual(songs.map(\.relationsBefore), [[0, 0], [0, 0], [0, 0]])
        XCTAssertEqual(songs.map(\.state), [.pending, .pending, .pending])
        XCTAssertEqual(songs.map(\.entryHex), f.player.ids.map(Optional.some))
        XCTAssertEqual(f.library.calls, ["ensure:\(name):" + (1...3).map(albumTestCatalogueID).joined(separator: ",")])
        XCTAssertEqual(f.adoptCalls, ["\(entry.txn):\(F.containerHex)"])
        XCTAssertEqual(f.proofCalls, [entry.txn])
        XCTAssertEqual(f.sequenceTxns, [entry.txn])
        XCTAssertEqual(f.toasts.last, .outcome(.playing(title: discoverAlbumPlayingTail(song: "Track 1")),
                                               title: albumTestAlbum))
        XCTAssertEqual(f.deleteIfOwnedCount, 0)
        XCTAssertEqual(f.player.commands, ["playCopy"])
    }

    func testTheSliceStartsAtTheCursorAndTheSequencerPlaysItsFirstTrack() throws {
        let f = F()
        let request = f.request(count: 4, selected: 2)
        f.play(request)
        let entry = try XCTUnwrap(f.entry)
        XCTAssertEqual(entry.songs?.map(\.catalogueID), [albumTestCatalogueID(3), albumTestCatalogueID(4)])
        XCTAssertEqual(entry.songs?.map(\.position), [1, 2])
        XCTAssertEqual(f.relationsFake.calls, [[albumTestCatalogueID(3), albumTestCatalogueID(4)],
                                               [albumTestCatalogueID(3), albumTestCatalogueID(4)]])
        XCTAssertTrue(f.player.calls.contains("read:1"))
        XCTAssertEqual(f.toasts.last, .outcome(.playing(title: discoverAlbumPlayingTail(song: "Track 3")),
                                               title: albumTestAlbum))
    }

    // MARK: Design test 4: the order of the writes and the send

    func testTheIntentR2AndTheSendRecordComeBeforeTheEnsure() {
        let f = F()
        f.play()
        XCTAssertTrue(f.logHasInOrder(["relations", "B", "insert", "relations", "update(sent)", "ensure"]), "\(f.log)")
        // Nothing is written between R2 and the send record.
        let r2 = f.log.lastIndex(of: "relations")!
        XCTAssertEqual(f.log[r2 + 1], "update(sent)")
        XCTAssertEqual(f.log[r2 + 2], "ensure")
        XCTAssertEqual((f.memory!.events.filter { $0.hasPrefix("insert") }).count, 1)
    }

    func testAFailedInsertSendsNoEnsure() throws {
        let f = F()
        f.memory!.failWrites = { $0.hasPrefix("insert:") }
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.relationsFake.calls.count, 1)
        XCTAssertTrue(f.stored().isEmpty)
        let file = "before-\(f.sequenceTxnsOrMintTxn).json"
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).calls.last, "delete:\(file)")
        XCTAssertEqual(f.toasts.last, f.refused(discoverJournalUnwritableText(playlist: albumTestAlbum)))
    }

    func testAFailedSendRecordSendsNoEnsureAndClosesTheEntry() throws {
        let f = F()
        f.memory!.failWrites = { label in label.hasPrefix("update:") && label.hasSuffix(":intent") }
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertEqual(f.library.calls, [])
        let entry = try XCTUnwrap(f.entry)
        XCTAssertEqual(entry.state, .closed)
        XCTAssertNil(entry.writeSentAt)
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).files, [:])
        XCTAssertEqual(f.toasts.last, f.refused(discoverJournalUnwritableText(playlist: albumTestAlbum)))
    }

    // MARK: Design test 5: a song already his

    func testR2AtOneMakesThatSongPreexistingAndThePlayGoesOn() throws {
        let f = F()
        let ids = (1...3).map(albumTestCatalogueID)
        let none = Dictionary(uniqueKeysWithValues: ids.map { ($0, [String?]()) })
        var r2 = none
        r2[ids[1]] = ["777"]
        f.relationsFake.results = [.success(none), .success(r2)]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .listening(f.name!))
        let songs = try XCTUnwrap(f.entry?.songs)
        XCTAssertEqual(songs.map(\.state), [.pending, .preexisting, .pending])
        XCTAssertEqual(songs.map(\.relationsBefore), [[0, 0], [0, 1], [0, 0]])
        XCTAssertEqual(f.toasts.last, .outcome(.playing(title: discoverAlbumPlayingTail(song: "Track 1")),
                                               title: albumTestAlbum))
    }

    func testR1AtOneWithAnUnresolvedAliasStillCountsAsHis() throws {
        let f = F()
        let ids = (1...3).map(albumTestCatalogueID)
        var r1 = Dictionary(uniqueKeysWithValues: ids.map { ($0, [String?]()) })
        r1[ids[0]] = [nil]
        f.relationsFake.results = [.success(r1)]   // R2 is answered the same
        f.play()
        let songs = try XCTUnwrap(f.entry?.songs)
        XCTAssertEqual(songs.map(\.state), [.preexisting, .pending, .pending])
        XCTAssertEqual(songs[0].relationsBefore, [1, 1])
    }

    func testWhenEverySongIsHisThePlayLineIsOnlyTheSong() throws {
        let f = F()
        let ids = (1...3).map(albumTestCatalogueID)
        f.relationsFake.results = [.success(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["1"] as [String?]) }))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .listening(f.name!))
        XCTAssertEqual(f.entry?.songs?.map(\.state), [.preexisting, .preexisting, .preexisting])
        XCTAssertEqual(f.toasts.last, .outcome(.playing(title: discoverAlbumPlayingOwnedTail(song: "Track 1")),
                                               title: albumTestAlbum))
    }

    // MARK: Design test 6: the ensure's uncertain answers

    func testAnUnknownEnsureOutcomeIsUncertainProtectedAndTold() throws {
        let f = F()
        f.library.ensureResults = [.failure(SpanDACLibraryOpError.outcomeUnknown("lost"))]
        let ended = try XCTUnwrap(state(f.play()))
        let name = try XCTUnwrap(f.name)
        XCTAssertEqual(ended, .unknownOutcome(name))
        XCTAssertTrue(f.coordinator.protectedNames.contains(name))
        let entry = try XCTUnwrap(f.entry)
        XCTAssertEqual(entry.state, .uncertain)
        XCTAssertEqual(entry.uncertainReason, "outcome_unknown")
        XCTAssertNotNil(entry.writeSentAt)
        XCTAssertEqual(entry.songs?.map(\.state), [.pending, .pending, .pending])
        XCTAssertNotNil((f.beforeSet as! InMemoryBeforeSetStore).files[entry.beforeFile!])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumMaybeAddedText(album: albumTestAlbum)))
        XCTAssertEqual(f.sequenceTxns, [])
        XCTAssertEqual(f.proofCalls, [])
    }

    func testAnEnsureThatMadeNothingLeavesEverySongUncertainAndTold() throws {
        let f = F()
        let ids = (1...3).map(albumTestCatalogueID)
        var r = Dictionary(uniqueKeysWithValues: ids.map { ($0, [String?]()) })
        r[ids[2]] = ["5"]
        f.relationsFake.results = [.success(r)]
        f.library.ensureResults = [.success((created: false, id: "p.other", alias: "99"))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        let entry = try XCTUnwrap(f.entry)
        XCTAssertEqual(entry.state, .uncertain)
        XCTAssertEqual(entry.uncertainReason, "not_created")
        XCTAssertEqual(entry.songs?.map(\.state), [.uncertain, .uncertain, .preexisting])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumNotOursText(album: albumTestAlbum)))
        XCTAssertEqual(f.sequenceTxns, [])
    }

    func testAConfirmedEnsureFailureClosesTheEntryAndDeletesTheSideFile() throws {
        let f = F()
        f.library.ensureResults = [.failure(SpanDACLibraryOpError.failed("Apple said no."))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertEqual(f.entry?.state, .closed)
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).files, [:])
        XCTAssertEqual(f.toasts.last, .outcome(.createFailed("Apple said no."), title: albumTestAlbum))
    }

    // MARK: Design test 7: no alias in time

    func testNoAliasWithinTheWaitRefusesAndLeavesTheIntentForReconcile() throws {
        let f = F()
        f.library.ensureResults = [.success((created: true, id: "p.album", alias: nil)),
                                   .success((created: false, id: "p.album", alias: nil))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .identity))
        let entry = try XCTUnwrap(f.entry)
        XCTAssertEqual(entry.state, .intent)
        XCTAssertNil(entry.hex)
        XCTAssertNotNil(entry.writeSentAt)
        XCTAssertEqual(f.deleteIfOwnedCount, 0)
        XCTAssertEqual(f.sequenceTxns, [])
        XCTAssertGreaterThan(f.library.calls.count, 1)   // the alias wait re-sent the same ensure
        XCTAssertEqual(Set(f.library.calls).count, 1)
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumNoIDText(album: albumTestAlbum)))
    }

    func testAnAliasThatArrivesDuringTheWaitPlays() throws {
        let f = F()
        f.library.ensureResults = [.success((created: true, id: "p.album", alias: nil)),
                                   .success((created: false, id: "p.album", alias: nil)),
                                   .success((created: false, id: "p.album", alias: F.containerAlias))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .listening(f.name!))
        XCTAssertEqual(f.library.calls.count, 3)
    }

    // MARK: Design test 8: E before the next player call; a failed record

    func testEAndEveryEntryHexAreOnDiskBeforeTheNextPlayerCall() throws {
        let f = F(fileBacked: true)
        let request = f.request()
        f.stagePlayer(for: request)
        var atNext: DiscoverCopyEntry?
        var sawRead = false
        f.player.onCall = { name in
            if name == "read:1" { sawRead = true; return }
            if sawRead && atNext == nil { atNext = f.entry }
        }
        f.play(request)
        let entry = try XCTUnwrap(atNext)
        XCTAssertEqual(f.player.calls[f.player.calls.firstIndex(of: "read:1")! + 1], "playCopy")
        XCTAssertEqual(entry.entryIDs, f.player.ids)
        XCTAssertEqual(entry.songs?.map(\.entryHex), f.player.ids.map(Optional.some))
    }

    func testAFailedRecordIsUnconfirmedDeletesOnceAndStillStartsTheProof() throws {
        let f = F()
        var failNext = false
        f.player.onCall = { name in if name == "read:1" { failNext = true } }
        f.memory!.failWrites = { label in
            guard failNext, label.hasPrefix("update:") else { return false }
            failNext = false
            return true
        }
        let ended = try XCTUnwrap(state(f.play()))
        let name = try XCTUnwrap(f.name)
        XCTAssertEqual(ended, .failedBeforePlay(name, .identity))
        XCTAssertEqual(f.deleteIfOwnedCount, 1)
        XCTAssertEqual(f.proofCalls.count, 1)
        XCTAssertFalse(f.player.calls.contains("playCopy"))
        XCTAssertNil(f.entry?.entryIDs)
        XCTAssertEqual(f.entry?.listeningEnded, true)
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumRefusalText(.unconfirmed(title: "Track 1"),
                                                                         album: albumTestAlbum)!))
        XCTAssertTrue(f.logHasInOrder(["deleteIfOwned", "startProof"]))
    }

    func testASequencerRefusalStillStartsTheProofAndRecordsTheEnd() throws {
        let f = F()
        f.player.trackCounts = [0]   // the container never loads
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .readiness))
        XCTAssertEqual(f.proofCalls.count, 1)
        XCTAssertEqual(f.deleteIfOwnedCount, 1)
        XCTAssertEqual(f.entry?.state, .owned)
        XCTAssertEqual(f.entry?.listeningEnded, true)
        XCTAssertEqual(f.toasts.last, f.refused(discoverCopyRefusalText(.notReady, playlist: albumTestAlbum)!))
    }

    // MARK: Design test 9 (last row): B, and the other S1 reads

    func testNoBeforeSetRefusesWithNoJournalEntryAndNoEnsure() throws {
        let f = F()
        f.beforeResult = nil
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumBeforeSetText(album: albumTestAlbum)))
    }

    func testABeforeSetReadPastItsBoundRefusesWithNoJournalEntryAndNoEnsure() throws {
        let f = F()
        f.beforeTakes = DiscoverAlbumTiming.beforeSetBound + 0.5
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumBeforeSetText(album: albumTestAlbum)))
    }

    func testABeforeSetReadWithinItsBoundPlays() throws {
        let f = F()
        f.beforeTakes = DiscoverAlbumTiming.beforeSetBound
        XCTAssertEqual(try XCTUnwrap(state(f.play())), .listening(f.name!))
    }

    func testAnUnreadableR1RefusesBeforeBAndWritesNothing() throws {
        let f = F()
        f.relationsFake.results = [.failure(SpanDACLibraryOpError.failed("no"))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertFalse(f.log.contains("B"))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumRelationsUnreadableText(album: albumTestAlbum)))
    }

    func testAnR1ThatLeavesASongOutIsUnreadable() throws {
        let f = F()
        f.relationsFake.results = [.success([albumTestCatalogueID(1): []])]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumRelationsUnreadableText(album: albumTestAlbum)))
    }

    func testAnUnwritableSideFileRefusesWithNoJournalEntry() throws {
        let f = F()
        (f.beforeSet as! InMemoryBeforeSetStore).failWrites = true
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(discoverJournalUnwritableText(playlist: albumTestAlbum)))
    }

    func testAnUnreadableR2ClosesTheEntryDeletesTheSideFileAndSendsNothing() throws {
        let f = F()
        let ids = (1...3).map(albumTestCatalogueID)
        f.relationsFake.results = [.success(Dictionary(uniqueKeysWithValues: ids.map { ($0, [String?]()) })),
                                   .failure(SpanDACLibraryOpError.failed("no"))]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .create))
        XCTAssertEqual(f.entry?.state, .closed)
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).files, [:])
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(discoverAlbumRelationsUnreadableText(album: albumTestAlbum)))
    }

    // MARK: G-a's gate

    func testAMovedGateAtTheIntentWritesNothingAndDeletesTheSideFile() throws {
        let f = F()
        f.gate.scripted = [1: .sourceChanged]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .selectionChanged))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertEqual((f.beforeSet as! InMemoryBeforeSetStore).files, [:])
        XCTAssertEqual(f.library.calls, [])
        XCTAssertEqual(f.toasts.last, f.refused(sourceChangedNothingPlayed))
    }

    func testASupersededGateAtTheIntentSaysNothing() throws {
        let f = F()
        f.gate.scripted = [1: .superseded]
        let ended = try XCTUnwrap(state(f.play()))
        XCTAssertEqual(ended, .failedBeforePlay(f.name!, .superseded))
        XCTAssertTrue(f.stored().isEmpty)
        XCTAssertFalse(f.toasts.contains { if case .outcome = $0 { return true } else { return false } })
    }
}

extension A2Fixture {
    /// The txn of the play: the UUID inside the minted name.
    var sequenceTxnsOrMintTxn: String {
        guard let name else { return "" }
        let afterPrefix = name.dropFirst(discoverPlaylistPrefix.count)
        return String(afterPrefix.prefix(36))
    }
}

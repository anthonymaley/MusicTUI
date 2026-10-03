import Darwin
import XCTest
@testable import music

/// Album-cleanup journal format 2, the before-set side file, and the three
/// seams in shipped files (score step A0, design tests 17 and 18). Always a
/// temporary directory: never `~/.config/music`. Scripts go to recording fakes.
final class DiscoverAlbumJournalTests: XCTestCase {

    private var root: URL!
    private var paths: DiscoverCopyPaths!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfh-a0-journal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DiscoverCopyPaths(directory: root.appendingPathComponent("discover-copies"))
    }

    override func tearDown() {
        chmod(paths.directory.path, 0o700)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func store() -> FileDiscoverCopyJournalStore { FileDiscoverCopyJournalStore(paths: paths) }

    private func copyEntry(_ txn: String, _ state: DiscoverCopyState, hex: String? = nil) -> DiscoverCopyEntry {
        DiscoverCopyEntry(txn: txn, playlistID: "pl.x", title: "Mix", state: state, hex: hex,
                          copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                          priorShuffle: nil, priorRepeat: nil, createdAt: 10, updatedAt: 10)
    }

    private func formatOnDisk() throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.journal)) as? [String: Any]
        return object?["format"] as? Int
    }

    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: paths.journal)
    }

    private func assertThrows(_ expected: DiscoverCopyJournalError, file: StaticString = #filePath,
                              line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? DiscoverCopyJournalError, expected, file: file, line: line)
        }
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    // MARK: Design test 17: formats

    func testTheReadFormatIsTwo() {
        XCTAssertEqual(discoverCopyJournalFormat, 2)
    }

    func testAFormatOneFileReadsAndItsCopyEntriesAreUnchanged() throws {
        // A format-1 file exactly as the shipped build writes it.
        try writeRaw("""
        {"entries":[{"copies_read":1,"copy_seen":false,"created_at":10,"hex":"00000000000000AB",\
        "playlist_id":"pl.x","prior_repeat":"all","prior_shuffle":true,"state":"listening",\
        "title":"Mix","told_at_launch":false,"txn":"A","updated_at":11,"watching":true}],"format":1}
        """)
        let entries = try store().entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .listening)
        XCTAssertEqual(entry.hex, "00000000000000AB")
        XCTAssertEqual(entry.priorShuffle, true)
        XCTAssertNil(entry.kind)
        XCTAssertNil(entry.songs)

        // Writing it back keeps format 1 and adds none of the new keys.
        try store().update(txn: "A") { $0.watching = false }
        XCTAssertEqual(try formatOnDisk(), 1)
        let text = try String(contentsOf: paths.journal, encoding: .utf8)
        for key in ["kind", "songs", "container_name", "before_file", "entry_ids"] {
            XCTAssertFalse(text.contains("\"\(key)\""), key)
        }
    }

    func testAHigherFormatIsTooNewAndTheReconcilerReplaysNothing() throws {
        let bodies = ["{\"entries\":[],\"format\":3}", "{\"entries\":[{\"surprise\":true}],\"format\":3}"]
        for text in bodies {
            try writeRaw(text)
            assertThrows(.tooNew) { _ = try self.store().entries() }
            assertThrows(.tooNew) { try self.store().insert(self.copyEntry("B", .intent)) }
        }

        let f = DFHC2Fixture()
        try FileManager.default.createDirectory(at: f.paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = Data("{\"entries\":[],\"format\":3}".utf8)
        try bytes.write(to: f.paths.journal)
        var replayed: [String] = []
        let reconciler = DiscoverCopyReconciler(copy: f.copySeams, post: f.post,
                                                albumReplay: { entry, _ in replayed.append(entry.txn) })
        reconciler.run(atLaunch: true)
        reconciler.run(atLaunch: false)
        XCTAssertEqual(replayed, [])
        XCTAssertEqual(f.toasts, [])
        XCTAssertEqual(f.ops.calls, [])
        XCTAssertEqual(f.deleteCalls, [])
        XCTAssertEqual(f.restoreCalls, [])
        XCTAssertEqual(try Data(contentsOf: f.paths.journal), bytes)
    }

    func testCopyOnlyIsWrittenAsFormatOneAndAnAlbumEntryMakesItFormatTwo() throws {
        let journal = store()
        try journal.insert(copyEntry("A", .intent))
        XCTAssertEqual(try formatOnDisk(), 1)

        try journal.insert(albumTestEntry())
        XCTAssertEqual(try formatOnDisk(), 2)
        XCTAssertEqual(try store().entries().map(\.txn), ["A", albumTestTxn])
        XCTAssertEqual(try store().entries()[1], albumTestEntry())

        // A format-2 file reads, and stays format 2 on the next write.
        try journal.update(txn: "A") { $0.state = .closed }
        XCTAssertEqual(try formatOnDisk(), 2)

        XCTAssertEqual(discoverCopyJournalWriteFormat([]), 1)
        XCTAssertEqual(discoverCopyJournalWriteFormat([copyEntry("A", .intent)]), 1)
        var explicitCopy = copyEntry("B", .intent)
        explicitCopy.kind = .playlistCopy
        XCTAssertEqual(discoverCopyJournalWriteFormat([explicitCopy]), 1)
        XCTAssertEqual(discoverCopyJournalWriteFormat([copyEntry("A", .intent), albumTestEntry()]), 2)
    }

    func testOnceTheAlbumEntryIsPrunedTheFileGoesBackToFormatOne() throws {
        let journal = store()
        try journal.insert(albumTestEntry(state: .closed, songs: [albumTestSong(1, state: .deleted)]))
        XCTAssertEqual(try formatOnDisk(), 2)
        for n in 1...20 { try journal.insert(copyEntry("c\(n)", .closed)) }
        XCTAssertFalse(try journal.entries().contains(where: { $0.kind == .albumContainer }))
        XCTAssertEqual(try formatOnDisk(), 1)
    }

    // MARK: Design test 17: invariants on insert, update and read

    /// Each one breaks exactly one new invariant.
    private func brokenEntries() -> [(String, DiscoverCopyEntry)] {
        var cases: [(String, DiscoverCopyEntry)] = []
        func album(_ label: String, _ change: (inout DiscoverCopyEntry) -> Void) {
            var entry = albumTestEntry()
            change(&entry)
            cases.append((label, entry))
        }
        album("no songs") { $0.songs = nil }
        album("empty songs") { $0.songs = [] }
        album("positions skip") { $0.songs = [albumTestSong(1), albumTestSong(3)] }
        album("positions out of order") { $0.songs = [albumTestSong(2), albumTestSong(1)] }
        album("positions from zero") { $0.songs = [albumTestSong(0), albumTestSong(1)] }
        album("no container name") { $0.containerName = nil }
        album("container name without the prefix") { $0.containerName = "Test Album" }
        album("no before file") { $0.beforeFile = nil }
        album("owned song without entry hex") { $0.songs = [albumTestSong(1, state: .owned, entryHex: nil, alias: "1")]
            $0.songs![0].entryHex = nil }
        album("owned song with malformed hex") { $0.songs = [albumTestSong(1, state: .owned, entryHex: "0000000000000001".lowercased() + "x")] }
        album("owned song without alias") { $0.songs = [albumTestSong(1, state: .owned)]
            $0.songs![0].alias = nil }
        album("owned song whose alias is another identity") { $0.songs = [albumTestSong(1, state: .owned, alias: "2")] }
        album("owned song whose alias is not an alias") { $0.songs = [albumTestSong(1, state: .owned, alias: "x1")] }
        album("deleted song without entry hex") { $0.songs = [albumTestSong(1, state: .deleted)]
            $0.songs![0].entryHex = nil }
        album("deleted song with malformed hex") { $0.songs = [albumTestSong(1, state: .deleted, entryHex: "00000000000000ab")] }
        album("album owned entry without hex (shipped rule)") { $0.state = .owned }
        album("album intent entry with a hex (shipped rule)") { $0.hex = "0000000000000001" }

        func copy(_ label: String, kind: DiscoverPlayKind?, _ change: (inout DiscoverCopyEntry) -> Void) {
            var entry = copyEntry(albumTestTxn, .intent)
            entry.kind = kind
            change(&entry)
            cases.append((label, entry))
        }
        for kind: DiscoverPlayKind? in [nil, .playlistCopy] {
            copy("copy with songs (\(String(describing: kind)))", kind: kind) { $0.songs = [albumTestSong(1)] }
            copy("copy with container name (\(String(describing: kind)))", kind: kind) {
                $0.containerName = discoverPlaylistPrefix + "x"
            }
            copy("copy with entry ids (\(String(describing: kind)))", kind: kind) { $0.entryIDs = [] }
        }
        return cases
    }

    func testEachNewInvariantIsEnforcedOnInsert() throws {
        let journal = store()
        try journal.insert(copyEntry("seed", .intent))
        let before = try Data(contentsOf: paths.journal)
        for (label, bad) in brokenEntries() {
            XCTAssertFalse(discoverCopyEntryHoldsInvariants(bad), label)
            XCTAssertThrowsError(try journal.insert(bad), label) { error in
                XCTAssertEqual(error as? DiscoverCopyJournalError, .writeFailed("invariant"), label)
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
    }

    func testEachNewInvariantIsEnforcedOnUpdate() throws {
        let journal = store()
        try journal.insert(albumTestEntry())
        let before = try Data(contentsOf: paths.journal)
        for (label, bad) in brokenEntries() {
            XCTAssertThrowsError(try journal.update(txn: albumTestTxn) { $0 = bad }, label) { error in
                XCTAssertEqual(error as? DiscoverCopyJournalError, .writeFailed("invariant"), label)
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
    }

    func testAFileHoldingAnEntryThatBreaksANewInvariantIsUnreadable() throws {
        struct Body: Encodable { let format: Int; let entries: [DiscoverCopyEntry] }
        for (label, bad) in brokenEntries() {
            for format in [1, 2] {
                let bytes = try JSONEncoder().encode(Body(format: format, entries: [bad]))
                try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try bytes.write(to: paths.journal)
                XCTAssertThrowsError(try store().entries(), label) { error in
                    XCTAssertEqual(error as? DiscoverCopyJournalError, .unreadable, label)
                }
                XCTAssertThrowsError(try store().insert(copyEntry("B", .intent)), label)
                XCTAssertEqual(try Data(contentsOf: paths.journal), bytes, label)
            }
        }
    }

    func testValidAlbumSongsInEveryStateAreAccepted() throws {
        let songs: [DiscoverAlbumSong] = [
            albumTestSong(1, state: .intent),
            albumTestSong(2, state: .pending),
            albumTestSong(3, state: .owned),
            albumTestSong(4, state: .preexisting),
            albumTestSong(5, state: .uncertain),
            albumTestSong(6, state: .deleted),
            albumTestSong(7, state: .kept, keptReason: "loved"),
            // A negative alias is the same identity as its unsigned hex.
            albumTestSong(8, state: .owned, entryHex: "FFFFFFFFFFFFFFFF", alias: "-1"),
        ]
        let entry = albumTestEntry(state: .listening, hex: "0000000000001234", songs: songs, watching: true)
        try store().insert(entry)
        XCTAssertEqual(try store().entries(), [entry])
    }

    func testAnAlbumEntryWithANonTerminalSongIsNeverPruned() throws {
        let album = albumTestEntry(state: .listening, hex: "0000000000001234",
                                   songs: [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)])
        let journal = store()
        try journal.insert(album)
        for n in 1...30 { try journal.insert(copyEntry("c\(n)", .closed)) }
        let kept = try journal.entries()
        XCTAssertEqual(kept.first, album)
        XCTAssertEqual(kept.filter { $0.state == .closed }.count, discoverCopyJournalClosedKept)
        XCTAssertEqual(discoverCopyJournalPruned([album] + (1...30).map { copyEntry("c\($0)", .closed) }).first, album)
    }

    // MARK: Design test 18: the mode guard holds on the album container

    func testAnAlbumEntrysHexIsOneOfOurCopiesAndTheRestoreHoldsOnIt() {
        let hex = "00000000C0FFEE00"
        let entries = [copyEntry("A", .closed), albumTestEntry(state: .listening, hex: hex, watching: true)]
        let ours = discoverOurCopies(entries)
        XCTAssertEqual(ours, .known([hex]))

        let request = DiscoverModeRestoreRequest(shuffle: true, songRepeat: .all, ours: ours, unlessHeChanged: true)
        XCTAssertTrue(discoverModeRestoreScript(request).contains("\"\(hex)\""))
        let playing = DiscoverCopyPlayerRead(state: "playing", playlistID: hex, trackID: "0000000000000001")
        let answer = dfhModeRestoreContract(request, modes: (shuffle: false, songRepeat: .off), player: playing) { _, _ in
            XCTFail("nothing may be set while the album container plays")
            return nil
        }
        XCTAssertEqual(answer, .held(current: hex))
    }

    // MARK: The before-set side file (K5, CH25)

    func testTheBeforeSetRoundTripsAndIsOnTheDiskPrivatelyBeforeItReturns() throws {
        let ids = ["0000000000000001", "00000000000000AB", "FFFFFFFFFFFFFFFF"]
        let file = try store().writeBeforeSet(txn: albumTestTxn, ids: ids)
        XCTAssertEqual(file, "before-\(albumTestTxn).json")

        let url = paths.directory.appendingPathComponent(file)
        XCTAssertEqual(mode(paths.directory), 0o700)
        XCTAssertEqual(mode(url), 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["format"] as? Int, 1)
        XCTAssertEqual(object["txn"] as? String, albumTestTxn)
        XCTAssertEqual(object["ids"] as? [String], ids)

        // A second store on the same paths reads it.
        XCTAssertEqual(try store().readBeforeSet(file: file), Set(ids))
        // The journal itself is untouched by it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.journal.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.directory.path)
        XCTAssertEqual(leftovers.sorted(), [file, "lock"])
    }

    func testAnEmptyBeforeSetRoundTrips() throws {
        let file = try store().writeBeforeSet(txn: albumTestTxn, ids: [])
        XCTAssertEqual(try store().readBeforeSet(file: file), [])
    }

    func testAMisnamedFileIsUnreadableAndNeverOpened() throws {
        // A real file at a path outside the pattern must still be refused.
        _ = try store().writeBeforeSet(txn: albumTestTxn, ids: ["0000000000000001"])
        let names = [
            "journal.json",
            "lock",
            "before-\(albumTestTxn.lowercased()).json",
            "before-\(albumTestTxn)",
            "before-\(albumTestTxn).json.tmp",
            "../discover-copies/before-\(albumTestTxn).json",
            "/before-\(albumTestTxn).json",
            "before-x.json",
            "",
        ]
        for name in names {
            assertThrows(.unreadable) { _ = try self.store().readBeforeSet(file: name) }
        }
    }

    func testAMissingWrongTxnMalformedIdOrOtherFormatIsUnreadable() throws {
        let other = "B1B2C3D4-0000-4000-8000-00000000B1B0"
        let file = "before-\(albumTestTxn).json"
        assertThrows(.unreadable) { _ = try self.store().readBeforeSet(file: file) }   // missing

        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = paths.directory.appendingPathComponent(file)
        let bodies = [
            "{\"format\":1,\"ids\":[\"0000000000000001\"],\"txn\":\"\(other)\"}",            // wrong txn
            "{\"format\":1,\"ids\":[\"000000000000000a\"],\"txn\":\"\(albumTestTxn)\"}",     // lowercase
            "{\"format\":1,\"ids\":[\"000000000000001\"],\"txn\":\"\(albumTestTxn)\"}",      // fifteen
            "{\"format\":1,\"ids\":[1],\"txn\":\"\(albumTestTxn)\"}",                        // not a string
            "{\"format\":2,\"ids\":[],\"txn\":\"\(albumTestTxn)\"}",                         // other format
            "{\"ids\":[],\"txn\":\"\(albumTestTxn)\"}",                                      // no format
            "not json",
            "",
        ]
        for body in bodies {
            try Data(body.utf8).write(to: url)
            assertThrows(.unreadable) { _ = try self.store().readBeforeSet(file: file) }
        }
    }

    func testABadTxnOrIdWritesNothing() throws {
        assertThrows(.writeFailed("before-set name")) {
            _ = try self.store().writeBeforeSet(txn: "../x", ids: [])
        }
        assertThrows(.writeFailed("before-set name")) {
            _ = try self.store().writeBeforeSet(txn: albumTestTxn.lowercased(), ids: [])
        }
        assertThrows(.writeFailed("before-set id")) {
            _ = try self.store().writeBeforeSet(txn: albumTestTxn, ids: ["0000000000000001", "nope"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testTheWriteTakesTheJournalsLock() throws {
        try store().insert(copyEntry("A", .intent))
        guard case .success(let held) = PlaySyncLock.acquire(paths.lock, waitingUpTo: 0) else {
            return XCTFail("could not take the lock")
        }
        assertThrows(.busy) { _ = try self.store().writeBeforeSet(txn: albumTestTxn, ids: []) }
        held.release()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.directory.appendingPathComponent("before-\(albumTestTxn).json").path))
    }

    func testDeleteRemovesTheFileAndNeverTouchesAMisnamedOne() throws {
        let file = try store().writeBeforeSet(txn: albumTestTxn, ids: [])
        store().deleteBeforeSet(file: "journal.json")
        store().deleteBeforeSet(file: "lock")
        try store().insert(copyEntry("A", .intent))
        store().deleteBeforeSet(file: "journal.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.journal.path))
        store().deleteBeforeSet(file: file)
        assertThrows(.unreadable) { _ = try self.store().readBeforeSet(file: file) }
        store().deleteBeforeSet(file: file)   // a second delete is harmless
    }

    // MARK: CH6: the deleter's close is kind-aware

    private final class Runner {
        var answer: String?
        private(set) var scripts: [String] = []
        init(_ answer: String?) { self.answer = answer }
        var run: ScriptRunner { { [self] script in scripts.append(script); return answer } }
    }

    private let containerHex = "00112233AABBCCDD"

    func testGoneOrDeletedOnAnAlbumEntryRecordsTheContainerGoneAndLeavesTheState() throws {
        for (answer, expected) in [("gone", DiscoverCopyDeleteResult.alreadyGone), ("deleted", .deleted)] {
            for state: DiscoverCopyState in [.owned, .listening] {
                let entry = albumTestEntry(state: state, hex: containerHex,
                                           songs: [albumTestSong(1, state: .owned), albumTestSong(2, state: .pending)],
                                           watching: true)
                let journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
                let runner = Runner(answer)
                let result = DiscoverCopyDeleter(journal: journal, run: runner.run).end(txn: albumTestTxn)
                XCTAssertEqual(result, expected, answer)
                XCTAssertEqual(runner.scripts, [discoverCopyEndScript(hex: containerHex, delete: true)])
                let after = try XCTUnwrap(journal.stored.first)
                XCTAssertEqual(after.state, state, "\(answer): the state is left alone")
                XCTAssertEqual(after.containerGone, true, answer)
                XCTAssertEqual(after.watching, false, answer)
                XCTAssertEqual(after.songs, entry.songs, answer)
                XCTAssertTrue(discoverCopyEntryHoldsInvariants(after))
            }
        }
    }

    func testGoneOrDeletedOnACopyEntryClosesItAsShipped() throws {
        for answer in ["gone", "deleted"] {
            var entry = copyEntry("C", .listening, hex: containerHex)
            entry.watching = true
            let journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
            _ = DiscoverCopyDeleter(journal: journal, run: Runner(answer).run).end(txn: "C")
            let after = try XCTUnwrap(journal.stored.first)
            XCTAssertEqual(after.state, .closed, answer)
            XCTAssertEqual(after.watching, false, answer)
            XCTAssertNil(after.containerGone, answer)
        }
    }

    func testTheOtherAnswersOnAnAlbumEntryChangeNothing() throws {
        for answer: String? in ["spared", "still", nil, "huh"] {
            let entry = albumTestEntry(state: .listening, hex: containerHex, watching: true)
            let journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
            _ = DiscoverCopyDeleter(journal: journal, run: Runner(answer).run).end(txn: albumTestTxn)
            XCTAssertEqual(journal.stored, [entry], String(describing: answer))
        }
    }

    // MARK: discoverCopyHandleEnd returns what it acted on

    func testHandleEndReturnsEachResult() {
        let cases: [(DiscoverCopyState, String?, DiscoverCopyDeleteResult)] = [
            (.listening, "deleted", .deleted),
            (.listening, "gone", .alreadyGone),
            (.listening, "spared", .spared),
            (.preexisting, "kept", .kept),
            (.listening, nil, .failed),
            (.listening, "still", .failed),
        ]
        for (state, answer, expected) in cases {
            var entry = copyEntry("H", state, hex: containerHex)
            entry.watching = true
            let journal = InMemoryDiscoverCopyJournalStore(entries: [entry])
            var restored: [String] = []
            var readopted: [String] = []
            let result = discoverCopyHandleEnd(txn: "H", deleter: DiscoverCopyDeleter(journal: journal, run: Runner(answer).run),
                                               journal: journal, restoreModes: { restored.append($0) },
                                               readopt: { txn, hex in readopted.append("\(txn):\(hex)") })
            XCTAssertEqual(result, expected, String(describing: answer))
            XCTAssertEqual(restored, ["H"])
            XCTAssertEqual(readopted, expected == .spared ? ["H:\(containerHex)"] : [])
        }
        // An unknown txn is `.kept` with no script.
        let journal = InMemoryDiscoverCopyJournalStore()
        let runner = Runner("deleted")
        XCTAssertEqual(discoverCopyHandleEnd(txn: "nobody", deleter: DiscoverCopyDeleter(journal: journal, run: runner.run),
                                             journal: journal, restoreModes: { _ in }, readopt: { _, _ in }), .kept)
        XCTAssertEqual(runner.scripts, [])
    }

    // MARK: Reconcile dispatch

    private typealias F = DFHC2Fixture

    func testAnAlbumEntryReachesAlbumReplayAndNeverTheCopyReplay() throws {
        let f = F()
        let album = albumTestEntry(state: .intent, priorShuffle: true)
        let copy = F.entry("copy", .intent)
        try f.journal.insert(album)
        try f.journal.insert(copy)
        f.ops.copiesResults = [.success([])]

        for atLaunch in [true, false] {
            var replayed: [(String, Bool)] = []
            let reconciler = DiscoverCopyReconciler(copy: f.copySeams, post: f.post,
                                                    albumReplay: { entry, launch in replayed.append((entry.txn, launch)) })
            reconciler.run(atLaunch: atLaunch)
            XCTAssertEqual(replayed.map(\.0), [albumTestTxn])
            XCTAssertEqual(replayed.map(\.1), [atLaunch])
        }
        // Only the copy entry asked SpanDAC, with its own playlist id.
        XCTAssertEqual(f.ops.calls, ["copies:\(F.playlistID)"])
        XCTAssertFalse(f.ops.calls.contains { $0.contains(albumTestAlbumID) })
        XCTAssertEqual(f.deleteCalls, [])
        // The mode-restore line runs for the album entry as for any other.
        XCTAssertEqual(f.restoreCalls, [albumTestTxn, albumTestTxn])
        let onDisk = try f.onDisk()
        XCTAssertEqual(onDisk.first, album, "the album entry is the album replay's to change")
        XCTAssertEqual(onDisk.last?.state, .closed, "the copy intent with no copy closes as shipped")
    }

    func testWithNoAlbumReplayAnAlbumEntryIsUntouched() throws {
        for state: DiscoverCopyState in [.intent, .owned, .listening, .uncertain, .preexisting] {
            let f = F()
            let hex: String? = state == .intent ? nil : containerHex
            let album = albumTestEntry(state: state, hex: hex, watching: state == .listening)
            try f.journal.insert(album)
            f.deleteResult = { _ in .deleted }
            let before = try f.onDisk()
            DiscoverCopyReconciler(copy: f.copySeams, post: f.post).run(atLaunch: true)
            DiscoverCopyReconciler(copy: f.copySeams, post: f.post).run(atLaunch: false)
            XCTAssertEqual(try f.onDisk(), before, "\(state)")
            XCTAssertEqual(f.toasts, [], "\(state)")
            XCTAssertEqual(f.ops.calls, [], "\(state)")
            XCTAssertEqual(f.deleteCalls, [], "\(state)")
            XCTAssertEqual(f.adoptCalls, [], "\(state)")
        }
    }

    func testAClosedAlbumEntryIsNotReplayed() throws {
        let f = F()
        try f.journal.insert(albumTestEntry(state: .closed, songs: [albumTestSong(1, state: .deleted)],
                                            priorRepeat: "all"))
        var replayed: [String] = []
        DiscoverCopyReconciler(copy: f.copySeams, post: f.post,
                               albumReplay: { entry, _ in replayed.append(entry.txn) }).run(atLaunch: true)
        XCTAssertEqual(replayed, [])
        XCTAssertEqual(f.restoreCalls, [albumTestTxn], "its recorded modes are still offered back")
    }
}

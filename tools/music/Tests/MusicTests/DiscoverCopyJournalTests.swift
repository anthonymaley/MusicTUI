import Darwin
import XCTest
@testable import music

/// The journal behind play-from-here (score step C2). Always a temporary
/// directory: never `~/.config/music`.
final class DiscoverCopyJournalTests: XCTestCase {

    private var root: URL!
    private var paths: DiscoverCopyPaths!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfh-c2-journal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DiscoverCopyPaths(directory: root.appendingPathComponent("discover-copies"))
    }

    override func tearDown() {
        chmod(paths.directory.path, 0o700)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func entry(_ txn: String, _ state: DiscoverCopyState, hex: String? = nil,
                       priorShuffle: Bool? = nil, priorRepeat: String? = nil) -> DiscoverCopyEntry {
        DiscoverCopyEntry(txn: txn, playlistID: "pl.x", title: "Mix", state: state, hex: hex,
                          copiesRead: 0, watching: false, copySeen: false, toldAtLaunch: false,
                          priorShuffle: priorShuffle, priorRepeat: priorRepeat, createdAt: 10, updatedAt: 10)
    }

    private func store() -> FileDiscoverCopyJournalStore { FileDiscoverCopyJournalStore(paths: paths) }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private func assertThrows(_ expected: DiscoverCopyJournalError, file: StaticString = #filePath,
                              line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? DiscoverCopyJournalError, expected, file: file, line: line)
        }
    }

    func testLivePathIsUnderConfigMusic() {
        XCTAssertTrue(DiscoverCopyPaths.live.journal.path.hasSuffix("/.config/music/discover-copies/journal.json"))
        XCTAssertTrue(DiscoverCopyPaths.live.lock.path.hasSuffix("/.config/music/discover-copies/lock"))
    }

    func testAMissingJournalIsEmptyAndReadingCreatesNothing() throws {
        XCTAssertEqual(try store().entries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testInsertIsOnDiskAsFormatOneWithPrivateModes() throws {
        try store().insert(entry("A", .intent))
        try store().insert(entry("B", .owned, hex: "00000000000000AB"))

        XCTAssertEqual(mode(paths.directory), 0o700)
        XCTAssertEqual(mode(paths.journal), 0o600)
        let data = try Data(contentsOf: paths.journal)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? Int, 1)
        let rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["txn"] as? String }, ["A", "B"])
        XCTAssertEqual(rows[1]["playlist_id"] as? String, "pl.x")
        XCTAssertEqual(rows[1]["copies_read"] as? Int, 0)
        // Sorted keys: "entries" precedes "format".
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\"entries\":["))

        // A second store on the same paths reads what the first wrote, in creation order.
        XCTAssertEqual(try store().entries().map(\.txn), ["A", "B"])
        XCTAssertEqual(try store().entries()[1], entry("B", .owned, hex: "00000000000000AB"))
    }

    func testUpdateRewritesOneEntryAndAnUnknownTxnIsNotFound() throws {
        let journal = store()
        try journal.insert(entry("A", .intent))
        let updated = try journal.update(txn: "A") { $0.state = .owned; $0.hex = "0000000000000001" }
        XCTAssertEqual(updated.state, .owned)
        XCTAssertEqual(try store().entries().first?.hex, "0000000000000001")
        assertThrows(.notFound) { try journal.update(txn: "missing") { $0.watching = true } }
    }

    func testAWriteThatWouldBreakAnInvariantIsRefusedAndNothingChanges() throws {
        let journal = store()
        try journal.insert(entry("A", .intent))
        let before = try Data(contentsOf: paths.journal)
        assertThrows(.writeFailed("invariant")) { try journal.insert(self.entry("B", .owned)) }
        assertThrows(.writeFailed("invariant")) { try journal.insert(self.entry("C", .intent, hex: "0000000000000001")) }
        assertThrows(.writeFailed("invariant")) { try journal.insert(self.entry("D", .listening, hex: "abc")) }
        assertThrows(.writeFailed("invariant")) { try journal.update(txn: "A") { $0.state = .owned } }
        assertThrows(.writeFailed("duplicate txn")) { try journal.insert(self.entry("A", .intent)) }
        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
    }

    func testAFailedWriteLeavesTheOldFile() throws {
        let journal = store()
        try journal.insert(entry("A", .intent))
        let before = try Data(contentsOf: paths.journal)

        // The directory no longer takes a new file, so the write cannot reach its rename.
        XCTAssertEqual(chmod(paths.directory.path, 0o500), 0)
        XCTAssertThrowsError(try journal.update(txn: "A") { $0.state = .closed }) { error in
            guard case .writeFailed = error as? DiscoverCopyJournalError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
        XCTAssertThrowsError(try journal.insert(entry("B", .intent)))
        XCTAssertEqual(chmod(paths.directory.path, 0o700), 0)

        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
        XCTAssertEqual(try store().entries(), [entry("A", .intent)])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.directory.path)
        XCTAssertEqual(leftovers.sorted(), ["journal.json", "lock"])
    }

    func testDurableReplaceFailingBeforeTheRenameLeavesTheOldFile() throws {
        // The same property one layer down, with the store's own writer: a
        // temporary file that cannot be created throws before the rename.
        let journal = store()
        try journal.insert(entry("A", .intent))
        let before = try Data(contentsOf: paths.journal)
        XCTAssertEqual(chmod(paths.directory.path, 0o500), 0)
        XCTAssertThrowsError(try DurableFile.replace(paths.journal, with: Data("{}".utf8))) { error in
            XCTAssertEqual((error as? DurableFileError)?.step, "create")
        }
        XCTAssertEqual(chmod(paths.directory.path, 0o700), 0)
        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
    }

    func testASecondStoreWhileTheLockIsHeldIsBusy() throws {
        try store().insert(entry("A", .intent))
        let before = try Data(contentsOf: paths.journal)
        guard case .success(let held) = PlaySyncLock.acquire(paths.lock, waitingUpTo: 0) else {
            return XCTFail("could not take the lock")
        }
        let second = store()
        assertThrows(.busy) { _ = try second.entries() }
        assertThrows(.busy) { try second.insert(self.entry("B", .intent)) }
        held.release()
        XCTAssertEqual(try Data(contentsOf: paths.journal), before)
        XCTAssertEqual(try second.entries().map(\.txn), ["A"])
    }

    func testUnreadableBytesAreNeverReadAsEmptyAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bodies: [(String, DiscoverCopyJournalError)] = [
            ("not json at all", .unreadable),
            ("", .unreadable),
            ("{\"entries\":[]}", .unreadable),
            ("{\"entries\":[],\"format\":0}", .unreadable),
            ("{\"entries\":[],\"format\":2}", .tooNew),
            ("{\"entries\":[{\"surprise\":true}],\"format\":2}", .tooNew),
            ("{\"entries\":[{\"surprise\":true}],\"format\":1}", .unreadable),
        ]
        for (text, expected) in bodies {
            let bytes = Data(text.utf8)
            try bytes.write(to: paths.journal)
            let journal = store()
            assertThrows(expected) { _ = try journal.entries() }
            assertThrows(expected) { try journal.insert(self.entry("A", .intent)) }
            assertThrows(expected) { try journal.update(txn: "A") { $0.watching = true } }
            XCTAssertEqual(try Data(contentsOf: paths.journal), bytes, "overwrote: \(text)")
        }
    }

    func testAnEntryThatBreaksAnInvariantMakesTheFileUnreadable() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        struct Body: Encodable { let format = 1; let entries: [DiscoverCopyEntry] }
        let broken: [DiscoverCopyEntry] = [
            entry("A", .owned),                              // owned without a hex
            entry("A", .listening, hex: "12ab"),             // not sixteen uppercase hex digits
            entry("A", .intent, hex: "0000000000000001"),    // intent with a hex
        ]
        for bad in broken {
            let bytes = try JSONEncoder().encode(Body(entries: [bad]))
            try bytes.write(to: paths.journal)
            assertThrows(.unreadable) { _ = try self.store().entries() }
            assertThrows(.unreadable) { try self.store().insert(self.entry("B", .intent)) }
            XCTAssertEqual(try Data(contentsOf: paths.journal), bytes)
        }
    }

    func testInsertPrunesOldClosedEntriesButNeverOnesWithModesOrUncertain() throws {
        var seeded: [DiscoverCopyEntry] = [
            entry("modes", .closed, priorShuffle: true),
            entry("repeat", .closed, priorRepeat: "all"),
            entry("unsure", .uncertain),
            entry("pre", .preexisting, hex: "0000000000000002"),
        ]
        seeded += (1...25).map { entry("c\($0)", .closed) }
        XCTAssertEqual(discoverCopyJournalPruned(seeded).count, 4 + 20)

        let journal = store()
        for item in seeded.prefix(24) { try journal.insert(item) }
        XCTAssertEqual(try journal.entries().count, 24)          // 20 plain closed: nothing pruned yet
        for item in seeded.dropFirst(24) { try journal.insert(item) }
        try journal.insert(entry("new", .intent))

        let kept = try journal.entries().map(\.txn)
        XCTAssertEqual(kept, ["modes", "repeat", "unsure", "pre"] + (6...25).map { "c\($0)" } + ["new"])
    }
}

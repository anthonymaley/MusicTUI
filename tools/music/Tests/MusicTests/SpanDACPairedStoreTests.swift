// tools/music/Tests/MusicTests/SpanDACPairedStoreTests.swift
//
// paired.json: a credential file. Mode 0600 in a 0700 folder, replaced by
// SpanDAC id on a re-pair, and refused (never repaired) when it is not safe.
// Every test works in a temporary folder; nothing here reads ~/.config/music.
import Darwin
import XCTest
@testable import music

final class SpanDACPairedStoreTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "spandac-store-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private var path: String { dir + "/spandac/paired.json" }

    private func record(_ id: String = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F", psk: String = String(repeating: "ab", count: 16),
                        key: UInt8 = 7) -> SpanDACPairRecord {
        SpanDACPairRecord(sourceID: id, sourceName: "Anthony’s iPad", pskID: psk,
                          pairKey: Data(repeating: key, count: 32), serviceName: id,
                          pairedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func mode(_ p: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(p, &info), 0)
        return info.st_mode & 0o777
    }

    func testAPairIsSavedAt0600InA0700FolderAndReadBack() throws {
        let store = SpanDACPairedStore(path: path)
        try store.save(record())
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(dir + "/spandac"), 0o700)
        XCTAssertEqual(SpanDACPairedStore(path: path).pairs(), [record()])
        XCTAssertEqual(try SpanDACPairedStore(path: path).lookup(record().sourceID).get(), record())
    }

    /// The controller id is minted once and kept.
    func testTheControllerIDIsMintedOnceAndKept() throws {
        let store = SpanDACPairedStore(path: path)
        let first = try store.controllerID()
        XCTAssertTrue(SpanDACPair.isCanonicalID(first))
        try store.save(record())
        XCTAssertEqual(try SpanDACPairedStore(path: path).controllerID(), first)
    }

    /// A re-pair with the same SpanDAC replaces the old identity and key.
    func testARepairReplacesTheOldPair() throws {
        let store = SpanDACPairedStore(path: path)
        try store.save(record())
        try store.save(record(psk: String(repeating: "cd", count: 16), key: 9))
        XCTAssertEqual(store.pairs().count, 1)
        XCTAssertEqual(store.pairs().first?.pskID, String(repeating: "cd", count: 16))
        XCTAssertEqual(store.pairs().first?.pairKey, Data(repeating: 9, count: 32))
    }

    func testForgetRemovesOnlyThatPair() throws {
        let store = SpanDACPairedStore(path: path)
        let other = record("6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91")
        try store.save(record())
        try store.save(other)
        XCTAssertTrue(try store.forget(sourceID: record().sourceID))
        XCTAssertFalse(try store.forget(sourceID: record().sourceID))
        XCTAssertEqual(store.pairs(), [other])
        XCTAssertEqual(store.lookup(record().sourceID).failure, .notPaired)
        XCTAssertEqual(mode(path), 0o600)
    }

    /// A key file others could read is refused, not quietly used or repaired.
    func testAWiderFileModeIsRefused() throws {
        let store = SpanDACPairedStore(path: path)
        try store.save(record())
        chmod(path, 0o644)
        XCTAssertEqual(store.pairs(), [])
        guard case .pairingsUnavailable(let why)? = store.lookup(record().sourceID).failure else {
            return XCTFail("a 0644 key file must be refused")
        }
        XCTAssertTrue(why.contains("mode 0600"), why)
        XCTAssertEqual(mode(path), 0o644, "refused, never repaired")
    }

    func testAFolderOthersCanEnterIsRefused() throws {
        let store = SpanDACPairedStore(path: path)
        try store.save(record())
        chmod(dir + "/spandac", 0o755)
        guard case .pairingsUnavailable? = store.lookup(record().sourceID).failure else {
            return XCTFail("a 0755 folder must be refused")
        }
        XCTAssertThrowsError(try store.save(record()))
    }

    /// A symlink in place of the file is never followed.
    func testASymlinkIsRefused() throws {
        try FileManager.default.createDirectory(atPath: dir + "/spandac", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = dir + "/elsewhere.json"
        try "{}".write(toFile: target, atomically: true, encoding: .utf8)
        chmod(target, 0o600)
        XCTAssertEqual(symlink(target, path), 0)
        guard case .pairingsUnavailable? = SpanDACPairedStore(path: path).lookup(record().sourceID).failure else {
            return XCTFail("a symlink must be refused")
        }
    }

    /// A malformed entry is dropped, never used; the good ones stay.
    func testAMalformedPairIsDropped() throws {
        let store = SpanDACPairedStore(path: path)
        try store.save(record())
        var text = try String(contentsOfFile: path, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"pairs\" : [", with: """
            "pairs" : [{"sid":"not-an-id","sname":"x","psk_id":"00","k_pair":"AA==","service":"x","paired_at":"2026-09-26T00:00:00Z"},
            """)
        try DurableFile.replace(URL(fileURLWithPath: path), with: Data(text.utf8))
        XCTAssertEqual(store.pairs(), [record()])
    }

    func testNoFileIsNoPairsAndNoProblem() {
        let store = SpanDACPairedStore(path: path)
        XCTAssertEqual(store.pairs(), [])
        XCTAssertNil(store.problem())
        XCTAssertEqual(store.lookup(record().sourceID).failure, .notPaired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/spandac"), "reading creates nothing")
    }

    func testTheLivePathIsBesideModeJSON() {
        XCTAssertTrue(SpanDACPairedStore.livePath.hasSuffix("/.config/music/spandac/paired.json"))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

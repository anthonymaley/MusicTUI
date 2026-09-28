// tools/music/Tests/MusicTests/DataProviderStoreTests.swift
//
// The persisted DATA axis (score: data route and output, C-AXES, C-REPAIR).
// Proves: the store defaults to open/never-shown, only the exact
// (spandac_mac, accepted) pair reads as accepted, reads never write, and the
// two stored files together fail closed rather than silently migrating.
import XCTest
@testable import music

final class DataProviderStoreTests: XCTestCase {

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "music-test-data-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dataPath(in dir: String) -> String {
        (dir as NSString).appendingPathComponent("data.json")
    }

    private func modePath(in dir: String) -> String {
        (dir as NSString).appendingPathComponent("mode.json")
    }

    func testMissingFileReadsOpenAndNeverShown() {
        let store = DataProviderStore(path: dataPath(in: tempDir()))
        let (data, ceremony) = store.read()
        XCTAssertEqual(data, .open)
        XCTAssertEqual(ceremony, .neverShown)
    }

    func testOnlySpanDACMacAndAcceptedTogetherAreAccepted() {
        let store = DataProviderStore(path: dataPath(in: tempDir()))
        store.accept()
        let (data, ceremony) = store.read()
        XCTAssertEqual(data, .spandacMac)
        XCTAssertEqual(ceremony, .accepted)
    }

    func testCorruptPartialOrUnknownDataReadsOpen() throws {
        let corrupt = dataPath(in: tempDir())
        try "{ not json".write(toFile: corrupt, atomically: true, encoding: .utf8)
        XCTAssertEqual(DataProviderStore(path: corrupt).read().data, .open)

        let partial = dataPath(in: tempDir())
        try "{\"data\":\"span".write(toFile: partial, atomically: true, encoding: .utf8)
        XCTAssertEqual(DataProviderStore(path: partial).read().data, .open)

        let unknown = dataPath(in: tempDir())
        try "{\"data\":\"from_the_future\",\"ceremony\":\"accepted\"}".write(toFile: unknown, atomically: true, encoding: .utf8)
        XCTAssertEqual(DataProviderStore(path: unknown).read().data, .open)
    }

    func testSpanDACDataWithoutAnAcceptedSwitchReadsOpen() throws {
        for ceremony in ["declined", "never_shown", "", "from_the_future"] {
            let path = dataPath(in: tempDir())
            try "{\"data\":\"spandac_mac\",\"ceremony\":\"\(ceremony)\"}"
                .write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertEqual(DataProviderStore(path: path).read().data, .open,
                           "spandac_mac with ceremony '\(ceremony)' must not read as SpanDAC data")
        }
        let noCeremony = dataPath(in: tempDir())
        try "{\"data\":\"spandac_mac\"}".write(toFile: noCeremony, atomically: true, encoding: .utf8)
        XCTAssertEqual(DataProviderStore(path: noCeremony).read().data, .open)
    }

    func testAcceptIsAtomicAndReadsBack() {
        let path = dataPath(in: tempDir())
        XCTAssertTrue(DataProviderStore(path: path).accept())
        let (data, ceremony) = DataProviderStore(path: path).read()
        XCTAssertEqual(data, .spandacMac)
        XCTAssertEqual(ceremony, .accepted)
    }

    func testDeclineKeepsDataOpen() {
        let path = dataPath(in: tempDir())
        DataProviderStore(path: path).decline()
        let (data, ceremony) = DataProviderStore(path: path).read()
        XCTAssertEqual(data, .open)
        XCTAssertEqual(ceremony, .declined)
    }

    func testStopUsingSpanDACReturnsToOpenAndDeclined() {
        let path = dataPath(in: tempDir())
        let store = DataProviderStore(path: path)
        store.accept()
        XCTAssertTrue(store.stopUsingSpanDAC())
        let (data, ceremony) = DataProviderStore(path: path).read()
        XCTAssertEqual(data, .open)
        XCTAssertEqual(ceremony, .declined)
    }

    func testReadsNeverWrite() {
        let path = dataPath(in: tempDir())
        _ = DataProviderStore(path: path).read()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "a read of a missing file must not create one")
    }

    func testDataFileLivesBesideModeJSON() {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        let data = DataProviderStore(beside: modes)
        data.accept()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataPath(in: dir)),
                     "data.json must live in the same directory as mode.json")
    }

    // MARK: - C-REPAIR: a stored SpanDAC output needs an accepted data state

    func testAStoredSpanDACOutputWithMissingDataIsBlocked() {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        modes.set(.source)
        let data = DataProviderStore(beside: modes)
        guard case .outputBlocked(let stored) = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected outputBlocked")
        }
        XCTAssertEqual(stored, .source)
    }

    func testAStoredSpanDACOutputWithCorruptDataIsBlocked() throws {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        modes.set(.source)
        try "{ not json".write(toFile: dataPath(in: dir), atomically: true, encoding: .utf8)
        let data = DataProviderStore(beside: modes)
        guard case .outputBlocked = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected outputBlocked")
        }
    }

    func testAStoredSpanDACOutputWithUnknownDataIsBlocked() throws {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        modes.set(.source)
        try "{\"data\":\"from_the_future\",\"ceremony\":\"accepted\"}"
            .write(toFile: dataPath(in: dir), atomically: true, encoding: .utf8)
        let data = DataProviderStore(beside: modes)
        guard case .outputBlocked = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected outputBlocked")
        }
    }

    func testAStoredSpanDACOutputWithExplicitOpenOrDeclinedIsBlocked() {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        modes.set(.source)
        let data = DataProviderStore(beside: modes)
        data.decline()
        guard case .outputBlocked = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected outputBlocked")
        }
    }

    func testAStoredNetworkOutputWithoutAcceptedDataIsBlocked() {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        let sourceID = UUID().uuidString
        modes.set(.networkSource(sourceID))
        let data = DataProviderStore(beside: modes)
        guard case .outputBlocked(let stored) = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected outputBlocked")
        }
        XCTAssertEqual(stored, .networkSource(sourceID))
    }

    func testMusicTUIOutputWithAnyDataFileIsConsistent() {
        let dir = tempDir()
        let modes = PlaybackModeStore(path: modePath(in: dir))
        modes.set(.musicApp)
        let data = DataProviderStore(beside: modes)
        // Even with no accepted ceremony, the MusicTUI output is never
        // blocked: only a stored SpanDAC output can be.
        guard case .consistent(let dataSelection, let output) = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected consistent")
        }
        XCTAssertEqual(dataSelection, .open)
        XCTAssertEqual(output, .musicApp)

        data.accept()
        guard case .consistent(let dataSelection2, let output2) = effectiveSelection(data: data, modes: modes) else {
            return XCTFail("expected consistent")
        }
        XCTAssertEqual(dataSelection2, .spandacMac)
        XCTAssertEqual(output2, .musicApp)
    }
}

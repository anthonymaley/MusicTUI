// tools/music/Tests/MusicTests/PlaybackModeStoreTests.swift
//
// The persisted Source Mode selection. Proves the properties the spec's binding
// rules depend on: Music.app is the default, the choice survives a restart, and
// it persists for a user with NO developer key configured.
//
// That last one is Codex's I3 and it is why this is its own file rather than a
// field on AuthConfig: AuthConfig requires keyId, teamId, keyPath and
// storefront, so a key-free user has no credential object to store a mode in.
import XCTest
@testable import music

final class PlaybackModeStoreTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "music-test-mode-\(UUID().uuidString).json"
    }

    /// Binding rule 1: an install that never opens Output behaves exactly as it
    /// ships today.
    func testDefaultsToMusicAppWhenNothingIsStored() {
        let store = PlaybackModeStore(path: tempPath())
        XCTAssertEqual(store.mode(), .musicApp)
    }

    /// Binding rule 2: the mode survives a restart. A second store over the same
    /// path is the restart, since nothing is shared in memory.
    func testSelectionSurvivesARestart() {
        let path = tempPath()
        PlaybackModeStore(path: path).set(.source)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .source)

        PlaybackModeStore(path: path).set(.musicApp)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    /// Codex I3. The store must not touch AuthConfig, so a key-free user can
    /// still choose and keep Source Mode. Nothing here reads ~/.config/music.
    func testPersistsWithNoCredentialsPresent() {
        let path = tempPath()
        let store = PlaybackModeStore(path: path)
        store.set(.source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "the mode is stored in its own file, independent of config.json")
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .source)
    }

    /// A corrupt file reads as the default rather than throwing. The mode is a
    /// preference, and refusing to start because one is unreadable would be
    /// worse than starting in the shipping default.
    func testCorruptFileFallsBackToTheDefault() throws {
        let path = tempPath()
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    /// An unknown value from a future version reads as the default too, rather
    /// than as a mode this build cannot serve.
    func testUnknownModeFallsBackToTheDefault() throws {
        let path = tempPath()
        try #"{"mode":"quantum"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp)
    }

    // MARK: - SpanDAC on the network (a third value, with a target)

    private let ipadID = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"

    /// The new value round-trips with the SpanDAC it names.
    func testTheNetworkValueRoundTripsWithItsTarget() throws {
        let path = tempPath()
        XCTAssertTrue(PlaybackModeStore(path: path).set(.networkSource(ipadID)))
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .networkSource(ipadID))
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String]
        XCTAssertEqual(stored, ["mode": "spandac_network", "target": ipadID])
    }

    /// The two existing values are written exactly as before: no `target`.
    func testTheExistingValuesAreWrittenByteIdentically() throws {
        let path = tempPath()
        PlaybackModeStore(path: path).set(.source)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), #"{"mode":"musictui_source"}"#)
        PlaybackModeStore(path: path).set(.musicApp)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), #"{"mode":"music_app"}"#)
    }

    /// A network selection this build cannot serve (no target, or a target
    /// that is not a SpanDAC id) reads as the default, like an unknown value.
    func testANetworkValueWithoutAUsableTargetFallsBackToTheDefault() throws {
        for body in [#"{"mode":"spandac_network"}"#,
                     #"{"mode":"spandac_network","target":""}"#,
                     #"{"mode":"spandac_network","target":"d2c4a6e8-1b3d-4f5a-8c7e-9a0b2c4d6e8f"}"#,
                     #"{"mode":"spandac_network","target":"not-an-id"}"#] {
            let path = tempPath()
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertEqual(PlaybackModeStore(path: path).mode(), .musicApp, body)
        }
    }

    /// A target beside the OLD values is ignored: only the new value names a
    /// SpanDAC on the network, so a build that knows only `musictui_source`
    /// can never be steered by a field it does not read.
    func testATargetBesideTheOldValuesChangesNothing() throws {
        let path = tempPath()
        try #"{"mode":"musictui_source","target":"\#(ipadID)"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(PlaybackModeStore(path: path).mode(), .source)
    }

    func testTheNetworkModeIsSourceBackedAndNamesItsTarget() {
        XCTAssertTrue(PlaybackMode.networkSource(ipadID).usesSource)
        XCTAssertTrue(PlaybackMode.source.usesSource)
        XCTAssertFalse(PlaybackMode.musicApp.usesSource)
        XCTAssertEqual(PlaybackMode.networkSource(ipadID).networkSourceID, ipadID)
        XCTAssertNil(PlaybackMode.source.networkSourceID)
        XCTAssertNotEqual(PlaybackMode.networkSource(ipadID), .networkSource(UUID().uuidString))
    }
}

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
}

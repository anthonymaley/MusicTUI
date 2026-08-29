import XCTest
@testable import music

/// `playlist create` needs a key only to SEED tracks by catalog id. Creating an
/// empty playlist is pure AppleScript (PlaylistCommands.swift already does it
/// for the temp-playlist machinery), so gating the whole command behind a
/// developer token asks $99/yr for something the app does for free elsewhere.
final class PlaylistCreateStrategyTests: XCTestCase {

    func testWithTokensUsesTheRESTPath() {
        XCTAssertEqual(playlistCreateStrategy(hasTokens: true, indexCount: 0, allLibraryRows: false), .rest)
        XCTAssertEqual(playlistCreateStrategy(hasTokens: true, indexCount: 3, allLibraryRows: false), .rest)
    }

    func testWithoutTokensAndNoTracksCreatesViaAppleScript() {
        XCTAssertEqual(playlistCreateStrategy(hasTokens: false, indexCount: 0, allLibraryRows: false), .appleScriptEmpty)
    }

    func testWithoutTokensButTracksRequestedNeedsAuth() {
        // Seeding resolves catalog ids from the result cache, which only a
        // catalog search populates. Refuse honestly rather than silently
        // creating an empty playlist the user did not ask for.
        XCTAssertEqual(playlistCreateStrategy(hasTokens: false, indexCount: 2, allLibraryRows: false), .needsAuthToSeed)
    }

    func testWithoutTokensAndOnlyLibraryRowsSeedsViaAppleScript() {
        XCTAssertEqual(playlistCreateStrategy(hasTokens: false, indexCount: 2, allLibraryRows: true), .appleScriptSeedFromLibrary)
    }

    func testWithTokensAndOnlyLibraryRowsSeedsViaAppleScript() {
        // Live 2026-08-28: a REST create with no catalog rows makes an empty
        // playlist that never syncs to Music.app, so the library rows can not
        // be duplicated in. A pure library selection takes the AppleScript
        // route whether or not tokens are present.
        XCTAssertEqual(playlistCreateStrategy(hasTokens: true, indexCount: 2, allLibraryRows: true), .appleScriptSeedFromLibrary)
    }
}

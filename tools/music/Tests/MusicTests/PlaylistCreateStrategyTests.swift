import XCTest
@testable import music

/// `playlist create` needs a key only to SEED tracks by catalog id. Creating an
/// empty playlist is pure AppleScript (PlaylistCommands.swift already does it
/// for the temp-playlist machinery), so gating the whole command behind a
/// developer token asks $99/yr for something the app does for free elsewhere.
final class PlaylistCreateStrategyTests: XCTestCase {

    func testWithTokensUsesTheRESTPath() {
        XCTAssertEqual(playlistCreateStrategy(hasTokens: true, indexCount: 0), .rest)
        XCTAssertEqual(playlistCreateStrategy(hasTokens: true, indexCount: 3), .rest)
    }

    func testWithoutTokensAndNoTracksCreatesViaAppleScript() {
        XCTAssertEqual(playlistCreateStrategy(hasTokens: false, indexCount: 0), .appleScriptEmpty)
    }

    func testWithoutTokensButTracksRequestedNeedsAuth() {
        // Seeding resolves catalog ids from the result cache, which only a
        // catalog search populates. Refuse honestly rather than silently
        // creating an empty playlist the user did not ask for.
        XCTAssertEqual(playlistCreateStrategy(hasTokens: false, indexCount: 2), .needsAuthToSeed)
    }
}

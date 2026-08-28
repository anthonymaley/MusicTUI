import XCTest
@testable import music

/// `playlist add` needs a key only to reach the CATALOG. Adding a track that is
/// already in the library is `duplicateLibraryTrack`, which this file already
/// ships and which has never needed a token.
final class PlaylistAddStrategyTests: XCTestCase {

    func testWithTokensUsesTheRESTPath() {
        XCTAssertEqual(playlistAddStrategy(hasTokens: true, itemsAreIndices: true), .rest)
        XCTAssertEqual(playlistAddStrategy(hasTokens: true, itemsAreIndices: false), .rest)
    }

    func testWithoutTokensATitleResolvesAgainstTheLibrary() {
        XCTAssertEqual(playlistAddStrategy(hasTokens: false, itemsAreIndices: false), .appleScriptLibrary)
    }

    func testWithoutTokensIndicesNeedAuth() {
        // Indices address the result cache, which only a catalog search fills.
        // Without a key there is nothing meaningful for them to point at.
        XCTAssertEqual(playlistAddStrategy(hasTokens: false, itemsAreIndices: true), .needsAuthForIndices)
    }
}

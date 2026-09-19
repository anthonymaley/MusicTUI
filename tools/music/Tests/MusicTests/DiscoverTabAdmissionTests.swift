import XCTest
@testable import music

/// The Discover tab's door. It was a user-token check made before the output
/// mode was ever consulted, so a keyless Bridge user was refused before the
/// scene existed - and every scene-level test still passed, because they build
/// the scene directly (Codex S2).
final class DiscoverTabAdmissionTests: XCTestCase {

    /// DoD 6: Bridge reads the feed with no keys, so the door is open.
    func testBridgeWithNoUserTokenIsAdmitted() {
        XCTAssertTrue(discoverTabAdmitted(mode: .source, hasUserToken: false))
    }

    /// Music.app mode must not change: no sign-in, no tab.
    func testMusicAppWithNoUserTokenIsStillRefused() {
        XCTAssertFalse(discoverTabAdmitted(mode: .musicApp, hasUserToken: false))
    }

    func testASignedInPersonIsAdmittedInEitherMode() {
        XCTAssertTrue(discoverTabAdmitted(mode: .musicApp, hasUserToken: true))
        XCTAssertTrue(discoverTabAdmitted(mode: .source, hasUserToken: true))
    }
}

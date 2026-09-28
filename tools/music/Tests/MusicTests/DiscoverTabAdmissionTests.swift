import XCTest
@testable import music

/// The Discover tab's door. It was a user-token check made before the output
/// mode was ever consulted, so a keyless SpanDAC user was refused before the
/// scene existed - and every scene-level test still passed, because they build
/// the scene directly (Codex S2). It now follows the DATA selection.
final class DiscoverTabAdmissionTests: XCTestCase {

    /// DoD 6: SpanDAC data reads the feed with no keys, so the door is open.
    func testSpanDACDataWithNoUserTokenIsAdmitted() {
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .spandacMac, output: .source),
                                          hasUserToken: false))
    }

    /// MusicTUI's own data must not change: no sign-in, no tab.
    func testOpenDataWithNoUserTokenIsStillRefused() {
        XCTAssertFalse(discoverTabAdmitted(selection: .consistent(data: .open, output: .musicApp),
                                           hasUserToken: false))
    }

    func testASignedInPersonIsAdmittedWhateverTheData() {
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .open, output: .musicApp),
                                          hasUserToken: true))
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .spandacMac, output: .musicApp),
                                          hasUserToken: true))
        XCTAssertTrue(discoverTabAdmitted(selection: .outputBlocked(stored: .source), hasUserToken: true))
    }
}

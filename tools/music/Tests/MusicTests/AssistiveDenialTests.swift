import XCTest
@testable import music

/// The Accessibility-denial classifier existed in THREE copies: the shared
/// `runMusicUIScript`, plus private duplicates in EQControl and
/// VisualizerControl. Three copies of a predicate is three chances for one to
/// learn a new error code the others never hear about. This pins the one
/// surviving definition.
final class AssistiveDenialTests: XCTestCase {

    /// The three signals a denial actually arrives as. `-1719` and `-25211`
    /// are the numeric forms; the text form is what AppleScript prints when
    /// the terminal is not trusted for Accessibility.
    func testRecognisesEveryKnownDenialSignal() {
        XCTAssertTrue(isAssistiveAccessDenial("osascript is not allowed assistive access."))
        XCTAssertTrue(isAssistiveAccessDenial("error -1719"))
        XCTAssertTrue(isAssistiveAccessDenial("error -25211"))
    }

    /// A denial must not swallow unrelated failures: translating every error
    /// into "grant Accessibility" would send the user to a settings pane that
    /// has nothing to do with the problem.
    func testLeavesUnrelatedFailuresAlone() {
        XCTAssertFalse(isAssistiveAccessDenial(""))
        XCTAssertFalse(isAssistiveAccessDenial("Music got an error: Can't get playlist \"Nope\"."))
        XCTAssertFalse(isAssistiveAccessDenial("error -1728"))
        XCTAssertFalse(isAssistiveAccessDenial("error -50"))
    }

    /// The signal can appear anywhere in a longer message, which is why this
    /// is a containment test rather than an equality one.
    func testMatchesTheSignalInsideALongerMessage() {
        XCTAssertTrue(isAssistiveAccessDenial(
            "System Events got an error: osascript is not allowed assistive access. (-1719)"))
    }
}

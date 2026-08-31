import XCTest
@testable import music

/// `showNowPlaying(waitForPlay:)` used to wait out only the "stopped" state, so
/// a play issued while PAUSED printed the outgoing track.
///
/// Measured 2026-08-30, four runs sampling every 50ms after a play issued from
/// paused. Every run was identical:
///
///     paused  | <old track>      <- the leak; the old guard accepted this
///     stopped | <new track>      <- already waited out
///     playing | <new track>      <- correct
///
/// `playing` never once appeared next to a stale track, so waiting for the
/// state to reach `playing` closes the whole window. Threading the previous
/// track's identity through the call sites was considered and rejected on that
/// evidence: it costs a read before every play and would spin on `music play`
/// with no arguments, where resuming keeps the same track by definition.
final class NowPlayingWaitTests: XCTestCase {

    // MARK: - The predicate

    /// Everything that is not `playing` is still in flight when we are waiting
    /// for a play to land. "paused" is the one that carried the bug; the
    /// transitional values are covered because the state machine passes
    /// through them and any of them would otherwise be read as final.
    func testWaitsWhileTheStateIsAnythingOtherThanPlaying() {
        for state in ["paused", "stopped", "fast forwarding", "rewinding", ""] {
            XCTAssertTrue(nowPlayingShouldWait(state: state, waitForPlay: true),
                          "\(state) is not a landed play")
        }
    }

    func testReadyOnceTheStateIsPlaying() {
        XCTAssertFalse(nowPlayingShouldWait(state: "playing", waitForPlay: true))
    }

    /// `music now` must stay immediate: it reports whatever is true right now,
    /// including a paused track, and waits for nothing.
    func testNeverWaitsWhenNotWaitingForAPlay() {
        for state in ["paused", "stopped", "playing", "fast forwarding"] {
            XCTAssertFalse(nowPlayingShouldWait(state: state, waitForPlay: false),
                           "\(state) must not block a plain read")
        }
    }

    // MARK: - The generated guard

    /// The guard that actually runs is AppleScript, so the predicate above
    /// cannot be the live code path. This test is what stops the two drifting:
    /// the emitted script must key on the SAME state the predicate treats as
    /// ready, not on a second copy of the string.
    func testGeneratedGuardKeysOnTheSameReadyStateAsThePredicate() {
        let guardScript = nowPlayingStateGuard(waitForPlay: true)
        XCTAssertTrue(guardScript.contains("\"\(nowPlayingReadyState)\""))
        XCTAssertTrue(guardScript.contains("error"),
                      "a not-yet-landed play must throw back into the retry loop")
        XCTAssertFalse(nowPlayingShouldWait(state: nowPlayingReadyState, waitForPlay: true))
    }

    /// The non-waiting guard is unchanged: it returns the STOPPED sentinel the
    /// caller already parses, and must NOT error, or `music now` would retry
    /// ten times on a stopped player instead of reporting it.
    func testNonWaitingGuardKeepsTheStoppedSentinelAndNeverErrors() {
        let guardScript = nowPlayingStateGuard(waitForPlay: false)
        XCTAssertTrue(guardScript.contains("STOPPED"))
        XCTAssertFalse(guardScript.contains("error"))
    }
}

import XCTest
@testable import music

/// Leaving Bridge for Music.app, after the 2026-09-22 gate found the Output tab
/// refusing with "Couldn't confirm Bridge paused" whenever Bridge was idle.
///
/// An idle Bridge answers `slice.pause` with `bad_request` "did not reach paused
/// within 3s" (reproduced by hand that day), and the old check threw on it
/// before reading the status that already accepted `idle`. The status still
/// decides; a refused pause alone no longer does.
final class BridgeSwitchPauseTests: XCTestCase {

    private func control(pause: String, status: String?) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: { _, line in
            if line.contains("slice.pause") { return pause }
            guard let status else { throw SourceAppError.unreadable }
            return status
        })
    }

    private func statusReply(_ playback: String) -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"\#(playback)","contract":2,"authorization":"authorized"}}"#
    }

    private let refusedPause = #"{"ok":false,"op":"slice.pause","error":{"kind":"bad_request","detail":"did not reach paused within 3s"}}"#
    private let acceptedPause = #"{"ok":true,"op":"slice.pause","status":{"playback":"paused"}}"#

    /// The gate's case exactly: nothing to pause, and Bridge says it is idle.
    func testAnIdleBridgeThatRefusesThePauseConfirms() throws {
        XCTAssertTrue(try confirmBridgeNotPlaying(control(pause: refusedPause, status: statusReply("idle"))))
    }

    func testAPausedOrStoppedBridgeConfirms() throws {
        for playback in ["paused", "stopped"] {
            XCTAssertTrue(try confirmBridgeNotPlaying(control(pause: acceptedPause, status: statusReply(playback))),
                          playback)
        }
    }

    /// Positive evidence only: a refused pause over a Bridge still playing must
    /// not switch, or both players could be going at once (rule 4).
    func testARefusedPauseOverAPlayingBridgeDoesNotConfirm() throws {
        for playback in ["playing", "loading"] {
            XCTAssertFalse(try confirmBridgeNotPlaying(control(pause: refusedPause, status: statusReply(playback))),
                           playback)
        }
    }

    /// No status, no evidence: the check throws, and the switch refuses.
    func testAnUnreadableStatusThrows() {
        XCTAssertThrowsError(try confirmBridgeNotPlaying(control(pause: refusedPause, status: nil)))
    }
}

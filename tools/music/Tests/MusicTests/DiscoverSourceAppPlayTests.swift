// tools/music/Tests/MusicTests/DiscoverSourceAppPlayTests.swift
//
// The `slice.play` client: one catalogue id, and every way its reply can lie.
//
// **What moved at step 2.** Enter on a Discover track used to send exactly one
// id, because the wire had no queue. It now sends the slice to the container's
// end through `slice.queue`, so the route tests and the shortened footer that
// pinned the one-track promise have gone; Anthony's 2026-09-10 ruling made that
// promise explicitly TEMPORARY, pending exactly this queue ("Don't pretend queue
// semantics exist yet"). The binding now lives in
// `DiscoverBridgeCollectionTests`.
//
// What remains here is still load-bearing: `slice.play` is how ONE catalogue id
// is played, and these pin its request shape and its reply discipline.
//
// TEMPORARY, with the adapter it exercises.
import XCTest
@testable import music

final class DiscoverSourceAppPlayTests: XCTestCase {

    private let ids = ["1001", "1002", "1003", "1004"]

    // MARK: - The wire request, and failing closed

    func testPlayRequestNamesTheTrack() {
        var sent: String?
        let client = SourceAppPlayback(path: "/nowhere") { _, line in
            sent = line
            return #"{"ok":true,"op":"slice.play","status":{"playback":"playing"}}"#
        }

        XCTAssertNoThrow(try client.play(catalogID: "1706428462"))
        let line = sent ?? ""
        XCTAssertTrue(line.contains("\"op\":\"slice.play\""), "got: \(line)")
        XCTAssertTrue(line.contains("\"id\":\"1706428462\""),
                      "the request must name the track; got: \(line)")
    }

    /// A refusal is surfaced, never swallowed. There is deliberately no fallback
    /// to Music.app: falling back would be the provider-precedence decision
    /// Anthony reserved to himself.
    func testARefusalReachesTheCaller() {
        let client = SourceAppPlayback(path: "/nowhere") { _, _ in
            #"{"ok":false,"op":"slice.play","error":{"kind":"unauthorized","detail":"no access"}}"#
        }
        XCTAssertThrowsError(try client.play(catalogID: "1")) { error in
            XCTAssertEqual(error as? SourceAppError, .notAuthorized)
        }
    }

    /// Bridge overloaded: decoded on the kind, never "Bridge refused" — the
    /// caller did nothing wrong (controller check, 2026-09-25).
    func testBusyIsReportedAsBusyNotRefused() {
        let client = SourceAppPlayback(path: "/nowhere") { _, _ in
            #"{"ok":false,"op":"slice.play","error":{"kind":"busy","detail":"Bridge is handling too many requests at once; try again in a moment."}}"#
        }
        XCTAssertThrowsError(try client.play(catalogID: "1")) { error in
            XCTAssertEqual(error as? SourceAppError, .busy)
            XCTAssertEqual((error as? SourceAppError)?.message, "Bridge is busy; try again in a moment.")
        }
    }

    /// Anthony, 2026-09-10, Blocking: "The reply must be a failure unless the
    /// resulting state is actually .playing; the client should also reject an ok
    /// reply whose status is not playing."
    ///
    /// `ok` answers "did the source accept the request". Only the status answers
    /// "is it playing". The source app used to report MusicKit errors and its own
    /// three-second timeout as `.failed` on an ok reply; since 2026-09-13 it
    /// replies `ok:false` with the command's failure and its status never says
    /// `failed`. `"failed"` stays in this list defensively: the client rejects
    /// every ok reply that is not playing, whoever sends it.
    func testAnOkReplyThatIsNotPlayingIsRejected() {
        for reported in ["idle", "failed", "paused", "stopped", "loading"] {
            let client = SourceAppPlayback(path: "/nowhere") { _, _ in
                "{\"ok\":true,\"op\":\"slice.play\",\"status\":{\"playback\":\"\(reported)\"}}"
            }
            XCTAssertThrowsError(try client.play(catalogID: "1"),
                                 "status \(reported) must not read as success")
        }
    }

    func testAPlayingReplyIsAccepted() {
        let client = SourceAppPlayback(path: "/nowhere") { _, _ in
            #"{"ok":true,"op":"slice.play","status":{"playback":"playing"}}"#
        }
        XCTAssertNoThrow(try client.play(catalogID: "1"))
    }

    /// An ok reply with no status at all is a contract violation rather than a
    /// success, the same rule the station search applies to a missing array.
    func testAnOkReplyWithNoStatusIsRejected() {
        let client = SourceAppPlayback(path: "/nowhere") { _, _ in
            #"{"ok":true,"op":"slice.play"}"#
        }
        XCTAssertThrowsError(try client.play(catalogID: "1"))
    }

    func testAnUnreadableReplyIsNotReadAsSuccess() {
        let client = SourceAppPlayback(path: "/nowhere") { _, _ in "{not json" }
        XCTAssertThrowsError(try client.play(catalogID: "1")) { error in
            XCTAssertEqual(error as? SourceAppError, .unreadable)
        }
    }
}

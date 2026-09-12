// tools/music/Tests/MusicTests/DiscoverSourceAppPlayTests.swift
//
// Discover's track-level Enter routed to the MusicTUISource app. Proves the
// properties that matter for the bridge: source mode sends exactly ONE catalog
// id rather than the slice to the container's end, the footer stops promising
// queue semantics that do not exist, and a refusal reaches the caller instead of
// falling back to Music.app.
//
// TEMPORARY, with the adapter it exercises.
import XCTest
@testable import music

final class DiscoverSourceAppPlayTests: XCTestCase {

    private let ids = ["1001", "1002", "1003", "1004"]

    // MARK: - One track, not a queue

    /// The whole honesty point of this slice (Anthony, 2026-09-10): "If the
    /// slice sends only one track, its footer should temporarily say 'Enter
    /// Play' in source-app mode. Don't pretend queue semantics exist yet."
    /// The route has to match the promise, so it carries one id and no tail.
    func testSourceModeSendsExactlyTheSelectedTrack() {
        let route = discoverPlayRoute(trackIDs: ids, from: 1, sourceApp: true)
        XCTAssertEqual(route, .sourceApp(catalogID: "1002"))
    }

    /// And the inverse, so the test above cannot pass for the wrong reason:
    /// with the option off this is unchanged, still the container sliced from
    /// the selected row to the end.
    func testNormalModeStillSlicesToTheContainerEnd() {
        let route = discoverPlayRoute(trackIDs: ids, from: 1, sourceApp: false)
        XCTAssertEqual(route, .container(catalogIDs: ["1002", "1003", "1004"]))
    }

    /// A cursor that cannot be resolved yields no route in either mode, so the
    /// caller reports it rather than playing something arbitrary.
    func testAnUnresolvableCursorYieldsNoRoute() {
        XCTAssertNil(discoverPlayRoute(trackIDs: ids, from: 9, sourceApp: true))
        XCTAssertNil(discoverPlayRoute(trackIDs: ids, from: 9, sourceApp: false))
        XCTAssertNil(discoverPlayRoute(trackIDs: [], from: 0, sourceApp: true))
    }

    // MARK: - The footer must not promise a queue

    func testFooterDropsPlayFromHereInSourceMode() {
        let song = DiscoverItem(id: "1", name: "n", subtitle: nil, url: nil,
                                artworkURL: nil, detail: .song)
        let normal = discoverFooterHint(.item(song), canGoBack: true, canRefresh: false,
                                        sourceApp: false)
        let source = discoverFooterHint(.item(song), canGoBack: true, canRefresh: false,
                                        sourceApp: true)

        XCTAssertTrue(normal.contains("Play from here"), "unchanged off the option: \(normal)")
        XCTAssertFalse(source.contains("from here"),
                       "source mode plays one track, so it must not promise the rest: \(source)")
        XCTAssertTrue(source.contains("Enter Play"), "got: \(source)")
    }

    /// Only the song row's wording moves. An album or playlist row still offers
    /// `p` for Play all, which Anthony kept explicitly.
    func testOtherRowsAreUnaffectedByTheOption() {
        let album = DiscoverItem(id: "2", name: "a", subtitle: nil, url: nil, artworkURL: nil,
                                 detail: .album(trackCount: 9, year: 2001, genre: nil))
        XCTAssertEqual(discoverFooterHint(.item(album), canGoBack: true, canRefresh: false, sourceApp: true),
                       discoverFooterHint(.item(album), canGoBack: true, canRefresh: false, sourceApp: false))
    }

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

    /// Anthony, 2026-09-10, Blocking: "The reply must be a failure unless the
    /// resulting state is actually .playing; the client should also reject an ok
    /// reply whose status is not playing."
    ///
    /// `ok` answers "did the source accept the request". Only the status answers
    /// "is it playing", and PlaybackOwner.play() represents both MusicKit errors
    /// and its own three-second timeout by setting `.failed` rather than
    /// throwing, so an ok-only client prints "Playing" over a failed play.
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

import XCTest
@testable import music

final class AlbumWatcherDecisionTests: XCTestCase {

    private let ids: Set<String> = ["ID1", "ID2", "ID3"]

    private func observe(state: String?, context: String?, currentID: String?)
        -> AlbumWatcherObservation {
        AlbumWatcherObservation(playerState: state,
                                currentPlaylist: context,
                                currentTrackID: currentID,
                                containerName: "__album__ U — Moon Safari",
                                containerTrackIDs: ids)
    }

    func testSparesWhilePlayingInsideTheContainer() {
        let o = observe(state: "playing", context: "__album__ U — Moon Safari", currentID: "ID2")
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// Album containers are resumable. This is where album and Discover
    /// lifecycles deliberately differ.
    func testSparesWhilePaused() {
        let o = observe(state: "paused", context: "__album__ U — Moon Safari", currentID: "ID1")
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    func testSparesWhileScrubbing() {
        for state in ["fast forwarding", "rewinding"] {
            let o = observe(state: state, context: "__album__ U — Moon Safari", currentID: "ID1")
            XCTAssertEqual(albumWatcherDecision(o), .spare, "must spare while \(state)")
        }
    }

    func testCollectsWhenStopped() {
        let o = observe(state: "stopped", context: nil, currentID: nil)
        XCTAssertEqual(albumWatcherDecision(o), .collect)
    }

    func testCollectsWhenReadableContextMovedElsewhere() {
        let o = observe(state: "playing", context: "House", currentID: "OTHER")
        XCTAssertEqual(albumWatcherDecision(o), .collect)
    }

    /// THE AUTOPLAY ON CASE. Measured 2026-09-01: state reads `playing` and
    /// `current playlist` throws. Context is useless here, so identity decides.
    func testCollectsWhenAutoplayBleedsToATrackOutsideTheSet() {
        let o = observe(state: "playing", context: nil, currentID: "OUTSIDE")
        XCTAssertEqual(albumWatcherDecision(o), .collect)
    }

    /// Same unreadable context, but the track is still ours: a transient
    /// context read failure must not collect a live container.
    func testSparesWhenContextUnreadableButTrackIsInTheSet() {
        let o = observe(state: "playing", context: nil, currentID: "ID3")
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// Both signals unreadable: fail toward sparing. An Apple Event error is
    /// never "the context changed".
    func testSparesWhenIdentityAndContextAreBothUnreadable() {
        let o = observe(state: "playing", context: nil, currentID: nil)
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    func testSparesWhenPlayerStateIsUnreadable() {
        let o = observe(state: nil, context: nil, currentID: nil)
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    func testConstantsAreOrderedSensibly() {
        XCTAssertLessThan(albumWatcherPollInterval, albumWatcherArmTimeout)
        XCTAssertLessThan(albumWatcherArmTimeout, albumWatcherMaxLifetime)
        XCTAssertGreaterThan(albumWatcherInlineIDLimit, 0)
    }
}

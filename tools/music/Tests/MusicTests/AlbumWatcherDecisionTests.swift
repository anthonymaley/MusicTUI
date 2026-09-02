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

    /// §16.7 (corrects §16.2's own regression suite): the OLD version of this
    /// test passed a non-nil `currentTrackID` OUTSIDE the set, so — under the
    /// PRE-§16.2 identity-first order — it returned via the identity branch
    /// and never touched context at all, despite its name. Under §16.2's new
    /// order, context is now checked before identity, so this is rewritten to
    /// be unambiguous about which branch it exercises AND to double as the
    /// same-album-twice regression: `currentID` is "ID2", INSIDE this
    /// container's own set, exactly as it would be if a second container of
    /// the SAME album duplicated references to the identical underlying
    /// library tracks (§16.2's rationale — `duplicate` copies a reference, so
    /// two containers of one album share every persistent ID). Under the OLD
    /// identity-first order this would have returned `.spare` (id inside the
    /// set), which is precisely the bug: the first container stayed spared,
    /// un-collectible, until its six-hour max lifetime. Only a readable,
    /// DIFFERING context can tell the two containers apart.
    func testCollectsWhenReadableContextMovedElsewhere() {
        let o = observe(state: "playing", context: "House", currentID: "ID2")
        XCTAssertEqual(albumWatcherDecision(o), .collect,
                       "a readable, differing context must collect even when the current track id "
                       + "belongs to this container's own set (same-album-twice)")
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

    /// Context-only branch coverage: identity unreadable, context readable and
    /// matching. macOS 26 throws -1728 on `persistent id` for some tracks, making
    /// this a real case.
    func testSparesWhenIdentityUnreadableButContextMatchesContainer() {
        let o = observe(state: "playing", context: "__album__ U — Moon Safari", currentID: nil)
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// Context-only branch coverage: identity unreadable, context readable and
    /// not matching. This is the signal that playback moved away.
    func testCollectsWhenIdentityUnreadableButContextMovedElsewhere() {
        let o = observe(state: "playing", context: "House", currentID: nil)
        XCTAssertEqual(albumWatcherDecision(o), .collect)
    }

    /// §16.2 REVERSES this: context now beats identity, not the other way
    /// round (§16.2 replaces §6.1's identity-first order — see the module doc
    /// on `albumWatcherDecision`). A readable, MATCHING context always
    /// spares, even when the current track id superficially looks like it is
    /// "outside the set" — the set only ever describes ONE container's own
    /// tracks, and a genuinely mismatched id here would mean the id read
    /// itself is unreliable, not that playback moved (context already says it
    /// didn't). Before §16.2 this asserted `.collect`.
    func testSparesWhenContextMatchesEvenIfIdentityLooksOutsideTheSet() {
        let o = observe(state: "playing", context: "__album__ U — Moon Safari", currentID: "OUTSIDE")
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    /// §16.2 step 2: a state value that is neither an `albumInUsePlayerState`
    /// NOR exactly `"stopped"` (a malformed read, or a future value Apple
    /// might add) must SPARE, not collect. The pre-§16.2 code used a negative
    /// allowlist test (`if !albumInUsePlayerStates.contains(state) { return
    /// .collect }`) that put exactly this case on the DELETE side — on the
    /// only code path in this app that deletes unattended. Context is set to
    /// something that would otherwise collect (differing, readable), to prove
    /// the unrecognised-state check gates BEFORE context is even consulted.
    func testSparesOnUnrecognisedPlayerStateEvenWhenContextHasMovedElsewhere() {
        let o = observe(state: "buffering", context: "House", currentID: "OUTSIDE")
        XCTAssertEqual(albumWatcherDecision(o), .spare)
    }

    func testConstantsAreOrderedSensibly() {
        XCTAssertLessThan(albumWatcherPollInterval, albumWatcherArmTimeout)
        XCTAssertLessThan(albumWatcherArmTimeout, albumWatcherMaxLifetime)
        XCTAssertGreaterThan(albumWatcherInlineIDLimit, 0)
    }
}

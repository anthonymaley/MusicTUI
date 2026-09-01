import XCTest
@testable import music

/// Queue-resume v2-lite: the bounded forward scan.
///
/// v1 adopted only when the playing track was still the saved current track, so
/// one track ending during the quit-relaunch gap discarded the queue. v2-lite
/// also looks a bounded distance ahead.
///
/// The identity available differs by position, and that asymmetry is the whole
/// design. At `currentIndex` both sides have a persistent ID (live read vs
/// `anchorPersistentID`). At forward positions the saved side has none, because
/// `TrackListEntry` carries no persistent ID - which is exactly why v2-full was
/// deferred. Forward matching is therefore name+artist only, and ambiguity
/// discards rather than guesses: a wrong adoption puts `currentSourcePosition`
/// on the wrong entry and the next auto-advance plays the wrong song, while a
/// discard only costs the queue.
final class QueueResumeForwardScanTests: XCTestCase {
    private func saved(currentIndex: Int, tracks: [TrackListEntry], anchorID: String?,
                       anchorName: String = "T", anchorArtist: String = "A") -> PersistedQueue {
        PersistedQueue(
            queue: AppQueue(playlistName: "P", tracks: tracks, currentIndex: currentIndex),
            anchorPersistentID: anchorID, anchorName: anchorName, anchorArtist: anchorArtist)
    }

    private func entry(_ name: String, _ artist: String, index: Int = 1) -> TrackListEntry {
        TrackListEntry(index: index, name: name, artist: artist, isCurrent: false)
    }

    /// Five distinct tracks, saved current at position 1.
    private func fiveTrackQueue(currentIndex: Int = 1) -> PersistedQueue {
        saved(currentIndex: currentIndex,
              tracks: [entry("One", "A", index: 11), entry("Two", "B", index: 12),
                       entry("Three", "C", index: 13), entry("Four", "D", index: 14),
                       entry("Five", "E", index: 15)],
              anchorID: "ID-1", anchorName: "One", anchorArtist: "A")
    }

    // MARK: - The unchanged current position

    func testStillAtTheSavedCurrentReturnsThatPosition() {
        let s = fiveTrackQueue()
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-1", playingName: "One",
                                      playingArtist: "A", saved: s), 1)
    }

    /// v1 semantics are preserved exactly at `currentIndex`: the persistent ID
    /// is authoritative there, and it is checked before any forward scanning.
    func testPersistentIDStillWinsAtTheCurrentPosition() {
        let s = saved(currentIndex: 1,
                      tracks: [entry("Same", "A", index: 11), entry("Same", "A", index: 12)],
                      anchorID: "ID-1", anchorName: "Same", anchorArtist: "A")
        // Playing ID equals the anchor, so this is the current track, not the
        // duplicate one position ahead.
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-1", playingName: "Same",
                                      playingArtist: "A", saved: s), 1)
    }

    // MARK: - The forward window

    func testMatchesOnePositionAhead() {
        let s = fiveTrackQueue()
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Two",
                                      playingArtist: "B", saved: s), 2)
    }

    func testMatchesTwoPositionsAhead() {
        let s = fiveTrackQueue()
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Three",
                                      playingArtist: "C", saved: s), 3)
    }

    func testMatchesThreePositionsAhead() {
        let s = fiveTrackQueue()
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Four",
                                      playingArtist: "D", saved: s), 4)
    }

    /// The window is exactly three. Four ahead is a walk-away, not a gap.
    func testDoesNotMatchFourPositionsAhead() {
        let s = fiveTrackQueue()
        XCTAssertNil(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Five",
                                    playingArtist: "E", saved: s))
    }

    func testWindowIsExactlyThree() {
        XCTAssertEqual(queueResumeForwardScan, 3)
    }

    func testWindowClampsAtTheEndOfTheQueue() {
        let s = saved(currentIndex: 2,
                      tracks: [entry("One", "A", index: 11), entry("Two", "B", index: 12)],
                      anchorID: "ID-1", anchorName: "Two", anchorArtist: "B")
        // Nothing after position 2 exists; scanning must not run off the end.
        XCTAssertNil(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Nope",
                                    playingArtist: "Z", saved: s))
    }

    /// Backward movement is out of scope: the user pressed prev, or the queue
    /// restarted. Discard, as v1 did.
    func testDoesNotScanBackwards() {
        let s = fiveTrackQueue(currentIndex: 4)
        XCTAssertNil(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Two",
                                    playingArtist: "B", saved: s))
    }

    // MARK: - Ambiguity

    /// Two entries in the window with the same normalized name AND artist cannot
    /// be told apart without a persistent ID, so the restore discards.
    func testDuplicateNameAndArtistInTheWindowIsAmbiguousAndDiscards() {
        let s = saved(currentIndex: 1,
                      tracks: [entry("One", "A", index: 11), entry("Repeat", "R", index: 12),
                               entry("Repeat", "R", index: 13)],
                      anchorID: "ID-1", anchorName: "One", anchorArtist: "A")
        XCTAssertNil(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Repeat",
                                    playingArtist: "R", saved: s))
    }

    /// Ambiguity is the name+artist PAIR, never the title alone. A covers
    /// compilation repeats a title under different artists and must still resume.
    func testSameTitleDifferentArtistsIsNotAmbiguous() {
        let s = saved(currentIndex: 1,
                      tracks: [entry("One", "A", index: 11), entry("Hallelujah", "Buckley", index: 12),
                               entry("Hallelujah", "Cale", index: 13)],
                      anchorID: "ID-1", anchorName: "One", anchorArtist: "A")
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Hallelujah",
                                      playingArtist: "Cale", saved: s), 3)
        XCTAssertEqual(resumePosition(playingPersistentID: "ID-OTHER", playingName: "Hallelujah",
                                      playingArtist: "Buckley", saved: s), 2)
    }

    /// Normalization matches `queueMatches`: case and whitespace insensitive on
    /// both halves of the pair.
    func testForwardMatchIsCaseAndWhitespaceInsensitive() {
        let s = fiveTrackQueue()
        XCTAssertEqual(resumePosition(playingPersistentID: nil, playingName: "  two  ",
                                      playingArtist: "b", saved: s), 2)
    }

    // MARK: - Positions are queue-array positions, not source positions

    /// The adopted index addresses the play-order array; the SOURCE position
    /// used by `play track N of playlist X` is that entry's own `.index`. The
    /// two differ once a queue is shuffled, and conflating them would play the
    /// wrong track while looking correct.
    func testAdoptedIndexIsAnArrayPositionWhileSourcePlayUsesEntryIndex() {
        let s = fiveTrackQueue()
        let pos = resumePosition(playingPersistentID: "ID-OTHER", playingName: "Three",
                                 playingArtist: "C", saved: s)
        XCTAssertEqual(pos, 3, "array position, 1-based into tracks")

        var q = s.queue
        q.currentIndex = pos!
        XCTAssertEqual(q.currentIndex, 3)
        XCTAssertEqual(q.currentSourcePosition, 13, "source position comes from the entry's .index")
        XCTAssertNotEqual(q.currentIndex, q.currentSourcePosition,
                          "the two must not be conflated")
    }

    // MARK: - decideQueueRestore integration

    func testDecideAdoptsWithTheCorrectedIndex() {
        let s = fiveTrackQueue()
        let d = decideQueueRestore(saved: s, playerStopped: false, playingPersistentID: "ID-OTHER",
                                   playingName: "Three", playingArtist: "C")
        guard case .adopt(let q) = d else { return XCTFail("expected adopt, got \(d)") }
        XCTAssertEqual(q.currentIndex, 3)
        XCTAssertEqual(q.tracks, s.queue.tracks, "only the index moves")
        XCTAssertEqual(q.playlistName, s.queue.playlistName)
    }

    func testDecideDiscardsOnAmbiguity() {
        let s = saved(currentIndex: 1,
                      tracks: [entry("One", "A", index: 11), entry("Repeat", "R", index: 12),
                               entry("Repeat", "R", index: 13)],
                      anchorID: "ID-1", anchorName: "One", anchorArtist: "A")
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: false,
                                          playingPersistentID: "ID-OTHER", playingName: "Repeat",
                                          playingArtist: "R"), .discard)
    }

    func testDecideDiscardsBeyondTheWindow() {
        let s = fiveTrackQueue()
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: false,
                                          playingPersistentID: "ID-OTHER", playingName: "Five",
                                          playingArtist: "E"), .discard)
    }

    /// A stopped player discards before any matching runs, unchanged from v1.
    func testStoppedPlayerStillDiscardsWithoutScanning() {
        let s = fiveTrackQueue()
        XCTAssertEqual(decideQueueRestore(saved: s, playerStopped: true, playingPersistentID: nil,
                                          playingName: "", playingArtist: ""), .discard)
    }
}

// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindowMarksCurrentByIndex() {
        // Format: "name\ncurrentIndex\ntotal\nwindowStart\nidx␟title␟artist..."
        // (fields are ASCII unit separator — titles can legally contain "|")
        let fs = String(asFieldSep)
        let raw = "Friday Mix\n3\n42\n2\n2\(fs)Song B\(fs)Artist B\n3\(fs)Song C\(fs)Artist C\n4\(fs)Song C\(fs)Artist C"
        let q = parseContextQueue(raw)
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.currentIndex, 3)
        XCTAssertEqual(q.total, 42)
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)
        XCTAssertFalse(q.tracks[2].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
    /// Now Playing shows the album's real title, not the transaction id.
    func testCleanContextNameStripsTheDiscoverPrefix() {
        XCTAssertEqual(cleanContextName("__discover__ 8B1F — Kid A"), "Kid A")
        XCTAssertEqual(cleanContextName("__queue__ House"), "House")
        XCTAssertEqual(cleanContextName("My Mix"), "My Mix")
    }

    /// Only the FIRST separator is consumed, so a title that itself contains
    /// the separator survives intact instead of being truncated at its own
    /// dash. A naive last-occurrence split, or a greedy split that eats every
    /// separator, both fail this: they'd return "Reprise" instead of the full
    /// title.
    func testCleanContextNamePreservesASeparatorInsideTheTitle() {
        XCTAssertEqual(cleanContextName("__discover__ 8B1F — Do It Again — Reprise"),
                       "Do It Again — Reprise")
    }

    /// A malformed or hand-edited Discover name with no separator degrades to
    /// the prefix-stripped remainder rather than an empty string.
    func testCleanContextNameDegradesWhenSeparatorIsMissing() {
        XCTAssertEqual(cleanContextName("__discover__ 8B1F"), "8B1F")
    }

    /// A `__temp__` container is playback plumbing, so Now Playing shows a
    /// stable label rather than the raw name. Anthony, 2026-09-03: do not
    /// expose `__temp__<timestamp>` and do not reduce it to a meaningless
    /// timestamp.
    func testCleanContextNameLabelsTempContainer() {
        XCTAssertEqual(cleanContextName("__temp__1756789012"), "Temporary playlist")
        XCTAssertEqual(cleanContextName("__temp__"), "Temporary playlist")
    }

    /// PRECEDENCE, and it is load-bearing. `tempPlaylistCreationPrefix` is in
    /// `tempPlaylistPrefixes` so the rail hides it, which means the generic
    /// strip loop would ALSO match a `__temp__` name and return the bare
    /// timestamp. The label branch must be reached first.
    ///
    /// This pins the precedence BEHAVIOUR rather than source order, which is
    /// the stronger property: another implementation could preserve the result
    /// without this literal branch layout. It fails if the two branches are
    /// swapped, because the generic loop's answer for this input is the
    /// digits. A test that only checked "not the raw name" would pass against
    /// the broken order.
    func testTempLabelBranchPrecedesGenericPrefixStrip() {
        let out = cleanContextName("__temp__1756789012")
        XCTAssertEqual(out, "Temporary playlist")
        XCTAssertNotEqual(out, "1756789012",
                          "generic strip loop won the race; the label branch must precede it")
    }

    /// A user's own playlist that merely CONTAINS the token is not plumbing.
    /// Matching is by prefix, so it is untouched in Now Playing.
    func testCleanContextNameLeavesNonPrefixedUserPlaylistAlone() {
        XCTAssertEqual(cleanContextName("my __temp__ mix"), "my __temp__ mix")
        XCTAssertEqual(cleanContextName("Best of __temp__"), "Best of __temp__")
    }
    func testGeniusClearsWhenRealPlaylistTakesOver() {
        // Within the grace window: keep it (post-trigger lag still shows old ctx).
        XCTAssertFalse(geniusShouldClear(elapsedSinceTrigger: 1, hasAppQueue: false, contextName: "Friday Mix"))
        // After grace, a real playlist context means Genius is over.
        XCTAssertTrue(geniusShouldClear(elapsedSinceTrigger: 5, hasAppQueue: false, contextName: "Friday Mix"))
        // Library context after grace = still Genius/library — keep it.
        XCTAssertFalse(geniusShouldClear(elapsedSinceTrigger: 5, hasAppQueue: false, contextName: "Music"))
        // An app-owned queue always wins immediately.
        XCTAssertTrue(geniusShouldClear(elapsedSinceTrigger: 0, hasAppQueue: true, contextName: "Music"))
    }
}

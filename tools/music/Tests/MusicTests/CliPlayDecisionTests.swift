import XCTest
@testable import music

final class CliPlayDecisionTests: XCTestCase {
    private func row(_ index: Int, name: String = "T", cloud: String = "unknown",
                     disc: Int = 0, track: Int = 0) -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: name, artist: "A", albumArtist: "A",
                        cloudStatus: cloud, disc: disc, track: track)
    }

    // MARK: decideAlbumPlay — CLI `play --album` twin of the TUI resolver

    /// The bug: the CLI picked minimum track number ignoring disc, so a
    /// multi-disc album could start on disc 2 (its track 1 enumerates first
    /// in library order).
    func testMultiDiscStartsOnDiscOne() {
        let rows = [
            row(50, name: "D2T1", disc: 2, track: 1),   // library order first
            row(51, name: "D1T2", disc: 1, track: 2),
            row(52, name: "D1T1", disc: 1, track: 1),
        ]
        XCTAssertEqual(decideAlbumPlay(rows, query: "Anything"), .play(rows: rows, position: 52, playable: 3, matched: 3))
    }

    /// The bug: an unplayable first track (prerelease) made `play` silently
    /// no-op while the CLI reported the still-playing old track as success.
    func testUnplayableFirstTrackIsSkipped() {
        let rows = [
            row(10, name: "T1", cloud: "prerelease", disc: 1, track: 1),
            row(11, name: "T2", disc: 1, track: 2),
        ]
        XCTAssertEqual(decideAlbumPlay(rows, query: "Anything"), .play(rows: rows, position: 11, playable: 1, matched: 2))
    }

    func testNoMatchesIsNotFound() {
        XCTAssertEqual(decideAlbumPlay([], query: "Anything"), .notFound)
    }

    func testAllUnplayableIsNonePlayable() {
        let rows = [
            row(10, cloud: "prerelease", disc: 1, track: 1),
            row(11, cloud: "removed", disc: 1, track: 2),
        ]
        XCTAssertEqual(decideAlbumPlay(rows, query: "Anything"), .nonePlayable(matched: 2))
    }

    // MARK: §16.6 — bounded album resolution: grouping and the broad-query regression

    func testIsBlankAlbumQueryRejectsEmptyAndWhitespace() {
        XCTAssertTrue(isBlankAlbumQuery(""))
        XCTAssertTrue(isBlankAlbumQuery("   "))
        XCTAssertTrue(isBlankAlbumQuery("\n\t "))
        XCTAssertFalse(isBlankAlbumQuery("Moon Safari"))
        XCTAssertFalse(isBlankAlbumQuery(" x "))
    }

    private func albumRow(_ index: Int, artist: String = "A", album: String,
                          disc: Int = 1, track: Int = 1, cloud: String = "subscription") -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: "T\(index)", artist: artist, albumArtist: artist,
                        cloudStatus: cloud, disc: disc, track: track, album: album)
    }

    func testGroupRowsByAlbumGroupsCaseAndWhitespaceDriftTogether() {
        let rows = [
            albumRow(1, album: "Moon Safari"),
            albumRow(2, album: "  moon   safari "),   // same album, drifted casing/whitespace
            albumRow(3, album: "Moon Safari Live"),   // a genuinely different album
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rows.map(\.index), [1, 2])
        XCTAssertEqual(groups[1].rows.map(\.index), [3])
    }

    /// Two different artists' albums that merely share a title must never be
    /// merged into one container.
    func testGroupRowsByAlbumKeepsSameTitledAlbumsByDifferentArtistsSeparate() {
        let rows = [
            albumRow(1, artist: "Artist A", album: "Greatest Hits"),
            albumRow(2, artist: "Artist B", album: "Greatest Hits"),
        ]
        XCTAssertEqual(groupRowsByAlbum(rows).count, 2)
    }

    /// §16.6's broad-query regression: `music play --album "live"` runs a
    /// bare `album contains "live"` fetch that can match many distinct
    /// albums. Before this fix every matched row became one flat set and one
    /// container was built spanning all of them. Now it must refuse.
    func testDecideAlbumPlayRefusesABroadQueryThatSpansMultipleAlbums() {
        let rows = [
            albumRow(1, artist: "A", album: "Live in NYC"),
            albumRow(2, artist: "B", album: "Live from Tokyo"),
            albumRow(3, artist: "C", album: "Alive"),
        ]
        switch decideAlbumPlay(rows, query: "live") {
        case .ambiguous(let albums):
            XCTAssertEqual(Set(albums), Set(["Live in NYC", "Live from Tokyo", "Alive"]))
        default:
            XCTFail("a broad query spanning multiple distinct albums must be refused, not merged into one container")
        }
    }

    /// A unique exact normalised match wins even when a loose match also
    /// exists — and, critically, the loose match's rows must never leak in.
    func testDecideAlbumPlayPrefersAUniqueExactNormalisedMatch() {
        let rows = [
            albumRow(1, artist: "Air", album: "Moon Safari"),
            albumRow(2, artist: "X", album: "Moon Safari Live"),
        ]
        switch decideAlbumPlay(rows, query: "Moon Safari") {
        case .play(let chosenRows, let position, let playable, let matched):
            XCTAssertEqual(position, 1)
            XCTAssertEqual(playable, 1)
            XCTAssertEqual(matched, 1, "only the exact match's own row may be used")
            XCTAssertEqual(chosenRows.map(\.index), [1], "only the exact match's own row may reach the container")
        default:
            XCTFail("a unique exact normalised match must resolve, not fail ambiguous")
        }
    }

    /// No exact match, but the query resolves to exactly one distinct album:
    /// it plays.
    func testDecideAlbumPlayResolvesWhenQueryLooselyMatchesExactlyOneDistinctAlbum() {
        let rows = [
            albumRow(1, artist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Air", album: "Moon Safari", track: 2),
        ]
        switch decideAlbumPlay(rows, query: "moon") {
        case .play(let chosenRows, let position, let playable, let matched):
            XCTAssertEqual(position, 1)
            XCTAssertEqual(playable, 2)
            XCTAssertEqual(matched, 2)
            XCTAssertEqual(chosenRows.map(\.index), [1, 2])
        default:
            XCTFail("a loose query resolving to exactly one distinct album must play it")
        }
    }

    /// §17.4: renamed from `testDecideAlbumPlayNeverCountsTracksFromMoreThanOneAlbum`,
    /// which asserted only on `matched`/`playable` — counts that happened to
    /// look right even while §17.1's defect made the actual container-seeding
    /// guarantee false, because `decideAlbumPlay` never seeds anything.
    /// This proves what `decideAlbumPlay` itself actually guarantees: its
    /// `.play` payload's `rows` are the exact match's own rows only. It does
    /// NOT prove the container is seeded correctly — that requires the rows
    /// to actually reach `playBoundedAlbum`'s build script, which is a
    /// separate, real seeding-level test:
    /// `BoundedAlbumPlayTests.testExactMatchSeedsOnlyItsOwnAlbumEvenWhenAnotherAlbumSharesTheQuery`.
    func testDecideAlbumPlayChosenRowsExcludeTheOtherAlbum() {
        let rows = [
            albumRow(1, artist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Air", album: "Moon Safari", track: 2),
            albumRow(3, artist: "X", album: "Moon Safari Deluxe", track: 1),
            albumRow(4, artist: "X", album: "Moon Safari Deluxe", track: 2),
            albumRow(5, artist: "X", album: "Moon Safari Deluxe", track: 3),
        ]
        switch decideAlbumPlay(rows, query: "Moon Safari") {
        case .play(let chosenRows, _, let playable, let matched):
            XCTAssertEqual(playable, 2, "must be the exact match's own 2 tracks, not all 5")
            XCTAssertEqual(matched, 2)
            XCTAssertEqual(Set(chosenRows.map(\.index)), [1, 2],
                          "only the exact match's own rows may reach the container, never the other album's")
        default:
            XCTFail("a unique exact normalised match must resolve")
        }
    }

    // MARK: firstPlayablePosition — `playLocalSong` twin of the same filter

    func testFirstPlayableSkipsUnplayableInFetchOrder() {
        let rows = [
            row(20, cloud: "prerelease"),
            row(21, cloud: "removed"),
            row(22),
        ]
        XCTAssertEqual(firstPlayablePosition(rows), 22)
    }

    /// Song search keeps fetch order — no album sort (matches span albums).
    func testFirstPlayableKeepsFetchOrder() {
        let rows = [row(30, disc: 2, track: 9), row(31, disc: 1, track: 1)]
        XCTAssertEqual(firstPlayablePosition(rows), 30)
    }

    func testFirstPlayableNilWhenNonePlayable() {
        XCTAssertNil(firstPlayablePosition([row(40, cloud: "prerelease")]))
        XCTAssertNil(firstPlayablePosition([]))
    }
}

extension CliPlayDecisionTests {

    func testOutcomeMessages() {
        XCTAssertNil(albumOutcomeMessage(.playing, title: "Moon Safari"))
        XCTAssertEqual(albumOutcomeMessage(.notFound, title: "Moon Safari"),
                       "No albums found matching 'Moon Safari'")
        XCTAssertEqual(albumOutcomeMessage(.nonePlayable(matched: 4), title: "X"),
                       "Found 4 track(s) matching 'X', but none are playable yet (pre-release or removed).")
    }

    /// Each failure names its own stage, so a bug report can tell them apart.
    /// `containerRemoved` doubles the case count: a message must never claim a
    /// cleanup that did not happen, so true and false read differently.
    func testFailureMessagesAreDistinct() {
        let msgs = [
            albumOutcomeMessage(.buildFailed(containerRemoved: true), title: "X"),
            albumOutcomeMessage(.buildFailed(containerRemoved: false), title: "X"),
            albumOutcomeMessage(.playFailed(containerRemoved: true), title: "X"),
            albumOutcomeMessage(.playFailed(containerRemoved: false), title: "X"),
            albumOutcomeMessage(.watcherFailed(containerRemoved: true), title: "X"),
            albumOutcomeMessage(.watcherFailed(containerRemoved: false), title: "X"),
        ].compactMap { $0 }
        XCTAssertEqual(Set(msgs).count, 6, "each failure stage/removal combination needs a distinct message")
        XCTAssertTrue(msgs.allSatisfy { $0.contains("X") })
    }

    /// A `false` removal must never claim the container was removed, and must
    /// point the user at the cleanup command that will collect it.
    func testFalseRemovalDoesNotClaimRemovalAndPointsToCleanup() {
        let msgs = [
            albumOutcomeMessage(.buildFailed(containerRemoved: false), title: "X")!,
            albumOutcomeMessage(.playFailed(containerRemoved: false), title: "X")!,
            albumOutcomeMessage(.watcherFailed(containerRemoved: false), title: "X")!,
        ]
        for msg in msgs {
            XCTAssertFalse(msg.lowercased().contains("removed"), "false removal must not claim removal: \(msg)")
            XCTAssertTrue(msg.contains("music playlist cleanup"), "false removal must point at cleanup: \(msg)")
        }
    }
}

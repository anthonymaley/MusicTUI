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
        XCTAssertEqual(decideAlbumPlay(rows, query: "Anything"), .play(rows: rows, displayName: "", position: 52, playable: 3, matched: 3))
    }

    /// The bug: an unplayable first track (prerelease) made `play` silently
    /// no-op while the CLI reported the still-playing old track as success.
    func testUnplayableFirstTrackIsSkipped() {
        let rows = [
            row(10, name: "T1", cloud: "prerelease", disc: 1, track: 1),
            row(11, name: "T2", disc: 1, track: 2),
        ]
        XCTAssertEqual(decideAlbumPlay(rows, query: "Anything"), .play(rows: rows, displayName: "", position: 11, playable: 1, matched: 2))
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

    private func albumRow(_ index: Int, artist: String = "A", albumArtist: String? = nil, album: String,
                          disc: Int = 1, track: Int = 1, cloud: String = "subscription") -> LibraryAlbumRow {
        LibraryAlbumRow(index: index, name: "T\(index)", artist: artist, albumArtist: albumArtist ?? artist,
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

    // MARK: §17.3 — compatible album-artist metadata collapses

    /// The album-artist field is not reliably uniform within one real album:
    /// commonly empty on locally added tracks. Before this fix, a genuine
    /// album with a mix of empty and populated album-artist credits split
    /// into two groups and returned an unactionable `.ambiguous` naming the
    /// same title twice. One side empty is a compatible pair, so it must
    /// collapse into ONE group carrying every row.
    func testGroupRowsByAlbumCollapsesEmptyAlbumArtistIntoAPopulatedOne() {
        let rows = [
            albumRow(1, artist: "Air", albumArtist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Air", albumArtist: "", album: "Moon Safari", track: 2),   // locally added, no album artist
            albumRow(3, artist: "Air", albumArtist: "Air", album: "Moon Safari", track: 3),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 1, "an empty album-artist credit must collapse into the one real album, not split it")
        XCTAssertEqual(Set(groups[0].rows.map(\.index)), [1, 2, 3])
    }

    /// §17.1/§16.6 must still hold after the collapse: `decideAlbumPlay`
    /// resolves and plays the WHOLE collapsed album, not a partial group.
    func testDecideAlbumPlayResolvesAnAlbumWithMixedEmptyAndPopulatedAlbumArtist() {
        let rows = [
            albumRow(1, artist: "Air", albumArtist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Air", albumArtist: "", album: "Moon Safari", track: 2),
        ]
        switch decideAlbumPlay(rows, query: "Moon Safari") {
        case .play(let chosenRows, _, _, let playable, let matched):
            XCTAssertEqual(playable, 2)
            XCTAssertEqual(matched, 2)
            XCTAssertEqual(Set(chosenRows.map(\.index)), [1, 2])
        default:
            XCTFail("compatible (empty vs populated) album-artist credits must collapse and play, not go ambiguous")
        }
    }

    /// The other direction, required by §17.3: two GENUINELY different albums
    /// that merely share a title must stay split and remain ambiguous — the
    /// compatibility rule must never merge unrelated albums just because they
    /// share a title.
    func testGroupRowsByAlbumKeepsGenuinelyDifferentAlbumArtistsSplit() {
        let rows = [
            albumRow(1, artist: "Artist A", albumArtist: "Artist A", album: "Greatest Hits"),
            albumRow(2, artist: "Artist B", albumArtist: "Artist B", album: "Greatest Hits"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 2, "genuinely different album artists sharing a title must never collapse")
    }

    func testDecideAlbumPlayStaysAmbiguousForGenuinelyDifferentAlbumArtists() {
        let rows = [
            albumRow(1, artist: "Artist A", albumArtist: "Artist A", album: "Greatest Hits"),
            albumRow(2, artist: "Artist B", albumArtist: "Artist B", album: "Greatest Hits"),
        ]
        switch decideAlbumPlay(rows, query: "Greatest Hits") {
        case .ambiguous:
            break
        default:
            XCTFail("genuinely different albums sharing a title must stay split and ambiguous")
        }
    }

    // MARK: §18.3 — an empty album-artist credit is not evidence of sameness

    /// THE actual defect §18.3 corrects: §17.3 treated "either credit empty"
    /// as unconditionally compatible, so a locally ripped album with a blank
    /// album-artist credit merged with ANY same-titled album, including one
    /// by a completely unrelated artist — bounded, silent, no ambiguity
    /// prompt. A blank credit with no matching track-artist evidence must
    /// stay split.
    func testGroupRowsByAlbumKeepsBlankAlbumArtistSplitFromAnUnrelatedArtistSharingATitle() {
        let rows = [
            albumRow(1, artist: "Local Rip", albumArtist: "", album: "Greatest Hits"),
            albumRow(2, artist: "Queen", albumArtist: "Queen", album: "Greatest Hits"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 2,
                       "a blank album-artist credit alone is not evidence of sameness")
    }

    func testDecideAlbumPlayStaysAmbiguousForBlankAlbumArtistAgainstAnUnrelatedArtist() {
        let rows = [
            albumRow(1, artist: "Local Rip", albumArtist: "", album: "Greatest Hits"),
            albumRow(2, artist: "Queen", albumArtist: "Queen", album: "Greatest Hits"),
        ]
        switch decideAlbumPlay(rows, query: "Greatest Hits") {
        case .ambiguous:
            break
        default:
            XCTFail("an unrelated blank-credit album sharing a title must not silently merge and play")
        }
    }

    /// The genuine collapse still works: when the blank group's OWN rows
    /// agree on one track artist, and that artist matches the other group's
    /// credit, that IS real evidence — the same idiom `selectArtistTracks`
    /// already uses (match on either credit). A blank-credit "Moon Safari"
    /// whose tracks are credited to "Air" still collapses with an "Air"
    /// group.
    func testGroupRowsByAlbumCollapsesWhenTheBlankGroupsTrackArtistMatchesTheOtherGroup() {
        let rows = [
            albumRow(1, artist: "Air", albumArtist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Air", albumArtist: "", album: "Moon Safari", track: 2),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 1, "the blank group's own track artist is real evidence when it agrees")
        XCTAssertEqual(Set(groups[0].rows.map(\.index)), [1, 2])
    }

    /// If the blank group's own rows don't even agree with EACH OTHER on one
    /// track artist, there is still no single usable signal, and it must not
    /// collapse — falling back to "no evidence" rather than picking one row
    /// arbitrarily.
    func testGroupRowsByAlbumDoesNotCollapseWhenTheBlankGroupsOwnTrackArtistsDisagree() {
        let rows = [
            albumRow(1, artist: "Air", albumArtist: "Air", album: "Moon Safari", track: 1),
            albumRow(2, artist: "Someone Else", albumArtist: "", album: "Moon Safari", track: 2),
            albumRow(3, artist: "Yet Another", albumArtist: "", album: "Moon Safari", track: 3),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 2,
                       "a blank group whose own rows disagree on track artist carries no single usable signal")
    }

    // MARK: §19 — containment is not identity (corrects §17.3/§18.3's subset arm)

    /// Inverts former `testGroupRowsByAlbumCollapsesASubsetCreditIntoTheFullerOne`
    /// (§17.3/§18.5): the subset arm used to collapse "Queen" into "Queen &
    /// David Bowie" on the reasoning that it is overwhelmingly a drifted
    /// collaboration credit. §19 closes that arm because the same shape
    /// ("Queen" token-prefixing "Queen & David Bowie") is indistinguishable
    /// from two different single artists whose names happen to share a
    /// token — see the Queen/Queen Latifah regression below. A subset credit
    /// must now stay split, same as a genuinely different one.
    func testGroupRowsByAlbumKeepsASubsetCreditSplitFromTheFullerOne() {
        let rows = [
            albumRow(1, artist: "Queen", albumArtist: "Queen", album: "Under Pressure"),
            albumRow(2, artist: "David Bowie", albumArtist: "Queen & David Bowie", album: "Under Pressure"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 2,
                       "a subset credit (\"Queen\") is not identical to the fuller one (\"Queen & David Bowie\") and must stay split")
    }

    /// THE regression §19 exists to close: two credits that merely share a
    /// leading token must never silently collapse into one container. Before
    /// this fix, `{"queen"}` being a subset of `{"queen", "latifah"}` merged
    /// *Greatest Hits* by Queen and *Greatest Hits* by Queen Latifah into one
    /// group, `exact.count == 1`, and one container was seeded with both
    /// albums — bounded and silent, no ambiguity prompt. Asserting the
    /// decision is `.ambiguous`, not just that the groups stayed separate,
    /// because the user-visible outcome (a resolvable prompt vs. a silent
    /// wrong-album container) is the point.
    func testDecideAlbumPlayStaysAmbiguousForATokenPrefixCreditPair() {
        let rows = [
            albumRow(1, artist: "Queen", albumArtist: "Queen", album: "Greatest Hits"),
            albumRow(2, artist: "Queen Latifah", albumArtist: "Queen Latifah", album: "Greatest Hits"),
        ]
        switch decideAlbumPlay(rows, query: "Greatest Hits") {
        case .ambiguous:
            break
        default:
            XCTFail("\"Queen\" being a token-subset of \"Queen Latifah\" must not silently merge two different artists' albums into one container")
        }
    }

    /// Genuine equality still collapses even when the two raw credit strings
    /// differ only by the punctuation `normalizeCredit` folds. This exercises
    /// the fallback path specifically: a blank-credit group's rows agree on
    /// one track artist written with "&", and the other group's own credit is
    /// the same artists written with a comma — different raw strings, equal
    /// after normalization, so they still collapse. (Two groups whose raw,
    /// unfolded album-artist credits are literally identical never reach this
    /// predicate at all — `groupRowsByAlbum`'s fine-grained key is already
    /// `normalizeCredit(albumArtist)`, so they land in the same group before
    /// the collapse step ever runs.)
    func testGroupRowsByAlbumCollapsesWhenEffectiveCreditsAreEqualOnlyAfterPunctuationNormalizes() {
        let rows = [
            albumRow(1, artist: "Queen & David Bowie", albumArtist: "", album: "Under Pressure"),
            albumRow(2, artist: "David Bowie", albumArtist: "Queen, David Bowie", album: "Under Pressure"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 1,
                       "credits equal only after normalizeCredit folds punctuation must still collapse")
        XCTAssertEqual(Set(groups[0].rows.map(\.index)), [1, 2])
    }

    // MARK: §17.3/§18.5 — a three-group bucket, previously untested

    /// Inverts former `testGroupRowsByAlbumCollapsesAThreeGroupBucketWhenEveryPairIsCompatible`
    /// (§17.3/§18.5): this was a classical-style credit chain, each credit
    /// superseding the last with an added performer, compatible only under
    /// the now-closed subset arm. Under §19's strict equality none of the
    /// three pairs are equal, so the all-or-nothing rule
    /// (`collapseCompatibleAlbumArtistGroups`) now keeps the whole bucket
    /// split rather than collapsing it.
    func testGroupRowsByAlbumKeepsAThreeGroupSubsetChainSplit() {
        let rows = [
            albumRow(1, artist: "Karajan", albumArtist: "Karajan", album: "Symphony No. 9"),
            albumRow(2, artist: "Karajan", albumArtist: "Karajan Berlin Philharmonic", album: "Symphony No. 9"),
            albumRow(3, artist: "Karajan", albumArtist: "Karajan Berlin Philharmonic Chorus", album: "Symphony No. 9"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 3,
                       "none of the three credits are strictly equal, so the bucket must stay split")
    }

    /// A three-group bucket with exactly one genuinely compatible pair must
    /// keep the WHOLE bucket split — the all-or-nothing rule documented on
    /// `collapseCompatibleAlbumArtistGroups` — never merge just the
    /// compatible pair and leave the third out, which could pick the wrong
    /// two rows to combine. Rows 1 and 2 reach the same effective credit,
    /// "air" — row 1 directly, row 2 via §18.3's track-artist fallback on
    /// its blank album-artist — so they are the compatible pair; row 3
    /// ("abba") is incompatible with both. This fixture replaces a former
    /// Queen / Queen & David Bowie / ABBA one that, under §19's strict
    /// string-equality rule, has every pair unequal: it kept asserting 3
    /// groups but for the wrong reason (`testGroupRowsByAlbumKeepsAThreeGroupSubsetChainSplit`
    /// above already covers "no pair is compatible"), so a pairwise-merging
    /// implementation of `collapseCompatibleAlbumArtistGroups` would have
    /// passed it silently. Only a fixture with a genuinely compatible pair
    /// can catch that mutation.
    func testGroupRowsByAlbumKeepsAThreeGroupBucketSplitWhenAnyPairIsIncompatible() {
        let rows = [
            albumRow(1, artist: "Air", albumArtist: "Air", album: "Anthology"),
            albumRow(2, artist: "Air", albumArtist: "", album: "Anthology"),   // effective credit "air" via §18.3 fallback
            albumRow(3, artist: "ABBA", albumArtist: "ABBA", album: "Anthology"),
        ]
        let groups = groupRowsByAlbum(rows)
        XCTAssertEqual(groups.count, 3,
                       "rows 1 and 2 are compatible (both effective credit \"air\"), but row 3 is not — the entire bucket must stay split, not merge the compatible pair alone")
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
        case .play(let chosenRows, _, let position, let playable, let matched):
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
        case .play(let chosenRows, _, let position, let playable, let matched):
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
        case .play(let chosenRows, _, _, let playable, let matched):
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

    /// §19.4: the message cannot know which of two problems the user is in
    /// — several genuinely distinct same-titled albums, or one album split
    /// across inconsistent album-artist metadata — so it must offer both
    /// remedies rather than implying it knows. Assert on the two remedies
    /// independently (not one fixed string), so this fails if either is
    /// dropped, alongside the pre-existing title list, the
    /// `(untitled album)` fallback, and the 8-item cap, all exercised at
    /// once by one payload of 10 albums with a blank title among the first
    /// eight.
    func testAmbiguousMessageOffersBothRemediesAndKeepsTheTitleList() {
        let albums = [""] + (1...9).map { "Album \($0)" }
        let msg = albumOutcomeMessage(.ambiguous(albums: albums), title: "X")!
        XCTAssertTrue(msg.contains("--artist"),
                      "must offer the --artist remedy for genuinely distinct same-titled albums: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("music"),
                      "must offer the fix-the-metadata-in-Music remedy for a metadata-split album: \(msg)")
        XCTAssertTrue(msg.contains("Album 1"), "must keep listing the matched titles: \(msg)")
        XCTAssertFalse(msg.contains("Album 9"), "must cap the listed titles at 8: \(msg)")
        XCTAssertTrue(msg.contains("2 more"), "must summarize what the cap dropped: \(msg)")
        XCTAssertTrue(msg.contains("(untitled album)"), "must fall back for a blank album title: \(msg)")
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

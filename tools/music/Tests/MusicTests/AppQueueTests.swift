// tools/music/Tests/MusicTests/AppQueueTests.swift
import XCTest
@testable import music

final class AppQueueTests: XCTestCase {
    private func makeQueue(_ count: Int, at index: Int = 1) -> AppQueue {
        AppQueue(
            playlistName: "P",
            tracks: (1...count).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) },
            currentIndex: index
        )
    }

    // MARK: - step

    func testStepAdvancesAndReturnsSourcePosition() {
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 2))
        let r = store.step(1)
        XCTAssertEqual(r?.playlist, "P")
        XCTAssertEqual(r?.position, 3)
        XCTAssertEqual(store.read()?.currentIndex, 3)
    }

    func testStepBackwardReachesTrackOne() {
        // The whole point of the app-owned queue: backward nav must not floor
        // mid-list the way Music's sticky resume position did.
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 2))
        XCTAssertEqual(store.step(-1)?.position, 1)
    }

    func testStepOffEitherEndReturnsNilAndKeepsPosition() {
        let store = AppQueueStore()
        store.set(makeQueue(3, at: 3))
        XCTAssertNil(store.step(1))
        XCTAssertEqual(store.read()?.currentIndex, 3, "a refused step must not move the queue")
        store.set(makeQueue(3, at: 1))
        XCTAssertNil(store.step(-1))
    }

    func testStepWithNoQueueIsNil() {
        XCTAssertNil(AppQueueStore().step(1))
    }

    // MARK: - jump

    func testJumpToAbsolutePosition() {
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 1))
        XCTAssertEqual(store.jump(to: 4)?.position, 4)
        XCTAssertEqual(store.read()?.currentIndex, 4)
    }

    func testJumpOutOfRangeIsNil() {
        let store = AppQueueStore()
        store.set(makeQueue(3, at: 1))
        XCTAssertNil(store.jump(to: 0))
        XCTAssertNil(store.jump(to: 4))
    }

    // MARK: - shuffled queues: play-order index vs source position

    func testShuffledQueueStepReturnsSourcePositionNotPlayOrder() {
        // Play order [3, 1, 2]: stepping from play-order 1 to 2 must play
        // SOURCE track 1 (`play track N of playlist` needs source positions).
        let tracks = [3, 1, 2].map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) }
        let store = AppQueueStore()
        store.set(AppQueue(playlistName: "P", tracks: tracks, currentIndex: 1))
        XCTAssertEqual(store.step(1)?.position, 1)
        XCTAssertEqual(store.step(1)?.position, 2)
    }

    // MARK: - window

    func testWindowMarksCurrentByPlayOrder() {
        let q = makeQueue(4, at: 3)
        let w = appQueueWindow(q)
        XCTAssertEqual(w.name, "P")
        XCTAssertEqual(w.tracks.count, 4)
        XCTAssertTrue(w.tracks[2].isCurrent)
        XCTAssertEqual(w.tracks.filter(\.isCurrent).count, 1)
        XCTAssertEqual(w.tracks[0].index, 1, "window indices are play-order positions for Enter-jump")
    }

    // MARK: - tolerant album matching (strict-clause fallback for artist drift)

    func testNormalizeCreditFoldsSeparatorPunctuation() {
        // Apple Music's display credit uses ", " where the local library stores
        // " & " (observed live on the pre-release "Mere Mortals" — Floating Points,
        // San Francisco Ballet Orchestra). Both must fold to one key so an exact
        // whose-clause miss can still be reconciled.
        XCTAssertEqual(
            normalizeCredit("Floating Points, San Francisco Ballet Orchestra"),
            normalizeCredit("Floating Points & San Francisco Ballet Orchestra"))
        // But genuinely different ensembles must NOT collapse together.
        XCTAssertNotEqual(
            normalizeCredit("Floating Points & San Francisco Ballet Orchestra"),
            normalizeCredit("Floating Points & San Francisco Symphony"))
    }

    func testParseLibraryAlbumRowsReadsAlbumArtistAndCloudStatus() {
        let fs = String(asFieldSep)
        let raw = "3\(fs)Movement 1 - Fire\(fs)Floating Points & SF Ballet\(fs)Floating Points & San Francisco Ballet Orchestra\(fs)prerelease\(fs)1\(fs)2\n"
                + "4\(fs)Movement 5 - Pandora’s Creation\(fs)FP\(fs)Floating Points & San Francisco Ballet Orchestra\(fs)subscription\(fs)1\(fs)6"
        let rows = parseLibraryAlbumRows(raw)
        XCTAssertEqual(rows.map(\.index), [3, 4])
        XCTAssertEqual(rows[1].name, "Movement 5 - Pandora’s Creation")
        XCTAssertEqual(rows[0].albumArtist, "Floating Points & San Francisco Ballet Orchestra")
        XCTAssertEqual(rows[0].cloudStatus, "prerelease")
        XCTAssertEqual(rows[1].cloudStatus, "subscription")
        XCTAssertEqual(rows.map(\.disc), [1, 1])
        XCTAssertEqual(rows.map(\.track), [2, 6])
    }

    func testParseLibraryAlbumRowsSkipsMalformed() {
        let fs = String(asFieldSep)
        // non-numeric index, blank line, a 5-field line (the pre-3.8.2 shape with
        // no disc/track), and non-numeric disc/track are all dropped
        let raw = "x\(fs)a\(fs)b\(fs)c\(fs)d\(fs)1\(fs)1\n\n7\(fs)five\(fs)field\(fs)line\(fs)subscription\n"
                + "8\(fs)a\(fs)b\(fs)c\(fs)subscription\(fs)one\(fs)two\n"
                + "9\(fs)Fire\(fs)FP\(fs)FP & SFBO\(fs)subscription\(fs)1\(fs)3"
        XCTAssertEqual(parseLibraryAlbumRows(raw).map(\.index), [9])
    }

    func testSortRowsByAlbumOrderSortsByTrackNumberNotLibraryOrder() {
        // The reported bug: the `whose` fetch yields tracks in Library position
        // order ("Mere Mortals" arrives Movement 2 first), so Play started
        // mid-album. Album order is the track number, not the fetch order.
        let rows = [
            LibraryAlbumRow(index: 40, name: "M2", artist: "FP", albumArtist: "FP", cloudStatus: "subscription", disc: 1, track: 2),
            LibraryAlbumRow(index: 41, name: "M1", artist: "FP", albumArtist: "FP", cloudStatus: "subscription", disc: 1, track: 1),
            LibraryAlbumRow(index: 39, name: "M3", artist: "FP", albumArtist: "FP", cloudStatus: "subscription", disc: 1, track: 3),
        ]
        XCTAssertEqual(sortRowsByAlbumOrder(rows).map(\.name), ["M1", "M2", "M3"])
    }

    func testSortRowsByAlbumOrderSortsDiscBeforeTrackAndTreatsUnsetDiscAsOne() {
        // Multi-disc albums play disc 1 end to end before disc 2. A disc number
        // of 0 (Music's value when none is set) means the only/first disc, so it
        // interleaves with disc 1 by track — not a phantom disc before it.
        let rows = [
            LibraryAlbumRow(index: 1, name: "d2t1", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 2, track: 1),
            LibraryAlbumRow(index: 2, name: "d0t2", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 0, track: 2),
            LibraryAlbumRow(index: 3, name: "d1t1", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 1, track: 1),
        ]
        XCTAssertEqual(sortRowsByAlbumOrder(rows).map(\.name), ["d1t1", "d0t2", "d2t1"])
    }

    func testSortRowsByAlbumOrderPutsUnknownTrackNumbersLastInFetchedOrder() {
        // A track number of 0 means Music has no number for the track; those
        // can't be placed in album order, so they follow the numbered tracks in
        // the order the fetch returned them rather than jumping to the front.
        let rows = [
            LibraryAlbumRow(index: 1, name: "unknownA", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 1, track: 0),
            LibraryAlbumRow(index: 2, name: "t2", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 1, track: 2),
            LibraryAlbumRow(index: 3, name: "unknownB", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 1, track: 0),
            LibraryAlbumRow(index: 4, name: "t1", artist: "X", albumArtist: "X", cloudStatus: "subscription", disc: 1, track: 1),
        ]
        XCTAssertEqual(sortRowsByAlbumOrder(rows).map(\.name), ["t1", "t2", "unknownA", "unknownB"])
    }

    func testOrderedPlayableAlbumTracksSortsThenFiltersKeepingMatchedCount() {
        // The resolver's single exit: sort into album order FIRST, then drop
        // unplayable tracks — and `matched` stays the pre-filter count so the
        // "Playing N of M" toast is unaffected by ordering.
        let rows = [
            LibraryAlbumRow(index: 5, name: "M2", artist: "FP", albumArtist: "FP", cloudStatus: "prerelease", disc: 1, track: 2),
            LibraryAlbumRow(index: 6, name: "M1", artist: "FP", albumArtist: "FP", cloudStatus: "subscription", disc: 1, track: 1),
            LibraryAlbumRow(index: 4, name: "M3", artist: "FP", albumArtist: "FP", cloudStatus: "subscription", disc: 1, track: 3),
        ]
        let res = orderedPlayableAlbumTracks(rows)
        XCTAssertEqual(res.tracks.map(\.name), ["M1", "M3"])
        XCTAssertEqual(res.tracks.map(\.index), [6, 4])
        XCTAssertEqual(res.matched, 3)
    }

    func testSelectAlbumTracksReturnsAllWhenOneAlbumArtist() {
        // The reported bug: every track shares one album artist, but the requested
        // artist string (from REST) matches none of them. A title-scoped fetch has
        // no ambiguity to resolve, so all of it must play.
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = [
            LibraryAlbumRow(index: 1, name: "M1", artist: "FP & Merks", albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "M2", artist: "FP & Adefris", albumArtist: aa, cloudStatus: "subscription"),
        ]
        let picked = selectAlbumTracks(rows, requestedArtist: "Floating Points, San Francisco Ballet Orchestra")
        XCTAssertEqual(picked.map(\.index), [1, 2])
    }

    func testSelectAlbumTracksDisambiguatesSameTitleCollisionByArtist() {
        // Two different albums both titled "Greatest Hits" in one library: play the
        // group whose album artist matches the requested one (punctuation-tolerant).
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "b", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 3, name: "c", artist: "TLC", albumArtist: "TLC", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectAlbumTracks(rows, requestedArtist: "Queen").map(\.index), [1, 2])
    }

    func testSelectAlbumTracksAmbiguousUnmatchedReturnsEmpty() {
        // A same-title collision where the requested artist matches neither group:
        // refuse to guess — a "couldn't load" beats playing the wrong album.
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "c", artist: "TLC", albumArtist: "TLC", cloudStatus: "subscription"),
        ]
        XCTAssertTrue(selectAlbumTracks(rows, requestedArtist: "Nirvana").isEmpty)
    }

    func testSelectAlbumTracksEmptyInputReturnsEmpty() {
        XCTAssertTrue(selectAlbumTracks([], requestedArtist: "X").isEmpty)
    }

    func testIsPlayableCloudStatus() {
        // Denylist, not allowlist: only genuinely-unavailable statuses are excluded,
        // so local files (unknown / other) and streamable tracks stay playable.
        XCTAssertFalse(isPlayableCloudStatus("prerelease"))          // verified live: play track no-ops
        XCTAssertFalse(isPlayableCloudStatus("no longer available"))
        XCTAssertFalse(isPlayableCloudStatus("removed"))
        XCTAssertFalse(isPlayableCloudStatus("Prerelease"))          // case-insensitive
        XCTAssertTrue(isPlayableCloudStatus("subscription"))
        XCTAssertTrue(isPlayableCloudStatus("purchased"))
        XCTAssertTrue(isPlayableCloudStatus("unknown"))              // local files must not be dropped
        XCTAssertTrue(isPlayableCloudStatus(""))
    }

    func testPrereleaseAlbumResolvesToPlayableSubsetOnly() {
        // The exact Mere Mortals scenario at the unit level: 14 title-matched rows,
        // one album artist, only Movements 5 & 10 streamable — the rest prerelease.
        // Disambiguation keeps the whole album; the playability filter leaves the two
        // that can actually play, and the matched count (14) survives for "N of M".
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = (1...14).map { i in
            LibraryAlbumRow(index: i, name: "Movement \(i)", artist: "FP", albumArtist: aa,
                            cloudStatus: (i == 5 || i == 10) ? "subscription" : "prerelease")
        }
        let album = selectAlbumTracks(rows, requestedArtist: "Floating Points, San Francisco Ballet Orchestra")
        XCTAssertEqual(album.count, 14, "one album — disambiguation keeps all 14")
        let playable = album.filter { isPlayableCloudStatus($0.cloudStatus) }
        XCTAssertEqual(playable.map(\.index), [5, 10], "only the two subscription movements can play")
    }

    // MARK: - seek parsing (CLI)

    func testParseSeekTargets() {
        XCTAssertEqual(parseSeekTarget("+30")?.delta, 30)
        XCTAssertEqual(parseSeekTarget("-15")?.delta, -15)
        XCTAssertEqual(parseSeekTarget("90")?.absolute, 90)
        XCTAssertEqual(parseSeekTarget("1:30")?.absolute, 90)
        XCTAssertEqual(parseSeekTarget("0:05")?.absolute, 5)
        XCTAssertNil(parseSeekTarget("abc"))
        XCTAssertNil(parseSeekTarget("1:75"))
        XCTAssertNil(parseSeekTarget(""))
    }

    // MARK: Artist-list playback (the same credit drift 3.8.1 fixed for albums)

    func testPrimaryCreditComponentSplitsOnBothSeparators() {
        // The pre-filter token for the fallback fetch. Both punctuation styles of
        // the same credit must yield the same leading artist, or the `contains`
        // clause misses the very rows the fallback exists to find.
        XCTAssertEqual(primaryCreditComponent("Floating Points, San Francisco Ballet Orchestra"), "Floating Points")
        XCTAssertEqual(primaryCreditComponent("Floating Points & San Francisco Ballet Orchestra"), "Floating Points")
        XCTAssertEqual(primaryCreditComponent("Floating Points, Cordula Merks & Victor Avdienko"), "Floating Points")
        XCTAssertEqual(primaryCreditComponent("Radiohead"), "Radiohead")
        XCTAssertEqual(primaryCreditComponent("  Aphex Twin  "), "Aphex Twin")
        XCTAssertEqual(primaryCreditComponent(""), "")
    }

    func testSelectArtistTracksMatchesViaAlbumArtistWhenTrackArtistsDiffer() {
        // The live repro: every movement credits a different soloist, so no track
        // `artist` equals the requested credit, but `album artist` is uniform and
        // does (once punctuation is folded). All four must play.
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = [
            LibraryAlbumRow(index: 1, name: "M1", artist: "Floating Points & Cordula Merks", albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "M2", artist: "Floating Points & Miriam Adefris", albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 3, name: "M3", artist: aa, albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 4, name: "M4", artist: "Floating Points, Cordula Merks & Victor Avdienko", albumArtist: aa, cloudStatus: "subscription"),
        ]
        let picked = selectArtistTracks(rows, requestedArtist: "Floating Points, San Francisco Ballet Orchestra")
        XCTAssertEqual(picked.map(\.index), [1, 2, 3, 4])
    }

    func testSelectArtistTracksMatchesViaTrackArtist() {
        // A compilation: the album artist is "Various Artists" but the track artist
        // is the requested one. That track belongs to the artist; the others don't.
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Kerri Chandler", albumArtist: "Various Artists", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "b", artist: "Moodymann", albumArtist: "Various Artists", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectArtistTracks(rows, requestedArtist: "Kerri Chandler").map(\.index), [1])
    }

    func testSelectArtistTracksDoesNotOverMatchOnSharedPrimaryCredit() {
        // The `contains` pre-filter is deliberately loose, so the Swift filter has to
        // be strict: a solo artist and a collaboration sharing a leading name are
        // separate entries in the Artists list and must not bleed into each other.
        let rows = [
            LibraryAlbumRow(index: 1, name: "solo", artist: "Floating Points", albumArtist: "Floating Points", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "collab", artist: "Floating Points & Pharoah Sanders", albumArtist: "Floating Points & Pharoah Sanders", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectArtistTracks(rows, requestedArtist: "Floating Points").map(\.index), [1])
        XCTAssertEqual(selectArtistTracks(rows, requestedArtist: "Floating Points, Pharoah Sanders").map(\.index), [2])
    }

    func testSelectArtistTracksEmptyWhenNothingMatches() {
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
        ]
        XCTAssertTrue(selectArtistTracks(rows, requestedArtist: "TLC").isEmpty)
    }

    func testSelectSongTrackFoldsCreditDrift() {
        // Song play has a title to scope by, so this mirrors the album fallback:
        // match the title, then resolve the artist punctuation-tolerantly.
        let rows = [
            LibraryAlbumRow(index: 7, name: "Movement 10", artist: "Floating Points, Cordula Merks & Victor Avdienko",
                            albumArtist: "Floating Points & San Francisco Ballet Orchestra", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectSongTrack(rows, requestedArtist: "Floating Points & San Francisco Ballet Orchestra")?.index, 7)
        XCTAssertNil(selectSongTrack(rows, requestedArtist: "Aphex Twin"))
    }

    func testSelectSongTrackRefusesRatherThanGuessOnUnfoldableDrift() {
        // Deliberate: a lone title match is NOT enough. If the credit drifts in a way
        // normalizeCredit can't fold, refuse and let the caller error, rather than
        // play a same-titled song by someone else. Same "refuse to guess" rule as
        // selectAlbumTracks. This is still strictly better than the old behaviour,
        // where `name is T and artist is A` failed on punctuation drift too.
        let rows = [
            LibraryAlbumRow(index: 3, name: "Idioteque", artist: "Radiohead", albumArtist: "Radiohead", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectSongTrack(rows, requestedArtist: "Radiohead")?.index, 3)
        XCTAssertNil(selectSongTrack(rows, requestedArtist: "Thom Yorke"))
    }

    func testArtistResolutionDropsUnplayableCloudStatuses() {
        // The second layer of the 3.8.1 bug applies here too: a pre-release track
        // silently no-ops on `play track`, so it must never enter an artist queue.
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = [
            LibraryAlbumRow(index: 1, name: "M1", artist: aa, albumArtist: aa, cloudStatus: "prerelease"),
            LibraryAlbumRow(index: 2, name: "M2", artist: aa, albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 3, name: "M3", artist: aa, albumArtist: aa, cloudStatus: "unknown"),
        ]
        let picked = selectArtistTracks(rows, requestedArtist: aa).filter { isPlayableCloudStatus($0.cloudStatus) }
        XCTAssertEqual(picked.map(\.index), [2, 3], "local files report 'unknown' and must stay playable")
    }
}

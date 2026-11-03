// tools/music/Tests/MusicTests/MarkedSetQueueTests.swift
import XCTest
@testable import music

/// Combined play, step 3: `markedSetQueue` turns the marked rows into ONE
/// identity-addressed `AppQueue`. Every reader is an injected fake; nothing
/// here reaches Music, osascript, the SpanDAC socket or ~/.config/music.
final class MarkedSetQueueTests: XCTestCase {

    private func entry(_ pid: String, _ name: String, album: String? = nil) -> TrackListEntry {
        persistentIDQueueEntry(persistentID: pid, name: name, artist: "Art", album: album)!
    }

    /// The marked "Chill" playlist's own persistent ID, captured at mark time.
    private static let chillID = "00000000000000F1"
    /// Another playlist's ID: one that took the name "Chill" after the mark.
    private static let otherID = "00000000000000F2"

    /// Fake readers over canned data, logging every read in order.
    private final class Readers {
        var albums: [String: AlbumResolution] = [:]
        /// Each playlist's tracks by its own persistent ID, the ONLY key a
        /// marked playlist is read by. `.some(nil)` is a read that did not
        /// answer; an ID with no entry is a playlist that no longer exists.
        var playlists: [String: [TrackListEntry]?] = [:]
        private(set) var log: [String] = []

        var readers: MarkedSetReaders {
            MarkedSetReaders(
                album: { title, artist in
                    self.log.append("album \(title) / \(artist)")
                    return self.albums[title] ?? AlbumResolution(tracks: [], matched: 0)
                },
                playlist: { pid in
                    self.log.append("playlist \(pid)")
                    guard let hit = self.playlists[pid] else { return .missing }
                    return hit.map { .tracks($0) }
                })
        }
    }

    private func mixedRig() -> Readers {
        let r = Readers()
        r.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                           entry("00000000000000A2", "Sexy Boy")], matched: 2)
        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop"), entry("00000000000000B2", "Angel")]
        r.albums["Mezzanine"] = AlbumResolution(tracks: [entry("00000000000000C1", "Risingson")], matched: 1)
        return r
    }

    private let mixed: [MarkedItem] = [.album(title: "Moon Safari", artist: "Air"),
                                       .playlist(id: MarkedSetQueueTests.chillID, name: "Chill"),
                                       .album(title: "Mezzanine", artist: "Massive Attack")]

    func testMixedSetPlaysInMarkOrder() throws {
        let r = mixedRig()
        let q = try markedSetQueue(mixed, shuffle: false, readers: r.readers)
        XCTAssertEqual(q.playlistName, persistentIDQueueSource, "addressed by persistent ID, never by a position")
        XCTAssertEqual(q.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["00000000000000A1", "00000000000000A2", "00000000000000B1", "00000000000000B2",
                        "00000000000000C1"])
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.contextLabel, "2 albums and 1 playlist")
        XCTAssertEqual(r.log, ["album Moon Safari / Air", "playlist 00000000000000F1",
                               "album Mezzanine / Massive Attack"],
                       "read in mark order, the playlist by the persistent ID its mark carries, with no name check")
    }

    func testASingleMarkIsLabelledByItsOwnName() throws {
        let r = mixedRig()
        XCTAssertEqual(try markedSetQueue([.playlist(id: Self.chillID, name: "Chill")], shuffle: false, readers: r.readers).contextLabel,
                       "Chill")
        XCTAssertEqual(try markedSetQueue([.album(title: "Moon Safari", artist: "Air")], shuffle: false,
                                          readers: r.readers).contextLabel, "Moon Safari")
        XCTAssertEqual(markedSetDisplayName([.playlist(id: "00000000000000E1", name: "A"),
                                             .playlist(id: "00000000000000E2", name: "B")]), "2 playlists")
        XCTAssertEqual(markedSetDisplayName([.album(title: "A", artist: "x"), .album(title: "B", artist: "y")]),
                       "2 albums")
    }

    func testShuffleKeepsEveryEntry() throws {
        let r = mixedRig()
        let ordered = try markedSetQueue(mixed, shuffle: false, readers: r.readers)
        let shuffled = try markedSetQueue(mixed, shuffle: true, readers: r.readers)
        XCTAssertEqual(shuffled.tracks.count, ordered.tracks.count)
        XCTAssertEqual(shuffled.tracks.map(\.index).sorted(), ordered.tracks.map(\.index).sorted(),
                       "every marked track, none twice, none dropped")
        XCTAssertEqual(shuffled.currentIndex, 1, "a shuffle plays from the top of its own order")
        XCTAssertEqual(shuffled.playlistName, persistentIDQueueSource)
    }

    func testOneFailedReadFailsTheWholePlay() {
        let r = mixedRig()
        r.playlists[Self.chillID] = .some(nil)       // the playlist read did not answer
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: r.readers)) { error in
            let message = (error as? ActionError)?.message ?? ""
            XCTAssertTrue(message.contains("'Chill'"), "names the item that failed: \(message)")
            XCTAssertTrue(message.contains("nothing played"), message)
        }
        XCTAssertFalse(r.log.contains("album Mezzanine / Massive Attack"), "stops at the first failure")

        let failedAlbum = mixedRig()
        failedAlbum.albums["Mezzanine"] = .readFailure
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: failedAlbum.readers)) { error in
            XCTAssertTrue(((error as? ActionError)?.message ?? "").contains("'Mezzanine'"))
        }

        let emptyAlbum = mixedRig()
        emptyAlbum.albums["Mezzanine"] = AlbumResolution(tracks: [], matched: 0)
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: emptyAlbum.readers),
                             "an album with nothing to play is never left out silently")
    }

    // MARK: - A marked playlist is its persistent ID, never its name

    /// The reviewer's case: "Chill" is marked, then renamed, and another
    /// playlist takes the name "Chill" before `p`. The play reads the marked
    /// playlist by the ID the mark captured, and never the one now called
    /// "Chill".
    func testARenamedMarkedPlaylistIsReadByItsOriginalIDNeverTheOneThatTookItsName() throws {
        let r = mixedRig()
        // The original, renamed since the mark: still the same ID.
        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop")]
        // The newcomer that now carries the name "Chill".
        r.playlists[Self.otherID] = [entry("00000000000000D1", "Not This")]
        let q = try markedSetQueue([.playlist(id: Self.chillID, name: "Chill")], shuffle: false, readers: r.readers)
        XCTAssertEqual(q.tracks.map { persistentIDOfQueueEntry($0.index) }, ["00000000000000B1"])
        XCTAssertEqual(r.log, ["playlist \(Self.chillID)"], "only the marked ID was read")
        XCTAssertFalse(r.log.contains("playlist \(Self.otherID)"), "the playlist that took the name was read")
    }

    /// The marked ID is gone at play time: the play refuses, naming the
    /// playlist, and reads no other playlist in its place.
    func testAMarkedPlaylistThatIsGoneRefusesAndReadsNoOther() {
        let r = mixedRig()
        r.playlists = [Self.otherID: [entry("00000000000000D1", "Not This")]]   // a namesake, not the marked one
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: r.readers)) { error in
            XCTAssertEqual((error as? ActionError)?.message,
                           "'Chill' is no longer in your playlists, so nothing played.")
        }
        XCTAssertEqual(r.log, ["album Moon Safari / Air", "playlist \(Self.chillID)"],
                       "one read of the marked ID, no other playlist, and nothing after it")
        XCTAssertEqual(markedPlaylistGoneLine("Chill"), "'Chill' is no longer in your playlists, so nothing played.")
    }

    // MARK: - A partly available album keeps its skipped count

    func testAPartlyAvailableAlbumCountsItsSkippedSongsAcrossTheSet() throws {
        let r = mixedRig()
        // Moon Safari: 3 matched, 2 playable. Mezzanine: 4 matched, 1 playable.
        r.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                           entry("00000000000000A2", "Sexy Boy")], matched: 3)
        r.albums["Mezzanine"] = AlbumResolution(tracks: [entry("00000000000000C1", "Risingson")], matched: 4)
        let plan = try markedSetPlan(mixed, shuffle: false, readers: r.readers)
        XCTAssertEqual(plan.queue.tracks.count, 5, "2 + 2 (playlist) + 1 queued")
        XCTAssertEqual(plan.matched, 9, "2 + 1 skipped, summed across the set; the playlist counts as matched in full")
        XCTAssertEqual(plan.notice, "5 of 9 are queued \u{2014} the rest aren't available yet.")
        XCTAssertEqual(plan.playingLine, "Playing 5 of 9 \u{2014} the rest aren't available yet.")
        XCTAssertEqual(plan.notice, partialAvailabilityNotice(queued: 5, matched: 9), "the single-album wording")
        XCTAssertEqual(plan.playingLine, partialAvailabilityPlayingLine(queued: 5, matched: 9))
        XCTAssertEqual(try markedSetQueue(mixed, shuffle: false, readers: r.readers), plan.queue)

        // Every matched track queued: no notice, no line.
        let full = try markedSetPlan(mixed, shuffle: false, readers: mixedRig().readers)
        XCTAssertEqual(full.matched, full.queue.tracks.count)
        XCTAssertNil(full.notice)
        XCTAssertNil(full.playingLine)
    }

    // MARK: - A song in two marked items plays once, at its first position

    /// Moon Safari and Chill share "Sexy Boy" (A2): it plays once, where the
    /// album put it, and the playlist's copy is dropped.
    private func sharingRig() -> Readers {
        let r = mixedRig()
        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop"), entry("00000000000000A2", "Sexy Boy"),
                                     entry("00000000000000B2", "Angel")]
        return r
    }

    func testASongInTwoMarkedItemsPlaysOnceAtItsFirstPosition() throws {
        let q = try markedSetQueue(mixed, shuffle: false, readers: sharingRig().readers)
        XCTAssertEqual(q.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["00000000000000A1", "00000000000000A2", "00000000000000B1", "00000000000000B2",
                        "00000000000000C1"],
                       "the shared song plays once, at the album's position")
    }

    func testShuffleDeDuplicatesBeforeShuffling() throws {
        let q = try markedSetQueue(mixed, shuffle: true, readers: sharingRig().readers)
        XCTAssertEqual(q.tracks.count, 5)
        XCTAssertEqual(Set(q.tracks.map(\.index)).count, 5, "a shuffled set holds a shared song twice")
    }

    /// A removed duplicate is not a skipped song, but the play says it was
    /// removed: a fully available set carries only the repeated-song sentence,
    /// and a partly available one carries the availability sentence it carries
    /// without the duplicate, then the repeated-song sentence last.
    func testARemovedDuplicateIsNotCountedAsUnavailableButIsSaid() throws {
        let full = try markedSetPlan(mixed, shuffle: false, readers: sharingRig().readers)
        XCTAssertEqual(full.matched, 5)
        XCTAssertEqual(full.notice, "1 repeated song plays once.", "a duplicate was reported as a song not available")
        XCTAssertEqual(full.playingLine, "Playing '2 albums and 1 playlist' on MusicTUI. 1 repeated song plays once.")

        // Moon Safari: 3 matched, 2 playable. Chill shares A2. The same
        // availability sentence as the same set without the shared song.
        let partly = sharingRig()
        partly.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                                entry("00000000000000A2", "Sexy Boy")], matched: 3)
        let plan = try markedSetPlan(mixed, shuffle: false, readers: partly.readers)
        XCTAssertEqual(plan.queue.tracks.count, 5)
        XCTAssertEqual(plan.matched, 6)
        XCTAssertEqual(plan.notice,
                       "5 of 6 are queued \u{2014} the rest aren't available yet. 1 repeated song plays once.")
        XCTAssertEqual(plan.playingLine,
                       "Playing 5 of 6 \u{2014} the rest aren't available yet. 1 repeated song plays once.")
    }

    /// A song repeated inside one marked playlist: every entry after the first
    /// is counted, one sentence, plural form.
    func testARepeatInsideOnePlaylistIsCountedAndSaid() throws {
        let r = Readers()
        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop"), entry("00000000000000B2", "Angel"),
                                     entry("00000000000000B1", "Teardrop"), entry("00000000000000B2", "Angel"),
                                     entry("00000000000000B1", "Teardrop")]
        let plan = try markedSetPlan([.playlist(id: Self.chillID, name: "Chill")], shuffle: false, readers: r.readers)
        XCTAssertEqual(plan.queue.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["00000000000000B1", "00000000000000B2"])
        XCTAssertEqual(plan.notice, "3 repeated songs play once.")
        XCTAssertEqual(plan.playingLine, "Playing 'Chill' on MusicTUI. 3 repeated songs play once.")

        r.playlists[Self.chillID] = [entry("00000000000000B1", "Teardrop"), entry("00000000000000B1", "Teardrop")]
        let one = try markedSetPlan([.playlist(id: Self.chillID, name: "Chill")], shuffle: false, readers: r.readers)
        XCTAssertEqual(one.notice, "1 repeated song plays once.")
    }

    /// Nothing repeated: the notice and the line are what they were.
    func testASetWithNoRepeatSaysNothingOfRepeats() throws {
        let plan = try markedSetPlan(mixed, shuffle: false, readers: mixedRig().readers)
        XCTAssertNil(plan.notice)
        XCTAssertNil(plan.playingLine)
    }

    func testNothingMarkedRefuses() {
        XCTAssertThrowsError(try markedSetQueue([], shuffle: false, readers: Readers().readers))
    }

    func testContinuationIsBounded() throws {
        let r = mixedRig()
        let q = try markedSetQueue(mixed, shuffle: false, readers: r.readers)
        // The NBSP-suffixed source reads as the library it plays from: the
        // end-of-queue continuation keeps to these tracks under the set's own
        // label, and never looks a playlist up by name.
        XCTAssertTrue(isLibraryContextName(q.playlistName))
        XCTAssertEqual(continuationSource(for: q),
                       .bounded(label: "2 albums and 1 playlist", source: persistentIDQueueSource, tracks: q.tracks))
        XCTAssertEqual(continuationShuffleTracks(continuationSource(for: q))?.map(\.index).sorted(),
                       q.tracks.map(\.index).sorted())
    }
}

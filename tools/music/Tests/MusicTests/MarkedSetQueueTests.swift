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

    /// Fake readers over canned data, logging every read in order.
    private final class Readers {
        var albums: [String: AlbumResolution] = [:]
        var playlists: [String: [TrackListEntry]?] = [:]
        var playlistCounts: [String: Int?] = [:]
        /// Each playlist's own persistent ID, by name: what the name check
        /// resolves, and the ONLY key the track read is addressed by.
        var playlistIDs: [String: String] = ["Chill": "00000000000000F1"]
        private(set) var log: [String] = []

        var readers: MarkedSetReaders {
            MarkedSetReaders(
                album: { title, artist in
                    self.log.append("album \(title) / \(artist)")
                    return self.albums[title] ?? AlbumResolution(tracks: [], matched: 0)
                },
                playlistID: { name in
                    self.log.append("count \(name)")
                    if let c = self.playlistCounts[name] {
                        guard let c else { return nil }
                        if c == 0 { return .notFound }
                        if c > 1 { return .duplicated(count: c) }
                    }
                    guard self.playlists[name] != nil, let pid = self.playlistIDs[name] else { return .notFound }
                    return .unique(persistentID: pid)
                },
                playlist: { pid in
                    self.log.append("playlist \(pid)")
                    guard let name = self.playlistIDs.first(where: { $0.value == pid })?.key else { return nil }
                    return self.playlists[name] ?? nil
                })
        }
    }

    private func mixedRig() -> Readers {
        let r = Readers()
        r.albums["Moon Safari"] = AlbumResolution(tracks: [entry("00000000000000A1", "La Femme d'Argent"),
                                                           entry("00000000000000A2", "Sexy Boy")], matched: 2)
        r.playlists["Chill"] = [entry("00000000000000B1", "Teardrop"), entry("00000000000000B2", "Angel")]
        r.albums["Mezzanine"] = AlbumResolution(tracks: [entry("00000000000000C1", "Risingson")], matched: 1)
        return r
    }

    private let mixed: [MarkedItem] = [.album(title: "Moon Safari", artist: "Air"),
                                       .playlist(name: "Chill"),
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
        XCTAssertEqual(r.log, ["album Moon Safari / Air", "count Chill", "playlist 00000000000000F1",
                               "album Mezzanine / Massive Attack"],
                       "read in mark order, the playlist by the persistent ID its name check resolved")
    }

    func testASingleMarkIsLabelledByItsOwnName() throws {
        let r = mixedRig()
        XCTAssertEqual(try markedSetQueue([.playlist(name: "Chill")], shuffle: false, readers: r.readers).contextLabel,
                       "Chill")
        XCTAssertEqual(try markedSetQueue([.album(title: "Moon Safari", artist: "Air")], shuffle: false,
                                          readers: r.readers).contextLabel, "Moon Safari")
        XCTAssertEqual(markedSetDisplayName([.playlist(name: "A"), .playlist(name: "B")]), "2 playlists")
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
        r.playlists["Chill"] = .some(nil)       // the playlist read did not answer
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

        let countFailed = mixedRig()
        countFailed.playlistCounts["Chill"] = .some(nil)
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: countFailed.readers)) { error in
            XCTAssertTrue(((error as? ActionError)?.message ?? "").contains("'Chill'"))
        }
        XCTAssertFalse(countFailed.log.contains { $0.hasPrefix("playlist ") }, "a failed name check reads no tracks")
    }

    func testADuplicatedPlaylistNameRefuses() {
        let r = mixedRig()
        r.playlistCounts["Chill"] = 2
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: r.readers)) { error in
            let message = (error as? ActionError)?.message ?? ""
            XCTAssertTrue(message.contains("'Chill'"), message)
        }
        XCTAssertFalse(r.log.contains { $0.hasPrefix("playlist ") }, "never guesses which of the two to read")

        let gone = mixedRig()
        gone.playlistCounts["Chill"] = 0
        XCTAssertThrowsError(try markedSetQueue(mixed, shuffle: false, readers: gone.readers)) { error in
            XCTAssertTrue(((error as? ActionError)?.message ?? "").contains("Couldn't find the playlist 'Chill'"))
        }
        XCTAssertFalse(gone.log.contains { $0.hasPrefix("playlist ") })
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

    func testTheNameCheckScriptOnlyReadsAndResolvesTheOnePlaylistsID() {
        let script = playlistIdentityScript("Chill \"Mix\"")
        XCTAssertTrue(script.contains("every playlist whose name is \"Chill \\\"Mix\\\"\""), script)
        XCTAssertTrue(script.contains("persistent ID of every playlist whose name is \"Chill \\\"Mix\\\"\""), script)
        XCTAssertTrue(script.contains("as list"), "one match can answer a bare value: \(script)")
        for word in ["make new", "duplicate", "delete", "set name"] {
            XCTAssertFalse(script.contains(word), word)
        }
        for word in ["before", "after", "active", "left"] {
            XCTAssertNil(script.range(of: "set \(word) to"), "reserved word as a variable: \(word)")
        }
        // A hostile name stays inside the literal.
        let hostile = "x\" & (do shell script \"id\") & \""
        XCTAssertFalse(playlistIdentityScript(hostile).contains("\"\(hostile)\""))
        XCTAssertTrue(playlistIdentityScript(hostile).contains(escapeAppleScriptString(hostile)))

        XCTAssertEqual(parsePlaylistIdentity("1\n00000000000000F1\n"), .unique(persistentID: "00000000000000F1"))
        XCTAssertEqual(parsePlaylistIdentity("1\n00000000000000f1"), .unique(persistentID: "00000000000000F1"))
        XCTAssertEqual(parsePlaylistIdentity("0\n"), .notFound)
        XCTAssertEqual(parsePlaylistIdentity("2\n"), .duplicated(count: 2))
        XCTAssertNil(parsePlaylistIdentity(""))
        XCTAssertNil(parsePlaylistIdentity("two"))
        XCTAssertNil(parsePlaylistIdentity("1\n"), "one playlist and no ID")
        XCTAssertNil(parsePlaylistIdentity("1\nnot-an-id"))
        XCTAssertNil(parsePlaylistIdentity("1\n00000000000000F1\n00000000000000F2"))
        XCTAssertNil(parsePlaylistIdentity("2\n00000000000000F1"))
        XCTAssertNil(parsePlaylistIdentity("-1\n"))
    }
}

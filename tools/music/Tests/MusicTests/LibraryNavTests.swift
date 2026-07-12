// tools/music/Tests/MusicTests/LibraryNavTests.swift
import XCTest
@testable import music

final class LibraryNavTests: XCTestCase {
    private let albumSel = LibrarySelection(id: "l.aaa", primary: "Kid A", secondary: "Radiohead")

    // Explicit level roots so the album/song tests don't depend on the sub-view
    // cycle order (which is exercised on its own below).
    private var albumsNav: LibraryNav { LibraryNav(subView: .albums, stack: [.albumList], cursor: 0) }
    private var songsNav: LibraryNav { LibraryNav(subView: .songs, stack: [.songList], cursor: 0) }

    func testStartsOnArtistsRoot() {
        let s = LibraryNav.initial
        XCTAssertEqual(s.subView, .artists)
        XCTAssertEqual(s.current, .artistList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testSubViewCycleIsArtistsAlbumsSongs() {
        var s = LibraryNav.initial
        XCTAssertEqual(s.subView, .artists)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .albums)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .songs)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .artists)              // wraps forward
        (s, _) = libraryReduce(s, .switchPrev, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .songs)                // wraps back
    }

    func testDownMovesCursorClamped() {
        var (s, _) = libraryReduce(albumsNav, .down, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.cursor, 1)
        (s, _) = libraryReduce(s, .down, itemCount: 2, selection: albumSel)  // clamp at last
        XCTAssertEqual(s.cursor, 1)
    }

    func testSwitchResetsCursorAndLevel() {
        var (s, _) = libraryReduce(albumsNav, .down, itemCount: 5, selection: albumSel)
        XCTAssertEqual(s.cursor, 1)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 5, selection: albumSel)
        XCTAssertEqual(s.subView, .songs)
        XCTAssertEqual(s.current, .songList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testEnterOnAlbumListPushesTracksAndFetches() {
        let (s, action) = libraryReduce(albumsNav, .enter, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.current, .tracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
        XCTAssertEqual(action, .fetchAlbumTracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
    }

    func testBackPopsToAlbumRoot() {
        var (s, _) = libraryReduce(albumsNav, .enter, itemCount: 2, selection: albumSel)
        (s, _) = libraryReduce(s, .back, itemCount: 10, selection: nil)
        XCTAssertEqual(s.current, .albumList)
    }

    func testPlayOnAlbumListEmitsAlbumPlay() {
        let (_, action) = libraryReduce(albumsNav, .play, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .play(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }

    func testShuffleOnAlbumListEmitsAlbumShuffle() {
        let (_, action) = libraryReduce(albumsNav, .shuffle, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .shuffle(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }

    func testArtistsEnterDrillsToArtistAlbums() {
        let s = LibraryNav.initial   // already on the Artists root
        let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
        let (s2, action) = libraryReduce(s, .enter, itemCount: 3, selection: artistSel)
        XCTAssertEqual(s2.current, .artistAlbums(artistID: "r.1", artistName: "Radiohead"))
        XCTAssertEqual(action, .fetchArtistAlbums(artistID: "r.1", artistName: "Radiohead"))
    }

    func testShuffleOnArtistListEmitsArtistShuffle() {
        let s = LibraryNav.initial   // Artists root
        let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
        let (_, action) = libraryReduce(s, .shuffle, itemCount: 3, selection: artistSel)
        XCTAssertEqual(action, .shuffle(.artist(id: "r.1", name: "Radiohead")))
    }

    func testSongsEnterPlaysTheSong() {
        let songSel = LibrarySelection(id: "i.s1", primary: "Idioteque", secondary: "Radiohead")
        let (_, action) = libraryReduce(songsNav, .enter, itemCount: 3, selection: songSel)
        XCTAssertEqual(action, .play(.song(id: "i.s1", title: "Idioteque", artist: "Radiohead")))
    }

    // MARK: - filteredArtistIndices (tier filter)

    private func artist(_ id: String, _ name: String) -> LibraryArtist { LibraryArtist(id: id, name: name) }

    /// All tier (nil set): the album filter is off; only the `/` text filter narrows.
    func testArtistFilterAllTierIsTextFilterOnly() {
        let arts = [artist("1", "Air"), artist("2", "Aphex Twin"), artist("3", "Boards of Canada")]
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: nil, filter: ""), [0, 1, 2])
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: nil, filter: "aph"), [1])
    }

    /// A filtered tier (non-nil set): only artists in the tier survive, AND-ed with
    /// the text filter. An artist not in the tier's set is hidden.
    func testArtistFilterTierIntersectsSet() {
        let arts = [artist("1", "Air"), artist("2", "Aphex Twin"), artist("3", "Boards of Canada")]
        let tier: Set<String> = ["air", "boards of canada"]
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: tier, filter: ""), [0, 2])
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: tier, filter: "air"), [0])
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: tier, filter: "aphex"), [])
    }

    /// Membership normalizes case + surrounding whitespace so REST name variants match.
    func testArtistFilterNormalizesCaseAndWhitespace() {
        let arts = [artist("1", "  Air "), artist("2", "APHEX TWIN")]
        let tier: Set<String> = ["air", "aphex twin"]
        XCTAssertEqual(filteredArtistIndices(artists: arts, albumArtistNames: tier, filter: ""), [0, 1])
    }

    func testArtistFilterModeCycles() {
        XCTAssertEqual(ArtistFilterMode.all.next, .epOr12)
        XCTAssertEqual(ArtistFilterMode.epOr12.next, .albums)
        XCTAssertEqual(ArtistFilterMode.albums.next, .all)
    }

    // MARK: - albumArtistSet (stub exclusion + tier split by track count)

    private func album(_ id: String, _ name: String, _ artist: String, _ tracks: Int) -> LibraryAlbum {
        LibraryAlbum(id: id, name: name, artist: artist, trackCount: tracks)
    }

    /// A one-track album (Apple's stub for a loose playlist song) does NOT qualify
    /// its artist; a multi-track album does. This is what stops the filter from being
    /// mute against exactly the playlist artists it targets.
    func testAlbumArtistSetExcludesOneTrackStubs() {
        let albums = [
            album("1", "Moon Safari", "Air", 10),
            album("2", "Some Playlist Song", "One Hit Wonder", 1),
            album("3", "Kid A", "Radiohead", 2),
        ]
        let set = albumArtistSet(from: albums)   // default minTracks = 2, unbounded max
        XCTAssertTrue(set.contains("air"))
        XCTAssertTrue(set.contains("radiohead"))
        XCTAssertFalse(set.contains("one hit wonder"))
    }

    /// Threshold honored, names normalized (so they match the artist list).
    func testAlbumArtistSetHonorsThresholdAndNormalizes() {
        let albums = [album("1", "X", "  MØ ", 3)]
        XCTAssertEqual(albumArtistSet(from: albums, minTracks: 5), [])
        XCTAssertEqual(albumArtistSet(from: albums, minTracks: 2), ["mø"])
    }

    /// The 12"/EP tier (2–5) and the Album tier (6+) split cleanly at the boundary;
    /// the 1-track stub is in neither.
    func testAlbumArtistSetSplitsEpFromAlbumByTrackCount() {
        let albums = [
            album("1", "12\" single", "Burial", 2),   // 12"/EP
            album("2", "EP", "Actress", 5),           // 12"/EP (upper boundary)
            album("3", "LP", "Radiohead", 6),         // album (lower boundary)
            album("4", "stub", "One Hit", 1),         // neither
        ]
        XCTAssertEqual(albumArtistSet(from: albums, minTracks: 2, maxTracks: 5), ["burial", "actress"])
        XCTAssertEqual(albumArtistSet(from: albums, minTracks: 6), ["radiohead"])
    }

    // MARK: - filteredAlbumIndices (tier-scoped drill)

    func testArtistFilterModeTrackRange() {
        XCTAssertNil(ArtistFilterMode.all.trackRange)
        XCTAssertEqual(ArtistFilterMode.epOr12.trackRange, 2...5)
        XCTAssertEqual(ArtistFilterMode.albums.trackRange, 6...Int.max)
    }

    /// A drilled album list is scoped to the active tier's track range; All (nil)
    /// shows everything and only the text filter narrows.
    func testFilteredAlbumIndicesTierScopesByTrackCount() {
        let albums = [
            album("1", "EP", "A", 3),     // 12"/EP
            album("2", "LP", "A", 8),     // album
            album("3", "stub", "A", 1),   // neither
        ]
        XCTAssertEqual(filteredAlbumIndices(albums: albums, trackRange: 6...Int.max, filter: ""), [1])
        XCTAssertEqual(filteredAlbumIndices(albums: albums, trackRange: 2...5, filter: ""), [0])
        XCTAssertEqual(filteredAlbumIndices(albums: albums, trackRange: nil, filter: ""), [0, 1, 2])
        XCTAssertEqual(filteredAlbumIndices(albums: albums, trackRange: nil, filter: "lp"), [1])
    }
}

// tools/music/Tests/MusicTests/DJArtistMixTests.swift
//
// The DJ's artist mix, as pure planning over a fake catalogue: choosing the
// artist (exactly one normalized exact-name match is taken, otherwise a picker
// that keeps the catalogue id), reading the artist's first 25 albums (any
// failed read fails the whole mix), de-duplicating by id, dropping and
// counting unavailable songs, and a uniformly random 50 (or all) in shuffled
// order. Nothing here reaches SpanDAC, a socket or a player.
import XCTest
@testable import music

/// A deterministic shuffler: reversed order, so "shuffled" is visible and exact.
struct DJReverseShuffle: DJShuffling {
    func shuffled<T>(_ items: [T]) -> [T] { items.reversed() }
}

/// A catalogue whose albums and tracks are scripted, recording every call.
final class DJFakeCatalogue: DJCatalogue {
    var albums: [CatalogueHit] = []
    var more = false
    var tracks: [String: [DiscoverItem]] = [:]
    var failAlbumList: Error?
    var failTracksFor: Set<String> = []
    private(set) var albumListCalls: [(artistID: String, limit: Int)] = []
    private(set) var trackReads: [String] = []
    /// Runs before each track read, to let a test flip a fence between reads.
    var beforeTrackRead: ((String) -> Void)?

    func artistAlbums(artistID: String, limit: Int) throws -> ArtistAlbums {
        albumListCalls.append((artistID, limit))
        if let failAlbumList { throw failAlbumList }
        return ArtistAlbums(albums: albums, more: more)
    }

    func containerTracks(for item: DiscoverItem) throws -> [DiscoverItem] {
        trackReads.append(item.id)
        beforeTrackRead?(item.id)
        if failTracksFor.contains(item.id) { throw SourceAppError.unreadable }
        return tracks[item.id] ?? []
    }
}

func djAlbum(_ id: String, _ title: String = "Album") -> CatalogueHit {
    CatalogueHit(kind: .album, id: id, title: title, subtitle: "Artist", album: nil)
}

func djArtistHit(_ id: String, _ title: String) -> CatalogueHit {
    CatalogueHit(kind: .artist, id: id, title: title, subtitle: nil, album: nil)
}

func djSong(_ id: String, title: String? = nil, length: RowLength = .milliseconds(180_000)) -> DiscoverItem {
    DiscoverItem(id: id, name: title ?? "Song \(id)", subtitle: "Artist", url: nil, artworkURL: nil, detail: .song,
                 length: length)
}

final class DJArtistMixTests: XCTestCase {

    // MARK: - Choosing the artist

    func testNormalizingIgnoresCaseAndALeadingTheOrA() {
        XCTAssertEqual(djNormalizedArtistName("The Radiohead"), "radiohead")
        XCTAssertEqual(djNormalizedArtistName("  radiohead "), "radiohead")
        XCTAssertEqual(djNormalizedArtistName("A Tribe Called Quest"), "tribe called quest")
        XCTAssertEqual(djNormalizedArtistName("the"), "the", "a bare article is a name, not an article")
        XCTAssertEqual(djNormalizedArtistName("Theory of a Deadman"), "theory of a deadman",
                       "a word that merely begins with The is not the article")
        XCTAssertEqual(djNormalizedArtistName("Alt-J"), "alt-j")
    }

    func testExactlyOneMatchIsTaken() {
        let hits = [djArtistHit("a1", "Radiohead Tribute Band"), djArtistHit("a2", "Radiohead"),
                    djArtistHit("a3", "Thom Yorke")]
        XCTAssertEqual(djResolveArtist(named: "radiohead", in: hits), .chosen(hits[1]))
    }

    func testALeadingTheOnEitherSideStillMatches() {
        let hits = [djArtistHit("a1", "The Beatles")]
        XCTAssertEqual(djResolveArtist(named: "Beatles", in: hits), .chosen(hits[0]))
        let other = [djArtistHit("a1", "Beatles")]
        XCTAssertEqual(djResolveArtist(named: "The Beatles", in: other), .chosen(other[0]))
    }

    /// Two artists of one name are not "one match": he picks, and the pick is
    /// the catalogue id, never a re-resolution of the name.
    func testTwoIdenticalNamesGoToThePicker() {
        let hits = [djArtistHit("a1", "Nirvana"), djArtistHit("a2", "Nirvana"), djArtistHit("a3", "Nirvana UK")]
        XCTAssertEqual(djResolveArtist(named: "Nirvana", in: hits), .pick([hits[0], hits[1]]))
    }

    func testNoExactMatchOffersTheFirstFiveArtists() {
        let hits = (1...7).map { djArtistHit("a\($0)", "Radio Band \($0)") }
        XCTAssertEqual(djResolveArtist(named: "Radiohead", in: hits), .pick(Array(hits.prefix(5))))
    }

    func testAPickerOfDuplicatesIsAlsoCappedAtFive() {
        let hits = (1...8).map { djArtistHit("a\($0)", "Nirvana") }
        XCTAssertEqual(djResolveArtist(named: "nirvana", in: hits), .pick(Array(hits.prefix(5))))
    }

    func testNoArtistsAtAllIsNone() {
        XCTAssertEqual(djResolveArtist(named: "Radiohead", in: []), .none)
    }

    // MARK: - Building the mix

    private func fixture(albums: Int, songsPerAlbum: Int) -> DJFakeCatalogue {
        let cat = DJFakeCatalogue()
        for a in 1...albums {
            cat.albums.append(djAlbum("alb\(a)", "Album \(a)"))
            cat.tracks["alb\(a)"] = (1...songsPerAlbum).map { djSong("a\(a)s\($0)") }
        }
        return cat
    }

    private func build(_ cat: DJFakeCatalogue, artist: CatalogueHit = djArtistHit("art1", "Radiohead"),
                       isCurrent: @escaping () -> Bool = { true }) throws -> DJArtistMix {
        try djBuildArtistMix(artist: artist, catalogue: cat, shuffler: DJReverseShuffle(), isCurrent: isCurrent)
    }

    func testTheChosenCatalogueIDAndThe25AlbumLimitAreWhatIsAsked() throws {
        let cat = fixture(albums: 2, songsPerAlbum: 3)
        _ = try build(cat, artist: djArtistHit("the-second-nirvana", "Nirvana"))
        XCTAssertEqual(cat.albumListCalls.map(\.artistID), ["the-second-nirvana"])
        XCTAssertEqual(cat.albumListCalls.map(\.limit), [25])
    }

    func testFewerThanFiftySongsPlayAllInShuffledOrder() throws {
        let cat = fixture(albums: 3, songsPerAlbum: 4)
        let mix = try build(cat)
        let source = (1...3).flatMap { a in (1...4).map { "a\(a)s\($0)" } }
        XCTAssertEqual(mix.ids, source.reversed(), "all songs, in the shuffler's order")
        XCTAssertEqual(mix.albumCount, 3)
        XCTAssertEqual(mix.unavailable, 0)
        XCTAssertFalse(mix.moreAlbums)
        XCTAssertEqual(mix.artistName, "Radiohead")
        XCTAssertEqual(mix.artistID, "art1")
    }

    func testMoreThanFiftySongsKeepExactlyFiftyDistinctOnes() throws {
        let cat = fixture(albums: 9, songsPerAlbum: 10)      // 90 songs
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.count, 50)
        XCTAssertEqual(Set(mix.ids).count, 50)
        let all = Set((1...9).flatMap { a in (1...10).map { "a\(a)s\($0)" } })
        XCTAssertTrue(Set(mix.ids).isSubset(of: all))
        XCTAssertLessThanOrEqual(mix.albumCount, 9)
        XCTAssertGreaterThanOrEqual(mix.albumCount, 5, "50 songs of 10 per album come from at least 5 albums")
    }

    func testExactlyFiftySongsPlayAll() throws {
        let cat = fixture(albums: 5, songsPerAlbum: 10)
        XCTAssertEqual(try build(cat).ids.count, 50)
    }

    func testASongOnTwoAlbumsIsQueuedOnce() throws {
        let cat = fixture(albums: 2, songsPerAlbum: 2)
        cat.tracks["alb2"] = [djSong("a1s1"), djSong("a2s2")]   // a1s1 is also on album 1
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.sorted(), ["a1s1", "a1s2", "a2s2"])
        XCTAssertEqual(mix.unavailable, 0, "a repeated song is not an unavailable one")
    }

    func testUnavailableSongsAreDroppedAndCounted() throws {
        let cat = fixture(albums: 1, songsPerAlbum: 3)
        cat.tracks["alb1"] = [djSong("x1"), djSong("x2", length: .null), djSong("x3", length: .null)]
        let mix = try build(cat)
        XCTAssertEqual(mix.ids, ["x1"])
        XCTAssertEqual(mix.unavailable, 2)
    }

    func testAnAlbumWithNoTracksIsNotCounted() throws {
        let cat = fixture(albums: 2, songsPerAlbum: 2)
        cat.tracks["alb2"] = []
        XCTAssertEqual(try build(cat).albumCount, 1)
    }

    func testMoreAlbumsIsCarriedFromTheAlbumPage() throws {
        let cat = fixture(albums: 2, songsPerAlbum: 2)
        cat.more = true
        XCTAssertTrue(try build(cat).moreAlbums)
    }

    // MARK: - Failures are whole

    func testAFailedAlbumReadFailsTheWholeMixNamingTheAlbum() {
        let cat = fixture(albums: 3, songsPerAlbum: 2)
        cat.failTracksFor = ["alb2"]
        XCTAssertThrowsError(try build(cat)) { error in
            guard case .albumReadFailed(let album, _)? = error as? DJArtistMixError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(album, "Album 2")
        }
        XCTAssertEqual(cat.trackReads, ["alb1", "alb2"], "reads stop at the first failure")
    }

    func testAFailedAlbumListFailsTheMix() {
        let cat = DJFakeCatalogue()
        cat.failAlbumList = SourceAppError.unreadable
        XCTAssertThrowsError(try build(cat)) { error in
            guard case .albumListFailed? = error as? DJArtistMixError else { return XCTFail("\(error)") }
        }
    }

    func testNoAlbumsOrNoPlayableSongsIsNoSongs() {
        let none = DJFakeCatalogue()
        XCTAssertThrowsError(try build(none)) { XCTAssertEqual($0 as? DJArtistMixError, .noSongs(artist: "Radiohead")) }
        let unplayable = fixture(albums: 1, songsPerAlbum: 1)
        unplayable.tracks["alb1"] = [djSong("x", length: .null)]
        XCTAssertThrowsError(try build(unplayable)) { XCTAssertEqual($0 as? DJArtistMixError, .noSongs(artist: "Radiohead")) }
    }

    /// The fence is asked before every read: once it is false no further
    /// album is read and the mix is cancelled, not failed.
    func testTheFenceStopsReadsBetweenAlbums() {
        let cat = fixture(albums: 4, songsPerAlbum: 2)
        var current = true
        cat.beforeTrackRead = { if $0 == "alb2" { current = false } }
        XCTAssertThrowsError(try build(cat, isCurrent: { current })) {
            XCTAssertEqual($0 as? DJArtistMixError, .cancelled)
        }
        XCTAssertEqual(cat.trackReads, ["alb1", "alb2"], "a read was sent after the fence turned")
    }

    // MARK: - Repeated titles (SpanDAC refuses a queue holding two songs of one exact title)

    func testAKidAOnTwoAlbumsKeepsOnlyTheFirstInAlbumOrder() throws {
        let cat = DJFakeCatalogue()
        cat.albums = [djAlbum("kid"), djAlbum("reissue")]
        cat.tracks["kid"] = [djSong("k1", title: "Everything In Its Right Place"), djSong("k2", title: "Kid A")]
        cat.tracks["reissue"] = [djSong("r1", title: "Kid A"), djSong("r2", title: "Idioteque")]
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.sorted(), ["k1", "k2", "r2"], "the reissue's Kid A (r1) must go")
        XCTAssertEqual(mix.repeatedTitles, 1)
        XCTAssertEqual(mix.albumCount, 2)
        XCTAssertEqual(mix.line, "Radiohead \u{00B7} 3 songs from 2 albums (1 repeated title skipped)")
    }

    func testThreeSongsOfOneTitleKeepTheFirstAndCountTwo() throws {
        let cat = DJFakeCatalogue()
        cat.albums = [djAlbum("a"), djAlbum("b"), djAlbum("c")]
        cat.tracks["a"] = [djSong("a1", title: "Creep")]
        cat.tracks["b"] = [djSong("b1", title: "Creep"), djSong("b2", title: "Karma Police")]
        cat.tracks["c"] = [djSong("c1", title: "Creep")]
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.sorted(), ["a1", "b2"])
        XCTAssertEqual(mix.repeatedTitles, 2)
        XCTAssertTrue(mix.line.hasSuffix("(2 repeated titles skipped)"), mix.line)
    }

    func testTitlesDifferingOnlyInCaseAreBothKept() throws {
        let cat = DJFakeCatalogue()
        cat.albums = [djAlbum("a")]
        cat.tracks["a"] = [djSong("a1", title: "Kid A"), djSong("a2", title: "kid a")]
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.sorted(), ["a1", "a2"])
        XCTAssertEqual(mix.repeatedTitles, 0)
    }

    func testRepeatedTitlesAreRemovedBeforeTheSampleOf50() throws {
        let cat = DJFakeCatalogue()
        cat.albums = [djAlbum("a"), djAlbum("b")]
        cat.tracks["a"] = (1...30).map { djSong("a\($0)", title: "T\($0)") }
        cat.tracks["b"] = (1...30).map { djSong("b\($0)", title: "T\($0)") }   // all repeat album a
        let mix = try build(cat)
        XCTAssertEqual(mix.ids.count, 30, "the 30 copies must not take places from a sample of 50")
        XCTAssertEqual(mix.repeatedTitles, 30)
        XCTAssertTrue(mix.ids.allSatisfy { $0.hasPrefix("a") })
    }

    func testAnUnavailableSongIsNotAlsoCountedAsARepeatedTitle() throws {
        let cat = DJFakeCatalogue()
        cat.albums = [djAlbum("a")]
        cat.tracks["a"] = [djSong("a1", title: "Kid A", length: .null), djSong("a2", title: "Kid A")]
        let mix = try build(cat)
        XCTAssertEqual(mix.ids, ["a2"], "the unavailable copy is dropped first, so the playable one is kept")
        XCTAssertEqual(mix.unavailable, 1)
        XCTAssertEqual(mix.repeatedTitles, 0)
    }

    func testTheLineJoinsUnavailableAndRepeatedTitleNotes() {
        let mix = DJArtistMix(artistName: "Radiohead", artistID: "a", ids: ["x", "y"], albumCount: 2,
                              moreAlbums: false, unavailable: 2, repeatedTitles: 3)
        XCTAssertEqual(mix.line,
                       "Radiohead \u{00B7} 2 songs from 2 albums (2 unavailable skipped; 3 repeated titles skipped)")
    }

    // MARK: - The card line

    func testTheLineNamesArtistSongsAlbumsAndWhatWasSkipped() {
        let mix = DJArtistMix(artistName: "Radiohead", artistID: "a", ids: Array(repeating: "x", count: 50),
                              albumCount: 9, moreAlbums: false, unavailable: 3)
        XCTAssertEqual(mix.line, "Radiohead \u{00B7} 50 songs from 9 albums (3 unavailable skipped)")
    }

    func testTheLineSaysFirst25AlbumsWhenThereAreMore() {
        let mix = DJArtistMix(artistName: "Radiohead", artistID: "a", ids: ["x"], albumCount: 1,
                              moreAlbums: true, unavailable: 0)
        XCTAssertEqual(mix.line, "Radiohead \u{00B7} 1 song from 1 album (first 25 albums)")
        let both = DJArtistMix(artistName: "Radiohead", artistID: "a", ids: ["x", "y"], albumCount: 2,
                               moreAlbums: true, unavailable: 1)
        XCTAssertEqual(both.line, "Radiohead \u{00B7} 2 songs from 2 albums (first 25 albums; 1 unavailable skipped)")
    }
}

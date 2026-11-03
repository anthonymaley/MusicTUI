// tools/music/Sources/TUI/ProviderSurfaces.swift
import Foundation

// Slice 3, Part 2, D1: surfaces, not one fat protocol.
//
// Each surface is one thing a scene or a CLI command reads or plays, declared
// on its own so an open-mode provider (`OpenMusicProvider`, P3) can conform to
// only the surfaces Music.app mode genuinely serves by id — Discover and
// stations — while `MusicDataProvider` (the Bridge seam) refines all five.
//
// **No conformer falls back to the other backend.** An open conformer never
// reaches Bridge; a Bridge conformer never makes a REST call.

/// Discover's rails and a container's tracks.
protocol DiscoverProviding {
    /// Whether this provider can read a feed at all. Open mode: a feed object
    /// exists (both tokens present, as ships). Bridge: always.
    var feedAvailable: Bool { get }
    func discoverRails(limit: Int) throws -> [DiscoverRail]
    func containerTracks(for item: DiscoverItem) throws -> [DiscoverItem]
    /// Discover's self-named sections (`DiscoverSection`), read after the
    /// rails under one shared deadline. Never throws: absent is the answer for
    /// a section that could not be read, and for a provider that serves none.
    func discoverSections() -> [DiscoverRail]
    /// The genres the Top charts can be read for. Empty: no genre row, which
    /// is the answer for a provider that serves none (SpanDAC without
    /// `slice.genres` and `slice.charts.genre`).
    func discoverGenres() -> [DiscoverGenre]
    /// One genre's Top chart sections. Empty: none could be read.
    func discoverGenreCharts(_ genre: DiscoverGenre) -> [DiscoverRail]
}

extension DiscoverProviding {
    func discoverSections() -> [DiscoverRail] { [] }
    func discoverGenres() -> [DiscoverGenre] { [] }
    func discoverGenreCharts(_ genre: DiscoverGenre) -> [DiscoverRail] { [] }
}

/// Radio's catalogue reads and a station play.
protocol StationProviding {
    /// Whether this provider can read the station catalogue at all. Open mode:
    /// a catalogue object exists (a developer key, as ships). Bridge: always.
    var catalogueAvailable: Bool { get }
    func searchStations(term: String, limit: Int) throws -> [Station]
    func liveStations() throws -> [Station]
    func personalStations() throws -> [Station]
    /// nil: Apple's catalogue does not carry this station. A normal answer,
    /// not an error (BBC Radio 1 is the known case).
    func station(id: String) throws -> Station?
    /// `url` is open mode's play handle; Bridge plays by id and ignores it.
    func playStation(id: String, name: String, url: String?) throws
}

/// Play catalogue songs by their catalogue ids, reporting how many Bridge
/// dropped as unavailable (`skipped_unavailable`).
protocol CataloguePlaying {
    func playCatalogue(ids: [String]) throws -> Int
}

/// Catalogue search: songs and albums.
protocol CatalogueSearching {
    func searchCatalogue(term: String, limit: Int) throws -> [CatalogueRecord]
}

/// The TUI's catalogue browse (Discover's `/` search): artists, albums and
/// songs, and one artist's albums. TUI-only: the CLI's `music search` reads
/// `CatalogueSearching` and `CatalogueRecord`, which this does not touch.
protocol CatalogueBrowsing {
    /// One `slice.search`, grouped by kind in Apple's order. Artists are asked
    /// for only when SpanDAC says it serves them; `artistsNote` says why not.
    func browseCatalogue(term: String, limit: Int) throws -> CatalogueSearchResults
    /// `slice.artistAlbums`: the first `limit` of an artist's catalogue albums.
    func artistAlbums(artistID: String, limit: Int) throws -> ArtistAlbums
}

/// A conformer that serves neither read says so, in the same update sentence
/// an older SpanDAC's `unknown_op` gives, never as an empty answer.
extension CatalogueBrowsing {
    func browseCatalogue(term: String, limit: Int) throws -> CatalogueSearchResults {
        throw MusicProviderError.notImplemented(BridgeMusicProvider.unsupportedSentence(forWireOp: "slice.search"))
    }
    func artistAlbums(artistID: String, limit: Int) throws -> ArtistAlbums {
        throw MusicProviderError.notImplemented(
            BridgeMusicProvider.unsupportedSentence(forWireOp: catalogueArtistAlbumsOp))
    }
}

/// The op that lists an artist's catalogue albums, and its capability name.
let catalogueArtistAlbumsOp = "slice.artistAlbums"
/// The capability that says `slice.search` answers `"artists": true`.
let catalogueSearchArtistCapability = "search.artist"

/// One catalogue browse result. The kind is SpanDAC's, never inferred from the
/// id's spelling; a kind this build does not model never becomes a hit.
struct CatalogueHit: Equatable {
    enum Kind: Equatable { case artist, album, song }
    let kind: Kind
    let id: String
    let title: String
    /// The wire's `subtitle` (the credit line). Always present for an album or
    /// a song; an artist record carries none.
    let subtitle: String?
    /// A song's album title, when SpanDAC sends one.
    let album: String?
}

/// One `slice.search`, grouped, each group in Apple's order.
struct CatalogueSearchResults: Equatable {
    var artists: [CatalogueHit]
    var albums: [CatalogueHit]
    var songs: [CatalogueHit]
    /// True only when artists were asked for (both capabilities listed).
    var artistsServed: Bool
    /// Why there are no artists, when they were not asked for: an older SpanDAC
    /// (`artistsNeedNewerSpanDAC`) or a status that could not be read
    /// (`artistsCouldNotCheck`). nil when artists were served.
    var artistsNote: String?

    static let artistsNeedNewerSpanDAC = "Artists need a newer SpanDAC on this Mac."
    static let artistsCouldNotCheck = "Couldn't check SpanDAC for artist search."
}

/// One artist's catalogue albums: the first page only. `more` true means there
/// are others beyond it (the screen says "First 25 albums.").
struct ArtistAlbums: Equatable {
    let albums: [CatalogueHit]
    let more: Bool
}

/// The account's listening history.
protocol HistoryProviding {
    func recentTracks(limit: Int) throws -> [HistoryItem]
    func heavyRotation(limit: Int) throws -> [HistoryItem]
}

/// One catalogue search result, typed by the op that produced it (D6): the
/// kind is Bridge's, never inferred from the id's spelling.
struct CatalogueRecord: Equatable {
    enum Kind: Equatable { case song, album }
    let kind: Kind
    let catalogueID: String
    let title: String
    /// The wire's `subtitle`: the credit line.
    let artist: String
    /// A song's album title, when Bridge sends one (optional, additive).
    let album: String?
}

/// One listening-history item, in Apple's order, with nothing filtered (D5).
///
/// `catalogueID` comes only from Apple's own `playParams.catalogId` on the
/// Bridge side; a library-only song has none, and nothing here invents one.
struct HistoryItem: Equatable {
    let type: String
    let id: String
    let name: String
    let artist: String?
    let album: String?
    let catalogueID: String?
}

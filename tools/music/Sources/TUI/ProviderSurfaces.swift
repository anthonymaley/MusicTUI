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

// tools/music/Sources/TUI/OpenMusicProvider.swift
import Foundation

/// Slice 3, Part 2, D1/D4: Music.app mode's side of the Discover and station
/// surfaces.
///
/// **A wrapper, never a re-derivation.** Each scene wraps the objects it already
/// receives — the web-service `feed`, the REST `catalog`, the `opener` — so no
/// initialiser and no `Shell.swift` line changes, and open mode keeps its
/// shipped behaviour byte for byte: every read reaches the same object with the
/// same arguments and rethrows that object's own error untranslated, because
/// the scenes' shipped failure handling keys on those errors (a web-service
/// failure has no words of its own and keeps the line it always had).
///
/// **Availability is the objects' presence** (D4): `feedAvailable` is
/// `discover != nil` (both tokens, `makeDiscoverFeed()`), `catalogueAvailable`
/// is `catalog != nil` (a developer key, `makeCatalog()`). A scene checks those
/// before reading; a read asked of an absent object anyway throws that object's
/// own `noToken`, and reaches nothing.
///
/// **Only Discover and stations.** Music.app library, playlists and container
/// playback are not id-shaped and stay shipped; open-mode catalogue search and
/// history stay the CLI's shipped bodies (D1). This type never reaches Bridge.
struct OpenMusicProvider: DiscoverProviding, StationProviding {

    private let discover: DiscoverFeedReading?
    private let catalog: RadioCatalog?
    private let opener: Opener

    init(discover: DiscoverFeedReading?, catalog: RadioCatalog?, opener: Opener) {
        self.discover = discover
        self.catalog = catalog
        self.opener = opener
    }

    // MARK: - DiscoverProviding

    var feedAvailable: Bool { discover != nil }

    func discoverRails(limit: Int) throws -> [DiscoverRail] {
        guard let discover else { throw DiscoverFeedError.noToken }
        return try discover.rails(limit: limit)
    }

    func containerTracks(for item: DiscoverItem) throws -> [DiscoverItem] {
        guard let discover else { throw DiscoverFeedError.noToken }
        return try discover.tracks(for: item)
    }

    // MARK: - StationProviding

    var catalogueAvailable: Bool { catalog != nil }

    /// The catalogue's search asks for its own fixed 25 (`RadioCatalog.search`),
    /// which is what ships; `limit` is not sent.
    func searchStations(term: String, limit: Int) throws -> [Station] {
        _ = limit
        guard let catalog else { throw RadioCatalogError.noToken }
        return try catalog.search(term: term)
    }

    func liveStations() throws -> [Station] {
        guard let catalog else { throw RadioCatalogError.noToken }
        return try catalog.liveStations()
    }

    func personalStations() throws -> [Station] {
        guard let catalog else { throw RadioCatalogError.noToken }
        return try catalog.personalStation()
    }

    /// nil is the catalogue not carrying the station (BBC Radio 1): normal.
    func station(id: String) throws -> Station? {
        guard let catalog else { throw RadioCatalogError.noToken }
        return try catalog.resolve(id: id)
    }

    /// The share URL IS Music.app's play handle (`stationPlayURL`), so a row
    /// without one refuses in the shipped words, before anything is opened.
    func playStation(id: String, name: String, url: String?) throws {
        guard let url else { throw ActionError(message: "That station has no play URL.") }
        try music.playStation(Station(id: id, name: name, url: url, isLive: nil, artworkURL: nil), via: opener)
    }
}

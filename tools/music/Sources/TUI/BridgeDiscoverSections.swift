// Discover's self-named sections as SpanDAC serves them, for SpanDAC data:
// `slice.recentlyAdded`, `slice.recentStations` and `slice.charts`.
//
// With SpanDAC as the data source every read is SpanDAC's and nothing falls
// back to the web service on either axis (Anthony, 2026-09-29). So a section
// appears only when SpanDAC ADVERTISES its op in `slice.status`'s
// `capabilities` (the op name is the capability, as for every op), and a
// section SpanDAC does not advertise sends nothing and is absent.
//
// Loaded the same way as the web service's sections (`loadDiscoverSections`):
// after the rails, all at once, under one shared deadline, appended when they
// land. The capability read is inside that deadline.
import Foundation

/// The three charts of one `slice.charts` reply, each in Apple's order.
struct DiscoverSectionCharts: Equatable {
    let songs: [DiscoverItem]
    let albums: [DiscoverItem]
    let playlists: [DiscoverItem]
}

enum BridgeDiscoverSections {
    /// The capability names, one per op.
    static let recentlyAddedOp = "slice.recentlyAdded"
    static let recentStationsOp = "slice.recentStations"
    static let chartsOp = "slice.charts"
    /// Genre browse, step 2. `slice.genres` lists the genres; the genre-scoped
    /// charts are `slice.charts` with a `genre` field, advertised separately
    /// as `slice.charts.genre` because an older SpanDAC ignores the unknown
    /// field and would answer the all-genre charts under a genre heading.
    static let genresOp = "slice.genres"
    static let chartsGenreCapability = "slice.charts.genre"

    /// What `slice.recentStations` is asked for: the web feed's own page.
    static let recentStationsLimit = DiscoverFeed.recentStationsLimit

    /// An ok `slice.recentlyAdded` reply's `items`: catalogue rows, in
    /// SpanDAC's order, decoded by `BridgeDiscoverFeed`'s row rules (an
    /// unknown kind is dropped; a row missing its kind, id or name fails the
    /// read). A missing `items` is a contract violation, never an empty list.
    static func recentlyAdded(fromReply reply: [String: Any]) throws -> [DiscoverItem] {
        guard let rows = reply["items"] as? [[String: Any]] else { throw SourceAppError.unreadable }
        return try BridgeDiscoverFeed.items(rows)
    }

    /// An ok `slice.recentStations` reply's `stations`, by the station rules
    /// Live and Personal use (every row needs its `url`, which a station play
    /// on the MusicTUI output needs). A missing `stations` is unreadable.
    static func recentStations(fromReply reply: [String: Any]) throws -> [DiscoverItem] {
        try SourceAppStationSearch.stations(fromWire: reply["stations"]).map { station in
            DiscoverItem(id: station.id, name: station.name, subtitle: nil, url: station.url,
                         artworkURL: station.artworkURL, detail: .station(isLive: station.isLive ?? false))
        }
    }

    /// An ok `slice.charts` reply's `charts`. All three keys must be present
    /// (an empty array is an answer; a missing key is unreadable). A row of
    /// another kind under a chart is not shown under it.
    static func charts(fromReply reply: [String: Any]) throws -> DiscoverSectionCharts {
        guard let charts = reply["charts"] as? [String: Any] else { throw SourceAppError.unreadable }
        func chart(_ key: String, _ kind: DiscoverItemKind) throws -> [DiscoverItem] {
            guard let rows = charts[key] as? [[String: Any]] else { throw SourceAppError.unreadable }
            return try BridgeDiscoverFeed.items(rows).filter { $0.kind == kind }
        }
        return DiscoverSectionCharts(songs: try chart("songs", .song), albums: try chart("albums", .album),
                                     playlists: try chart("playlists", .playlist))
    }
}

extension BridgeDiscoverSections {
    /// An ok `slice.genres` reply's `genres`, in SpanDAC's order. A missing
    /// `genres`, or a row missing its `id` or `name`, is unreadable (a contract
    /// violation), never a shorter list.
    static func genres(fromReply reply: [String: Any]) throws -> [DiscoverGenre] {
        guard let rows = reply["genres"] as? [[String: Any]] else { throw SourceAppError.unreadable }
        return try rows.map { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else {
                throw SourceAppError.unreadable
            }
            return DiscoverGenre(id: id, name: name)
        }
    }

    /// A genre-scoped `slice.charts` reply: the all-genre shape, but only if it
    /// echoes the `genre` that was asked for. The capability read and this read
    /// are two transactions, so a SpanDAC replaced between them (an older one
    /// ignores the field) would answer all-genre charts that we would title
    /// with the genre. A missing or different echo is unreadable.
    static func charts(fromReply reply: [String: Any], genre: String) throws -> DiscoverSectionCharts {
        guard reply["genre"] as? String == genre else { throw SourceAppError.unreadable }
        return try charts(fromReply: reply)
    }

    /// Genre browse is offered only when SpanDAC advertises BOTH the genre list
    /// and the genre-scoped charts: with one alone the row would be missing its
    /// list, or would head all-genre charts with a genre's name.
    static func offersGenres(_ capabilities: [String]) -> Bool {
        capabilities.contains(genresOp) && capabilities.contains(chartsGenreCapability)
    }
}

/// The sections SpanDAC serves, within `deadline` from this call's start.
///
/// One `slice.status` for the capabilities first; if it cannot be read, no
/// section op is sent and there are no sections. Then one read per ADVERTISED
/// op, all at once. A read that throws, for any reason, leaves its section
/// absent; a `slice.charts` failure leaves all three charts absent.
func bridgeDiscoverSectionRails(control: SourceControlling,
                                deadline: TimeInterval = DiscoverFeed.defaultSectionDeadline) -> [DiscoverRail] {
    loadDiscoverSections(deadline: deadline) {
        guard let capabilities = try? control.capabilities() else { return [] }
        var reads: [DiscoverSectionRead] = []
        if capabilities.contains(BridgeDiscoverSections.recentlyAddedOp) {
            reads.append { (try? control.recentlyAdded()).map { [.recentlyAdded: $0] } ?? [:] }
        }
        if capabilities.contains(BridgeDiscoverSections.recentStationsOp) {
            reads.append {
                (try? control.recentStations(limit: BridgeDiscoverSections.recentStationsLimit))
                    .map { [.recentStations: $0] } ?? [:]
            }
        }
        if capabilities.contains(BridgeDiscoverSections.chartsOp) {
            reads.append {
                guard let charts = try? control.charts() else { return [:] }
                return [.topSongs: charts.songs, .topAlbums: charts.albums, .topPlaylists: charts.playlists]
            }
        }
        return reads
    }
}

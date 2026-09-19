// TEMPORARY, with the rest of the slice wire (see StationSearchSource.swift).
//
// Discover's feed as Bridge serves it: `slice.recommendations` and
// `slice.containerTracks`, read over the app's own Apple Music access, so the
// client needs no developer key and no web sign-in (DoD 6).
//
// **What Bridge does not send, recorded rather than papered over** (Anthony,
// 2026-09-19: left degraded for v1). No recently-played flag, so
// `orderedDiscoverRails` leaves Bridge's rails in Apple's order; no share URL;
// no year, genre, track count, live flag or playlist description, so the detail
// panel is thinner than on Music.app output.
import Foundation

struct BridgeDiscoverFeed: DiscoverFeedReading {
    private let control: SourceAppControl

    init(path: String = SourceAppStationSearch.socketPath) {
        control = SourceAppControl(path: path)
    }

    /// Seam for tests, matching the other Bridge clients' own.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        control = SourceAppControl(path: path, transport: transport)
    }

    /// Apple's rails in Apple's order, empty ones dropped - the same rule the
    /// web-service feed applies.
    func rails(limit: Int) throws -> [DiscoverRail] {
        let reply = try control.send(["op": "slice.recommendations", "limit": limit])
        // A missing collection on an ok reply is a contract violation, not an
        // empty feed: an honest empty one carries an empty array. The same rule
        // station search keeps (Codex S1).
        guard let rows = reply["rails"] as? [[String: Any]] else { throw SourceAppError.unreadable }
        return try rows.enumerated().compactMap { index, row in
            guard let title = row["title"] as? String,
                  let rawItems = row["items"] as? [[String: Any]] else { throw SourceAppError.unreadable }
            let items = try Self.items(rawItems)
            guard !items.isEmpty else { return nil }
            // The wire sends no rail id, and the scene keys scroll state and
            // hero artwork off it. Position makes it distinct; the title makes
            // it readable in a log.
            return DiscoverRail(id: "bridge:\(index):\(title)", title: title, items: items,
                                isRecentlyPlayed: false, resourceTypes: [])
        }
    }

    /// A station or a song has no track list, so none is asked for - the same
    /// answer the web-service feed gives without spending a request.
    ///
    /// The KIND goes back on the wire: a catalogue id does not say whether it is
    /// an album or a playlist, and Bridge once read every one as an album.
    func tracks(for item: DiscoverItem) throws -> [DiscoverItem] {
        let kind: String
        switch item.kind {
        case .album:          kind = "album"
        case .playlist:       kind = "playlist"
        case .station, .song: return []
        }
        let reply = try control.send(["op": "slice.containerTracks", "id": item.id, "kind": kind])
        guard let rows = reply["items"] as? [[String: Any]] else { throw SourceAppError.unreadable }
        return try Self.items(rows)
    }

    /// A kind this build does not model is DROPPED rather than guessed at: a rail
    /// one row shorter is a smaller wrong than a row whose Enter does something
    /// the person did not ask for. That is forward compatibility, and it is the
    /// ONLY thing dropped: a row with no kind, or a known kind missing its id or
    /// name, is malformed and fails the whole read.
    private static func items(_ rows: [[String: Any]]) throws -> [DiscoverItem] {
        try rows.compactMap { row in
            guard let kind = row["kind"] as? String else { throw SourceAppError.unreadable }
            guard ["station", "album", "playlist", "song"].contains(kind) else { return nil }
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String else { throw SourceAppError.unreadable }
            let detail: DiscoverItemDetail
            switch kind {
            case "station":  detail = .station(isLive: false)
            case "album":    detail = .album(trackCount: nil, year: nil, genre: nil)
            case "playlist": detail = .playlist(description: nil)
            case "song":     detail = .song
            default:         return nil
            }
            return DiscoverItem(id: id, name: name, subtitle: row["subtitle"] as? String,
                                // `artwork_url` is the WIRE's spelling (the app's
                                // CodingKeys), not the Swift property's.
                                url: nil, artworkURL: row["artwork_url"] as? String, detail: detail)
        }
    }
}

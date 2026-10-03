// The Discover tab's read layer: Apple's own For You rails plus recently played.
// Both endpoints need a Music User Token (403 without), unlike RadioCatalog's
// catalog reads which run on the developer token alone.
//
// Probed live 2026-08-25, full write-up in docs/platform-notes.md. What the
// probes settled, so nobody re-derives it:
//
//  - /v1/me/recommendations returned 17 rails on first probe; a same-day
//    re-probe with the same limit and account returned 10. Rail count is NOT
//    a stable fact — it varies call to call, which is part of why Discover
//    resolves down to a fixed five-slot selection (see selectDiscoverRails)
//    rather than assuming a fixed shape from the feed. Ids were stable across
//    calls, and the response carried `cache-control: private, max-age=600`.
//    Ten minutes is Apple's own hint to its clients, so refresh-on-load with a
//    10 minute cache tracks the real rotation rather than guessing at one.
//    Caching is the caller's job.
//  - "Top Picks for You", the first rail in Music.app's Discover, is NOT in that
//    list. It is composed client side. Its ingredients are here (its station
//    cards live in "Stations for You", its new release in "New Releases for
//    You"), but the rail itself cannot be fetched. Do not go looking again.
//  - The feed carries its own "Recently Played" rail under kind
//    `recently-played`. /v1/me/recent/played returns the same thing with more
//    items and a `?types=` filter, so both are exposed here.
//  - Dead ends already paid for: /v1/me/home 404, catalog/new-releases 400,
//    music-summaries 404 (there is no Replay API), platform=web rejected.
//  - Probed 200 the same day and surfaced since as self-named sections
//    (`DiscoverSection`): /v1/me/library/recently-added,
//    /v1/me/recent/radio-stations, /v1/catalog/{sf}/charts. Their response
//    shapes here follow Apple's documentation, not a recorded probe body.
import Foundation

enum DiscoverFeedError: Error {
    case noToken
    case fetchFailed
    case badResponse
}

/// What a Discover row points at. Rails are deliberately mixed: one rail can hold
/// stations, albums and playlists side by side, and each plays differently.
enum DiscoverItemKind: Equatable {
    case station, album, playlist, song
}

/// Kind-specific metadata, all of it present inline in the recommendations
/// payload (probed live 2026-08-25) so the detail panel costs no extra request.
/// Modelled as an enum rather than a widening set of optionals so an album
/// cannot carry isLive and a station cannot carry a track count.
enum DiscoverItemDetail: Equatable {
    case station(isLive: Bool)
    case album(trackCount: Int?, year: Int?, genre: String?)
    case playlist(description: String?)
    case song

    var kind: DiscoverItemKind {
        switch self {
        case .station:  return .station
        case .album:    return .album
        case .playlist: return .playlist
        case .song:     return .song
        }
    }

    /// nil for a type Apple added that we do not model yet: skip the row rather
    /// than throwing, matching the old DiscoverItemKind(apiType:) behaviour.
    init?(apiType: String, attributes a: [String: Any]) {
        switch apiType {
        case "stations":
            self = .station(isLive: a["isLive"] as? Bool ?? false)
        case "albums":
            self = .album(trackCount: a["trackCount"] as? Int,
                          year: discoverReleaseYear(a["releaseDate"] as? String),
                          genre: (a["genreNames"] as? [String])?.first)
        case "playlists":
            self = .playlist(
                description: (a["description"] as? [String: Any])?["standard"] as? String)
        case "songs":
            self = .song
        default:
            return nil   // Apple can add a type at any time; skip, don't throw
        }
    }
}

/// Apple's releaseDate is "YYYY-MM-DD". Anything else yields nil rather than a
/// zero, which would render as year 0 in the panel.
private func discoverReleaseYear(_ raw: String?) -> Int? {
    guard let raw, raw.count >= 4 else { return nil }
    return Int(raw.prefix(4))
}

struct DiscoverItem: Equatable {
    let id: String
    let name: String
    /// artistName for albums and songs, curatorName for playlists, nil for
    /// stations (which carry neither).
    let subtitle: String?
    /// The https:// share URL. For a station this is the play handle: rewrite
    /// the scheme to music:// and `open` it (see StationPlayback). For an album
    /// or playlist it is NOT a play handle — the scheme rewrite does nothing on
    /// those, measured 2026-08-25.
    let url: String?
    let artworkURL: String?
    let detail: DiscoverItemDetail
    /// The row's length as SpanDAC's `slice.containerTracks` gave it (W2).
    /// `.absent` for every row that did not come from that op.
    var length: RowLength = .absent

    var kind: DiscoverItemKind { detail.kind }
}

struct DiscoverRail: Equatable {
    let id: String
    let title: String
    let items: [DiscoverItem]
    /// True for the feed's own recently-played rail. Keyed off the API's `kind`
    /// rather than the display title, which is localized.
    let isRecentlyPlayed: Bool
    /// The API's own content-type flag, e.g. ["albums"]. This is what rail
    /// selection runs on: titles are localized and rotate, flags do not.
    let resourceTypes: [String]
    /// Which self-named section this rail is, or nil for one of Apple's For
    /// You rails. A section never competes for the five curated slots; it is
    /// shown after them, in `DiscoverSection`'s own order.
    var section: DiscoverSection? = nil
}

/// Discover's self-named sections: feeds the web service serves beside the
/// For You rails, read by `DiscoverFeed` only (the TODO's "Discover second
/// pass", endpoints probed 200 on 2026-08-25).
///
/// **Web-service data only.** With SpanDAC selected as the data source every
/// read is SpanDAC's (Anthony, 2026-09-29: no fallback on either axis), and
/// SpanDAC serves no equivalent of any of these, so under SpanDAC data the
/// sections are simply absent: `BridgeDiscoverFeed` never builds one.
///
/// `allCases` order IS the display order: his own library and listening
/// first, then the storefront's charts.
enum DiscoverSection: CaseIterable, Equatable {
    case recentlyAdded, recentStations, topSongs, topAlbums, topPlaylists

    var title: String {
        switch self {
        case .recentlyAdded:  return "Recently Added"
        case .recentStations: return "Recent Stations"
        case .topSongs:       return "Top Songs"
        case .topAlbums:      return "Top Albums"
        case .topPlaylists:   return "Top Playlists"
        }
    }

    /// Distinct from every For You rail id (Apple's ids carry no colon), so
    /// the scene's scroll and hero state never collide with one.
    var railID: String {
        switch self {
        case .recentlyAdded:  return "section:recently-added"
        case .recentStations: return "section:recent-stations"
        case .topSongs:       return "section:top-songs"
        case .topAlbums:      return "section:top-albums"
        case .topPlaylists:   return "section:top-playlists"
        }
    }

    var resourceTypes: [String] {
        switch self {
        case .recentlyAdded:  return ["albums", "playlists"]
        case .recentStations: return ["stations"]
        case .topSongs:       return ["songs"]
        case .topAlbums:      return ["albums"]
        case .topPlaylists:   return ["playlists"]
        }
    }
}

// MARK: - Display model (pure, so the scene's layout is testable without a network)

/// A flattened Discover row. Rails become headers; items and View all are selectable.
enum DiscoverDisplayRow: Equatable {
    case header(String)
    case item(DiscoverItem)
    case viewAll(DiscoverRail)
}

/// What the cursor is on. `.viewAll` is not a DiscoverItem, so a DiscoverItem?
/// selection would return nil there and Enter would silently do nothing.
/// Modelling both cases means every selectable row has an action and a footer
/// hint by construction, and a future row type is a compile error in both
/// switches rather than a no-op.
enum DiscoverSelection: Equatable {
    case item(DiscoverItem)
    case viewAll(DiscoverRail)
}

/// Music.app's Discover leads with Top Picks and then Recently Played. Top Picks is
/// not fetchable at all, so the closest honest thing is to lead with the row the
/// user actually recognizes rather than leaving it wherever the feed put it.
/// Stable otherwise: relative order is preserved on both sides of the split.
func orderedDiscoverRails(_ rails: [DiscoverRail]) -> [DiscoverRail] {
    rails.filter(\.isRecentlyPlayed) + rails.filter { !$0.isRecentlyPlayed }
}

func discoverDisplayRows(rails: [DiscoverRail], perRail: Int) -> [DiscoverDisplayRow] {
    let cap = max(1, perRail)
    return rails.flatMap { rail -> [DiscoverDisplayRow] in
        let items = rail.items.prefix(cap)
        // An empty rail is a bare heading with nothing under it, which reads as
        // a bug rather than as an empty state.
        guard !items.isEmpty else { return [] }
        var rows: [DiscoverDisplayRow] = [.header(rail.title)] + items.map { DiscoverDisplayRow.item($0) }
        // Only when there is genuinely more to see; otherwise it is needless
        // navigation to a screen showing the same rows.
        if rail.items.count > cap { rows.append(.viewAll(rail)) }
        return rows
    }
}

/// Indices of the rows a cursor may land on. Headers are not selectable.
///
/// Deliberately an exhaustive switch rather than "anything that is not a
/// header": a new row case must be an explicit decision here, at the point
/// selectability is decided, not only in discoverSelection where it is projected.
/// Those two must agree, and a deny-list lets them drift silently.
func selectableDiscoverIndices(_ rows: [DiscoverDisplayRow]) -> [Int] {
    rows.enumerated().compactMap { i, row in
        switch row {
        case .header:  return nil
        case .item:    return i
        case .viewAll: return i
        }
    }
}

/// Project the cursor onto what it is actually pointing at.
func discoverSelection(rows: [DiscoverDisplayRow], cursor: Int) -> DiscoverSelection? {
    let selectable = selectableDiscoverIndices(rows)
    guard cursor >= 0, cursor < selectable.count else { return nil }
    switch rows[selectable[cursor]] {
    case .item(let item):  return .item(item)
    case .viewAll(let r):  return .viewAll(r)
    case .header:          return nil
    }
}

/// What `DiscoverScene` reads a feed through. Two providers stand behind it:
/// `DiscoverFeed` (Apple's web service, needs both tokens) and
/// `BridgeDiscoverFeed` (the Bridge app, needs neither). WHICH one a read uses
/// is the routing coordinator's decision, made per read.
protocol DiscoverFeedReading {
    func rails(limit: Int) throws -> [DiscoverRail]
    func tracks(for item: DiscoverItem) throws -> [DiscoverItem]
}

final class DiscoverFeed: DiscoverFeedReading {
    private let storefront: String
    private let token: () -> String?
    private let fetch: (String) -> Data?
    private let base = "https://api.music.apple.com"

    init(storefront: String, token: @escaping () -> String?, fetch: @escaping (String) -> Data?) {
        self.storefront = storefront
        self.token = token
        self.fetch = fetch
    }

    /// Apple's For You rails, empty ones dropped, then the self-named
    /// sections (`DiscoverSection`) this feed could read.
    ///
    /// The recommendations read is the feed: if it fails, the whole read
    /// fails, exactly as before. A SECTION's read failing only drops that
    /// section, because a missing "Top Albums" is a smaller wrong than no
    /// Discover at all. Sections are read only after the recommendations
    /// succeed, one after another (at most five extra round trips, and
    /// none at all on a dead connection, where the first read already threw).
    func rails(limit: Int = 30) throws -> [DiscoverRail] {
        try recommendationRails(limit: limit) + sectionRails()
    }

    /// Apple's For You rails alone, empty ones dropped.
    func recommendationRails(limit: Int = 30) throws -> [DiscoverRail] {
        let root = try json(at: "/v1/me/recommendations?limit=\(limit)")
        let rows = root["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let a = row["attributes"] as? [String: Any] else { return nil }
            let contents = ((row["relationships"] as? [String: Any])?["contents"]
                            as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let items = decodeItems(contents)
            // A rail with nothing in it is an empty heading, not a row.
            guard !items.isEmpty else { return nil }
            return DiscoverRail(
                id: id,
                title: (a["title"] as? [String: Any])?["stringForDisplay"] as? String ?? "",
                items: items,
                isRecentlyPlayed: (a["kind"] as? String) == "recently-played",
                resourceTypes: (a["resourceTypes"] as? [String]) ?? [])
        }
    }

    /// The mixed recently-played rail: stations, albums and playlists, newest
    /// first. Matches Music.app's own Recently Played row.
    func recentlyPlayed(limit: Int = 20) throws -> [DiscoverItem] {
        let root = try json(at: "/v1/me/recent/played?limit=\(limit)")
        return decodeItems(root["data"] as? [[String: Any]] ?? [])
    }

    // MARK: - Sections

    /// Items per chart. Apple's own default (documented: default 20, max 200).
    static let chartLimit = 20
    /// Recently played stations. 10 is the endpoint's default page.
    static let recentStationsLimit = 10

    /// Every section this feed could read, empty ones dropped, in
    /// `DiscoverSection` order.
    func sectionRails() -> [DiscoverRail] {
        var found: [DiscoverSection: [DiscoverItem]] = [:]
        found[.recentlyAdded] = try? recentlyAdded()
        found[.recentStations] = try? recentStations()
        if let charts = try? charts() {
            found[.topSongs] = charts.songs
            found[.topAlbums] = charts.albums
            found[.topPlaylists] = charts.playlists
        }
        return DiscoverSection.allCases.compactMap { section in
            guard let items = found[section], !items.isEmpty else { return nil }
            return DiscoverRail(id: section.railID, title: section.title, items: items,
                                isRecentlyPlayed: false, resourceTypes: section.resourceTypes,
                                section: section)
        }
    }

    /// What he added to his library most recently, newest first, as CATALOGUE
    /// items.
    ///
    /// The endpoint answers with LIBRARY resources (`library-albums`,
    /// `library-playlists`, ids like `l.NWqWi1m`, and a library album's
    /// `playParams` carries no catalogue id: Apple's documented example). Every
    /// Discover drill-in and play runs on catalogue ids, so each row is
    /// resolved to its catalogue counterpart through the documented `catalog`
    /// relationship, one batched request per resource type. A row with no
    /// known counterpart (his own playlists, an upload) is DROPPED, never
    /// guessed at: a row whose Enter opens nothing is worse than a shorter rail.
    func recentlyAdded() throws -> [DiscoverItem] {
        let root = try json(at: "/v1/me/library/recently-added")
        let rows = root["data"] as? [[String: Any]] ?? []
        func ids(_ type: String) -> [String] {
            rows.compactMap { ($0["type"] as? String) == type ? $0["id"] as? String : nil }
        }
        let albums = catalogCounterparts(library: "albums", catalogType: "albums", ids: ids("library-albums"))
        let playlists = catalogCounterparts(library: "playlists", catalogType: "playlists",
                                            ids: ids("library-playlists"))
        let resolved: [[String: Any]] = rows.compactMap { row in
            guard let id = row["id"] as? String, let type = row["type"] as? String else { return nil }
            switch type {
            case "library-albums":    return albums[id]
            case "library-playlists": return playlists[id]
            default:                  return nil
            }
        }
        return decodeItems(resolved)
    }

    /// Library id -> its catalogue resource, for those that have one. The
    /// catalogue resource's own attributes are used when it carries them; when
    /// it is only an identifier, the library row's attributes (name, artist,
    /// artwork) stand in, under the CATALOGUE id and type. Any failure is an
    /// empty map: the rows simply do not resolve.
    private func catalogCounterparts(library collection: String, catalogType: String,
                                     ids: [String]) -> [String: [String: Any]] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: ".-_"))) ?? $0 }
            .joined(separator: ",")
        guard let root = try? json(at: "/v1/me/library/\(collection)?ids=\(list)&include=catalog") else { return [:] }
        var out: [String: [String: Any]] = [:]
        for row in root["data"] as? [[String: Any]] ?? [] {
            guard let libraryID = row["id"] as? String,
                  let catalog = (((row["relationships"] as? [String: Any])?["catalog"]
                                  as? [String: Any])?["data"] as? [[String: Any]])?.first,
                  let catalogID = catalog["id"] as? String else { continue }
            let attributes = (catalog["attributes"] as? [String: Any]) ?? (row["attributes"] as? [String: Any])
            guard let attributes else { continue }
            out[libraryID] = ["id": catalogID, "type": (catalog["type"] as? String) ?? catalogType,
                              "attributes": attributes]
        }
        return out
    }

    /// Stations he played recently, newest first. Catalogue stations with
    /// their share URL, so Enter plays them exactly as a For You station does.
    func recentStations() throws -> [DiscoverItem] {
        let root = try json(at: "/v1/me/recent/radio-stations?limit=\(Self.recentStationsLimit)")
        return decodeItems(root["data"] as? [[String: Any]] ?? []).filter { $0.kind == .station }
    }

    /// The storefront's top charts, one request for all three. The response
    /// maps each requested type to an ARRAY of charts; the first chart of each
    /// type with anything in it is the one shown.
    func charts() throws -> (songs: [DiscoverItem], albums: [DiscoverItem], playlists: [DiscoverItem]) {
        let root = try json(at: "/v1/catalog/\(storefront)/charts?types=songs,albums,playlists&limit=\(Self.chartLimit)")
        let results = root["results"] as? [String: Any] ?? [:]
        func chart(_ type: String, _ kind: DiscoverItemKind) -> [DiscoverItem] {
            for chart in results[type] as? [[String: Any]] ?? [] {
                let items = decodeItems(chart["data"] as? [[String: Any]] ?? []).filter { $0.kind == kind }
                if !items.isEmpty { return items }
            }
            return []
        }
        return (chart("songs", .song), chart("albums", .album), chart("playlists", .playlist))
    }

    /// The tracks on an album or playlist, for a read-only drill-in. Both live
    /// under `relationships.tracks` and both answer to the developer token
    /// alone (verified 2026-08-25).
    ///
    /// Returns empty for a station without spending a request: stations have no
    /// tracks relationship (the API 400s with "No relationship found matching
    /// 'tracks'"). Their nearest equivalent is the next-tracks feed, which is a
    /// POST that advances the station, so it does not belong behind a browse key.
    func tracks(for item: DiscoverItem) throws -> [DiscoverItem] {
        let collection: String
        switch item.kind {
        case .album: collection = "albums"
        case .playlist: collection = "playlists"
        case .station, .song: return []
        }
        let root = try json(at: "/v1/catalog/\(storefront)/\(collection)/\(item.id)?include=tracks")
        let rows = root["data"] as? [[String: Any]] ?? []
        let tracks = ((rows.first?["relationships"] as? [String: Any])?["tracks"]
                      as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return decodeItems(tracks)
    }

    // MARK: - Parsing

    private func decodeItems(_ rows: [[String: Any]]) -> [DiscoverItem] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["type"] as? String,
                  let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String,
                  let detail = DiscoverItemDetail(apiType: type, attributes: a)
            else { return nil }
            return DiscoverItem(
                id: id,
                name: name,
                subtitle: (a["artistName"] as? String) ?? (a["curatorName"] as? String),
                url: a["url"] as? String,
                artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String,
                detail: detail)
        }
    }

    private func json(at path: String) throws -> [String: Any] {
        guard token() != nil else { throw DiscoverFeedError.noToken }
        guard let data = fetch(base + path) else { throw DiscoverFeedError.fetchFailed }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiscoverFeedError.badResponse
        }
        return root
    }
}

/// Wired against the real AuthManager. nil when either token is missing —
/// callers hide the Discover tab rather than showing an error surface, the same way
/// makeCatalog() degrades to favorites-only.
func makeDiscoverFeed() -> DiscoverFeed? {
    let auth = AuthManager()
    guard (try? auth.requireDeveloperToken()) != nil, auth.userToken() != nil else { return nil }
    return DiscoverFeed(
        storefront: auth.storefront(),
        token: { AuthManager().userToken() },
        fetch: { urlString in
            let auth = AuthManager()
            guard let url = URL(string: urlString),
                  let dev = try? auth.requireDeveloperToken(),
                  let user = auth.userToken() else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(dev)", forHTTPHeaderField: "Authorization")
            req.setValue(user, forHTTPHeaderField: "Music-User-Token")
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 20)
            return out
        })
}

/// Whether the Discover tab opens at all.
///
/// The door follows the DATA selection, not the output (score: data route and
/// output, step 5). The WEB SERVICE needs a user token (both its endpoints are
/// /v1/me/), so with MusicTUI's own data no sign-in means no tab, exactly as
/// before. SpanDAC on this Mac reads the feed with no keys, so once a person
/// has accepted SpanDAC as the data source the door is open, whatever the
/// output is. A blocked output (C-REPAIR) reads MusicTUI's own data, so it
/// needs the sign-in like open data does. A later change of data source is
/// answered by the scene itself, in words.
///
/// Pure and out here so the door is testable: as a guard inside the shell it
/// could be reverted with every scene-level test still green (Codex S2).
/// `hasUserToken` is only asked when the selection does not already open the
/// door, so SpanDAC data never reads the token file.
func discoverTabAdmitted(selection: EffectiveSelection, hasUserToken: @autoclosure () -> Bool) -> Bool {
    if case .consistent(.spandacMac, _) = selection { return true }
    return hasUserToken()
}

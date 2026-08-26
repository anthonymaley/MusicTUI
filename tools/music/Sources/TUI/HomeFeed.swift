// The Home tab's read layer: Apple's own For You rails plus recently played.
// Both endpoints need a Music User Token (403 without), unlike RadioCatalog's
// catalog reads which run on the developer token alone.
//
// Probed live 2026-08-25, full write-up in docs/platform-notes.md. What the
// probes settled, so nobody re-derives it:
//
//  - /v1/me/recommendations returned 17 rails, ids stable across calls, and
//    `cache-control: private, max-age=600`. Ten minutes is Apple's own hint to
//    its clients, so refresh-on-load with a 10 minute cache tracks the real
//    rotation rather than guessing at one. Caching is the caller's job.
//  - "Top Picks for You", the first rail in Music.app's Home, is NOT in that
//    list. It is composed client side. Its ingredients are here (its station
//    cards live in "Stations for You", its new release in "New Releases for
//    You"), but the rail itself cannot be fetched. Do not go looking again.
//  - The feed carries its own "Recently Played" rail under kind
//    `recently-played`. /v1/me/recent/played returns the same thing with more
//    items and a `?types=` filter, so both are exposed here.
//  - Dead ends already paid for: /v1/me/home 404, catalog/new-releases 400,
//    music-summaries 404 (there is no Replay API), platform=web rejected.
import Foundation

enum HomeFeedError: Error {
    case noToken
    case fetchFailed
    case badResponse
}

/// What a Home row points at. Rails are deliberately mixed: one rail can hold
/// stations, albums and playlists side by side, and each plays differently.
enum HomeItemKind: Equatable {
    case station, album, playlist, song
}

/// Kind-specific metadata, all of it present inline in the recommendations
/// payload (probed live 2026-08-25) so the detail panel costs no extra request.
/// Modelled as an enum rather than a widening set of optionals so an album
/// cannot carry isLive and a station cannot carry a track count.
enum HomeItemDetail: Equatable {
    case station(isLive: Bool)
    case album(trackCount: Int?, year: Int?, genre: String?)
    case playlist(description: String?)
    case song

    var kind: HomeItemKind {
        switch self {
        case .station:  return .station
        case .album:    return .album
        case .playlist: return .playlist
        case .song:     return .song
        }
    }

    /// nil for a type Apple added that we do not model yet: skip the row rather
    /// than throwing, matching the old HomeItemKind(apiType:) behaviour.
    init?(apiType: String, attributes a: [String: Any]) {
        switch apiType {
        case "stations":
            self = .station(isLive: a["isLive"] as? Bool ?? false)
        case "albums":
            self = .album(trackCount: a["trackCount"] as? Int,
                          year: homeReleaseYear(a["releaseDate"] as? String),
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
private func homeReleaseYear(_ raw: String?) -> Int? {
    guard let raw, raw.count >= 4 else { return nil }
    return Int(raw.prefix(4))
}

struct HomeItem: Equatable {
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
    let detail: HomeItemDetail

    var kind: HomeItemKind { detail.kind }
}

struct HomeRail: Equatable {
    let id: String
    let title: String
    let items: [HomeItem]
    /// True for the feed's own recently-played rail. Keyed off the API's `kind`
    /// rather than the display title, which is localized.
    let isRecentlyPlayed: Bool
    /// The API's own content-type flag, e.g. ["albums"]. This is what rail
    /// selection runs on: titles are localized and rotate, flags do not.
    let resourceTypes: [String]
}

// MARK: - Display model (pure, so the scene's layout is testable without a network)

/// A flattened Home row. Rails become headers; only items are selectable.
enum HomeDisplayRow: Equatable {
    case header(String)
    case item(HomeItem)
}

/// Music.app's Home leads with Top Picks and then Recently Played. Top Picks is
/// not fetchable at all, so the closest honest thing is to lead with the row the
/// user actually recognizes rather than leaving it wherever the feed put it.
/// Stable otherwise: relative order is preserved on both sides of the split.
func orderedHomeRails(_ rails: [HomeRail]) -> [HomeRail] {
    rails.filter(\.isRecentlyPlayed) + rails.filter { !$0.isRecentlyPlayed }
}

func homeDisplayRows(rails: [HomeRail], perRail: Int) -> [HomeDisplayRow] {
    rails.flatMap { rail -> [HomeDisplayRow] in
        let items = rail.items.prefix(max(1, perRail))
        // An empty rail is a bare heading with nothing under it, which reads as
        // a bug rather than as an empty state.
        guard !items.isEmpty else { return [] }
        return [.header(rail.title)] + items.map { HomeDisplayRow.item($0) }
    }
}

/// Indices of the rows a cursor may land on. Headers are not selectable.
func selectableHomeIndices(_ rows: [HomeDisplayRow]) -> [Int] {
    rows.enumerated().compactMap { i, row in
        if case .item = row { return i }
        return nil
    }
}

final class HomeFeed {
    private let storefront: String
    private let token: () -> String?
    private let fetch: (String) -> Data?
    private let base = "https://api.music.apple.com"

    init(storefront: String, token: @escaping () -> String?, fetch: @escaping (String) -> Data?) {
        self.storefront = storefront
        self.token = token
        self.fetch = fetch
    }

    /// Apple's For You rails, empty ones dropped.
    func rails(limit: Int = 30) throws -> [HomeRail] {
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
            return HomeRail(
                id: id,
                title: (a["title"] as? [String: Any])?["stringForDisplay"] as? String ?? "",
                items: items,
                isRecentlyPlayed: (a["kind"] as? String) == "recently-played",
                resourceTypes: (a["resourceTypes"] as? [String]) ?? [])
        }
    }

    /// The mixed recently-played rail: stations, albums and playlists, newest
    /// first. Matches Music.app's own Recently Played row.
    func recentlyPlayed(limit: Int = 20) throws -> [HomeItem] {
        let root = try json(at: "/v1/me/recent/played?limit=\(limit)")
        return decodeItems(root["data"] as? [[String: Any]] ?? [])
    }

    /// The tracks on an album or playlist, for a read-only drill-in. Both live
    /// under `relationships.tracks` and both answer to the developer token
    /// alone (verified 2026-08-25).
    ///
    /// Returns empty for a station without spending a request: stations have no
    /// tracks relationship (the API 400s with "No relationship found matching
    /// 'tracks'"). Their nearest equivalent is the next-tracks feed, which is a
    /// POST that advances the station, so it does not belong behind a browse key.
    func tracks(for item: HomeItem) throws -> [HomeItem] {
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

    private func decodeItems(_ rows: [[String: Any]]) -> [HomeItem] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["type"] as? String,
                  let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String,
                  let detail = HomeItemDetail(apiType: type, attributes: a)
            else { return nil }
            return HomeItem(
                id: id,
                name: name,
                subtitle: (a["artistName"] as? String) ?? (a["curatorName"] as? String),
                url: a["url"] as? String,
                artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String,
                detail: detail)
        }
    }

    private func json(at path: String) throws -> [String: Any] {
        guard token() != nil else { throw HomeFeedError.noToken }
        guard let data = fetch(base + path) else { throw HomeFeedError.fetchFailed }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomeFeedError.badResponse
        }
        return root
    }
}

/// Wired against the real AuthManager. nil when either token is missing —
/// callers hide the Home tab rather than showing an error surface, the same way
/// makeCatalog() degrades to favorites-only.
func makeHomeFeed() -> HomeFeed? {
    let auth = AuthManager()
    guard (try? auth.requireDeveloperToken()) != nil, auth.userToken() != nil else { return nil }
    return HomeFeed(
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

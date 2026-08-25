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

    init?(apiType: String) {
        switch apiType {
        case "stations": self = .station
        case "albums": self = .album
        case "playlists": self = .playlist
        case "songs": self = .song
        default: return nil   // Apple can add a type at any time; skip, don't throw
        }
    }
}

struct HomeItem: Equatable {
    let id: String
    let kind: HomeItemKind
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
}

struct HomeRail: Equatable {
    let id: String
    let title: String
    let items: [HomeItem]
    /// True for the feed's own recently-played rail. Keyed off the API's `kind`
    /// rather than the display title, which is localized.
    let isRecentlyPlayed: Bool
}

final class HomeFeed {
    private let token: () -> String?
    private let fetch: (String) -> Data?
    private let base = "https://api.music.apple.com"

    init(token: @escaping () -> String?, fetch: @escaping (String) -> Data?) {
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
                isRecentlyPlayed: (a["kind"] as? String) == "recently-played")
        }
    }

    /// The mixed recently-played rail: stations, albums and playlists, newest
    /// first. Matches Music.app's own Recently Played row.
    func recentlyPlayed(limit: Int = 20) throws -> [HomeItem] {
        let root = try json(at: "/v1/me/recent/played?limit=\(limit)")
        return decodeItems(root["data"] as? [[String: Any]] ?? [])
    }

    // MARK: - Parsing

    private func decodeItems(_ rows: [[String: Any]]) -> [HomeItem] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["type"] as? String,
                  let kind = HomeItemKind(apiType: type),
                  let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String
            else { return nil }
            return HomeItem(
                id: id,
                kind: kind,
                name: name,
                subtitle: (a["artistName"] as? String) ?? (a["curatorName"] as? String),
                url: a["url"] as? String,
                artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String)
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

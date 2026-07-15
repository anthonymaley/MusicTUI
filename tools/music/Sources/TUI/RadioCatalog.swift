// Catalog station reads. Developer token only — live-verified 200 with no
// Music-User-Token (2026-07-15), which the Apple docs never state.
//
// Hard limits established by probe, do NOT design around them being fixable:
//  - no browse-all: unfiltered /stations 400s ("No id(s) supplied")
//  - no genre browse: a station-genre is {"name":"Jazz"} — no link to stations
//    in either direction, and filter[genre] 400s
//  - search is shallow (5-7 hits, no pagination) and unreliable: searching
//    "bbc radio 1" returns Mozart and Beethoven stations
//  - the API does not cover everything playable: BBC Radio 1 returns data:[]
//    by id in us/gb/be with and without a user token. Reason unknown. So
//    `resolve` returning nil is NORMAL, not an error.
import Foundation

enum RadioCatalogError: Error {
    case noToken
    case fetchFailed
    case badResponse
}

final class RadioCatalog {
    private let storefront: String
    private let token: () -> String?
    private let fetch: (String) -> Data?

    init(storefront: String, token: @escaping () -> String?, fetch: @escaping (String) -> Data?) {
        self.storefront = storefront
        self.token = token
        self.fetch = fetch
    }

    private var base: String { "https://api.music.apple.com/v1/catalog/\(storefront)" }

    func liveStations() throws -> [Station] {
        try stations(at: "\(base)/stations?filter[featured]=apple-music-live-radio")
    }

    func personalStation() throws -> [Station] {
        try stations(at: "\(base)/stations?filter[identity]=personal")
    }

    /// nil when the API doesn't know the id — normal (BBC Radio 1), not an error.
    func resolve(id: String) throws -> Station? {
        try stations(at: "\(base)/stations?ids=\(id)").first
    }

    func search(term: String) throws -> [Station] {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let data = try get("\(base)/search?term=\(q)&types=stations&limit=25")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let st = results["stations"] as? [String: Any]
        else { return [] }   // no stations key = zero hits, not a failure
        return decode(st["data"] as? [[String: Any]] ?? [])
    }

    private func stations(at url: String) throws -> [Station] {
        let data = try get(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RadioCatalogError.badResponse
        }
        return decode(root["data"] as? [[String: Any]] ?? [])
    }

    private func get(_ url: String) throws -> Data {
        guard token() != nil else { throw RadioCatalogError.noToken }
        guard let data = fetch(url) else { throw RadioCatalogError.fetchFailed }
        return data
    }

    private func decode(_ rows: [[String: Any]]) -> [Station] {
        rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let a = row["attributes"] as? [String: Any],
                  let name = a["name"] as? String,
                  let url = a["url"] as? String
            else { return nil }
            return Station(
                id: id, name: name, url: url,
                isLive: a["isLive"] as? Bool,
                artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String)
        }
    }
}

/// Wired against the real AuthManager. nil when there's no developer token —
/// callers degrade to favorites-only rather than erroring.
func makeCatalog() -> RadioCatalog? {
    let auth = AuthManager()
    guard (try? auth.requireDeveloperToken()) != nil else { return nil }
    return RadioCatalog(
        storefront: auth.storefront(),
        token: { try? AuthManager().requireDeveloperToken() },
        fetch: { urlString in
            guard let url = URL(string: urlString),
                  let tok = try? AuthManager().requireDeveloperToken() else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 20)
            return out
        })
}

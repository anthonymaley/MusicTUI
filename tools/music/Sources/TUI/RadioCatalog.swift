// Catalog station reads. Live stations: developer token only, live-verified
// 200 with no Music-User-Token (2026-07-15). Personal stations: a developer
// token alone got 403 at the 2026-09-25 gate, so the Music-User-Token is now
// sent whenever AuthManager has one; live reads keep working with or without
// it.
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

/// One fetch's outcome: nil is a transport-level failure (`fetchFailed`);
/// otherwise the HTTP status and whatever body came back, which `get` checks
/// itself rather than trusting a non-nil `Data` to mean success.
struct RadioCatalogResponse {
    let status: Int
    let data: Data
}

enum RadioCatalogError: Error, Equatable {
    case noToken
    case fetchFailed
    case badResponse
    /// A non-2xx response. `appleTitle` is the JSON:API `errors[0].title`
    /// when the body has one.
    case httpStatus(Int, appleTitle: String?)
}

extension RadioCatalogError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noToken: return "No developer token configured."
        case .fetchFailed: return "Radio catalogue request failed."
        case .badResponse: return "Radio catalogue returned an unreadable response."
        case .httpStatus(let status, let title):
            if let title, !title.isEmpty { return "\(title) (status \(status))." }
            return "Radio catalogue request failed (status \(status))."
        }
    }
}

final class RadioCatalog {
    private let storefront: String
    private let token: () -> String?
    private let fetch: (String) -> RadioCatalogResponse?
    /// Whether a Music-User-Token is on hand — read only for the Personal
    /// browse's "no token, run auth" message; live reads never consult it.
    let hasUserToken: () -> Bool

    init(storefront: String, token: @escaping () -> String?,
         fetch: @escaping (String) -> RadioCatalogResponse?,
         hasUserToken: @escaping () -> Bool = { false }) {
        self.storefront = storefront
        self.token = token
        self.fetch = fetch
        self.hasUserToken = hasUserToken
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
        guard let response = fetch(url) else { throw RadioCatalogError.fetchFailed }
        guard (200...299).contains(response.status) else {
            throw RadioCatalogError.httpStatus(response.status, appleTitle: Self.appleErrorTitle(in: response.data))
        }
        return response.data
    }

    /// Apple's JSON:API error shape: `{"errors":[{"title": "..."}]}`. nil when
    /// the body isn't that shape — the status code alone still gets reported.
    private static func appleErrorTitle(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]],
              let title = errors.first?["title"] as? String
        else { return nil }
        return title
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

/// The request `makeCatalog()`'s fetch sends: the developer token always,
/// the Music-User-Token added on top when the caller has one. Pure and free
/// of `AuthManager`, so header presence is testable without touching real
/// config (Personal needs the user token — see the header comment above —
/// live reads are unaffected by its presence either way).
func radioCatalogRequest(url: URL, developerToken: String, userToken: String?) -> URLRequest {
    var req = URLRequest(url: url)
    req.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
    if let userToken {
        req.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
    }
    return req
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
            let req = radioCatalogRequest(url: url, developerToken: tok, userToken: AuthManager().userToken())
            let sem = DispatchSemaphore(value: 0)
            var out: RadioCatalogResponse?
            URLSession.shared.dataTask(with: req) { data, response, _ in
                if let data, let http = response as? HTTPURLResponse {
                    out = RadioCatalogResponse(status: http.statusCode, data: data)
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 20)
            return out
        },
        hasUserToken: { AuthManager().userToken() != nil })
}

import Foundation

struct CatalogSong {
    let id: String
    let title: String
    let artist: String
    let album: String

    func toDict() -> [String: Any] {
        ["id": id, "title": title, "artist": artist, "album": album]
    }
}

struct RESTAPIBackend {
    let developerToken: String
    let userToken: String?
    let storefront: String

    // MARK: - Raw requests

    func get(_ path: String) async throws -> (Data, Int) {
        let url = URL(string: "https://api.music.apple.com\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if let userToken = userToken {
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    func post(_ path: String, body: Data? = nil) async throws -> (Data, Int) {
        let url = URL(string: "https://api.music.apple.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if let userToken = userToken {
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    func delete(_ path: String) async throws -> (Data, Int) {
        let url = URL(string: "https://api.music.apple.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if let userToken = userToken {
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    // MARK: - Catalog Search

    func searchSongs(query: String, limit: Int = 10) async throws -> [CatalogSong] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (data, status) = try await get("/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs&limit=\(limit)")
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }
        return try parseSongs(from: data)
    }

    // MARK: - Library Operations (require user token)

    func addToLibrary(songIDs: [String]) async throws {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let ids = songIDs.joined(separator: ",")
        let (_, status) = try await post("/v1/me/library?ids[songs]=\(ids)")
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
    }

    // MARK: - Parsing

    private func parseSongs(from data: Data) throws -> [CatalogSong] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        let songs = results?["songs"] as? [String: Any]
        let songData = songs?["data"] as? [[String: Any]] ?? []

        return songData.map { song in
            let attrs = song["attributes"] as? [String: Any] ?? [:]
            return CatalogSong(
                id: song["id"] as? String ?? "",
                title: attrs["name"] as? String ?? "Unknown",
                artist: attrs["artistName"] as? String ?? "Unknown",
                album: attrs["albumName"] as? String ?? ""
            )
        }
    }
}

enum APIError: Error, LocalizedError {
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "API request failed with status \(code)"
        }
    }
}

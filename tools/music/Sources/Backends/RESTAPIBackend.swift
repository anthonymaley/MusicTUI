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
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http.statusCode)
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
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http.statusCode)
    }

    // MARK: - Catalog Search

    func searchSongs(query: String, limit: Int = 10) async throws -> [CatalogSong] {
        try await search(term: query, types: [.songs], limit: limit).songs
    }

    /// Multi-type search across the catalog or the user's library. Library
    /// search needs a user token and uses the `library-*` type names against
    /// the `/v1/me/library/search` endpoint.
    func search(term: String, types: [SearchType], limit: Int = 10,
                library: Bool = false) async throws -> SearchResults {
        if library { guard userToken != nil else { throw AuthError.userTokenRequired } }
        let path = searchPath(storefront: storefront, term: term, types: types,
                              limit: limit, library: library)
        let (data, status) = try await get(path)
        guard (200...299).contains(status) else {
            if library && (status == 401 || status == 403) { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseSearchResults(from: data, types: types, library: library)
    }

    func song(id: String) async throws -> CatalogSong {
        let (data, status) = try await get("/v1/catalog/\(storefront)/songs/\(id)")
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }
        return try parseCatalogSong(from: data)
    }

    // MARK: - Library Browse (require user token)

    func libraryAlbums(limit: Int = 100, offset: Int = 0) async throws -> [LibraryAlbum] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let (data, status) = try await get(libraryAlbumsPath(limit: limit, offset: offset))
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseLibraryAlbums(from: data)
    }

    func librarySongs(limit: Int = 100, offset: Int = 0) async throws -> [LibrarySong] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let (data, status) = try await get(librarySongsPath(limit: limit, offset: offset))
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseLibrarySongs(from: data)
    }

    func libraryArtists(limit: Int = 100, offset: Int = 0) async throws -> [LibraryArtist] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let (data, status) = try await get(libraryArtistsPath(limit: limit, offset: offset))
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseLibraryArtists(from: data)
    }

    func artistAlbums(artistID: String) async throws -> [LibraryAlbum] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let (data, status) = try await get(artistAlbumsPath(artistID: artistID))
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseLibraryAlbums(from: data)   // the relationship returns album objects
    }

    /// The library album a library song belongs to, via the song's `albums`
    /// relationship. One targeted request that yields the SAME album object
    /// (id + artwork) `libraryAlbums()` streams to the Library tab — the Now
    /// tab's route from a playing track to the Library tab's own cover, since
    /// `/v1/me/library/search` can't reliably resolve an album by name (probed
    /// live 2026-07-15: it matches album NAME only, never artistName, and even
    /// an exact name misses — "People's Instinctive Travels a" returns nothing
    /// while the single word "instinctive" returns the album).
    func libraryAlbumForSong(songID: String) async throws -> LibraryAlbum? {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let (data, status) = try await get(librarySongAlbumsPath(songID: songID))
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        return parseLibraryAlbums(from: data).first   // the relationship returns album objects
    }

    // MARK: - Library Operations (require user token)

    func addToLibrary(songIDs: [String]) async throws {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let ids = songIDs.joined(separator: ",")
        let path = "/v1/me/library?ids%5Bsongs%5D=\(ids)"
        let (_, status) = try await post(path)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
    }

    // MARK: - Library Playlists (require user token)

    struct LibraryPlaylist {
        let id: String
        let name: String
        var artworkURL: String? = nil
    }

    /// All library playlists, following pagination. User-created playlists are
    /// all API-visible (verified live); only the built-in smart playlists
    /// (Music, Recently Added, ...) are AppleScript-only.
    func libraryPlaylists() async throws -> [LibraryPlaylist] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        var out: [LibraryPlaylist] = []
        var path: String? = "/v1/me/library/playlists?limit=100"
        while let p = path {
            let (data, status) = try await get(p)
            guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for item in json?["data"] as? [[String: Any]] ?? [] {
                let attrs = item["attributes"] as? [String: Any] ?? [:]
                guard let id = item["id"] as? String, let name = attrs["name"] as? String else { continue }
                out.append(LibraryPlaylist(id: id, name: name,
                                           artworkURL: (attrs["artwork"] as? [String: Any])?["url"] as? String))
            }
            path = json?["next"] as? String
        }
        return out
    }

    /// API ID of the library playlist with this exact name, or nil if the API
    /// can't see it (built-in smart playlists; a locally-created playlist that
    /// hasn't synced yet).
    func playlistID(named name: String) async throws -> String? {
        try await libraryPlaylists().first { $0.name == name }?.id
    }

    /// Add catalog songs to a library playlist directly — no add-to-library,
    /// no sync sleep, no AppleScript title lookup. POST returns 204.
    func addTracksToPlaylist(playlistID: String, songIDs: [String]) async throws {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        guard !songIDs.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: playlistTracksRequestBody(songIDs: songIDs))
        let (_, status) = try await post("/v1/me/library/playlists/\(playlistID)/tracks", body: body)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
    }

    /// Create a library playlist (optionally with catalog songs in one call)
    /// and return its API ID.
    func createPlaylist(name: String, songIDs: [String] = []) async throws -> String {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let body = try JSONSerialization.data(withJSONObject: playlistCreationRequestBody(name: name, songIDs: songIDs))
        let (data, status) = try await post("/v1/me/library/playlists", body: body)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = (json?["data"] as? [[String: Any]])?.first?["id"] as? String else {
            throw APIError.noData
        }
        return id
    }

    // MARK: - Parsing

    private func parseCatalogSong(from data: Data) throws -> CatalogSong {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let songData = json?["data"] as? [[String: Any]] ?? []
        guard let song = songData.first else {
            throw APIError.noData
        }
        return parseCatalogSongObject(song)
    }
}

/// Body for POST /v1/me/library/playlists/{id}/tracks (verified against the
/// LibraryPlaylistTracksRequest schema: the wrapper field is `data`, catalog
/// songs use type `songs`). Pure, for testability.
func playlistTracksRequestBody(songIDs: [String]) -> [String: Any] {
    ["data": songIDs.map { ["id": $0, "type": "songs"] }]
}

/// Body for POST /v1/me/library/playlists, optionally seeding tracks via the
/// `relationships.tracks` shape so create+populate is a single request. Pure.
func playlistCreationRequestBody(name: String, songIDs: [String]) -> [String: Any] {
    var body: [String: Any] = ["attributes": ["name": name]]
    if !songIDs.isEmpty {
        body["relationships"] = ["tracks": playlistTracksRequestBody(songIDs: songIDs)]
    }
    return body
}

// MARK: - Multi-type search (pure helpers, testable without the network)

struct CatalogAlbum {
    let id: String; let name: String; let artist: String
    var artworkURL: String? = nil
    func toDict() -> [String: Any] { ["id": id, "name": name, "artist": artist] }
}
struct CatalogArtist {
    let id: String; let name: String
    func toDict() -> [String: Any] { ["id": id, "name": name] }
}
struct CatalogPlaylist {
    let id: String; let name: String; let curator: String
    func toDict() -> [String: Any] { ["id": id, "name": name, "curator": curator] }
}

/// The entity types `music search` can request. Library search uses the
/// `library-` prefixed type names and results keys (Apple Music API convention).
enum SearchType: String, CaseIterable {
    case songs, albums, artists, playlists
    func apiKey(library: Bool) -> String { library ? "library-\(rawValue)" : rawValue }
}

struct SearchResults {
    var songs: [CatalogSong] = []
    var albums: [CatalogAlbum] = []
    var artists: [CatalogArtist] = []
    var playlists: [CatalogPlaylist] = []
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// Parse a comma/space-separated list into known types, dropping unknowns and
/// de-duping while preserving order. Empty/all-unknown falls back to songs.
func parseSearchTypes(_ raw: String) -> [SearchType] {
    let parsed = raw.lowercased()
        .split(whereSeparator: { $0 == "," || $0 == " " })
        .compactMap { SearchType(rawValue: String($0)) }
    var seen = Set<SearchType>(), out: [SearchType] = []
    for t in parsed where seen.insert(t).inserted { out.append(t) }
    return out.isEmpty ? [.songs] : out
}

/// Build the search request path. Catalog → `/v1/catalog/{sf}/search`; library →
/// `/v1/me/library/search` with `library-` type names.
func searchPath(storefront: String, term: String, types: [SearchType],
                limit: Int, library: Bool) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=")
    let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
    let typeList = types.map { $0.apiKey(library: library) }.joined(separator: ",")
    let base = library ? "/v1/me/library/search" : "/v1/catalog/\(storefront)/search"
    return "\(base)?term=\(encoded)&types=\(typeList)&limit=\(limit)"
}

/// Parse an Apple Music search response into typed results. Catalog and library
/// share the shape `results[<key>].data[].attributes`; only the keys differ.
func parseSearchResults(from data: Data, types: [SearchType], library: Bool) -> SearchResults {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let results = json?["results"] as? [String: Any] ?? [:]
    var out = SearchResults()
    for type in types {
        let items = (results[type.apiKey(library: library)] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        switch type {
        case .songs: out.songs = items.map(parseCatalogSongObject)
        case .albums: out.albums = items.map(parseCatalogAlbumObject)
        case .artists: out.artists = items.map(parseCatalogArtistObject)
        case .playlists: out.playlists = items.map(parseCatalogPlaylistObject)
        }
    }
    return out
}

func parseCatalogSongObject(_ song: [String: Any]) -> CatalogSong {
    let attrs = song["attributes"] as? [String: Any] ?? [:]
    return CatalogSong(
        id: song["id"] as? String ?? "",
        title: attrs["name"] as? String ?? "Unknown",
        artist: attrs["artistName"] as? String ?? "Unknown",
        album: attrs["albumName"] as? String ?? "")
}

func parseCatalogAlbumObject(_ album: [String: Any]) -> CatalogAlbum {
    let attrs = album["attributes"] as? [String: Any] ?? [:]
    return CatalogAlbum(
        id: album["id"] as? String ?? "",
        name: attrs["name"] as? String ?? "Unknown",
        artist: attrs["artistName"] as? String ?? "Unknown",
        // Same `attributes.artwork.url` read parseLibraryAlbums already does —
        // the Now-tab album route (NowArtwork.swift) needs it to accept a hit.
        artworkURL: (attrs["artwork"] as? [String: Any])?["url"] as? String)
}

func parseCatalogArtistObject(_ artist: [String: Any]) -> CatalogArtist {
    let attrs = artist["attributes"] as? [String: Any] ?? [:]
    return CatalogArtist(
        id: artist["id"] as? String ?? "",
        name: attrs["name"] as? String ?? "Unknown")
}

func parseCatalogPlaylistObject(_ playlist: [String: Any]) -> CatalogPlaylist {
    let attrs = playlist["attributes"] as? [String: Any] ?? [:]
    return CatalogPlaylist(
        id: playlist["id"] as? String ?? "",
        name: attrs["name"] as? String ?? "Unknown",
        curator: attrs["curatorName"] as? String ?? "")
}

// MARK: - Library browse (pure helpers)

struct LibraryAlbum { let id: String; let name: String; let artist: String; let trackCount: Int
    var artworkURL: String? = nil
    func toDict() -> [String: Any] { ["id": id, "name": name, "artist": artist, "trackCount": trackCount] } }

func libraryAlbumsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/albums?limit=\(limit)&offset=\(offset)"
}

// Library list endpoints return resources under a top-level `data` array
// (unlike catalog search's results{<key>}{data}).
func parseLibraryDataArray(from data: Data) -> [[String: Any]] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return json?["data"] as? [[String: Any]] ?? []
}

func parseLibraryAlbums(from data: Data) -> [LibraryAlbum] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibraryAlbum(id: obj["id"] as? String ?? "",
                            name: a["name"] as? String ?? "Unknown",
                            artist: a["artistName"] as? String ?? "Unknown",
                            // Library-albums trackCount = tracks of this album IN the
                            // library; a loose playlist-song stub reads as 1, which the
                            // album-artists filter uses to exclude it. Missing → 0.
                            trackCount: a["trackCount"] as? Int ?? 0,
                            artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String)
    }
}

struct LibrarySong { let id: String; let title: String; let artist: String; let album: String
    func toDict() -> [String: Any] { ["id": id, "title": title, "artist": artist, "album": album] } }

func librarySongsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/songs?limit=\(limit)&offset=\(offset)"
}

func parseLibrarySongs(from data: Data) -> [LibrarySong] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibrarySong(id: obj["id"] as? String ?? "",
                           title: a["name"] as? String ?? "Unknown",
                           artist: a["artistName"] as? String ?? "Unknown",
                           album: a["albumName"] as? String ?? "")
    }
}

struct LibraryArtist { let id: String; let name: String
    func toDict() -> [String: Any] { ["id": id, "name": name] } }

func libraryArtistsPath(limit: Int, offset: Int) -> String {
    "/v1/me/library/artists?limit=\(limit)&offset=\(offset)"
}
func artistAlbumsPath(artistID: String) -> String {
    "/v1/me/library/artists/\(artistID)/albums?limit=100"
}
/// A library song's `albums` relationship — one album per song, so no paging.
func librarySongAlbumsPath(songID: String) -> String {
    "/v1/me/library/songs/\(songID)/albums"
}
func parseLibraryArtists(from data: Data) -> [LibraryArtist] {
    parseLibraryDataArray(from: data).map { obj in
        let a = obj["attributes"] as? [String: Any] ?? [:]
        return LibraryArtist(id: obj["id"] as? String ?? "", name: a["name"] as? String ?? "Unknown")
    }
}

enum APIError: Error, LocalizedError {
    case requestFailed(Int)
    case noData
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "API request failed with status \(code)"
        case .noData: return "API response did not include data"
        case .invalidResponse: return "API returned a non-HTTP response"
        }
    }
}

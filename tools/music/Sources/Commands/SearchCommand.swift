import ArgumentParser
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search the Apple Music catalog (developer token) or your library (no token).")
    @Argument(help: "Search query") var query: [String]
    @Option(name: .long, help: "Filter by artist") var artist: String?
    @Option(name: .long, help: "Filter by album") var album: String?
    @Option(name: .long, help: "Types to search: songs,albums,artists,playlists") var types: String = "songs"
    @Flag(name: .long, help: "Search your library instead of the catalog (no token needed)") var library = false
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let searchTypes = parseSearchTypes(types)
        let results: SearchResults
        let term: String
        if library {
            // Branch Search.run() before requireDeveloperToken(). Catalog
            // search still needs the developer token; --library must not
            // read either token before doing its AppleScript path.
            term = query.joined(separator: " ")
            results = try librarySearchResults(term: term, artist: artist, album: album,
                                               types: searchTypes, limit: limit)
        } else {
            let auth = AuthManager()
            let devToken = try auth.requireDeveloperToken()
            let api = RESTAPIBackend(developerToken: devToken, userToken: nil, storefront: auth.storefront())
            var catalogTerm = query.joined(separator: " ")
            if let artist = artist { catalogTerm += " \(artist)" }
            if let album = album { catalogTerm += " \(album)" }
            term = catalogTerm
            results = try syncRun { try await api.search(term: term, types: searchTypes, limit: limit, library: false) }
        }

        if results.isEmpty {
            print("No results for '\(term)'")
            throw ExitCode.failure
        }

        // Cache songs so index-based `add`/quick-pick keep working off results.
        if !results.songs.isEmpty {
            let songResults = searchCacheRows(results.songs, origin: library ? .library : .catalog)
            try? ResultCache().writeSongs(songResults)
        }

        if json {
            let output = OutputFormat(mode: .json)
            // Preserve the historic bare-array shape for the songs-only default;
            // only switch to a keyed object when more than one type is present.
            if searchTypes == [.songs] {
                print(output.render(results.songs.map { $0.toDict() }))
            } else {
                var payload: [String: Any] = [:]
                if !results.songs.isEmpty { payload["songs"] = results.songs.map { $0.toDict() } }
                if !results.albums.isEmpty { payload["albums"] = results.albums.map { $0.toDict() } }
                if !results.artists.isEmpty { payload["artists"] = results.artists.map { $0.toDict() } }
                if !results.playlists.isEmpty { payload["playlists"] = results.playlists.map { $0.toDict() } }
                print(output.render(payload))
            }
            return
        }

        printSearchResults(results)
    }
}

/// Cache rows for numbered song results. Library search rows carry Music's
/// persistent id, not a catalog id, so they are tagged by origin and the
/// index readers route them by that tag instead of by the id.
func searchCacheRows(_ songs: [CatalogSong], origin: SongOrigin) -> [SongResult] {
    songs.enumerated().map { (i, s) in
        SongResult(index: i + 1, title: s.title, artist: s.artist, album: s.album,
                   catalogId: s.id, origin: origin)
    }
}

/// Human-readable multi-type search output. Songs stay numbered (they back the
/// index-based `add`/quick-pick cache); other types are listed with their ids.
func printSearchResults(_ r: SearchResults) {
    for (i, s) in r.songs.enumerated() {
        print("\(i + 1). \(s.title) — \(s.artist) [\(s.album)] (id: \(s.id))")
    }
    if !r.albums.isEmpty {
        print(r.songs.isEmpty ? "Albums:" : "\nAlbums:")
        for a in r.albums { print("  \(a.name) — \(a.artist) (id: \(a.id))") }
    }
    if !r.artists.isEmpty {
        print(r.songs.isEmpty && r.albums.isEmpty ? "Artists:" : "\nArtists:")
        for a in r.artists { print("  \(a.name) (id: \(a.id))") }
    }
    if !r.playlists.isEmpty {
        print(r.songs.isEmpty && r.albums.isEmpty && r.artists.isEmpty ? "Playlists:" : "\nPlaylists:")
        for p in r.playlists {
            let by = p.curator.isEmpty ? "" : " — \(p.curator)"
            print("  \(p.name)\(by) (id: \(p.id))")
        }
    }
}

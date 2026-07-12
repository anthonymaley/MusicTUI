import ArgumentParser
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search the Apple Music catalog or your library.")
    @Argument(help: "Search query") var query: [String]
    @Option(name: .long, help: "Filter by artist") var artist: String?
    @Option(name: .long, help: "Filter by album") var album: String?
    @Option(name: .long, help: "Types to search: songs,albums,artists,playlists") var types: String = "songs"
    @Flag(name: .long, help: "Search your library instead of the catalog") var library = false
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        // Library search needs the user token; catalog search does not.
        let userToken = library ? try auth.requireUserToken() : nil
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var term = query.joined(separator: " ")
        if let artist = artist { term += " \(artist)" }
        if let album = album { term += " \(album)" }
        let searchTypes = parseSearchTypes(types)

        let results = try syncRun {
            try await api.search(term: term, types: searchTypes, limit: limit, library: library)
        }

        if results.isEmpty {
            print("No results for '\(term)'")
            throw ExitCode.failure
        }

        // Cache songs so index-based `add`/quick-pick keep working off results.
        if !results.songs.isEmpty {
            let songResults = results.songs.enumerated().map { (i, s) in
                SongResult(index: i + 1, title: s.title, artist: s.artist, album: s.album, catalogId: s.id)
            }
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

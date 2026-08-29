import ArgumentParser
import Foundation

/// What `add N` does with a cached row. A library row is already owned, so
/// with no target playlist there is nothing to add and nothing to fetch; with
/// targets it is duplicated straight in. Neither needs a token. Pure.
enum AddIndexRoute: Equatable {
    case alreadyInLibrary
    case duplicateIntoPlaylists
    case catalog
    /// A catalog-origin row with no catalog id (a keyless `playlist tracks`
    /// listing writes these). Refused here, before any token read, so an
    /// empty id never reaches the API from either auth state.
    case noCatalogId
}

func addIndexRoute(origin: SongOrigin, catalogId: String, hasTargets: Bool) -> AddIndexRoute {
    switch origin {
    case .catalog: return catalogId.isEmpty ? .noCatalogId : .catalog
    case .library: return hasTargets ? .duplicateIntoPlaylists : .alreadyInLibrary
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library, or add to a playlist.")
    @Argument(help: "Search query or result index") var query: [String] = []
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Option(name: .long, help: "Add to playlist(s)") var to: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        // A library row needs no token for anything, so it is handled before
        // the token reads below, the same way `search --library` branches
        // before requireDeveloperToken().
        if id == nil, query.count == 1, let index = Int(query[0]) {
            let song = try ResultCache().lookupSong(index: index)
            switch addIndexRoute(origin: song.origin, catalogId: song.catalogId, hasTargets: !to.isEmpty) {
            case .catalog:
                break
            case .noCatalogId:
                if json {
                    print(OutputFormat(mode: .json).render(
                        ["added": false, "error": "no catalog id", "track": song.title, "artist": song.artist]))
                } else {
                    print("No catalog ID for '\(song.title)' by \(song.artist): playlist listings do not carry one.")
                    print("It is already in your library. To put it in a playlist: music search --library \"\(song.title)\"  then  music add N --to \"<playlist>\".")
                }
                throw ExitCode.failure
            case .alreadyInLibrary:
                if json {
                    print(OutputFormat(mode: .json).render(
                        ["added": false, "alreadyInLibrary": true, "track": song.title, "artist": song.artist]))
                } else {
                    print("Already in your library: \(song.title) by \(song.artist).")
                }
                return
            case .duplicateIntoPlaylists:
                let backend = AppleScriptBackend()
                var landed: [String] = []
                for pl in to {
                    if duplicateLibraryTrack(backend: backend, title: song.title, artist: song.artist, toPlaylist: pl) {
                        landed.append(pl)
                        if !json { print("Added to '\(pl)'.") }
                    } else if !json {
                        print("Couldn't add '\(song.title)' to '\(pl)'.")
                    }
                }
                if json {
                    print(OutputFormat(mode: .json).render(
                        ["added": landed.count, "track": song.title, "artist": song.artist, "playlists": landed]))
                }
                if landed.isEmpty { throw ExitCode.failure }
                return
            }
        }

        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var songToAdd: CatalogSong?
        var trackTitle: String?
        var trackArtist: String?

        if let catalogID = id {
            try syncRun { try await api.addToLibrary(songIDs: [catalogID]) }
            // The API playlist-add only needs the ID (this path used to fall
            // through silently because it had no title for the AppleScript lookup).
            let backend = AppleScriptBackend()
            for pl in to {
                try addSongs([CatalogSong(id: catalogID, title: "(id \(catalogID))", artist: "", album: "")],
                             to: pl, api: api, backend: backend)
                print("Added to '\(pl)'.")
            }
            print(json ? "{\"added\":\"\(catalogID)\"}" : "Added (id: \(catalogID)).")
            return
        } else if query.count == 1, let index = Int(query[0]) {
            let cache = ResultCache()
            let song = try cache.lookupSong(index: index)
            songToAdd = CatalogSong(id: song.catalogId, title: song.title, artist: song.artist, album: song.album)
        } else if !query.isEmpty {
            let searchQuery = query.joined(separator: " ")
            let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
            guard let song = songs.first else {
                print("No results for '\(searchQuery)'")
                throw ExitCode.failure
            }
            songToAdd = song
        } else if !to.isEmpty {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & (ASCII character 31) & artist of current track")
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: asFieldSep)
            if parts.count >= 2 {
                trackTitle = String(parts[0])
                trackArtist = String(parts[1])
            }
        } else {
            print("Usage: music add <query>, music add <index>, or music add --to <playlist>")
            throw ExitCode.failure
        }

        if let song = songToAdd {
            print("Found: \(song.title) — \(song.artist) [\(song.album)]")
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }

            if to.isEmpty {
                if json {
                    let output = OutputFormat(mode: .json)
                    print(output.render(["added": true, "track": song.title, "artist": song.artist, "id": song.id]))
                } else {
                    print("Added to library.")
                }
                return
            }
        }

        if !to.isEmpty {
            let backend = AppleScriptBackend()
            if let song = songToAdd {
                // Catalog ID known: direct API add per playlist (no sync sleep).
                for pl in to {
                    try addSongs([song], to: pl, api: api, backend: backend)
                    print("Added to '\(pl)'.")
                }
            } else if let title = trackTitle, let artist = trackArtist {
                // Current track (no catalog ID): it's already in the library, so
                // the AppleScript duplicate is direct — no sync wait needed.
                for pl in to {
                    if duplicateLibraryTrack(backend: backend, title: title, artist: artist, toPlaylist: pl) {
                        print("Added to '\(pl)'.")
                    } else {
                        print("Couldn't add '\(title)' to '\(pl)'.")
                    }
                }
            }
        }
    }
}

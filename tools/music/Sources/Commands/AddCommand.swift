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
    /// A Bridge row, library or catalogue, with or without its Bridge id. Its
    /// case in `Add.execute` IS the refusal (score S3, D3; Part 2 D6, Q3's
    /// default), so dropping the case is a compile error rather than a silent
    /// fall-through to the token reads.
    case bridgeRow
}

func addIndexRoute(origin: SongOrigin, catalogId: String, hasTargets: Bool) -> AddIndexRoute {
    switch origin {
    case .catalog: return catalogId.isEmpty ? .noCatalogId : .catalog
    case .library: return hasTargets ? .duplicateIntoPlaylists : .alreadyInLibrary
    case .bridgeLibrary, .bridgeCatalog: return .bridgeRow
    }
}

/// Parse the two-field current-track payload
/// (`name & ASCII 31 & artist`) that `add --to` reads over AppleScript.
///
/// nil means the read did not produce a usable track, and the caller must
/// refuse rather than continue. The old inline version was
/// `if parts.count >= 2 { ... }` with no else, so a malformed read left both
/// fields nil, skipped every downstream branch, and exited 0 having added
/// nothing and said nothing.
///
/// `split` omits empty subsequences, so a separator with a missing side
/// ("Title" plus separator, or separator plus artist) yields one field and is
/// correctly refused. Extra trailing fields are ignored rather than rejected.
func parseCurrentTrackFields(_ raw: String) -> (title: String, artist: String)? {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: asFieldSep)
    guard parts.count >= 2 else { return nil }
    return (title: String(parts[0]), artist: String(parts[1]))
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library, or add to a playlist.")
    @Argument(help: "Search query or result index") var query: [String] = []
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Option(name: .long, help: "Add to playlist(s)") var to: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try refuseInBridge(addAction(query: query, id: id, to: to), json: json)
        try execute(deps: .liveRequiringTokens)
    }

    /// The shipped body after the Bridge gate, reading the cache and the auth
    /// state only through `deps` (score S3). The cache is read once and that
    /// row is carried through; a Bridge row is refused before any token read,
    /// AppleScript or REST.
    func execute(deps: CachedRowCommandDeps) throws {
        // A library row needs no token for anything, so it is handled before
        // the token reads below, the same way `search --library` branches
        // before requireDeveloperToken().
        var cachedRow: SongResult?
        if id == nil, query.count == 1, let index = Int(query[0]) {
            let song = try ResultCache.row(index: index, in: deps.readSongs())
            switch addIndexRoute(origin: song.origin, catalogId: song.catalogId, hasTargets: !to.isEmpty) {
            case .bridgeRow:
                printCachedRowRefusal(bridgeRowsRefusal([song]) ?? "", json: json)
                throw ExitCode.failure
            case .catalog:
                cachedRow = song
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

        // `liveRequiringTokens` throws the shipped `AuthError` for a missing
        // token; these guards only cover an injected read that returns nil.
        let auth = try deps.readAuth()
        guard let devToken = auth.dev else { throw AuthError.configNotFound }
        guard let userToken = auth.user else { throw AuthError.userTokenRequired }
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront)

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
        } else if let song = cachedRow {
            // The row read above, not a second read of the same index.
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
            guard let fields = parseCurrentTrackFields(result) else {
                if json {
                    print(OutputFormat(mode: .json).render(
                        ["added": false, "error": "no current track"]))
                } else {
                    print("Couldn't read the current track, so there is nothing to add. Is anything playing?")
                }
                throw ExitCode.failure
            }
            trackTitle = fields.title
            trackArtist = fields.artist
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

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
        try runSearch(query: query, artist: artist, album: album, types: types, library: library,
                      limit: limit, json: json, env: .live())
    }
}

/// `music search`, dispatched (slice 3 S7, D1). `--library` is
/// `.searchLibrary`, which Bridge serves from its own library; the catalogue
/// search is `.catalogSearch`, which Bridge serves with `slice.search` (Part 2
/// P6; Decision 7: Music.app mode keeps its developer-key body). Neither is
/// playback, so neither takes the output lock.
func runSearch(query: [String], artist: String?, album: String?, types: String, library: Bool,
               limit: Int, json: Bool, env: CLIBridgeEnv,
               musicApp: ([String], String?, String?, String, Bool, Int, Bool) throws -> Void = searchViaMusicApp) throws {
    try cliDispatch(library ? .searchLibrary : .catalogSearch, json: json, env: env,
                    musicApp: { try musicApp(query, artist, album, types, library, limit, json) },
                    bridge: library
                        ? { try bridgeSearchLibraryCommand($0, query: query, artist: artist, album: album,
                                                           types: types, limit: limit, json: json, env: env) }
                        : { try bridgeSearchCatalogueCommand($0, query: query, artist: artist, album: album,
                                                             types: types, limit: limit, json: json, env: env) })
}

/// The shipped `music search` body, verbatim.
func searchViaMusicApp(query: [String], artist: String?, album: String?, types: String, library: Bool,
                       limit: Int, json: Bool) throws {
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

// MARK: - search --library with Bridge selected (S7, D3, D4)

let bridgeSearchSongsOnlyRefusal = "Bridge library search returns songs only in this version."

/// `music search --library` with Bridge selected: songs from Bridge's own
/// library, matched as `librarySearchScript` matches (`bridgeLibrarySearch`).
///
/// **Publish, then print (D3).** The rows are written to the result cache
/// (atomically) BEFORE any numbered row is shown, so a number on screen is
/// always a number `music play N` can find. A failed write shows no numbered
/// rows and exits 1. No results publishes an empty list, so a later `play N`
/// refuses as out of range rather than playing an older search's row.
func bridgeSearchLibraryCommand(_ session: CLIBridgeSession, query: [String], artist: String?, album: String?,
                                types: String, limit: Int, json: Bool, env: CLIBridgeEnv) throws {
    guard parseSearchTypes(types) == [.songs] else {
        throw ActionError(message: bridgeSearchSongsOnlyRefusal)
    }
    let term = query.joined(separator: " ")
    let found = try bridgeLibrarySearch(provider: session.provider, term: term, artist: artist, album: album,
                                        limit: limit, budget: session.budget, sleep: env.sleep,
                                        onWarming: { _ in env.err(cliBridgeWarmingProgress) })
    let rows: [MusicRow]
    switch found {
    case .refused(let why): throw ActionError(message: why)
    case .rows(let matched): rows = matched
    }

    let published = rows.enumerated().map { i, row in
        SongResult(index: i + 1, title: row.title, artist: row.artist, album: row.album ?? "",
                   catalogId: "", origin: .bridgeLibrary, bridgeID: row.id)
    }
    do {
        try env.cache.writeSongs(published)
    } catch {
        throw ActionError(message: "Couldn't save these results, so music play N would not find them: \(error.localizedDescription)")
    }

    guard !published.isEmpty else {
        throw ActionError(message: "No results for '\(term)'")
    }
    if json {
        // No `id`: `add --id` must never be handed a Bridge library id.
        env.out(OutputFormat(mode: .json).render(published.map {
            ["bridge_id": $0.bridgeID ?? "", "title": $0.title, "artist": $0.artist, "album": $0.album]
        }))
    } else {
        for row in published {
            env.out("\(row.index). \(row.title) \u{2014} \(row.artist) [\(row.album)]")
        }
    }
}

// MARK: - catalogue search with Bridge selected (Part 2 P6, D5, D6)

let bridgeCatalogueSearchTypesRefusal = "Bridge catalogue search returns songs and albums only in this version."

/// `music search` (catalogue) with Bridge selected: one `slice.search` with the
/// shipped term (query, then `--artist`, then `--album`) and `--limit`.
///
/// **Provenance (D6).** Only records Bridge typed `song` become cached rows,
/// as `.bridgeCatalog` with the id in `bridgeID` and an empty `catalogId`; the
/// origin comes from this op, never from the id. Albums are shown, never
/// cached. `--types` narrows what is shown to the kinds asked for (default
/// songs); anything but songs and albums refuses before any request.
///
/// **Publish, then print (D3).** As `search --library`: the rows are written
/// atomically before any line is shown; a failed write shows no rows and exits
/// 1; no results publishes an empty list.
func bridgeSearchCatalogueCommand(_ session: CLIBridgeSession, query: [String], artist: String?, album: String?,
                                  types: String, limit: Int, json: Bool, env: CLIBridgeEnv) throws {
    let searchTypes = Set(parseSearchTypes(types))
    guard searchTypes.isSubset(of: [.songs, .albums]) else {
        throw ActionError(message: bridgeCatalogueSearchTypesRefusal)
    }
    var term = query.joined(separator: " ")
    if let artist = artist { term += " \(artist)" }
    if let album = album { term += " \(album)" }
    guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ActionError(message: "Name something to search for.")
    }

    let found = try retryingWhileWarming(budget: session.budget,
                                         onWarming: { _ in env.err(cliBridgeWarmingProgress) },
                                         sleep: env.sleep) {
        try session.provider.searchCatalogue(term: term, limit: limit)
    }
    let records = found.filter { record in
        switch record.kind {
        case .song:  return searchTypes.contains(.songs)
        case .album: return searchTypes.contains(.albums)
        }
    }

    let published = catalogueSearchSongRows(records).map { row in
        SongResult(index: row.index, title: row.title, artist: row.artist, album: row.album ?? "",
                   catalogId: "", origin: .bridgeCatalog, bridgeID: row.bridgeID)
    }
    do {
        try env.cache.writeSongs(published)
    } catch {
        throw ActionError(message: "Couldn't save these results, so music play N would not find them: \(error.localizedDescription)")
    }

    guard !records.isEmpty else {
        throw ActionError(message: "No results for '\(term)'")
    }
    if json {
        env.out(catalogueSearchJSON(records))
    } else {
        catalogueSearchLines(records).forEach(env.out)
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

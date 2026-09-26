// tools/music/Sources/Commands/CLIBridgeListings.swift
//
// The Bridge branches of `music discover`, `playlist list`, `playlist tracks`
// and `similar <title>` (slice 3 Part 2, P8; decisions D2, D6, D8, D10), and
// the two playlist verbs' dispatch. Each Bridge body runs inside
// `cliDispatch`'s `.source` branch, after readiness, with the command's one
// `CLIBridgeSession`: every read shares its one warm-up budget, none takes the
// output lock (these are reads), and each prints through P4's renderers
// (`CLIBridgeReads.swift`).
//
// **Publish, then print (D3).** `playlist tracks` and `similar` write their
// rows to the result cache before any numbered line is shown: playlist tracks
// as `.bridgeLibrary` (Bridge library ids), similar as `.bridgeCatalog`
// (records Bridge's catalogue search typed as songs, D6). A failed write shows
// no rows and exits 1.
//
// **No auto-pick (D8).** With Music.app selected `playlist tracks` shows the
// FIRST playlist with that exact name (shipped, kept). With Bridge selected
// the name resolves by S4's rule (exact, else a unique substring, temp
// playlists never counted); two or more refuse with a list and no track read.
//
// `suggest`, `new-releases --artist` and `discover --recent` are refused with
// Bridge selected (Anthony's Q1 default): the first two by the matrix
// (`cliBridgeNotServedReason`), before any request; `--recent` here, first
// thing in the Bridge body.
import Foundation

// MARK: - discover

/// D10, verbatim.
let bridgeDiscoverRecentRefusal =
    "Bridge doesn't serve the Recently Played rail. Switch Output to Music.app to use music discover --recent."

/// What the Bridge feed is asked for: the Discover tab's own rail limit
/// (`DiscoverScene`), so the CLI curates from the same feed the TUI does.
let bridgeDiscoverFeedLimit = 30

/// `music discover` with Bridge selected: `--recent` refuses first; otherwise
/// one `slice.recommendations`, curated by `resolvedDiscoverRails` (the one
/// function the TUI uses too) unless `--all`, then `--limit` and `--per-rail`,
/// printed by P4 (no `recentlyPlayed` or `url` in JSON: Bridge sends neither).
func bridgeDiscoverCommand(_ session: CLIBridgeSession, limit: Int, perRail: Int, recent: Bool,
                           json: Bool, all: Bool, env: CLIBridgeEnv) throws {
    guard !recent else { throw ActionError(message: bridgeDiscoverRecentRefusal) }
    let feedRails = try session.provider.discoverRails(limit: bridgeDiscoverFeedLimit)
    let curated = all ? feedRails : resolvedDiscoverRails(feedRails)
    let rails = curated.prefix(max(1, limit)).map { rail in
        DiscoverRail(id: rail.id, title: rail.title, items: Array(rail.items.prefix(max(1, perRail))),
                     isRecentlyPlayed: rail.isRecentlyPlayed, resourceTypes: rail.resourceTypes)
    }
    if json {
        env.out(bridgeDiscoverJSON(rails))
    } else {
        bridgeDiscoverLines(rails).forEach(env.out)
    }
}

// MARK: - playlist list, playlist tracks

/// `music playlist list`, dispatched as `.playlistListing` (P8). Neither
/// branch takes the output lock. `musicApp` is the shipped `listPlaylists`,
/// injected so a test can count it.
func runPlaylistList(json: Bool, env: CLIBridgeEnv,
                     musicApp: (Bool) throws -> Void = listPlaylists) throws {
    try cliDispatch(.playlistListing, json: json, env: env,
                    musicApp: { try musicApp(json) },
                    bridge: { try bridgePlaylistListCommand($0, json: json, env: env) })
}

/// `music playlist tracks NAME`, dispatched as `.playlistListing` (P8).
/// `musicApp` is the shipped `showPlaylistTracks`, injected.
func runPlaylistTracks(name: String, json: Bool, env: CLIBridgeEnv,
                       musicApp: (String, Bool) throws -> Void = showPlaylistTracks) throws {
    try cliDispatch(.playlistListing, json: json, env: env,
                    musicApp: { try musicApp(name, json) },
                    bridge: { try bridgePlaylistTracksCommand($0, name: name, json: json, env: env) })
}

/// Bridge's playlists, every page, temp playlists hidden (Part 1 D4), on the
/// session's one budget.
private func bridgeVisiblePlaylists(_ session: CLIBridgeSession, env: CLIBridgeEnv) throws -> [MusicRow] {
    var rows: [MusicRow] = []
    if let error = walkLibraryPages(fetch: session.provider.libraryPlaylists,
                                    onPage: { page in rows.append(contentsOf: page.rows); return true },
                                    onRestart: { rows = [] },
                                    onWarming: { _ in env.err(cliBridgeWarmingProgress) },
                                    sleep: env.sleep, budget: session.budget) {
        throw error
    }
    return rows.filter { !isTempPlaylistName($0.title) }
}

/// `music playlist list` with Bridge selected: Bridge's own playlists.
func bridgePlaylistListCommand(_ session: CLIBridgeSession, json: Bool, env: CLIBridgeEnv) throws {
    let playlists = try bridgeVisiblePlaylists(session, env: env)
    if json {
        env.out(playlistListJSON(playlists))
    } else {
        playlistListLines(playlists).forEach(env.out)
    }
}

/// `music playlist tracks NAME` with Bridge selected: the playlist resolved by
/// S4's name rule, its tracks walked on the same budget, published as
/// `.bridgeLibrary` rows (so `music play N` queues them by library id), then
/// printed. An empty playlist lists nothing and publishes an empty list (so a
/// later `play N` cannot reach an older listing's row); it is not refused: a
/// listing is not a play.
func bridgePlaylistTracksCommand(_ session: CLIBridgeSession, name: String, json: Bool, env: CLIBridgeEnv) throws {
    let playlist: MusicRow
    switch matchRowsByName(try bridgeVisiblePlaylists(session, env: env), query: name) {
    case .notFound:
        throw ActionError(message: bridgePlaylistNotFoundRefusal(name))
    case .ambiguous(let matches):
        throw ActionError(message: bridgeAmbiguousPlaylistsRefusal(query: name, matches: matches))
    case .one(let row):
        playlist = row
    }

    var tracks: [MusicRow] = []
    if let error = walkLibraryPages(
        fetch: { cursor, limit in try session.provider.playlistTracks(playlistID: playlist.id, cursor: cursor, limit: limit) },
        limit: 500,
        onPage: { page in tracks.append(contentsOf: page.rows); return true },
        onRestart: { tracks = [] },
        onWarming: { _ in env.err(cliBridgeWarmingProgress) },
        sleep: env.sleep, budget: session.budget) {
        throw error
    }

    try publishBridgeListingRows(playlistTrackSongRows(tracks).map { row in
        SongResult(index: row.index, title: row.title, artist: row.artist, album: row.album ?? "",
                   catalogId: "", origin: .bridgeLibrary, bridgeID: row.bridgeID)
    }, env: env)
    if json {
        env.out(playlistTracksJSON(playlist: playlist.title, tracks: tracks))
    } else {
        playlistTracksLines(tracks).forEach(env.out)
    }
}

/// S4's not-found sentence for a playlist (`CLIBridgeSelection.swift`), verbatim.
func bridgePlaylistNotFoundRefusal(_ query: String) -> String {
    "No playlist named '\(query)' in your Bridge library."
}

/// S4's ambiguity sentence for playlists (`CLIBridgeSelection.swift`),
/// verbatim: up to five names, then "; and <n-5> more". `CLIBridgeListingsTests`
/// pins this copy against `resolveBridgePlaylistSelection`'s own refusal.
func bridgeAmbiguousPlaylistsRefusal(query: String, matches: [MusicRow]) -> String {
    let shown = matches.prefix(5).map { $0.artist.isEmpty ? $0.title : "\($0.title) — \($0.artist)" }.joined(separator: "; ")
    var message = "'\(query)' matches \(matches.count) playlists in your Bridge library: \(shown)"
    if matches.count > 5 { message += "; and \(matches.count - 5) more" }
    return message + ". Use the exact name."
}

// MARK: - similar <title>

/// `music similar <title> [--artist A]` with Bridge selected (Q1 default:
/// served): the shipped algorithm (`Similar.runViaMusicApp`) on Bridge's catalogue
/// search, songs only. The seed is the first song for `title[ artist]`
/// (limit 1; none → the shipped `Could not find '<q>'`); then the seed's
/// artist (limit + 5, the seed removed); then, if still short, the seed's
/// title (limit, de-duplicated by id). The first `limit` are published as
/// `.bridgeCatalog` rows, then printed as shipped. The shipped interactive
/// picker is not offered: its actions play and add through Music.app.
func bridgeSimilarCommand(_ session: CLIBridgeSession, query: [String], artist: String?, limit: Int,
                          json: Bool, env: CLIBridgeEnv) throws {
    let title = query.joined(separator: " ")
    let searchQuery = artist.map { "\(title) \($0)" } ?? title
    func songs(_ term: String, _ count: Int) throws -> [CatalogueRecord] {
        try retryingWhileWarming(budget: session.budget,
                                 onWarming: { _ in env.err(cliBridgeWarmingProgress) },
                                 sleep: env.sleep) {
            try session.provider.searchCatalogue(term: term, limit: count)
        }.filter { $0.kind == .song }
    }

    guard let seed = try songs(searchQuery, 1).first else {
        throw ActionError(message: "Could not find '\(searchQuery)'")
    }
    var similar = try songs(seed.artist, limit + 5).filter { $0.catalogueID != seed.catalogueID }
    if similar.count < limit {
        let existing = Set(similar.map(\.catalogueID) + [seed.catalogueID])
        similar += try songs(seed.title, limit).filter { !existing.contains($0.catalogueID) }
    }
    let shown = Array(similar.prefix(limit))

    try publishBridgeListingRows(catalogueSearchSongRows(shown).map { row in
        SongResult(index: row.index, title: row.title, artist: row.artist, album: row.album ?? "",
                   catalogId: "", origin: .bridgeCatalog, bridgeID: row.bridgeID)
    }, env: env)
    if json {
        env.out(catalogueSearchJSON(shown))
    } else {
        env.out("Similar to: \(seed.title) — \(seed.artist)")
        for (i, s) in shown.enumerated() {
            env.out("\(i + 1). \(s.title) — \(s.artist)\(s.album.map { " [\($0)]" } ?? "")")
        }
    }
}

// MARK: - private

/// D3: write the rows atomically, or refuse with P6's sentence so no number is
/// shown that `music play N` could not find.
private func publishBridgeListingRows(_ rows: [SongResult], env: CLIBridgeEnv) throws {
    do {
        try env.cache.writeSongs(rows)
    } catch {
        throw ActionError(message: "Couldn't save these results, so music play N would not find them: \(error.localizedDescription)")
    }
}

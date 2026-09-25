// tools/music/Sources/Commands/HistoryCommands.swift
import ArgumentParser
import Foundation

// Listening history via the REST API (endpoints verified against Apple's
// docs JSON). Results land in the shared ResultCache, so `music play 3`,
// `music add 2`, and `music playlist create X 1 2 3` chain off them.

/// Why there is no keyless `music recent`: it shows Apple's account level
/// history, which only the REST API serves. Music.app's own "Recently
/// Played" is a different, this Mac only list (measured 2026-08-27: zero
/// overlapping rows between the two), so an AppleScript read would answer
/// a different question. Pure, for testability.
func recentNeedsAuthMessage(json: Bool) -> String {
    let text = "music recent shows Apple's account level listening history, which only the Apple Music API serves. Music.app's own Recently Played is a different, this Mac only list (measured 2026-08-27: zero overlapping rows), so there is no keyless equivalent. Run: music auth setup"
    if json {
        return OutputFormat(mode: .json).render(["recent": [], "error": text])
    }
    return "✗ " + text
}

struct Recent: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recently played tracks.")
    @Option(name: .long, help: "Max results (API caps at 10 per page)") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try runRecent(limit: limit, json: json, env: .live(), musicApp: runViaMusicApp)
    }

    /// The shipped `music recent` body, verbatim: Music.app mode's branch.
    func runViaMusicApp() throws {
        let auth = AuthManager()
        if auth.userToken() == nil || (try? auth.requireDeveloperToken()) == nil {
            if json { print(recentNeedsAuthMessage(json: true)) } else { errorOut(recentNeedsAuthMessage(json: false)) }
            throw ExitCode.failure
        }
        let api = try makeUserAPI()
        // Apple's docs slug says "played-tracks" but the live API serves
        // /recent/played/tracks (the hyphenated path 404s — verified live).
        let lim = min(10, max(1, limit))
        var (data, status) = try syncRun { try await api.get("/v1/me/recent/played/tracks?limit=\(lim)") }
        if status == 404 {
            (data, status) = try syncRun { try await api.get("/v1/me/recent/played-tracks?limit=\(lim)") }
        }
        guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
        try printHistorySongs(data: data, label: "recent", json: json)
    }
}

struct Rotation: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Your heavy-rotation music.")
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try runRotation(limit: limit, json: json, env: .live(), musicApp: runViaMusicApp)
    }

    /// The shipped `music rotation` body, verbatim: Music.app mode's branch.
    func runViaMusicApp() throws {
        let api = try makeUserAPI()
        let (data, status) = try syncRun { try await api.get("/v1/me/history/heavy-rotation?limit=\(min(10, max(1, limit)))") }
        guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
        try printHistorySongs(data: data, label: "heavy rotation", json: json)
    }
}

// MARK: - Dispatch (slice 3 Part 2, P9 [serve]; decisions D6, D9, D10)
//
// D9 passed for both ops (B2, `b2/b2-summary.md`): Bridge's ordered
// `(type, id, catalog_id)` list equalled the REST path's on three occasions,
// so with Bridge selected `recent` and `rotation` read Bridge
// (`slice.recentTracks`, `slice.heavyRotation`). With Music.app selected the
// shipped bodies above run unchanged, auth check and REST included.
//
// The Bridge bodies read no token, run no AppleScript and make no REST call.
// They are reads: no output lock. **Publish, then print (D3):** the items
// `historyCatalogueID` names (a `songs` item by its own id, a `library-songs`
// item by its `catalog_id`, the type always Bridge's) are written as
// `.bridgeCatalog` rows before any line is shown, so `music play N` queues
// that catalogue id; everything else is listed unnumbered and never cached.
// The list is published even when it holds no song, so a later `play N`
// cannot reach an older listing's row.

/// `music recent`, dispatched as `.recent`. `musicApp` is the shipped body,
/// injected so a test can count it.
func runRecent(limit: Int, json: Bool, env: CLIBridgeEnv, musicApp: () throws -> Void) throws {
    try cliDispatch(.recent, json: json, env: env,
                    musicApp: musicApp,
                    bridge: { session in
                        try bridgeHistoryCommand(session, label: "recent", limit: limit, json: json, env: env) {
                            try session.provider.recentTracks(limit: $0)
                        }
                    })
}

/// `music rotation`, dispatched as `.rotation`. `musicApp` is the shipped
/// body, injected so a test can count it.
func runRotation(limit: Int, json: Bool, env: CLIBridgeEnv, musicApp: () throws -> Void) throws {
    try cliDispatch(.rotation, json: json, env: env,
                    musicApp: musicApp,
                    bridge: { session in
                        try bridgeHistoryCommand(session, label: "heavy rotation", limit: limit, json: json, env: env) {
                            try session.provider.heavyRotation(limit: $0)
                        }
                    })
}

/// The Bridge body both history verbs share: one read (limit clamped to
/// 1...10, as shipped), retried only while Bridge answers `warming`, on the
/// session's one budget; publish; then print through P4's renderers with the
/// shipped label.
func bridgeHistoryCommand(_ session: CLIBridgeSession, label: String, limit: Int, json: Bool,
                          env: CLIBridgeEnv, read: (Int) throws -> [HistoryItem]) throws {
    let lim = min(10, max(1, limit))
    let items = try retryingWhileWarming(budget: session.budget,
                                         onWarming: { _ in env.err(cliBridgeWarmingProgress) },
                                         sleep: env.sleep) {
        try read(lim)
    }

    let published = historySongRows(items).map { row in
        SongResult(index: row.index, title: row.title, artist: row.artist, album: row.album,
                   catalogId: "", origin: .bridgeCatalog, bridgeID: row.catalogueID)
    }
    do {
        try env.cache.writeSongs(published)
    } catch {
        throw ActionError(message: "Couldn't save these results, so music play N would not find them: \(error.localizedDescription)")
    }

    if json {
        env.out(historyJSON(items, label: label))
    } else {
        historyLines(items, label: label).forEach(env.out)
    }
}

private func makeUserAPI() throws -> RESTAPIBackend {
    let auth = AuthManager()
    let devToken = try auth.requireDeveloperToken()
    let userToken = try auth.requireUserToken()
    return RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
}

/// Print a history response. Items can be mixed resource types (songs,
/// albums, playlists, stations); song-shaped items go into the ResultCache so
/// index chaining works, others are listed with their type.
func printHistorySongs(data: Data, label: String, json: Bool, cache: ResultCache = ResultCache()) throws {
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let items = parsed?["data"] as? [[String: Any]] ?? []
    guard !items.isEmpty else {
        print(json ? "{\"\(label.replacingOccurrences(of: " ", with: "-"))\":[]}" : "No \(label) history.")
        return
    }

    var cacheable: [SongResult] = []
    var lines: [String] = []
    var dicts: [[String: Any]] = []
    for item in items {
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let type = item["type"] as? String ?? ""
        let name = attrs["name"] as? String ?? "Unknown"
        let artist = attrs["artistName"] as? String ?? ""
        let album = attrs["albumName"] as? String ?? ""
        let isSong = type.contains("song")
        let playParamsCatalogId = (attrs["playParams"] as? [String: Any])?["catalogId"] as? String
        let isLibraryType = type.hasPrefix("library-")   // same signal `kind` below already uses
        let origin: SongOrigin = (playParamsCatalogId == nil && isLibraryType) ? .library : .catalog
        let catalogId = playParamsCatalogId ?? (isSong ? (item["id"] as? String ?? "") : "")
        if isSong {
            cacheable.append(SongResult(index: cacheable.count + 1, title: name, artist: artist, album: album, catalogId: catalogId, origin: origin))
            lines.append("\(cacheable.count). \(name) — \(artist)\(album.isEmpty ? "" : " [\(album)]")")
        } else {
            let kind = type.replacingOccurrences(of: "library-", with: "").replacingOccurrences(of: "s", with: "", options: [.anchored, .backwards])
            lines.append("   \(name)\(artist.isEmpty ? "" : " — \(artist)") (\(kind))")
        }
        dicts.append(["type": type, "name": name, "artist": artist, "album": album])
    }
    if !cacheable.isEmpty { try? cache.writeSongs(cacheable) }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["items": dicts]))
    } else {
        for line in lines { print(line) }
    }
}

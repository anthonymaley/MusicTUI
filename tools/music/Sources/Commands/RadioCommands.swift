// CLI surface for radio. With Music.app selected, `play` resolves by favorite
// name first (works with no token), then falls back to catalog search, taking
// the first match of each (shipped). With Bridge selected, search, the add
// lookup and play go through Bridge (slice 3 Part 2, P7), and play never picks
// between two matches (D8, `CLIBridgeRadio.swift`). Favourites are MusicTUI's
// own `StationStore` in both modes.
import ArgumentParser
import Foundation

struct Radio: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Play and manage radio stations.",
        subcommands: [RadioList.self, RadioPlay.self, RadioAdd.self, RadioSearch.self],
        defaultSubcommand: RadioList.self)
}

struct RadioList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List favorite stations.")
    func run() throws {
        let favs = StationStore().favorites()
        guard !favs.isEmpty else {
            print("No favorite stations. Add one: music radio add <url>")
            return
        }
        for (i, s) in favs.enumerated() {
            print("\(i + 1). \(s.name)\(s.isLive == true ? "  [LIVE]" : "")")
        }
    }
}

struct RadioPlay: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "play", abstract: "Play a station by name or URL.")
    @Argument(help: "Favorite name, search term, or station URL") var query: [String]

    func run() throws {
        try runRadioPlay(query: query, env: .live())
    }
}

/// `music radio play`, dispatched (slice 3 S6; Part 2 P7). Both branches play
/// under the output lock: Music.app's shipped body (it plays via `open
/// music://`, not AppleScript) inside `cliDispatch`, Bridge's one
/// `slice.playStation` through `session.mutate`. `opener` and `stations` are
/// the shipped `SystemOpener()` and `StationStore()`, injected; `musicApp`
/// replaces the whole Music.app body for tests that only count it.
func runRadioPlay(query: [String], env: CLIBridgeEnv, opener: Opener = SystemOpener(),
                  stations: StationStore = StationStore(),
                  musicApp: (([String]) throws -> Void)? = nil) throws {
    try cliDispatch(.radioStationPlay, json: false, env: env,
                    musicApp: {
                        if let musicApp { try musicApp(query) }
                        else { try radioPlayViaMusicApp(query: query, opener: opener, stations: stations) }
                    },
                    bridge: { try bridgeRadioPlayCommand($0, query: query, stations: stations, env: env) })
}

/// The shipped `radio play` body, verbatim but for its injected opener and
/// favourites store. First match wins (Music.app mode keeps it; D8).
func radioPlayViaMusicApp(query: [String], opener: Opener = SystemOpener(),
                          stations: StationStore = StationStore()) throws {
    let input = query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !input.isEmpty else { throw ValidationError("Name or URL required.") }

    if ["http://", "https://", "music://"].contains(where: { input.hasPrefix($0) }) {
        guard let p = parseStationURL(input), stationPlayURL(input) != nil else {
            throw ValidationError("Not an Apple Music station URL.")
        }
        let s = Station(id: p.id, name: displayNameFromSlug(p.slug), url: input,
                        isLive: nil, artworkURL: nil)
        try playStation(s, via: opener)
        print("▶ \(s.name)")
        return
    }

    // Favorites first — no network, no token.
    if let hit = stations.favorites().first(where: {
        $0.name.localizedCaseInsensitiveContains(input)
    }) {
        try playStation(hit, via: opener)
        print("▶ \(hit.name)")
        return
    }

    guard let catalog = makeCatalog() else {
        errorOut("✗ No match in favorites, and search needs auth (music auth setup).")
        return
    }
    guard let hit = try catalog.search(term: input).first else {
        errorOut("✗ No station found for “\(input)”. Try pasting the station URL.")
        return
    }
    try playStation(hit, via: opener)
    print("▶ \(hit.name)")
}

struct RadioAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Favorite a station by URL.")
    @Argument(help: "Station URL") var url: String

    func run() throws {
        try runRadioAdd(url: url, env: .live())
    }
}

/// `music radio add URL` (slice 3 Part 2, P7). The URL is validated first, as
/// shipped; then ONLY the name lookup dispatches, as `.radioStationLookup`:
/// Bridge's `slice.station` with Bridge selected, the shipped catalogue
/// resolve with Music.app. Both are enrichment under `try?`, so any failure,
/// a refusal included, keeps the slug name and prints nothing of its own. The
/// favourite is MusicTUI's own `StationStore` state, saved in both modes.
func runRadioAdd(url: String, env: CLIBridgeEnv, stations: StationStore = StationStore(),
                 musicAppLookup: (String) -> Station? = radioLookupViaMusicApp) throws {
    guard stationPlayURL(url) != nil, let p = parseStationURL(url) else {
        throw ValidationError("Not an Apple Music station URL.")
    }
    var resolved: Station?
    // The lookup's own refusals and failures degrade to the slug name, so the
    // dispatch prints nothing: `out` is silenced for it alone.
    let quiet = CLIBridgeEnv(routing: env.routing, modeStore: env.modeStore, cache: env.cache,
                             out: { _ in }, err: env.err, sleep: env.sleep)
    try? cliDispatch(.radioStationLookup, json: false, env: quiet,
                     musicApp: { resolved = musicAppLookup(p.id) },
                     bridge: { resolved = bridgeRadioStationLookup($0, id: p.id) })
    let s = resolved ?? Station(id: p.id, name: displayNameFromSlug(p.slug),
                                url: url, isLive: nil, artworkURL: nil)
    try stations.add(s)
    env.out("★ \(s.name)")
}

/// The shipped lookup, verbatim: the API can't resolve everything playable
/// (BBC Radio 1) — degrade, don't fail.
func radioLookupViaMusicApp(_ id: String) -> Station? {
    let resolved = try? makeCatalog()?.resolve(id: id)
    return resolved ?? nil
}

struct RadioSearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search catalog stations.")
    @Argument(help: "Search term") var term: [String]

    func run() throws {
        try runRadioSearch(term: term, env: .live())
    }
}

/// `music radio search`, dispatched (slice 3 Part 2, P7): Bridge's
/// `slice.searchStations` with Bridge selected, the shipped catalogue body
/// with Music.app. A read, so no output lock.
func runRadioSearch(term: [String], env: CLIBridgeEnv,
                    musicApp: ([String]) throws -> Void = radioSearchViaMusicApp) throws {
    try cliDispatch(.radioSearch, json: false, env: env, musicApp: { try musicApp(term) },
                    bridge: { try bridgeRadioSearchCommand($0, term: term, env: env) })
}

/// The shipped `radio search` body, verbatim.
func radioSearchViaMusicApp(term: [String]) throws {
    guard let catalog = makeCatalog() else {
        errorOut("✗ Search needs auth (music auth setup).")
        return
    }
    let hits = try catalog.search(term: term.joined(separator: " "))
    guard !hits.isEmpty else {
        print("No stations found. Station search is shallow — pasting the URL always works.")
        return
    }
    for s in hits {
        print("\(s.name)\(s.isLive == true ? "  [LIVE]" : "")\n  \(s.url)")
    }
}

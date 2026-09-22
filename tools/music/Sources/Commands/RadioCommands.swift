// CLI surface for radio. `play` resolves by favorite name first (works with no
// token), then falls back to catalog search.
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
        try refuseInBridge(.radioStationPlay)   // plays via `open music://`, not AppleScript
        let input = query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { throw ValidationError("Name or URL required.") }

        if ["http://", "https://", "music://"].contains(where: { input.hasPrefix($0) }) {
            guard let p = parseStationURL(input), stationPlayURL(input) != nil else {
                throw ValidationError("Not an Apple Music station URL.")
            }
            let s = Station(id: p.id, name: displayNameFromSlug(p.slug), url: input,
                            isLive: nil, artworkURL: nil)
            try playStation(s, via: SystemOpener())
            print("▶ \(s.name)")
            return
        }

        // Favorites first — no network, no token.
        if let hit = StationStore().favorites().first(where: {
            $0.name.localizedCaseInsensitiveContains(input)
        }) {
            try playStation(hit, via: SystemOpener())
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
        try playStation(hit, via: SystemOpener())
        print("▶ \(hit.name)")
    }
}

struct RadioAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Favorite a station by URL.")
    @Argument(help: "Station URL") var url: String

    func run() throws {
        guard stationPlayURL(url) != nil, let p = parseStationURL(url) else {
            throw ValidationError("Not an Apple Music station URL.")
        }
        // The API can't resolve everything playable (BBC Radio 1) — degrade, don't fail.
        let resolved = try? makeCatalog()?.resolve(id: p.id)
        let s = (resolved ?? nil) ?? Station(id: p.id, name: displayNameFromSlug(p.slug),
                                             url: url, isLive: nil, artworkURL: nil)
        try StationStore().add(s)
        print("★ \(s.name)")
    }
}

struct RadioSearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search catalog stations.")
    @Argument(help: "Search term") var term: [String]

    func run() throws {
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
}

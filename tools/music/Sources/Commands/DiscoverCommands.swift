// tools/music/Sources/Commands/DiscoverCommands.swift
import ArgumentParser
import Foundation

// The Discover feed on the CLI, mirroring Music.app's Discover screen: Apple's For You
// rails plus the mixed recently-played row. Read-only by design.
//
// Nothing here plays anything, and that is deliberate. A Discover row is usually a
// CATALOG item you do not own, and there is no write-free way to play a catalog
// album: music:// only plays stations, and the library API is add-only. Playing
// an album from Discover means adding it to the library first, which is the exact
// thing Discover is not for. See docs/platform-notes.md before adding a play verb.

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Your Discover feed: For You rails and recently played.")

    @Option(name: .long, help: "Max rails to show") var limit: Int = 8
    @Option(name: .long, help: "Max items per rail") var perRail: Int = 6
    @Flag(name: .long, help: "Only the recently played row") var recent = false
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: .long, help: "Every rail from the feed, uncurated") var all = false

    func run() throws {
        guard let feed = makeDiscoverFeed() else {
            print("Discover needs a Music User Token. Run: music auth setup")
            throw ExitCode.failure
        }

        if recent {
            let items = try feed.recentlyPlayed(limit: max(1, perRail))
            printItems(items, json: json)
            return
        }

        // `resolvedDiscoverRails` is the one function both `music discover` and the
        // Discover tab go through to turn a raw feed into curated rails. CLI/TUI
        // drift on shared data is this repo's most-repeated bug (1c06027 was
        // exactly this), so composing its two pieces by hand at a call site is
        // exactly what this guards against. `--all` deliberately skips BOTH
        // `resolvedDiscoverRails` (the five-slot selection policy) AND
        // `orderedDiscoverRails` (which hoists Recently Played ahead of Apple's
        // order) — it exists for scripting and inspection, so it must show
        // exactly what the API returned, in the order the API returned it.
        // Any reordering here would make the flag's own help text ("Every
        // rail from the feed, uncurated") a lie.
        //
        // Items per rail is deliberately NOT unified: the TUI shows 4 with a
        // `View all N` to page through the rest; the CLI has no navigation to
        // offer instead, so it keeps `--per-rail` (default 6). That is a
        // decision, not drift.
        let feedRails = try feed.rails()
        let curated = all ? feedRails : resolvedDiscoverRails(feedRails)
        let rails = curated.prefix(max(1, limit))
        if json {
            let payload = rails.map { rail -> [String: Any] in
                ["title": rail.title,
                 "recentlyPlayed": rail.isRecentlyPlayed,
                 "items": rail.items.prefix(max(1, perRail)).map(itemDict)]
            }
            print(OutputFormat(mode: .json).render(payload))
            return
        }

        for rail in rails {
            print("\n\(rail.title)")
            for item in rail.items.prefix(max(1, perRail)) {
                print("  " + line(item))
            }
        }
    }

    private func printItems(_ items: [DiscoverItem], json: Bool) {
        if json {
            print(OutputFormat(mode: .json).render(items.map(itemDict)))
        } else {
            for item in items { print(line(item)) }
        }
    }

    /// A station is the only kind Discover can actually play, so it is the only one
    /// that gets a play marker. Everything else is browse-only for now.
    private func line(_ item: DiscoverItem) -> String {
        let playable = item.kind == .station ? "▶ " : "  "
        let subtitle = item.subtitle.map { " — \($0)" } ?? ""
        return "\(playable)\(item.name)\(subtitle)  [\(label(item.kind))]"
    }

    private func itemDict(_ item: DiscoverItem) -> [String: Any] {
        var d: [String: Any] = ["name": item.name, "kind": label(item.kind), "id": item.id]
        if let s = item.subtitle { d["subtitle"] = s }
        if let u = item.url { d["url"] = u }
        if let a = item.artworkURL { d["artwork"] = a }
        return d
    }

    private func label(_ kind: DiscoverItemKind) -> String {
        switch kind {
        case .station: return "station"
        case .album: return "album"
        case .playlist: return "playlist"
        case .song: return "song"
        }
    }
}

import Foundation

/// The three AppleScript-backed closures the playlist browser/scene needs,
/// plus shared caches captured inside them. Built once per browse session.
struct PlaylistDataSources {
    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)]
    let onPreview: (Int) -> [String]?
    let onTracks: (Int) -> PlaylistPreview?
    /// One-shot REST map of lowercased-trimmed playlist name → (REST id, artwork
    /// URL), for real hero covers. nil when the user isn't signed in / no dev
    /// token — the scene keeps gradients, exactly today's token-less behavior.
    /// Name matching is heuristic (same class as albumArtistSet); built-in smart
    /// playlists aren't API-visible and simply never match.
    let onArtworkMap: (() -> [String: (id: String, url: String)])?
}

/// One playlist's rail metadata, persisted between launches so the browser paints
/// instantly instead of waiting on per-playlist AppleScript (`count of tracks`,
/// `duration` — slow for large playlists). Keyed by playlist name.
struct CachedPlaylistMeta: Codable {
    let count: Int
    let durationSec: Int
    let isSmart: Bool
    let specialKind: String
}

/// On-disk cache of playlist rail metadata at `~/.config/music/playlist-meta.json`
/// (same dir as ResultCache). Best-effort: any read/write failure is silent and the
/// browser falls back to a live (background) fetch.
enum PlaylistMetaCache {
    static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/music/playlist-meta.json"
    }

    static func load() -> [String: CachedPlaylistMeta] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONDecoder().decode([String: CachedPlaylistMeta].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ dict: [String: CachedPlaylistMeta]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Parse one `onMeta` result line: "idx|count|durationSeconds|smart|specialKind".
func parsePlaylistMetaLine(_ line: Substring) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    let f = line.split(separator: "|", maxSplits: 4).map(String.init)
    guard f.count == 5, let idx = Int(f[0]) else { return nil }
    let count = Int(f[1]) ?? 0
    let dur = Int(Double(f[2]) ?? 0)
    let smart = f[3].trimmingCharacters(in: .whitespaces) == "true"
    return (idx, count, dur, smart, f[4].trimmingCharacters(in: .whitespaces))
}

func parsePlaylistMetaLine(_ line: String) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    parsePlaylistMetaLine(Substring(line))
}

/// Parse the `onTracks` result: "totalCount|line\nline\n...".
func parsePlaylistTracksResult(_ result: String) -> (count: Int, lines: [String]) {
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "|", maxSplits: 1)
    let count = Int(parts.first ?? "0") ?? 0
    let lines = parts.count > 1
        ? String(parts[1]).components(separatedBy: "\n").filter { !$0.isEmpty }
        : []
    return (count, lines)
}

/// Fetch the user's playlist names (one instant AppleScript call).
/// Delete leftover "__queue__ …" temp playlists from prior sessions, sparing the one
/// currently playing — deleting the playing playlist reverts Music to the library.
/// Safe to run off-main at startup; playTrack also sweeps after each play.
func sweepQueuePlaylists(backend: AppleScriptBackend) {
    _ = try? syncRun {
        try await backend.runMusic("""
            set keepName to ""
            try
                set keepName to name of current playlist
            end try
            repeat with pp in (every user playlist)
                try
                    set nm to name of pp
                    if (nm starts with "__queue__ ") and (nm is not keepName) then delete pp
                end try
            end repeat
        """)
    }
}

/// Parse the rail-names script output: one `U<US>name` (user playlist) or
/// `S<US>name` (subscription playlist) line per playlist. Pure, tested.
/// Filters obsolete `__queue__` temp playlists so they don't clutter the rail.
func parseRailPlaylistNames(_ raw: String) -> (names: [String], subscription: Set<String>) {
    var names: [String] = []
    var subscription: Set<String> = []
    for line in raw.components(separatedBy: "\n") {
        let parts = line.split(separator: asFieldSep, maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("__queue__ ") else { continue }
        names.append(name)
        if parts[0].trimmingCharacters(in: .whitespaces) == "S" { subscription.insert(name) }
    }
    return (names, subscription)
}

/// Apple-curated playlists added to the library are class `subscription
/// playlist`, NOT `user playlist` — `every user playlist` silently omits them
/// (they only ever appeared in the rail via manual duplicates). Enumerate both
/// classes in one call; downstream code resolves `playlist "name"` generically,
/// which covers both.
func fetchUserPlaylistNames(backend: AppleScriptBackend) -> (names: [String], subscription: Set<String>) {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set output to ""
            repeat with p in (every user playlist)
                if output is not "" then set output to output & linefeed
                set output to output & "U" & fs & name of p
            end repeat
            repeat with p in (every subscription playlist)
                if output is not "" then set output to output & linefeed
                set output to output & "S" & fs & name of p
            end repeat
            return output
        """)
    }) else { return ([], []) }
    return parseRailPlaylistNames(result)
}

/// Build the three data-source closures over a fixed `names` list. Each closure
/// owns its own cache. Bulk `tracks 1 thru n` fetches (never per-element) per the
/// performance lesson in docs/playbook.md.
func makePlaylistDataSources(backend: AppleScriptBackend, names: [String], artworkAPI: RESTAPIBackend? = nil) -> PlaylistDataSources {
    var trackCache: [Int: PlaylistPreview] = [:]
    var previewCacheLight: [Int: [String]] = [:]

    let onTracks: (Int) -> PlaylistPreview? = { idx in
        if let cached = trackCache[idx] { return cached }
        guard idx >= 0, idx < names.count else { return nil }
        let plName = names[idx]
        let escapedPlName = escapeAppleScriptString(plName)
        guard let trackResult = try? syncRun({
            try await backend.runMusic("""
                set total to count of tracks of playlist "\(escapedPlName)"
                set n to total
                if n > 200 then set n to 200
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(escapedPlName)"
                    set ars to artist of tracks 1 thru n of playlist "\(escapedPlName)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " — " & (item i of ars)
                    end repeat
                end if
                return (total as text) & "|" & output
            """)
        }) else { return nil }
        let parsed = parsePlaylistTracksResult(trackResult)
        let preview = PlaylistPreview(name: plName, trackCount: parsed.count, tracks: parsed.lines)
        trackCache[idx] = preview
        return preview
    }

    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)] = { indices in
        guard !indices.isEmpty else { return [:] }
        var clauses = ""
        for idx in indices where idx >= 0 && idx < names.count {
            let esc = escapeAppleScriptString(names[idx])
            // Each playlist is independent: a failure (resolution or any property)
            // must not abort the whole batch, and each property degrades to a default
            // rather than throwing. Otherwise one bad entry blanks 8 rows.
            clauses += """
            try
                set p to playlist "\(esc)"
                set c to 0
                try
                    set c to count of tracks of p
                end try
                set d to 0
                try
                    set d to duration of p
                end try
                set sm to false
                try
                    set sm to smart of p
                end try
                set sk to "none"
                try
                    set sk to (special kind of p as text)
                end try
                set output to output & "\(idx)|" & c & "|" & d & "|" & sm & "|" & sk & linefeed
            end try

            """
        }
        guard let result = try? syncRun({
            try await backend.runMusic("""
                set output to ""
                \(clauses)
                return output
            """)
        }) else { return [:] }
        var out: [Int: (Int, Int, Bool, String)] = [:]
        for line in result.split(separator: "\n") {
            if let p = parsePlaylistMetaLine(line) {
                out[p.index] = (p.count, p.durationSec, p.isSmart, p.specialKind)
            }
        }
        return out
    }

    let onPreview: (Int) -> [String]? = { idx in
        if let c = previewCacheLight[idx] { return c }
        guard idx >= 0, idx < names.count else { return nil }
        let esc = escapeAppleScriptString(names[idx])
        guard let res = try? syncRun({
            try await backend.runMusic("""
                set total to count of tracks of playlist "\(esc)"
                set n to total
                if n > 40 then set n to 40
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(esc)"
                    set ars to artist of tracks 1 thru n of playlist "\(esc)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " \u{2014} " & (item i of ars)
                    end repeat
                end if
                return output
            """)
        }) else { return nil }
        let lines = res.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").map(String.init)
        previewCacheLight[idx] = lines
        return lines
    }

    return PlaylistDataSources(
        onMeta: onMeta, onPreview: onPreview, onTracks: onTracks,
        onArtworkMap: artworkAPI.map { api in
            {
                let playlists = (try? syncRun { try await api.libraryPlaylists() }) ?? []
                var map: [String: (id: String, url: String)] = [:]
                for p in playlists {
                    guard let u = p.artworkURL else { continue }
                    map[p.name.lowercased().trimmingCharacters(in: .whitespaces)] = (p.id, u)
                }
                return map
            }
        }
    )
}

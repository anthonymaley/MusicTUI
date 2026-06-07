import Foundation

/// The three AppleScript-backed closures the playlist browser/scene needs,
/// plus shared caches captured inside them. Built once per browse session.
struct PlaylistDataSources {
    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)]
    let onPreview: (Int) -> [String]?
    let onTracks: (Int) -> PlaylistPreview?
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
func fetchUserPlaylistNames(backend: AppleScriptBackend) -> [String] {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            set output to ""
            repeat with p in (every user playlist)
                if output is not "" then set output to output & linefeed
                set output to output & name of p
            end repeat
            return output
        """)
    }) else { return [] }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Build the three data-source closures over a fixed `names` list. Each closure
/// owns its own cache. Bulk `tracks 1 thru n` fetches (never per-element) per the
/// performance lesson in docs/playbook.md.
func makePlaylistDataSources(backend: AppleScriptBackend, names: [String]) -> PlaylistDataSources {
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
            clauses += """
            set p to playlist "\(esc)"
            set output to output & "\(idx)|" & (count of tracks of p) & "|" & (duration of p) & "|" & (smart of p) & "|" & (special kind of p as text) & linefeed

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
                if n > 8 then set n to 8
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

    return PlaylistDataSources(onMeta: onMeta, onPreview: onPreview, onTracks: onTracks)
}

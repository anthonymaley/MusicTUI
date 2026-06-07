// tools/music/Sources/TUI/Shell/PlaybackContext.swift
import Foundation

/// The current playback context: the name of what's playing (playlist or album)
/// and a window of its tracks around the current one, with the current marked.
struct ContextQueue {
    let name: String
    let tracks: [TrackListEntry]   // index = real position in the current playlist
}

/// Pure parse of the pollContextQueue result.
/// Format: line 1 = context name, line 2 = current index, line 3 = window start,
/// then "index|title|artist" rows.
func parseContextQueue(_ raw: String, currentTitle: String, currentArtist: String) -> ContextQueue {
    let lines = raw.components(separatedBy: "\n")
    guard lines.count >= 3 else { return ContextQueue(name: "", tracks: []) }
    let name = lines[0].trimmingCharacters(in: .whitespaces)
    var tracks: [TrackListEntry] = []
    for line in lines.dropFirst(3) where !line.isEmpty {
        let f = line.split(separator: "|", maxSplits: 2).map(String.init)
        guard f.count == 3, let idx = Int(f[0]) else { continue }
        tracks.append(TrackListEntry(
            index: idx, name: f[1], artist: f[2],
            isCurrent: f[1] == currentTitle && f[2] == currentArtist
        ))
    }
    return ContextQueue(name: name, tracks: tracks)
}

/// Fetch the current playlist's name + a window of tracks around the current
/// index (current-2 .. current+40, clamped). Returns an empty ContextQueue when
/// there is no usable playlist context (caller falls back to album tracks).
func pollContextQueue(np: NowPlayingState, backend: AppleScriptBackend = AppleScriptBackend()) -> ContextQueue {
    guard let raw = try? syncRun({
        try await backend.runMusic("""
            try
                set cp to current playlist
                set cpName to name of cp
                set ct to current track
                set idx to index of ct
                set total to count of tracks of cp
                set startIdx to idx - 2
                if startIdx < 1 then set startIdx to 1
                set endIdx to idx + 40
                if endIdx > total then set endIdx to total
                set output to cpName & linefeed & idx & linefeed & startIdx
                if endIdx >= startIdx then
                    set ns to name of tracks startIdx thru endIdx of cp
                    set ars to artist of tracks startIdx thru endIdx of cp
                    repeat with i from 1 to (count of ns)
                        set output to output & linefeed & (startIdx + i - 1) & "|" & (item i of ns) & "|" & (item i of ars)
                    end repeat
                end if
                return output
            end try
            return ""
        """)
    }) else { return ContextQueue(name: "", tracks: []) }
    return parseContextQueue(raw, currentTitle: np.track, currentArtist: np.artist)
}

/// Extract the current track's album art and render it to ANSI lines at the
/// given size (chafa true-color if available, CoreGraphics block fallback).
/// Empty array when no artwork is available.
func currentTrackArtLines(width: Int, height: Int) -> [String] {
    guard let path = extractArtwork() else { return [] }
    return artworkToAscii(path: path, width: width, height: height)
}

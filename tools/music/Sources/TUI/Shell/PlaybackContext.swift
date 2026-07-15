// tools/music/Sources/TUI/Shell/PlaybackContext.swift
import Foundation

/// The current playback context: the name of what's playing (playlist or album)
/// and a window of its tracks around the current one, with the current marked.
struct ContextQueue {
    let name: String
    let currentIndex: Int
    let total: Int
    let tracks: [TrackListEntry]   // index = real position in the current playlist
}

/// Pure parse of the pollContextQueue result.
/// Format: line 1 = context name, line 2 = current index, line 3 = total,
/// line 4 = window start, then "index|title|artist" rows.
func parseContextQueue(_ raw: String) -> ContextQueue {
    let lines = raw.components(separatedBy: "\n")
    guard lines.count >= 4 else { return ContextQueue(name: "", currentIndex: -1, total: 0, tracks: []) }
    let name = lines[0].trimmingCharacters(in: .whitespaces)
    // Mark the current track by its real playlist index (line 2), not by
    // title/artist — a library with duplicate adjacent tracks would otherwise
    // mark more than one row as current.
    let currentIndex = Int(lines[1].trimmingCharacters(in: .whitespaces)) ?? -1
    let total = Int(lines[2].trimmingCharacters(in: .whitespaces)) ?? 0
    var tracks: [TrackListEntry] = []
    for line in lines.dropFirst(4) where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 2).map(String.init)
        guard f.count == 3, let idx = Int(f[0]) else { continue }
        tracks.append(TrackListEntry(
            index: idx, name: f[1], artist: f[2],
            isCurrent: idx == currentIndex
        ))
    }
    return ContextQueue(name: name, currentIndex: currentIndex, total: total, tracks: tracks)
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
                set fs to (ASCII character 31)
                set output to cpName & linefeed & idx & linefeed & total & linefeed & startIdx
                if endIdx >= startIdx then
                    set ns to name of tracks startIdx thru endIdx of cp
                    set ars to artist of tracks startIdx thru endIdx of cp
                    repeat with i from 1 to (count of ns)
                        set output to output & linefeed & (startIdx + i - 1) & fs & (item i of ns) & fs & (item i of ars)
                    end repeat
                end if
                return output
            end try
            return ""
        """)
    }) else { return ContextQueue(name: "", currentIndex: -1, total: 0, tracks: []) }
    return parseContextQueue(raw)
}

/// Extract the current track's album art and render it to ANSI lines at the
/// given size (chafa true-color if available, CoreGraphics block fallback).
/// Empty lines + nil path when no artwork is available. The path is the temp
/// file `extractArtwork()` wrote to — handed back alongside the lines (one
/// AppleScript round-trip, not two) so the Now tab can also transmit the raw
/// bytes via the kitty graphics protocol.
func currentTrackArtLines(width: Int, height: Int) -> (lines: [String], path: String?) {
    guard let path = extractArtwork() else { return ([], nil) }
    return (artworkToAscii(path: path, width: width, height: height), path)
}

/// Strip internal temp-playlist prefixes so the UI shows the real source name
/// ("__queue__ House" -> "House").
func cleanContextName(_ name: String) -> String {
    for p in ["__queue__ "] {
        if name.hasPrefix(p) { return String(name.dropFirst(p.count)) }
    }
    return name
}

/// True when a context name is the on-device library (where autoplay lands).
func isLibraryContextName(_ name: String) -> Bool {
    let n = name.trimmingCharacters(in: .whitespaces)
    return n == "Music" || n == "Library"
}

/// Whether to drop the latched "Genius Shuffle active" state. Music exposes no
/// genius flag and reports `current playlist` as the library during Genius, so
/// the latch (set when we trigger Genius) clears once a real playlist or an
/// app-owned queue takes over. The grace window keeps it set through the
/// post-trigger snapshot lag, when the previous (real) context is still showing.
func geniusShouldClear(elapsedSinceTrigger: TimeInterval, hasAppQueue: Bool, contextName: String) -> Bool {
    if hasAppQueue { return true }
    return elapsedSinceTrigger > 3 && !contextName.isEmpty && !isLibraryContextName(contextName)
}

/// Pure queue-end guard. Fires only when a real playlist's last track ended
/// naturally and playback flipped to library autoplay — not on manual library
/// browsing or mid-playlist changes.
func detectQueueEnd(prevWasRealPlaylist: Bool, prevAtLastTrack: Bool,
                    prevNaturalEnd: Bool, nowIsLibraryAutoplay: Bool) -> Bool {
    prevWasRealPlaylist && prevAtLastTrack && prevNaturalEnd && nowIsLibraryAutoplay
}

import Foundation
import CoreGraphics
import ImageIO
#if canImport(Darwin)
import Darwin
#endif

struct NowPlayingState {
    var track: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Int = 0
    var position: Int = 0
    var state: String = "stopped"
}

struct TrackListEntry {
    let index: Int
    let name: String
    let artist: String
    let isCurrent: Bool
}

/// Result of a single poll. Distinguishes a genuine stop (player reported
/// "stopped") from a transient read failure (AppleScript threw or returned
/// something unparseable). Collapsing both to `nil` previously caused two
/// bugs: a single hiccup mid-track blanked the UI, and in context mode it
/// skipped to the next track.
enum PollOutcome {
    case active(NowPlayingState)
    case stopped
    case unavailable
}

/// Lean player-state read for the shell's 1s poll: track metadata + position
/// only. Deliberately no AirPlay enumeration (slow with sleeping HomePods) and
/// no loved/disliked — nothing in the shell renders them, and this script runs
/// every second.
func pollNowPlaying(backend: AppleScriptBackend = AppleScriptBackend()) -> PollOutcome {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            try
                set state to player state as text
                if state is "stopped" then return "STOPPED"
                set fs to (ASCII character 31)
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                return t & fs & a & fs & al & fs & (round d) & fs & (round p) & fs & state
            end try
            return "STOPPED"
        """)
    }) else { return .unavailable }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return .stopped }
    let parts = trimmed.split(separator: asFieldSep, maxSplits: 5).map(String.init)
    guard parts.count >= 6 else { return .unavailable }

    return .active(NowPlayingState(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: Int(parts[3]) ?? 0, position: Int(parts[4]) ?? 0,
        state: parts[5]
    ))
}

func pollSurroundingTracks(backend: AppleScriptBackend = AppleScriptBackend()) -> [TrackListEntry] {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            try
                set cp to current playlist
                set ct to current track
                set idx to index of ct
                set total to count of tracks of cp
                set output to ""
                set fs to (ASCII character 31)
                set startIdx to idx - 4
                if startIdx < 1 then set startIdx to 1
                set endIdx to idx + 4
                if endIdx > total then set endIdx to total
                repeat with i from startIdx to endIdx
                    set t to track i of cp
                    if output is not "" then set output to output & linefeed
                    if i = idx then
                        set output to output & ">" & i & fs & name of t & fs & artist of t
                    else
                        set output to output & " " & i & fs & name of t & fs & artist of t
                    end if
                end repeat
                return output
            end try
            return ""
        """)
    }) else { return [] }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    return trimmed.components(separatedBy: "\n").compactMap { line in
        let isCurrent = line.hasPrefix(">")
        let clean = String(line.dropFirst()) // drop > or space
        let parts = clean.split(separator: asFieldSep, maxSplits: 2).map(String.init)
        guard parts.count >= 3, let idx = Int(parts[0]) else { return nil }
        return TrackListEntry(index: idx, name: parts[1], artist: parts[2], isCurrent: isCurrent)
    }
}

func pollAlbumTracks(for np: NowPlayingState, backend: AppleScriptBackend = AppleScriptBackend()) -> [TrackListEntry] {
    let album = escapeAppleScriptString(np.album)
    let artist = escapeAppleScriptString(np.artist)
    let currentTitle = np.track
    let currentArtist = np.artist

    guard !album.isEmpty, let result = try? syncRun({
        try await backend.runMusic("""
            try
                set currentDisc to 0
                try
                    set currentDisc to disc number of current track
                end try
                set matches to {}
                if currentDisc is not 0 then
                    set matches to (every track of playlist "Library" whose album is "\(album)" and artist contains "\(artist)" and disc number is currentDisc)
                end if
                if (count of matches) = 0 then
                    set matches to (every track of playlist "Library" whose album is "\(album)" and artist contains "\(artist)")
                end if
                if (count of matches) = 0 then
                    set matches to (every track of playlist "Library" whose album is "\(album)")
                end if
                set fs to (ASCII character 31)
                set output to ""
                repeat with t in matches
                    if output is not "" then set output to output & linefeed
                    set tn to 0
                    try
                        set tn to track number of t
                    end try
                    set output to output & tn & fs & name of t & fs & artist of t
                end repeat
                return output
            end try
            return ""
        """)
    }) else { return pollSurroundingTracks(backend: backend) }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return pollSurroundingTracks(backend: backend) }

    let sorted: [TrackListEntry] = trimmed.components(separatedBy: "\n").compactMap { line -> TrackListEntry? in
        let parts = line.split(separator: asFieldSep, maxSplits: 2).map(String.init)
        guard parts.count >= 3 else { return nil }
        let idx = Int(parts[0]) ?? 0
        let name = parts[1]
        let artist = parts[2]
        return TrackListEntry(
            index: idx,
            name: name,
            artist: artist,
            isCurrent: name == currentTitle && artist == currentArtist
        )
    }
    .sorted {
        if $0.index == $1.index { return $0.name < $1.name }
        if $0.index == 0 { return false }
        if $1.index == 0 { return true }
        return $0.index < $1.index
    }

    var seen: Set<String> = []
    var deduped: [TrackListEntry] = []
    for entry in sorted {
        let key = trackKey(title: entry.name, artist: entry.artist)
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        deduped.append(entry)
    }

    return deduped.enumerated().map { offset, entry in
        TrackListEntry(
            index: offset + 1,
            name: entry.name,
            artist: entry.artist,
            isCurrent: entry.isCurrent
        )
    }
}

/// Extract the current track's artwork bytes to `artPath` (caller-supplied —
/// see PlaybackPoller's per-album temp paths: writing every album to the SAME
/// fixed path let a revisited album's raw bytes go stale relative to
/// whatever album was extracted most recently, since a lines-cache hit skips
/// re-extraction; a stable per-album path makes that staleness impossible
/// instead of just less likely).
func extractArtwork(to artPath: String) -> String? {
    let backend = AppleScriptBackend()
    guard let result = try? syncRun({
        try await backend.runMusic("""
            try
                set artworks_ to artworks of current track
                if (count of artworks_) > 0 then
                    set artData to raw data of item 1 of artworks_
                    set filePath to "\(artPath)"
                    set fileRef to open for access POSIX file filePath with write permission
                    set eof of fileRef to 0
                    write artData to fileRef
                    close access fileRef
                    return "OK"
                end if
            end try
            return "NONE"
        """)
    }) else { return nil }
    if result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" {
        return artPath
    }
    return nil
}

func artworkToAscii(path: String, width: Int = 20, height: Int = 10) -> [String] {
    // Try chafa first (true color, half-block characters)
    if let chafaPath = findExecutable("chafa") {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: chafaPath)
        proc.arguments = [
            "--format", "symbols",
            "--size", "\(width)x\(height)",
            "--symbols", "block+border+space",
            "--color-space", "rgb",
            path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                return output.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
        } catch {}
    }

    // Fallback: CoreGraphics brightness mapping
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }

    let w = width
    let h = height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = w * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: h * bytesPerRow)

    guard let context = CGContext(
        data: &pixelData, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return [] }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    let blocks: [Character] = [" ", "░", "▒", "▓", "█"]
    var lines: [String] = []

    for y in 0..<h {
        var line = ""
        for x in 0..<w {
            let offset = ((h - 1 - y) * bytesPerRow) + (x * bytesPerPixel)
            let r = Int(pixelData[offset])
            let g = Int(pixelData[offset + 1])
            let b = Int(pixelData[offset + 2])
            let brightness = (r + g + b) / 3
            let idx = min(blocks.count - 1, brightness * blocks.count / 256)
            line.append(blocks[idx])
        }
        lines.append(line)
    }
    return lines
}

func findExecutable(_ name: String) -> String? {
    let paths = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)"
    ]
    for path in paths {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

func formatTime(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

struct TimelineRow {
    let index: Int?
    let label: String
    let isCurrent: Bool
    let wasPlayed: Bool
}

func trackKey(title: String, artist: String) -> String {
    "\(title)\u{0}\(artist)"
}

/// Returns false when the script failed OR no library track matched — the
/// caller can surface "not found" instead of silently doing nothing.
@discardableResult
func playLibraryTrack(backend: AppleScriptBackend, title: String, artist: String) -> Bool {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            \(libraryTrackLookupScript(title: title, artist: artist))
            if (count of results) > 0 then
                play item 1 of results
                return "PLAYED"
            end if
            return "NONE"
        """)
    }) else { return false }
    return result.trimmingCharacters(in: .whitespacesAndNewlines) == "PLAYED"
}

func renderTimelineRows(
    rows: [TimelineRow],
    header: String,
    x: Int,
    y: Int,
    width: Int,
    visibleHeight: Int,
    cursorIndex: Int,
    scrollOffset: inout Int
) -> String {
    var out = ""
    var tRow = y

    out += ANSICode.moveTo(row: tRow, col: x)
    out += "\(ANSICode.bold)\(ANSICode.cyan)\(header)\(ANSICode.reset)"
    tRow += 1
    out += ANSICode.moveTo(row: tRow, col: x)
    out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(18, max(1, header.count + 2))))\(ANSICode.reset)"
    tRow += 2

    let rowHeight = max(1, visibleHeight - 3)
    guard !rows.isEmpty else { return out }

    let clampedCursor = max(0, min(rows.count - 1, cursorIndex))
    if clampedCursor < scrollOffset { scrollOffset = clampedCursor }
    if clampedCursor >= scrollOffset + rowHeight { scrollOffset = clampedCursor - rowHeight + 1 }

    let end = min(rows.count, scrollOffset + rowHeight)

    // Cap the selection highlight to hug the content: widest visible row + 1,
    // never wider than the pane. Avoids a highlight bar spanning a huge pane.
    func rowContent(_ row: TimelineRow) -> String {
        let indexText = row.index.map { String(format: "%02d", $0) } ?? "  "
        let marker = row.isCurrent ? "\u{25B6} " : "  "
        let label = truncText(row.label, to: max(1, width - 6))
        return "\(marker)\(indexText)  \(label)"
    }
    var maxLen = 0
    for rowIndex in scrollOffset..<end { maxLen = max(maxLen, rowContent(rows[rowIndex]).count) }
    let highlightWidth = min(width, maxLen + 1)

    for rowIndex in scrollOffset..<end {
        let row = rows[rowIndex]
        let isCursor = rowIndex == clampedCursor
        // Consistent geometry for every row — state is encoded as color/highlight,
        // never as indentation. A 2-col status slot (▶ for the playing track, else
        // blank), the index, then the label.
        let content = rowContent(row)
        let padded = content.count < highlightWidth ? content + String(repeating: " ", count: highlightWidth - content.count) : content

        out += ANSICode.moveTo(row: tRow, col: x)
        if isCursor {
            // Full-width highlight line for the selected row.
            out += "\(ANSICode.inverse)\(padded)\(ANSICode.reset)"
        } else if row.isCurrent {
            out += "\(ANSICode.lime)\(content)\(ANSICode.reset)"
        } else if row.wasPlayed {
            out += "\(ANSICode.dim)\(content)\(ANSICode.reset)"
        } else {
            out += content
        }
        tRow += 1
    }

    return out
}

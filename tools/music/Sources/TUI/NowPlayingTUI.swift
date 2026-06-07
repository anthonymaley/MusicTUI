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
    var speakers: [(name: String, volume: Int)] = []
    var shuffleEnabled: Bool = false
    var repeatMode: String = "off"
    var loved: Bool = false
    var disliked: Bool = false
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

/// Consecutive `.unavailable` polls tolerated before the UI falls back to the
/// "stopped" screen. A single transient AppleScript hiccup must not blank a
/// screen that is actually playing.
private let unavailableBlankThreshold = 4

func pollNowPlaying(backend: AppleScriptBackend = AppleScriptBackend()) -> PollOutcome {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            try
                set state to player state as text
                if state is "stopped" then return "STOPPED"
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                set spk to ""
                set deviceList to every AirPlay device
                repeat with dev in deviceList
                    if selected of dev then
                        if spk is not "" then set spk to spk & ","
                        set spk to spk & name of dev & ":" & sound volume of dev
                    end if
                end repeat
                set sh to shuffle enabled
                set rp to song repeat as text
                set lv to false
                set dl to false
                try
                    set lv to loved of current track
                    set dl to disliked of current track
                end try
                return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk & "|" & sh & "|" & rp & "|" & lv & "|" & dl
            end try
            return "STOPPED"
        """)
    }) else { return .unavailable }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return .stopped }
    let parts = trimmed.split(separator: "|", maxSplits: 10).map(String.init)
    guard parts.count >= 7 else { return .unavailable }

    let speakers = parts[6].split(separator: ",").compactMap { pair -> (name: String, volume: Int)? in
        let kv = pair.split(separator: ":", maxSplits: 1)
        guard let first = kv.first else { return nil }
        return (name: String(first), volume: Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0)
    }

    let shuffleEnabled = parts.count > 7 && parts[7].trimmingCharacters(in: .whitespaces) == "true"
    let repeatMode = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespaces) : "off"
    let loved = parts.count > 9 && parts[9].trimmingCharacters(in: .whitespaces) == "true"
    let disliked = parts.count > 10 && parts[10].trimmingCharacters(in: .whitespaces) == "true"

    return .active(NowPlayingState(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: Int(parts[3]) ?? 0, position: Int(parts[4]) ?? 0,
        state: parts[5], speakers: speakers,
        shuffleEnabled: shuffleEnabled, repeatMode: repeatMode,
        loved: loved, disliked: disliked
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
                set startIdx to idx - 4
                if startIdx < 1 then set startIdx to 1
                set endIdx to idx + 4
                if endIdx > total then set endIdx to total
                repeat with i from startIdx to endIdx
                    set t to track i of cp
                    if output is not "" then set output to output & linefeed
                    if i = idx then
                        set output to output & ">" & i & "|" & name of t & "|" & artist of t
                    else
                        set output to output & " " & i & "|" & name of t & "|" & artist of t
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
        let parts = clean.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 3, let idx = Int(parts[0]) else { return nil }
        return TrackListEntry(index: idx, name: parts[1], artist: parts[2], isCurrent: isCurrent)
    }
}

func pollAlbumTracks(for np: NowPlayingState, backend: AppleScriptBackend = AppleScriptBackend()) -> [TrackListEntry] {
    let album = np.album.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let artist = np.artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
                set output to ""
                repeat with t in matches
                    if output is not "" then set output to output & linefeed
                    set tn to 0
                    try
                        set tn to track number of t
                    end try
                    set output to output & tn & "|" & name of t & "|" & artist of t
                end repeat
                return output
            end try
            return ""
        """)
    }) else { return pollSurroundingTracks(backend: backend) }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return pollSurroundingTracks(backend: backend) }

    let sorted: [TrackListEntry] = trimmed.components(separatedBy: "\n").compactMap { line -> TrackListEntry? in
        let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
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

func clearBlock(x: Int, y: Int, width: Int, height: Int) -> String {
    guard width > 0, height > 0 else { return "" }
    var out = ""
    let blank = String(repeating: " ", count: width)
    for row in y..<(y + height) {
        out += ANSICode.moveTo(row: row, col: x)
        out += blank
    }
    return out
}

func extractArtwork() -> String? {
    let artPath = "/tmp/music-now-art.dat"
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
            "--work", "9",
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

/// Radio from the currently-playing track's artist (unchanged public behavior).
func startRadioStation() -> PlaybackContext? {
    let backend = AppleScriptBackend()
    // Get current track info
    guard let info = try? syncRun({
        try await backend.runMusic("return name of current track & \"|\" & artist of current track")
    }) else { return nil }
    let parts = info.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1)
    guard parts.count >= 2 else { return nil }
    return startRadioStation(seedTitle: String(parts[0]), seedArtist: String(parts[1]))
}

/// Build + play an artist station seeded by an explicit track/artist.
func startRadioStation(seedTitle: String, seedArtist: String) -> PlaybackContext? {
    let backend = AppleScriptBackend()
    let trackName = seedTitle
    let artistName = seedArtist
    let playlistName = "__radio__ \(artistName) — \(trackName)"
    let escapedPlaylist = escapeAppleScriptString(playlistName)
    let escapedArtist = escapeAppleScriptString(artistName)

    // Search catalog for the artist to build a radio-like playlist
    let auth = AuthManager()
    guard let devToken = try? auth.requireDeveloperToken(),
          let userToken = try? auth.requireUserToken() else {
        // No auth — fall back to a real shuffled library playlist by the same artist.
        let output = try? syncRun {
            try await backend.runMusic("""
                try
                    if exists playlist "\(escapedPlaylist)" then delete playlist "\(escapedPlaylist)"
                end try
                make new playlist with properties {name:"\(escapedPlaylist)"}
                set artistTracks to (every track of playlist "Library" whose artist contains "\(escapedArtist)")
                set output to ""
                set addedCount to 0
                repeat with t in artistTracks
                    if addedCount is greater than or equal to 50 then exit repeat
                    duplicate t to playlist "\(escapedPlaylist)"
                    set addedCount to addedCount + 1
                    if output is not "" then set output to output & linefeed
                    set output to output & name of t & " — " & artist of t
                end repeat
                set shuffle enabled to true
                if addedCount > 0 then play playlist "\(escapedPlaylist)"
                return output
            """)
        }
        let tracks = output?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []
        guard !tracks.isEmpty else { return nil }
        return PlaybackContext(playlistName: playlistName, tracks: tracks, startIndex: 0)
    }

    let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

    // Search for more songs by the same artist
    guard let songs = try? syncRun({ try await api.searchSongs(query: artistName, limit: 25) }),
          !songs.isEmpty else { return nil }

    // Create a temp playlist and shuffle it
    _ = try? syncRun {
        try await backend.runMusic("""
            try
                if exists playlist "\(escapedPlaylist)" then delete playlist "\(escapedPlaylist)"
            end try
            make new playlist with properties {name:"\(escapedPlaylist)"}
        """)
    }

    // Add songs to library first, then to playlist
    let ids = songs.map { $0.id }
    try? syncRun { try await api.addToLibrary(songIDs: ids) }
    try? syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }

    var playlistTracks: [String] = []
    for song in songs {
        let et = escapeAppleScriptString(song.title)
        let ea = escapeAppleScriptString(song.artist)
        let added = try? syncRun {
            try await backend.runMusic("""
                set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                if (count of results) = 0 then
                    set results to (every track of playlist "Library" whose name contains "\(et)" and artist contains "\(ea)")
                end if
                if (count of results) > 0 then
                    duplicate item 1 of results to playlist "\(escapedPlaylist)"
                    return name of item 1 of results & " — " & artist of item 1 of results
                end if
                return ""
            """)
        }
        let line = added?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !line.isEmpty {
            playlistTracks.append(line)
        }
    }

    guard !playlistTracks.isEmpty else { return nil }

    // Shuffle play the radio playlist
    _ = try? syncRun { try await backend.runMusic("set shuffle enabled to true") }
    _ = try? syncRun { try await backend.runMusic("play playlist \"\(escapedPlaylist)\"") }
    return PlaybackContext(playlistName: playlistName, tracks: playlistTracks, startIndex: 0)
}

// MARK: - Now Playing result for context-aware mode

enum NowPlayingResult {
    case back   // user pressed b/Esc — return to browser
    case quit   // user pressed q
}

enum TimelineRowKind {
    case playlist
    case history
    case queue
}

struct TimelineRow {
    let id: String
    let kind: TimelineRowKind
    let index: Int?
    let title: String
    let artist: String
    let label: String
    let isCurrent: Bool
    let wasPlayed: Bool
    let isReplayable: Bool
}

func splitTrackLine(_ line: String) -> (title: String, artist: String) {
    let parts = line.split(separator: "\u{2014}", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    let title = parts.first.map { String($0) } ?? line
    let artist = parts.count > 1 ? String(parts[1]) : ""
    return (title, artist)
}

func trackKey(title: String, artist: String) -> String {
    "\(title)\u{0}\(artist)"
}

func buildPlaylistRows(
    contextTracks: [String],
    history: [(track: String, artist: String)],
    currentIndex: Int?
) -> [TimelineRow] {
    let played = Set(history.map { trackKey(title: $0.track, artist: $0.artist) })
    return contextTracks.enumerated().map { i, line in
        let parsed = splitTrackLine(line)
        return TimelineRow(
            id: trackKey(title: parsed.title, artist: parsed.artist),
            kind: .playlist,
            index: i + 1,
            title: parsed.title,
            artist: parsed.artist,
            label: line,
            isCurrent: i == currentIndex,
            wasPlayed: played.contains(trackKey(title: parsed.title, artist: parsed.artist)),
            isReplayable: true
        )
    }
}

func buildStandaloneRows(
    history: [(track: String, artist: String)],
    surrounding: [TrackListEntry]
) -> [TimelineRow] {
    var rows: [TimelineRow] = []
    let surroundingKeys = Set(surrounding.map { trackKey(title: $0.name, artist: $0.artist) })

    for item in history.reversed() {
        let key = trackKey(title: item.track, artist: item.artist)
        guard !surroundingKeys.contains(key) else { continue }
        rows.append(
            TimelineRow(
                id: key,
                kind: .history,
                index: nil,
                title: item.track,
                artist: item.artist,
                label: "\(item.track) — \(item.artist)",
                isCurrent: false,
                wasPlayed: true,
                isReplayable: true
            )
        )
    }

    let played = Set(history.map { trackKey(title: $0.track, artist: $0.artist) })

    rows.append(contentsOf: surrounding.map { entry in
        let key = trackKey(title: entry.name, artist: entry.artist)
        return TimelineRow(
            id: key,
            kind: .queue,
            index: entry.index,
            title: entry.name,
            artist: entry.artist,
            label: "\(entry.name) — \(entry.artist)",
            isCurrent: entry.isCurrent,
            wasPlayed: played.contains(key),
            isReplayable: true
        )
    })

    return rows
}

func playTrackInPlaylist(backend: AppleScriptBackend, playlistName: String, index: Int) {
    let escapedPlaylist = playlistName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    _ = try? syncRun {
        try await backend.runMusic("play track \(index) of playlist \"\(escapedPlaylist)\"")
    }
}

func playTrackInCurrentPlaylist(backend: AppleScriptBackend, index: Int) {
    _ = try? syncRun {
        try await backend.runMusic("play track \(index) of current playlist")
    }
}

func playLibraryTrack(backend: AppleScriptBackend, title: String, artist: String) {
    let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let escapedArtist = artist.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    _ = try? syncRun {
        try await backend.runMusic("""
            set results to (every track of playlist "Library" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
            if (count of results) = 0 then
                set results to (every track of playlist "Library" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
            end if
            if (count of results) > 0 then play item 1 of results
        """)
    }
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
    out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(8, max(1, header.count))))\(ANSICode.reset)"
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

// MARK: - Shared Now Playing Layout

struct NowPlayingLayout {
    static let artX = 3
    static let artY = 11
    static let artW = 26
    static let metaX = 34
    static let metaY = 11
    static let metaW = 30
    static let timelineX = 80
    static let progBarW = 18
}

/// Render metadata, progress bar, speaker info, and mode indicators.
/// Returns ANSI string to append to output buffer.
func renderNowPlayingMetadata(
    np: NowPlayingState,
    artLines: [String],
    frame: ScreenFrame
) -> String {
    let artX = NowPlayingLayout.artX
    let artY = NowPlayingLayout.artY
    let artW = NowPlayingLayout.artW
    let metaX = NowPlayingLayout.metaX
    let metaY = NowPlayingLayout.metaY
    let metaW = NowPlayingLayout.metaW
    let progBarW = NowPlayingLayout.progBarW

    var out = ""

    // Cover art
    let artSize = min(artW, 26, frame.statusY - artY - 2)
    for i in 0..<artSize {
        if i < artLines.count {
            out += ANSICode.moveTo(row: artY + i, col: artX)
            out += "\(artLines[i])\(ANSICode.reset)"
        }
    }

    // Track title with rating icon
    let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
    let ratingIcon = np.loved ? " \(ANSICode.red)\u{2665}\(ANSICode.reset)\(ANSICode.bold)" : np.disliked ? " \(ANSICode.dim)\u{2193}\(ANSICode.reset)\(ANSICode.bold)" : ""
    let titlePrefixLen = np.loved || np.disliked ? 4 : 2
    out += ANSICode.moveTo(row: metaY, col: metaX)
    out += String(repeating: " ", count: metaW + 4)
    out += ANSICode.moveTo(row: metaY, col: metaX)
    out += "\(ANSICode.bold)\(playIcon)\(ratingIcon) \(truncText(np.track, to: metaW - titlePrefixLen))\(ANSICode.reset)"

    // Artist
    out += ANSICode.moveTo(row: metaY + 2, col: metaX)
    out += String(repeating: " ", count: metaW + 4)
    out += ANSICode.moveTo(row: metaY + 2, col: metaX)
    out += truncText(np.artist, to: metaW)

    // Album
    out += ANSICode.moveTo(row: metaY + 4, col: metaX)
    out += String(repeating: " ", count: metaW + 4)
    out += ANSICode.moveTo(row: metaY + 4, col: metaX)
    out += "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"

    // Progress bar
    let elapsed = formatTime(np.position)
    let total = formatTime(np.duration)
    let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
    let knobIdx = max(0, min(progBarW - 1, Int(ratio * Double(progBarW - 1))))
    var barStr = ""
    for i in 0..<progBarW {
        barStr += i == knobIdx ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)"
    }
    out += ANSICode.moveTo(row: metaY + 8, col: metaX)
    out += "\(elapsed) \(barStr) \(total)"

    // Output / Volume grid
    let labelW = 9
    if !np.speakers.isEmpty {
        let primarySpk = np.speakers.first!
        out += ANSICode.moveTo(row: metaY + 12, col: metaX)
        out += "\(ANSICode.dim)Output\(ANSICode.reset)"
        out += ANSICode.moveTo(row: metaY + 12, col: metaX + labelW)
        out += truncText(primarySpk.name, to: metaW - labelW)

        var nextMetaRow = metaY + 14
        if np.speakers.count > 1 {
            let mixStr = np.speakers.map { "\($0.name) \($0.volume)" }.joined(separator: ", ")
            out += ANSICode.moveTo(row: nextMetaRow, col: metaX)
            out += "\(ANSICode.dim)Mix\(ANSICode.reset)"
            out += ANSICode.moveTo(row: nextMetaRow, col: metaX + labelW)
            out += "\(ANSICode.dim)\(truncText(mixStr, to: metaW - labelW))\(ANSICode.reset)"
            nextMetaRow += 2
        }

        out += ANSICode.moveTo(row: nextMetaRow, col: metaX)
        out += "\(ANSICode.dim)Volume\(ANSICode.reset)"
        out += ANSICode.moveTo(row: nextMetaRow, col: metaX + labelW)
        out += "\(primarySpk.volume)"
    }

    // Shuffle/repeat indicators
    var modeStr = ""
    if np.shuffleEnabled { modeStr += "Shuffle" }
    if np.repeatMode == "one" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat One" }
    else if np.repeatMode == "all" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat" }
    let modeRow = np.speakers.isEmpty ? metaY + 12 : metaY + 18
    out += ANSICode.moveTo(row: modeRow, col: metaX)
    out += String(repeating: " ", count: metaW + 4)
    if !modeStr.isEmpty {
        out += ANSICode.moveTo(row: modeRow, col: metaX)
        out += "\(ANSICode.dim)\(modeStr)\(ANSICode.reset)"
    }

    return out
}

/// Render "Nothing playing" screen.
func renderNowPlayingStopped(footer: String) {
    let frame = ScreenFrame.current()
    var out = ANSICode.clearScreen + renderShell(title: "Now Playing", status: "", footer: footer)
    out += ANSICode.moveTo(row: frame.bodyY + 2, col: 3)
    out += "\(ANSICode.dim)Nothing playing.\(ANSICode.reset)"
    print(out, terminator: "")
    fflush(stdout)
}

/// Drain all pending input from stdin.
func flushStdin() {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    while poll(&pfd, 1, 0) > 0 && pfd.revents & Int16(POLLIN) != 0 {
        var discard = [UInt8](repeating: 0, count: 256)
        _ = Darwin.read(STDIN_FILENO, &discard, 256)
    }
}

/// Run speaker picker as modal subflow. Returns after user confirms/quits.
func runSpeakerPickerModal(backend: AppleScriptBackend) {
    let speakerDevices: [[String: Any]]
    do {
        speakerDevices = try fetchSpeakerDevices()
    } catch {
        verbose("failed to fetch speakers: \(error.localizedDescription)")
        return
    }
    var volumes = speakerDevices.map { $0["volume"] as! Int }
    var items = speakerDevices.map {
        MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
    }
    _ = runMultiSelectList(title: "AirPlay Speakers", items: &items, onToggle: { idx, selected in
        let name = speakerDevices[idx]["name"] as! String
        do {
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(name))\" to \(selected)")
            }
        } catch {
            verbose("speaker operation failed: \(error.localizedDescription)")
        }
    }, onAdjust: { idx, delta in
        volumes[idx] = min(100, max(0, volumes[idx] + delta))
        let name = speakerDevices[idx]["name"] as! String
        let vol = volumes[idx]
        do {
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(name))\" to \(vol)")
            }
        } catch {
            verbose("speaker operation failed: \(error.localizedDescription)")
        }
        return "vol: \(vol)"
    })
}

/// Run volume mixer as modal subflow. Returns after user quits.
func runVolumeMixerModal(backend: AppleScriptBackend) {
    let devices: [[String: Any]]
    do {
        devices = try fetchSpeakerDevices()
    } catch {
        verbose("failed to fetch speakers: \(error.localizedDescription)")
        return
    }
    var speakers = devices.compactMap { d -> MixerSpeaker? in
        guard d["selected"] as? Bool == true else { return nil }
        return MixerSpeaker(name: d["name"] as! String, volume: d["volume"] as! Int)
    }
    guard !speakers.isEmpty else { return }
    runVolumeMixer(speakers: &speakers) { name, volume in
        do {
            _ = try syncRun {
                try await backend.runMusic("set sound volume of AirPlay device \"\(escapeAppleScriptString(name))\" to \(volume)")
            }
        } catch {
            verbose("speaker operation failed: \(error.localizedDescription)")
        }
    }
}

/// Refresh artwork for current track.
func refreshNowPlayingArtwork(artW: Int, artY: Int, statusY: Int) -> [String] {
    let artSize = min(artW, 26, statusY - artY - 2)
    if let artPath = extractArtwork() {
        return artworkToAscii(path: artPath, width: artW, height: artSize)
    }
    return []
}

// MARK: - Context-aware Now Playing (used from playlist browser)

func runNowPlayingWithContext(_ context: PlaybackContext?) -> NowPlayingResult {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")

    let timelineX = NowPlayingLayout.timelineX
    let metaY = NowPlayingLayout.metaY
    let artW = NowPlayingLayout.artW
    let artY = NowPlayingLayout.artY

    var artLines: [String] = []
    var lastTrackName = ""
    var lastArtistName = ""
    var lastCurrentIdx: Int? = nil
    var lastShuffleEnabled = false
    var stoppedPolls = 0
    var errorPolls = 0
    var history: [(track: String, artist: String)] = []
    var queueCursor = context?.startIndex ?? 0
    var queueScroll = 0
    var activePlaylistName = context?.playlistName ?? ""
    var contextTracks: [String] = context?.tracks ?? []

    func findCurrentTrackIndex(np: NowPlayingState) -> Int? {
        var substringMatch: Int? = nil
        for (i, track) in contextTracks.enumerated() {
            let parts = track.split(separator: "\u{2014}", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let title = parts.first ?? ""
            if title == np.track { return i }
            if substringMatch == nil && !title.isEmpty && (np.track.contains(title) || title.contains(np.track)) {
                substringMatch = i
            }
        }
        return substringMatch
    }

    func render(_ np: NowPlayingState) {
        let frame = ScreenFrame.current()
        let timelineW = frame.width - timelineX - 3
        let footerText = "\(ANSICode.bold)↑↓\(ANSICode.reset) Playlist  \(ANSICode.bold)Enter\(ANSICode.reset) Play  \(ANSICode.bold)←→\(ANSICode.reset) Seek  \(ANSICode.bold)Space\(ANSICode.reset) \u{23EF}  \(ANSICode.bold)z\(ANSICode.reset) Shuffle  \(ANSICode.bold)r\(ANSICode.reset) Radio  \(ANSICode.bold)s\(ANSICode.reset) Spk  \(ANSICode.bold)v\(ANSICode.reset) Mix  \(ANSICode.bold)+-\(ANSICode.reset) Vol  \(ANSICode.bold)b\(ANSICode.reset) Back  \(ANSICode.bold)q\(ANSICode.reset) Quit"

        let titleText = !activePlaylistName.isEmpty ? "\u{266B} Now Playing \u{2014} \(activePlaylistName)" : "\u{266B} Now Playing"
        var out = renderShell(title: titleText, status: "", footer: footerText)
        out += ANSICode.moveTo(row: frame.bodyY + 2, col: 1)
        out += String(repeating: " ", count: frame.width)
        out += renderNowPlayingMetadata(np: np, artLines: artLines, frame: frame)

        // --- Timeline pane ---
        if timelineW >= 24 {
            let currentIdx = findCurrentTrackIndex(np: np)
            let rows = buildPlaylistRows(contextTracks: contextTracks, history: history, currentIndex: currentIdx)
            out += renderTimelineRows(
                rows: rows,
                header: "Playlist",
                x: timelineX,
                y: metaY,
                width: timelineW,
                visibleHeight: frame.statusY - metaY - 2,
                cursorIndex: queueCursor,
                scrollOffset: &queueScroll
            )
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    let contextStoppedFooter = "\(ANSICode.bold)b\(ANSICode.reset) Back   \(ANSICode.bold)q\(ANSICode.reset) Quit"

    func refreshArtwork() {
        let frame = ScreenFrame.current()
        artLines = refreshNowPlayingArtwork(artW: artW, artY: artY, statusY: frame.statusY)
    }

    func refreshTimelineOnly() {
        let frame = ScreenFrame.current()
        let timelineW = frame.width - timelineX - 3
        let currentIdx = lastCurrentIdx
        let rows = buildPlaylistRows(contextTracks: contextTracks, history: history, currentIndex: currentIdx)
        guard timelineW >= 24 && !rows.isEmpty else { return }

        var out = ""
        for r in metaY..<(frame.statusY - 2) {
            out += ANSICode.moveTo(row: r, col: timelineX)
            out += String(repeating: " ", count: max(0, timelineW))
        }
        out += renderTimelineRows(
            rows: rows,
            header: "Playlist",
            x: timelineX,
            y: metaY,
            width: timelineW,
            visibleHeight: frame.statusY - metaY - 2,
            cursorIndex: queueCursor,
            scrollOffset: &queueScroll
        )

        print(out, terminator: "")
        fflush(stdout)
    }

    // Initial render
    let backend = AppleScriptBackend()
    switch pollNowPlaying(backend: backend) {
    case .active(let np):
        lastTrackName = np.track
        lastArtistName = np.artist
        lastShuffleEnabled = np.shuffleEnabled
        stoppedPolls = 0
        refreshArtwork()
        if let idx = findCurrentTrackIndex(np: np) {
            lastCurrentIdx = idx
        }
        render(np)
    case .stopped, .unavailable:
        renderNowPlayingStopped(footer: contextStoppedFooter)
    }

    while true {
        // Terminal was resized (SIGWINCH): wipe stale artifacts so the next
        // poll tick repaints cleanly against the new dimensions.
        if terminalResized {
            terminalResized = false
            print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
            fflush(stdout)
        }
        let key = KeyPress.read(timeout: 1.0)

        if let key = key {
            switch key {
            case .up:
                if !contextTracks.isEmpty {
                    queueCursor = max(0, queueCursor - 1)
                    refreshTimelineOnly()
                    continue
                } else {
                    _ = try? syncRun { try await backend.runMusic("previous track") }
                }
            case .down:
                if !contextTracks.isEmpty {
                    let rows = buildPlaylistRows(contextTracks: contextTracks, history: history, currentIndex: lastCurrentIdx)
                    queueCursor = min(max(0, rows.count - 1), queueCursor + 1)
                    refreshTimelineOnly()
                    continue
                } else {
                    _ = try? syncRun { try await backend.runMusic("next track") }
                }
            case .enter:
                let rows = buildPlaylistRows(contextTracks: contextTracks, history: history, currentIndex: lastCurrentIdx)
                if queueCursor < rows.count {
                    let row = rows[queueCursor]
                    let plName = activePlaylistName
                    if let index = row.index {
                        playTrackInPlaylist(backend: backend, playlistName: plName, index: index)
                    }
                }
            case .left:
                _ = try? syncRun {
                    try await backend.runMusic("set player position to (player position - 30)")
                }
            case .right:
                _ = try? syncRun {
                    try await backend.runMusic("set player position to (player position + 30)")
                }
            case .space:
                _ = try? syncRun { try await backend.runMusic("playpause") }
            case .char("z"):
                _ = try? syncRun {
                    try await backend.runMusic("""
                        set sh to shuffle enabled
                        set shuffle enabled to not sh
                    """)
                }
            case .char("r"):
                let frame = ScreenFrame.current()
                var loadingOut = ANSICode.moveTo(row: frame.statusY, col: 3)
                loadingOut += ANSICode.clearLine
                loadingOut += "\(ANSICode.yellow)Building radio station…\(ANSICode.reset)"
                print(loadingOut, terminator: "")
                fflush(stdout)
                if let radioContext = startRadioStation() {
                    activePlaylistName = radioContext.playlistName
                    contextTracks = radioContext.tracks
                    queueCursor = radioContext.startIndex
                    queueScroll = 0
                    history.removeAll()
                    lastTrackName = ""
                    lastArtistName = ""
                    lastCurrentIdx = nil
                    refreshTimelineOnly()
                }
            case .f7, .char("<"), .char(","):
                if let idx = lastCurrentIdx, !activePlaylistName.isEmpty {
                    if lastShuffleEnabled, contextTracks.count > 1 {
                        let randomIndex = (0..<contextTracks.count).filter { $0 != idx }.randomElement() ?? max(0, idx - 1)
                        playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: randomIndex + 1)
                    } else if idx > 0 {
                        playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: idx)
                    }
                }
            case .f9, .char(">"), .char("."):
                if let idx = lastCurrentIdx, !activePlaylistName.isEmpty {
                    if lastShuffleEnabled, contextTracks.count > 1 {
                        let randomIndex = (0..<contextTracks.count).filter { $0 != idx }.randomElement() ?? min(contextTracks.count - 1, idx + 1)
                        playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: randomIndex + 1)
                    } else if idx + 1 < contextTracks.count {
                        playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: idx + 2)
                    }
                }
            case .char("+"), .char("="):
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume + 5)") }
            case .char("-"):
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume - 5)") }
            case .char("s"):
                terminal.exitRawMode()
                runSpeakerPickerModal(backend: backend)
                terminal.enterRawMode()
            case .char("v"):
                terminal.exitRawMode()
                runVolumeMixerModal(backend: backend)
                terminal.enterRawMode()
            case .char("b"), .escape:
                return .back
            case .char("q"):
                return .quit
            default:
                break
            }
        }

        // Re-poll and render
        switch pollNowPlaying(backend: backend) {
        case .active(let np):
            stoppedPolls = 0
            errorPolls = 0
            lastShuffleEnabled = np.shuffleEnabled
            if np.track != lastTrackName {
                if !lastTrackName.isEmpty {
                    if history.first.map({ $0.track != lastTrackName || $0.artist != lastArtistName }) ?? true {
                        history.insert((track: lastTrackName, artist: lastArtistName), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrackName = np.track
                lastArtistName = np.artist
                refreshArtwork()
                if let idx = findCurrentTrackIndex(np: np) {
                    lastCurrentIdx = idx
                }
                flushStdin()
            } else {
                // Track didn't change — update currentIdx silently
                if let idx = findCurrentTrackIndex(np: np) {
                    lastCurrentIdx = idx
                }
            }
            render(np)
        case .stopped:
            // Genuine end-of-track: advance to the next track in the playlist.
            errorPolls = 0
            stoppedPolls += 1
            if let idx = lastCurrentIdx,
               idx + 1 < contextTracks.count,
               !activePlaylistName.isEmpty {
                if lastShuffleEnabled, contextTracks.count > 1 {
                    let randomIndex = (0..<contextTracks.count).filter { $0 != idx }.randomElement() ?? min(contextTracks.count - 1, idx + 1)
                    playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: randomIndex + 1)
                } else {
                    playTrackInPlaylist(backend: backend, playlistName: activePlaylistName, index: idx + 2)
                }
                stoppedPolls = 0
                continue
            }
            if !lastTrackName.isEmpty && stoppedPolls < 4 {
                continue
            }
            renderNowPlayingStopped(footer: contextStoppedFooter)
        case .unavailable:
            // Transient read failure — keep the last good frame and do NOT
            // advance. Only fall back to the stopped screen after sustained
            // failure (player likely gone), never on a single hiccup.
            errorPolls += 1
            if errorPolls < unavailableBlankThreshold { continue }
            renderNowPlayingStopped(footer: contextStoppedFooter)
        }
    }
}

// MARK: - Standalone Now Playing (for `music now`)

func runNowPlayingTUI() {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")

    let timelineX = NowPlayingLayout.timelineX
    let metaY = NowPlayingLayout.metaY
    let artW = NowPlayingLayout.artW
    let artY = NowPlayingLayout.artY
    let standaloneStoppedFooter = "\(ANSICode.dim)Controls\(ANSICode.reset)  \(ANSICode.bold)q\(ANSICode.reset) Quit"

    var surroundingTracks: [TrackListEntry] = []
    var artLines: [String] = []
    var lastTrackName = ""
    var lastArtistName = ""
    var lastPosition = 0
    var lastDuration = 0
    var stoppedPolls = 0
    var errorPolls = 0
    var history: [(track: String, artist: String)] = []
    var timelineCursor = 0
    var timelineScroll = 0

    func render(_ np: NowPlayingState) {
        let frame = ScreenFrame.current()
        let timelineW = frame.width - timelineX - 3
        let footerText = "\(ANSICode.dim)Controls\(ANSICode.reset)  \(ANSICode.bold)↑↓\(ANSICode.reset) Album  \(ANSICode.bold)Enter\(ANSICode.reset) Play  \(ANSICode.bold)←→\(ANSICode.reset) Seek  \(ANSICode.bold)Space\(ANSICode.reset) \u{23EF}  \(ANSICode.bold)r\(ANSICode.reset) Radio  \(ANSICode.bold)s\(ANSICode.reset) Spk  \(ANSICode.bold)v\(ANSICode.reset) Mix  \(ANSICode.bold)+-\(ANSICode.reset) Vol  \(ANSICode.bold)q\(ANSICode.reset) Quit"

        var out = renderShell(title: "\u{266B} Now Playing", status: "", footer: footerText)
        out += renderNowPlayingMetadata(np: np, artLines: artLines, frame: frame)

        // --- Timeline pane ---
        if timelineW >= 24 {
            let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
            out += renderTimelineRows(
                rows: rows,
                header: "Album",
                x: timelineX,
                y: metaY,
                width: timelineW,
                visibleHeight: frame.statusY - metaY - 2,
                cursorIndex: timelineCursor,
                scrollOffset: &timelineScroll
            )
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    func refreshTrackContext(_ np: NowPlayingState) {
        surroundingTracks = pollAlbumTracks(for: np, backend: backend)
        let frame = ScreenFrame.current()
        artLines = refreshNowPlayingArtwork(artW: artW, artY: artY, statusY: frame.statusY)
    }

    // Redraw only the timeline pane (no AppleScript poll)
    func refreshTimelineOnly() {
        let frame = ScreenFrame.current()
        let timelineW = frame.width - timelineX - 3
        let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
        guard timelineW >= 24 && !rows.isEmpty else { return }

        var out = ""
        for r in metaY..<(frame.statusY - 2) {
            out += ANSICode.moveTo(row: r, col: timelineX)
            out += String(repeating: " ", count: max(0, timelineW))
        }
        out += renderTimelineRows(
            rows: rows,
            header: "Album",
            x: timelineX,
            y: metaY,
            width: timelineW,
            visibleHeight: frame.statusY - metaY - 2,
            cursorIndex: timelineCursor,
            scrollOffset: &timelineScroll
        )

        print(out, terminator: "")
        fflush(stdout)
    }

    // Initial render
    let backend = AppleScriptBackend()
    switch pollNowPlaying(backend: backend) {
    case .active(let np):
        lastTrackName = np.track
        lastArtistName = np.artist
        lastPosition = np.position
        lastDuration = np.duration
        stoppedPolls = 0
        refreshTrackContext(np)
        let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
        timelineCursor = rows.firstIndex(where: { $0.isCurrent }) ?? 0
        render(np)
    case .stopped, .unavailable:
        renderNowPlayingStopped(footer: standaloneStoppedFooter)
    }

    while true {
        // Terminal was resized (SIGWINCH): wipe stale artifacts so the next
        // poll tick repaints cleanly against the new dimensions.
        if terminalResized {
            terminalResized = false
            print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
            fflush(stdout)
        }
        let key = KeyPress.read(timeout: 1.0)

        if let key = key {
            switch key {
            case .up:
                let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
                if !rows.isEmpty {
                    timelineCursor = max(0, timelineCursor - 1)
                    refreshTimelineOnly()
                    continue
                }
            case .down:
                let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
                if !rows.isEmpty {
                    timelineCursor = min(max(0, rows.count - 1), timelineCursor + 1)
                    refreshTimelineOnly()
                    continue
                }
            case .enter:
                let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
                if timelineCursor < rows.count {
                    let row = rows[timelineCursor]
                    playLibraryTrack(backend: backend, title: row.title, artist: row.artist)
                }
            case .left:
                _ = try? syncRun {
                    try await backend.runMusic("set player position to (player position - 30)")
                }
            case .right:
                _ = try? syncRun {
                    try await backend.runMusic("set player position to (player position + 30)")
                }
            case .space:
                _ = try? syncRun { try await backend.runMusic("playpause") }
            case .char("r"):
                let frame2 = ScreenFrame.current()
                var loadingOut2 = ANSICode.moveTo(row: frame2.statusY, col: 3)
                loadingOut2 += ANSICode.clearLine
                loadingOut2 += "\(ANSICode.yellow)Building radio station…\(ANSICode.reset)"
                print(loadingOut2, terminator: "")
                fflush(stdout)
                if let radioContext = startRadioStation() {
                    terminal.exitRawMode()
                    _ = runNowPlayingWithContext(radioContext)
                    return
                }
            case .f7, .char("<"), .char(","):
                if let currentPos = surroundingTracks.firstIndex(where: { $0.isCurrent }), currentPos > 0 {
                    let entry = surroundingTracks[currentPos - 1]
                    playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                }
            case .f9, .char(">"), .char("."):
                if let currentPos = surroundingTracks.firstIndex(where: { $0.isCurrent }), currentPos + 1 < surroundingTracks.count {
                    let entry = surroundingTracks[currentPos + 1]
                    playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                }
            case .char("+"), .char("="):
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume + 5)") }
            case .char("-"):
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume - 5)") }
            case .char("s"):
                terminal.exitRawMode()
                runSpeakerPickerModal(backend: backend)
                terminal.enterRawMode()
            case .char("v"):
                terminal.exitRawMode()
                runVolumeMixerModal(backend: backend)
                terminal.enterRawMode()
            case .char("q"), .escape:
                return
            default:
                break
            }
        }

        // Re-poll and render
        switch pollNowPlaying(backend: backend) {
        case .active(let np):
            stoppedPolls = 0
            errorPolls = 0
            lastPosition = np.position
            lastDuration = np.duration
            if np.track != lastTrackName {
                if !lastTrackName.isEmpty {
                    if history.first.map({ $0.track != lastTrackName || $0.artist != lastArtistName }) ?? true {
                        history.insert((track: lastTrackName, artist: lastArtistName), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrackName = np.track
                lastArtistName = np.artist
                refreshTrackContext(np)
                let rows = buildStandaloneRows(history: history, surrounding: surroundingTracks)
                timelineCursor = rows.firstIndex(where: { $0.isCurrent }) ?? 0
                // Drain all input that queued during the slow refresh
                flushStdin()
            }
            render(np)
        case .stopped:
            // Genuine stop. Auto-advance only if the track reached its end.
            errorPolls = 0
            stoppedPolls += 1
            let naturalEnd = lastDuration > 0 && lastPosition >= max(0, lastDuration - 4)
            if naturalEnd,
               let currentPos = surroundingTracks.firstIndex(where: { $0.isCurrent }),
               currentPos + 1 < surroundingTracks.count {
                let entry = surroundingTracks[currentPos + 1]
                playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                stoppedPolls = 0
                continue
            }
            if !lastTrackName.isEmpty && stoppedPolls < 4 {
                continue
            }
            renderNowPlayingStopped(footer: standaloneStoppedFooter)
        case .unavailable:
            // Transient read failure — keep the last good frame, never blank
            // on a single hiccup.
            errorPolls += 1
            if errorPolls < unavailableBlankThreshold { continue }
            renderNowPlayingStopped(footer: standaloneStoppedFooter)
        }
    }
}

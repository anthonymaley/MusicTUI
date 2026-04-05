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
}

struct TrackListEntry {
    let index: Int
    let name: String
    let artist: String
    let isCurrent: Bool
}

func pollNowPlaying() -> NowPlayingState? {
    let backend = AppleScriptBackend()
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
                return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk & "|" & sh & "|" & rp
            end try
            return "STOPPED"
        """)
    }) else { return nil }

    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return nil }
    let parts = trimmed.split(separator: "|", maxSplits: 8).map(String.init)
    guard parts.count >= 7 else { return nil }

    let speakers = parts[6].split(separator: ",").map { pair -> (name: String, volume: Int) in
        let kv = pair.split(separator: ":", maxSplits: 1)
        return (name: String(kv[0]), volume: Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0)
    }

    let shuffleEnabled = parts.count > 7 && parts[7].trimmingCharacters(in: .whitespaces) == "true"
    let repeatMode = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespaces) : "off"

    return NowPlayingState(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: Int(parts[3]) ?? 0, position: Int(parts[4]) ?? 0,
        state: parts[5], speakers: speakers,
        shuffleEnabled: shuffleEnabled, repeatMode: repeatMode
    )
}

func pollSurroundingTracks() -> [TrackListEntry] {
    let backend = AppleScriptBackend()
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

func startRadioStation() {
    let backend = AppleScriptBackend()
    // Get current track info
    guard let info = try? syncRun({
        try await backend.runMusic("return name of current track & \"|\" & artist of current track")
    }) else { return }
    let parts = info.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1)
    guard parts.count >= 2 else { return }
    let trackName = String(parts[0])
    let artistName = String(parts[1])

    // Search catalog for the artist to build a radio-like playlist
    let auth = try? AuthManager()
    guard let devToken = try? auth?.requireDeveloperToken(),
          let userToken = try? auth?.requireUserToken() else {
        // No auth — fall back to playing more by the same artist from library
        _ = try? syncRun {
            try await backend.runMusic("""
                set artistTracks to (every track of playlist "Library" whose artist contains "\(artistName.replacingOccurrences(of: "\"", with: "\\\""))")
                set shuffle enabled to true
                play item 1 of artistTracks
            """)
        }
        return
    }

    let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth!.storefront())

    // Search for more songs by the same artist
    guard let songs = try? syncRun({ try await api.searchSongs(query: artistName, limit: 25) }),
          !songs.isEmpty else { return }

    // Create a temp playlist and shuffle it
    let playlistName = "__radio__\(trackName)"
    _ = try? syncRun {
        try await backend.runMusic("make new playlist with properties {name:\"\(playlistName.replacingOccurrences(of: "\"", with: "\\\""))\"}")
    }

    // Add songs to library first, then to playlist
    let ids = songs.map { $0.id }
    try? syncRun { try await api.addToLibrary(songIDs: ids) }
    try? syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }

    for song in songs {
        let et = song.title.replacingOccurrences(of: "\"", with: "\\\"")
        let ea = song.artist.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? syncRun {
            try await backend.runMusic("""
                set results to (every track of playlist "Library" whose name is "\(et)" and artist is "\(ea)")
                if (count of results) = 0 then
                    set results to (every track of playlist "Library" whose name contains "\(et)" and artist contains "\(ea)")
                end if
                if (count of results) > 0 then
                    duplicate item 1 of results to playlist "\(playlistName.replacingOccurrences(of: "\"", with: "\\\""))"
                end if
            """)
        }
    }

    // Shuffle play the radio playlist
    _ = try? syncRun { try await backend.runMusic("set shuffle enabled to true") }
    _ = try? syncRun { try await backend.runMusic("play playlist \"\(playlistName.replacingOccurrences(of: "\"", with: "\\\""))\"") }
}

// MARK: - Now Playing result for context-aware mode

enum NowPlayingResult {
    case back   // user pressed b/Esc — return to browser
    case quit   // user pressed q
}

// MARK: - Context-aware Now Playing (used from playlist browser)

func runNowPlayingWithContext(_ context: PlaybackContext?) -> NowPlayingResult {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    // --- Layout ---
    let artX = 3
    let artY = 11
    let artW = 28
    let metaX = 34
    let metaY = 11
    let metaW = 34
    let queueX = 74
    let queueY = 11
    let progBarW = 18

    var artLines: [String] = []
    var lastTrackName = ""
    var queueCursor = context?.startIndex ?? 0
    var queueScroll = 0

    // Build queue entries from context
    let contextTracks: [String] = context?.tracks ?? []

    func findCurrentTrackIndex(np: NowPlayingState) -> Int? {
        // Match by track name in the context track list
        for (i, track) in contextTracks.enumerated() {
            let parts = track.split(separator: "\u{2014}", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let title = parts.first ?? ""
            if title == np.track || np.track.contains(title) || title.contains(np.track) {
                return i
            }
        }
        return nil
    }

    func render(_ np: NowPlayingState) {
        let frame = ScreenFrame.current()
        let queueW = frame.width - queueX - 3
        let footerText = "\(ANSICode.bold)↑↓\(ANSICode.reset) Queue  \(ANSICode.bold)Enter\(ANSICode.reset) Play  \(ANSICode.bold)←→\(ANSICode.reset) Seek  \(ANSICode.bold)Space\(ANSICode.reset) Pause  \(ANSICode.bold)s\(ANSICode.reset) Spk  \(ANSICode.bold)v\(ANSICode.reset) Vol  \(ANSICode.bold)r\(ANSICode.reset) Radio  \(ANSICode.bold)b\(ANSICode.reset) Back  \(ANSICode.bold)q\(ANSICode.reset) Quit"

        let titleText = context != nil ? "Now Playing \u{2014} \(context!.playlistName)" : "Now Playing"
        var out = renderShell(title: titleText, status: "", footer: footerText)

        // Queue header
        if queueW >= 24 {
            out += ANSICode.moveTo(row: 5, col: queueX)
            out += "\(ANSICode.bold)\(ANSICode.cyan)Queue\(ANSICode.reset)"
            out += ANSICode.moveTo(row: 6, col: queueX)
            out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: 18))\(ANSICode.reset)"
        }

        // --- Cover art ---
        let artSize = min(artW, 28, frame.statusY - artY - 2)
        for i in 0..<artSize {
            if i < artLines.count {
                out += ANSICode.moveTo(row: artY + i, col: artX)
                out += "\(artLines[i])\(ANSICode.reset)"
            }
        }

        // --- Metadata ---
        let playIcon = np.state == "playing" ? "▶" : "⏸"
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"

        out += ANSICode.moveTo(row: metaY + 2, col: metaX)
        out += "\(ANSICode.bold)\(truncText(np.artist, to: metaW))\(ANSICode.reset)"

        out += ANSICode.moveTo(row: metaY + 4, col: metaX)
        out += "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"

        // Progress bar
        let elapsed = formatTime(np.position)
        let total = formatTime(np.duration)
        let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
        let knobIdx = max(0, min(progBarW - 1, Int(ratio * Double(progBarW - 1))))

        var barStr = ""
        for i in 0..<progBarW {
            if i == knobIdx {
                barStr += "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)"
            } else {
                barStr += "\(ANSICode.dim)\u{2500}\(ANSICode.reset)"
            }
        }

        out += ANSICode.moveTo(row: metaY + 8, col: metaX)
        out += "\(elapsed) \(barStr) \(total)"

        // Outputs block
        let labelW = 8
        if !np.speakers.isEmpty {
            let primarySpk = np.speakers.first!
            out += ANSICode.moveTo(row: metaY + 12, col: metaX)
            out += "\(ANSICode.dim)Output\(ANSICode.reset)"
            out += ANSICode.moveTo(row: metaY + 12, col: metaX + labelW)
            out += truncText(primarySpk.name, to: metaW - labelW)

            if np.speakers.count > 1 {
                let mixStr = np.speakers.map { "\($0.name) \($0.volume)" }.joined(separator: ", ")
                out += ANSICode.moveTo(row: metaY + 14, col: metaX)
                out += "\(ANSICode.dim)Mix\(ANSICode.reset)"
                out += ANSICode.moveTo(row: metaY + 14, col: metaX + labelW)
                out += "\(ANSICode.dim)\(truncText(mixStr, to: metaW - labelW))\(ANSICode.reset)"
            }

            out += ANSICode.moveTo(row: metaY + 16, col: metaX)
            out += "\(ANSICode.dim)Volume\(ANSICode.reset)"
            out += ANSICode.moveTo(row: metaY + 16, col: metaX + labelW)
            out += "\(primarySpk.volume)"
        }

        // Shuffle/repeat indicators
        var modeStr = ""
        if np.shuffleEnabled { modeStr += "Shuffle" }
        if np.repeatMode == "one" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat One" }
        else if np.repeatMode == "all" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat" }
        if !modeStr.isEmpty {
            let modeRow = np.speakers.isEmpty ? metaY + 12 : metaY + 18
            out += ANSICode.moveTo(row: modeRow, col: metaX)
            out += "\(ANSICode.dim)\(modeStr)\(ANSICode.reset)"
        }

        // --- Queue (from context) ---
        if queueW >= 24 && !contextTracks.isEmpty {
            let currentIdx = findCurrentTrackIndex(np: np)
            let queueVisible = max(1, min(contextTracks.count, frame.statusY - queueY - 2))

            if queueCursor < queueScroll { queueScroll = queueCursor }
            if queueCursor >= queueScroll + queueVisible { queueScroll = queueCursor - queueVisible + 1 }

            let qEnd = min(contextTracks.count, queueScroll + queueVisible)
            for i in queueScroll..<qEnd {
                let row = queueY + (i - queueScroll)
                out += ANSICode.moveTo(row: row, col: queueX)
                let idx = String(format: "%02d", i + 1)
                let rowText = truncText(contextTracks[i], to: queueW - 6)

                if i == queueCursor {
                    let marker = (i == currentIdx) ? "\(ANSICode.green)\u{25B6}" : "\(ANSICode.cyan)\u{25B6}"
                    out += "\(marker)\(ANSICode.reset) \(ANSICode.bold)\(idx)  \(rowText)\(ANSICode.reset)"
                } else if i == currentIdx {
                    out += "\(ANSICode.green)\u{25B6}\(ANSICode.reset) \(ANSICode.bold)\(idx)  \(rowText)\(ANSICode.reset)"
                } else {
                    out += "\(ANSICode.dim)  \(idx)  \(rowText)\(ANSICode.reset)"
                }
            }
        } else if queueW >= 24 {
            // No context — fall back to pollSurroundingTracks display
            let trackList = pollSurroundingTracks()
            let queueVisible = min(8, frame.statusY - queueY - 2)
            for (i, entry) in trackList.prefix(queueVisible).enumerated() {
                out += ANSICode.moveTo(row: queueY + i, col: queueX)
                let idx = String(format: "%02d", entry.index)
                let rowText = truncText("\(entry.name) \u{2014} \(entry.artist)", to: queueW - 6)
                if entry.isCurrent {
                    out += "\(ANSICode.green)\u{25B6}\(ANSICode.reset) \(ANSICode.bold)\(idx)  \(rowText)\(ANSICode.reset)"
                } else {
                    out += "\(ANSICode.dim)  \(idx)  \(rowText)\(ANSICode.reset)"
                }
            }
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    func renderStopped() {
        let frame = ScreenFrame.current()
        let footerText = "\(ANSICode.bold)b\(ANSICode.reset) Back   \(ANSICode.bold)q\(ANSICode.reset) Quit"
        var out = renderShell(title: "Now Playing", status: "", footer: footerText)
        out += ANSICode.moveTo(row: frame.bodyY + 2, col: 3)
        out += "\(ANSICode.dim)Nothing playing.\(ANSICode.reset)"
        print(out, terminator: "")
        fflush(stdout)
    }

    func refreshArtwork() {
        let frame = ScreenFrame.current()
        let artSize = min(artW, 28, frame.statusY - artY - 2)
        if let artPath = extractArtwork() {
            artLines = artworkToAscii(path: artPath, width: artW, height: artSize)
        } else {
            artLines = []
        }
    }

    // Drain all pending input from stdin
    func flushStdin() {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 0) > 0 && pfd.revents & Int16(POLLIN) != 0 {
            var discard = [UInt8](repeating: 0, count: 256)
            _ = Darwin.read(STDIN_FILENO, &discard, 256)
        }
    }

    // Initial render
    let backend = AppleScriptBackend()
    if let np = pollNowPlaying() {
        lastTrackName = np.track
        refreshArtwork()
        // Sync queue cursor to current track
        if let idx = findCurrentTrackIndex(np: np) {
            queueCursor = idx
        }
        render(np)
    } else {
        renderStopped()
    }

    while true {
        let key = KeyPress.read(timeout: 1.0)

        if let key = key {
            switch key {
            case .up:
                if !contextTracks.isEmpty {
                    queueCursor = max(0, queueCursor - 1)
                } else {
                    _ = try? syncRun { try await backend.runMusic("previous track") }
                }
            case .down:
                if !contextTracks.isEmpty {
                    queueCursor = min(contextTracks.count - 1, queueCursor + 1)
                } else {
                    _ = try? syncRun { try await backend.runMusic("next track") }
                }
            case .enter:
                if !contextTracks.isEmpty && queueCursor < contextTracks.count {
                    // Play the selected track from context
                    let trackLine = contextTracks[queueCursor]
                    let trackParts = trackLine.split(separator: "\u{2014}", maxSplits: 1)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let title = trackParts.first ?? ""
                    let artist = trackParts.count > 1 ? trackParts[1] : ""
                    let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
                    let escapedArtist = artist.replacingOccurrences(of: "\"", with: "\\\"")
                    let plName = context?.playlistName ?? ""
                    _ = try? syncRun {
                        try await backend.runMusic("""
                            set results to (every track of playlist "\(plName)" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                            if (count of results) = 0 then
                                set results to (every track of playlist "\(plName)" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                            end if
                            if (count of results) > 0 then play item 1 of results
                        """)
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
            case .char("r"):
                startRadioStation()
            case .char("s"):
                // Speaker picker as modal subflow
                terminal.exitRawMode()
                let speakerDevices: [[String: Any]]
                do {
                    speakerDevices = try fetchSpeakerDevices()
                } catch {
                    verbose("failed to fetch speakers: \(error.localizedDescription)")
                    terminal.enterRawMode()
                    continue
                }
                do {
                    var volumes = speakerDevices.map { $0["volume"] as! Int }
                    var items = speakerDevices.map {
                        MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
                    }
                    _ = runMultiSelectList(title: "AirPlay Speakers", items: &items, onToggle: { idx, selected in
                        let name = speakerDevices[idx]["name"] as! String
                        do {
                            _ = try syncRun {
                                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(selected)")
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
                                try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(vol)")
                            }
                        } catch {
                            verbose("speaker operation failed: \(error.localizedDescription)")
                        }
                        return "vol: \(vol)"
                    })
                }
                terminal.enterRawMode()
            case .char("v"):
                // Volume mixer as modal subflow
                terminal.exitRawMode()
                let volDevices: [[String: Any]]
                do {
                    volDevices = try fetchSpeakerDevices()
                } catch {
                    verbose("failed to fetch speakers: \(error.localizedDescription)")
                    terminal.enterRawMode()
                    continue
                }
                var speakers = volDevices.compactMap { d -> MixerSpeaker? in
                    guard d["selected"] as? Bool == true else { return nil }
                    return MixerSpeaker(name: d["name"] as! String, volume: d["volume"] as! Int)
                }
                if !speakers.isEmpty {
                    runVolumeMixer(speakers: &speakers) { name, volume in
                        do {
                            _ = try syncRun {
                                try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(volume)")
                            }
                        } catch {
                            verbose("speaker operation failed: \(error.localizedDescription)")
                        }
                    }
                }
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
        if let np = pollNowPlaying() {
            if np.track != lastTrackName {
                lastTrackName = np.track
                refreshArtwork()
                // Sync queue cursor to current track if it changed
                if let idx = findCurrentTrackIndex(np: np) {
                    queueCursor = idx
                }
                flushStdin()
            }
            render(np)
        } else {
            renderStopped()
        }
    }
}

// MARK: - Standalone Now Playing (for `music now`)

func runNowPlayingTUI() {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    // --- Layout ---
    let artX = 3
    let artY = 11
    let artW = 28
    let metaX = 34
    let metaY = 11
    let metaW = 34
    let queueX = 74
    let queueY = 11
    let progBarW = 18

    var trackList: [TrackListEntry] = []
    var artLines: [String] = []
    var lastTrackName = ""

    func render(_ np: NowPlayingState) {
        let frame = ScreenFrame.current()
        let queueW = frame.width - queueX - 3
        let footerText = "\(ANSICode.dim)Controls\(ANSICode.reset)  \(ANSICode.bold)↑ ↓\(ANSICode.reset) Skip   \(ANSICode.bold)← →\(ANSICode.reset) Seek   \(ANSICode.bold)Space\(ANSICode.reset) Pause   \(ANSICode.bold)s\(ANSICode.reset) Speakers   \(ANSICode.bold)v\(ANSICode.reset) Volume   \(ANSICode.bold)r\(ANSICode.reset) Radio   \(ANSICode.bold)q\(ANSICode.reset) Quit"

        var out = renderShell(title: "Now Playing", status: "", footer: footerText)

        // Queue header
        if queueW >= 24 {
            out += ANSICode.moveTo(row: 5, col: queueX)
            out += "\(ANSICode.bold)\(ANSICode.cyan)Queue\(ANSICode.reset)"
            out += ANSICode.moveTo(row: 6, col: queueX)
            out += "\(ANSICode.dim)\(String(repeating: "─", count: 18))\(ANSICode.reset)"
        }

        // --- Cover art ---
        let artSize = min(artW, 28, frame.statusY - artY - 2)
        for i in 0..<artSize {
            if i < artLines.count {
                out += ANSICode.moveTo(row: artY + i, col: artX)
                out += "\(artLines[i])\(ANSICode.reset)"
            }
        }

        // --- Metadata ---
        // Title
        let playIcon = np.state == "playing" ? "▶" : "⏸"
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"

        // Artist
        out += ANSICode.moveTo(row: metaY + 2, col: metaX)
        out += "\(ANSICode.bold)\(truncText(np.artist, to: metaW))\(ANSICode.reset)"

        // Album
        out += ANSICode.moveTo(row: metaY + 4, col: metaX)
        out += "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"

        // Progress bar: "0:00 ───────●────────── 5:56"
        let elapsed = formatTime(np.position)
        let total = formatTime(np.duration)
        let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
        let knobIdx = max(0, min(progBarW - 1, Int(ratio * Double(progBarW - 1))))

        var barStr = ""
        for i in 0..<progBarW {
            if i == knobIdx {
                barStr += "\(ANSICode.bold)●\(ANSICode.reset)"
            } else {
                barStr += "\(ANSICode.dim)─\(ANSICode.reset)"
            }
        }

        out += ANSICode.moveTo(row: metaY + 8, col: metaX)
        out += "\(elapsed) \(barStr) \(total)"

        // Outputs block
        let labelW = 8
        if !np.speakers.isEmpty {
            let primarySpk = np.speakers.first!
            out += ANSICode.moveTo(row: metaY + 12, col: metaX)
            out += "\(ANSICode.dim)Output\(ANSICode.reset)"
            out += ANSICode.moveTo(row: metaY + 12, col: metaX + labelW)
            out += truncText(primarySpk.name, to: metaW - labelW)

            if np.speakers.count > 1 {
                let mixStr = np.speakers.map { "\($0.name) \($0.volume)" }.joined(separator: ", ")
                out += ANSICode.moveTo(row: metaY + 14, col: metaX)
                out += "\(ANSICode.dim)Mix\(ANSICode.reset)"
                out += ANSICode.moveTo(row: metaY + 14, col: metaX + labelW)
                out += "\(ANSICode.dim)\(truncText(mixStr, to: metaW - labelW))\(ANSICode.reset)"
            }

            out += ANSICode.moveTo(row: metaY + 16, col: metaX)
            out += "\(ANSICode.dim)Volume\(ANSICode.reset)"
            out += ANSICode.moveTo(row: metaY + 16, col: metaX + labelW)
            out += "\(primarySpk.volume)"
        }

        // Shuffle/repeat indicators
        var modeStr = ""
        if np.shuffleEnabled { modeStr += "Shuffle" }
        if np.repeatMode == "one" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat One" }
        else if np.repeatMode == "all" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat" }
        if !modeStr.isEmpty {
            let modeRow = np.speakers.isEmpty ? metaY + 12 : metaY + 18
            out += ANSICode.moveTo(row: modeRow, col: metaX)
            out += "\(ANSICode.dim)\(modeStr)\(ANSICode.reset)"
        }

        // --- Queue ---
        if queueW >= 24 {
            let queueVisible = min(8, frame.statusY - queueY - 2)
            for (i, entry) in trackList.prefix(queueVisible).enumerated() {
                out += ANSICode.moveTo(row: queueY + i, col: queueX)
                let idx = String(format: "%02d", entry.index)
                let rowText = truncText("\(entry.name) — \(entry.artist)", to: queueW - 6)
                if entry.isCurrent {
                    out += "\(ANSICode.green)▶\(ANSICode.reset) \(ANSICode.bold)\(idx)  \(rowText)\(ANSICode.reset)"
                } else {
                    out += "\(ANSICode.dim)  \(idx)  \(rowText)\(ANSICode.reset)"
                }
            }
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    func renderStopped() {
        let frame = ScreenFrame.current()
        let footerText = "\(ANSICode.dim)Controls\(ANSICode.reset)  \(ANSICode.bold)q\(ANSICode.reset) Quit"
        var out = renderShell(title: "Now Playing", status: "", footer: footerText)
        out += ANSICode.moveTo(row: frame.bodyY + 2, col: 3)
        out += "\(ANSICode.dim)Nothing playing.\(ANSICode.reset)"
        print(out, terminator: "")
        fflush(stdout)
    }

    func refreshTrackContext() {
        trackList = pollSurroundingTracks()
        let frame = ScreenFrame.current()
        let artSize = min(artW, 28, frame.statusY - artY - 2)
        if let artPath = extractArtwork() {
            artLines = artworkToAscii(path: artPath, width: artW, height: artSize)
        } else {
            artLines = []
        }
    }

    // Drain all pending input from stdin
    func flushStdin() {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 0) > 0 && pfd.revents & Int16(POLLIN) != 0 {
            var discard = [UInt8](repeating: 0, count: 256)
            _ = Darwin.read(STDIN_FILENO, &discard, 256)
        }
    }

    var lastSkipTime: UInt64 = 0
    func millisSinceEpoch() -> UInt64 {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return UInt64(tv.tv_sec) * 1000 + UInt64(tv.tv_usec) / 1000
    }

    // Initial render
    let backend = AppleScriptBackend()
    if let np = pollNowPlaying() {
        lastTrackName = np.track
        refreshTrackContext()
        render(np)
    } else {
        renderStopped()
    }

    while true {
        let key = KeyPress.read(timeout: 1.0)

        if let key = key {
            switch key {
            case .up:
                _ = try? syncRun { try await backend.runMusic("previous track") }
            case .down:
                _ = try? syncRun { try await backend.runMusic("next track") }
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
                startRadioStation()
            case .char("s"):
                // Speaker picker as modal subflow
                terminal.exitRawMode()
                let spkDevices2: [[String: Any]]
                do {
                    spkDevices2 = try fetchSpeakerDevices()
                } catch {
                    verbose("failed to fetch speakers: \(error.localizedDescription)")
                    terminal.enterRawMode()
                    continue
                }
                do {
                    var volumes = spkDevices2.map { $0["volume"] as! Int }
                    var items = spkDevices2.map {
                        MultiSelectItem(label: $0["name"] as! String, sublabel: "vol: \($0["volume"]!)", selected: $0["selected"] as! Bool)
                    }
                    _ = runMultiSelectList(title: "AirPlay Speakers", items: &items, onToggle: { idx, selected in
                        let name = spkDevices2[idx]["name"] as! String
                        do {
                            _ = try syncRun {
                                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(selected)")
                            }
                        } catch {
                            verbose("speaker operation failed: \(error.localizedDescription)")
                        }
                    }, onAdjust: { idx, delta in
                        volumes[idx] = min(100, max(0, volumes[idx] + delta))
                        let name = spkDevices2[idx]["name"] as! String
                        let vol = volumes[idx]
                        do {
                            _ = try syncRun {
                                try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(vol)")
                            }
                        } catch {
                            verbose("speaker operation failed: \(error.localizedDescription)")
                        }
                        return "vol: \(vol)"
                    })
                }
                terminal.enterRawMode()
            case .char("v"):
                terminal.exitRawMode()
                let volDevices2: [[String: Any]]
                do {
                    volDevices2 = try fetchSpeakerDevices()
                } catch {
                    verbose("failed to fetch speakers: \(error.localizedDescription)")
                    terminal.enterRawMode()
                    continue
                }
                var speakers = volDevices2.compactMap { d -> MixerSpeaker? in
                    guard d["selected"] as? Bool == true else { return nil }
                    return MixerSpeaker(name: d["name"] as! String, volume: d["volume"] as! Int)
                }
                if !speakers.isEmpty {
                    runVolumeMixer(speakers: &speakers) { name, volume in
                        do {
                            _ = try syncRun {
                                try await backend.runMusic("set sound volume of AirPlay device \"\(name)\" to \(volume)")
                            }
                        } catch {
                            verbose("speaker operation failed: \(error.localizedDescription)")
                        }
                    }
                }
                terminal.enterRawMode()
            case .char("q"), .escape:
                return
            default:
                break
            }
        }

        // Re-poll and render
        if let np = pollNowPlaying() {
            if np.track != lastTrackName {
                lastTrackName = np.track
                refreshTrackContext()
                // Drain all input that queued during the slow refresh
                flushStdin()
            }
            render(np)
        } else {
            renderStopped()
        }
    }
}

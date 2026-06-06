import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlaylistPreview {
    let name: String
    let trackCount: Int
    let tracks: [String]  // formatted as "Title — Artist"
}

// MARK: - Shared types for 2-screen browser

struct PlaybackContext {
    let playlistName: String
    let tracks: [String]  // "Title — Artist" format
    let startIndex: Int
}

struct BrowserState {
    var plCursor: Int
    var plScroll: Int
    var trCursor: Int
    var trScroll: Int
    var focus: BrowserFocus
}

enum BrowserFocus {
    case playlists, tracks
}

enum BrowserResult {
    case playTrack(playlistIndex: Int, trackIndex: Int, context: PlaybackContext, state: BrowserState)
    case playPlaylist(index: Int, context: PlaybackContext, state: BrowserState)
    case shufflePlaylist(index: Int, context: PlaybackContext, state: BrowserState)
    case nowPlaying(context: PlaybackContext, state: BrowserState)
    case quit
}

// MARK: - Playlist browser (2-pane)

func runPlaylistBrowser(
    playlists: [String],
    onTracks: @escaping (Int) -> PlaylistPreview?,
    savedState: BrowserState? = nil
) -> BrowserResult {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")

    var focus: BrowserFocus = savedState?.focus ?? .playlists
    var plCursor = savedState?.plCursor ?? 0
    var plScroll = savedState?.plScroll ?? 0
    var trCursor = savedState?.trCursor ?? 0
    var trScroll = savedState?.trScroll ?? 0

    // Cache
    var previewCache: [Int: PlaylistPreview] = [:]
    var lastLoadedPl = -1

    func currentState() -> BrowserState {
        BrowserState(plCursor: plCursor, plScroll: plScroll,
                     trCursor: trCursor, trScroll: trScroll, focus: focus)
    }

    func makeContext(trackIndex: Int) -> PlaybackContext {
        let preview = previewCache[plCursor]
        return PlaybackContext(
            playlistName: playlists[plCursor],
            tracks: preview?.tracks ?? [],
            startIndex: trackIndex
        )
    }

    func loadPreview() {
        guard plCursor != lastLoadedPl else { return }
        lastLoadedPl = plCursor

        if previewCache[plCursor] == nil {
            previewCache[plCursor] = onTracks(plCursor)
        }

        // Reset track cursor when playlist changes (unless restoring state)
        if savedState == nil || plCursor != (savedState?.plCursor ?? -1) {
            trCursor = 0
            trScroll = 0
        }
    }

    let leftX = 3
    let leftW = 38
    let rightX = 48

    func render() {
        let frame = ScreenFrame.current()
        let rightW = frame.width - rightX - 2
        let maxPlVisible = max(1, frame.statusY - frame.bodyY - 4)
        let preview = previewCache[plCursor]

        let plFocused = focus == .playlists
        let statusText = "\(playlists.count) playlists"

        let footerText: String
        if plFocused {
            footerText = "\(ANSICode.bold)\u{2191}\u{2193}\(ANSICode.reset) Navigate   \(ANSICode.bold)Tab\(ANSICode.reset) Tracks   \(ANSICode.bold)p\(ANSICode.reset) Play   \(ANSICode.bold)s\(ANSICode.reset) Shuffle   \(ANSICode.bold)b\(ANSICode.reset) Now Playing   \(ANSICode.bold)q\(ANSICode.reset) Quit"
        } else {
            footerText = "\(ANSICode.bold)\u{2191}\u{2193}\(ANSICode.reset) Navigate   \(ANSICode.bold)Enter\(ANSICode.reset) Play   \(ANSICode.bold)Tab\(ANSICode.reset) Playlists   \(ANSICode.bold)b\(ANSICode.reset) Now Playing   \(ANSICode.bold)q\(ANSICode.reset) Quit"
        }

        var out = renderShell(title: "Playlists", status: statusText, footer: footerText)
        // Wipe the body before repainting so shorter rows (after scrolling, or
        // when the right pane flips to the placeholder) don't leave stale tails.
        out += clearBody(frame)

        // --- Left pane: playlist list ---
        let listY = frame.bodyY + 2

        // Playlist scroll
        if plCursor < plScroll { plScroll = plCursor }
        if plCursor >= plScroll + maxPlVisible { plScroll = plCursor - maxPlVisible + 1 }

        let plEnd = min(playlists.count, plScroll + maxPlVisible)
        for i in plScroll..<plEnd {
            let row = listY + (i - plScroll)
            out += ANSICode.moveTo(row: row, col: leftX)
            let name = truncText(playlists[i], to: leftW - 4)
            if i == plCursor {
                let color = plFocused ? ANSICode.cyan : ANSICode.dim
                out += "\(color)\u{25B6}\(ANSICode.reset) \(ANSICode.bold)\(name)\(ANSICode.reset)"
            } else {
                out += "  \(name)"
            }
        }

        // --- Right pane ---
        guard rightW > 10 else {
            print(out, terminator: "")
            fflush(stdout)
            return
        }

        var rightRow = frame.bodyY

        if let preview = preview {
            // Playlist title
            out += ANSICode.moveTo(row: rightRow, col: rightX)
            out += "\(ANSICode.bold)\(truncText(preview.name, to: rightW))\(ANSICode.reset)"
            rightRow += 1

            // Track count + position indicator
            let trackStartY = rightRow + 3  // after count line, blank, and rule
            let maxTrVisible = max(1, frame.statusY - trackStartY - 1)
            let displayCount = preview.tracks.count
            let totalCount = preview.trackCount

            out += ANSICode.moveTo(row: rightRow, col: rightX)
            var countStr = "\(totalCount) tracks"
            if displayCount < totalCount {
                let rangeEnd = min(trScroll + maxTrVisible, displayCount)
                countStr = "\(displayCount) of \(totalCount) tracks \u{00B7} \(trScroll + 1)-\(rangeEnd)"
            } else if displayCount > maxTrVisible {
                let rangeEnd = min(trScroll + maxTrVisible, displayCount)
                countStr = "\(totalCount) tracks \u{00B7} \(trScroll + 1)-\(rangeEnd)"
            }
            out += "\(ANSICode.dim)\(countStr)\(ANSICode.reset)"
            rightRow += 1

            // Rule
            rightRow += 1
            out += ANSICode.moveTo(row: rightRow, col: rightX)
            out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(rightW, 18)))\(ANSICode.reset)"
            rightRow += 1

            // Track list (scrollable)
            if trCursor < trScroll { trScroll = trCursor }
            if trCursor >= trScroll + maxTrVisible { trScroll = trCursor - maxTrVisible + 1 }

            let trEnd = min(preview.tracks.count, trScroll + maxTrVisible)
            let trFocused = focus == .tracks

            for i in trScroll..<trEnd {
                let row = rightRow + (i - trScroll)
                out += ANSICode.moveTo(row: row, col: rightX)
                let idx = String(format: "%02d", i + 1)
                let trackText = truncText(preview.tracks[i], to: rightW - 6)

                if i == trCursor && trFocused {
                    out += "\(ANSICode.cyan)\u{25B6}\(ANSICode.reset) \(ANSICode.bold)\(idx)  \(trackText)\(ANSICode.reset)"
                } else {
                    out += "\(ANSICode.dim)  \(idx)\(ANSICode.reset)  \(trackText)"
                }
            }
        } else {
            // Placeholder — tracks not yet loaded for this playlist
            out += ANSICode.moveTo(row: rightRow, col: rightX)
            out += "\(ANSICode.bold)\(truncText(playlists[plCursor], to: rightW))\(ANSICode.reset)"
            rightRow += 2
            out += ANSICode.moveTo(row: rightRow, col: rightX)
            out += "\(ANSICode.dim)Enter to browse tracks\(ANSICode.reset)"
            rightRow += 1
            out += ANSICode.moveTo(row: rightRow, col: rightX)
            out += "\(ANSICode.dim)p = play \u{00B7} s = shuffle\(ANSICode.reset)"
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    // If restoring state, load the preview for the current playlist immediately
    if savedState != nil {
        loadPreview()
    }

    render()

    while true {
        let key = KeyPress.read(timeout: 60.0)
        guard let key = key else { continue }

        let trackCount = previewCache[plCursor]?.tracks.count ?? 0

        switch key {
        case .up:
            if focus == .playlists {
                plCursor = max(0, plCursor - 1)
                // Show cached preview if available, otherwise right pane shows placeholder
                if previewCache[plCursor] != nil { loadPreview() }
            } else {
                trCursor = max(0, trCursor - 1)
            }

        case .down:
            if focus == .playlists {
                plCursor = min(playlists.count - 1, plCursor + 1)
                if previewCache[plCursor] != nil { loadPreview() }
            } else {
                trCursor = min(trackCount - 1, trCursor + 1)
            }

        case .char("\t"):  // Tab — activate and switch focus
            if focus == .playlists {
                loadPreview()
                focus = .tracks
            } else {
                focus = .playlists
            }

        case .enter:
            if focus == .playlists {
                loadPreview()
                focus = .tracks
                trCursor = 0
                trScroll = 0
            } else {
                return .playTrack(playlistIndex: plCursor, trackIndex: trCursor,
                                  context: makeContext(trackIndex: trCursor),
                                  state: currentState())
            }

        case .left, .escape:
            if focus == .tracks {
                focus = .playlists
            } else {
                return .quit
            }

        case .char("p"):
            return .playPlaylist(index: plCursor,
                                 context: makeContext(trackIndex: 0),
                                 state: currentState())

        case .char("s"):
            return .shufflePlaylist(index: plCursor,
                                    context: makeContext(trackIndex: 0),
                                    state: currentState())

        case .char("b"):
            return .nowPlaying(context: makeContext(trackIndex: 0),
                               state: currentState())

        case .char("q"):
            return .quit

        default:
            break
        }

        render()
    }
}

// MARK: - Simple list picker (backward compat)

func runListPicker(
    title: String,
    items: [String],
    onPreview: ((Int) -> PlaylistPreview?)? = nil,
    onArtwork: ((Int) -> String?)? = nil
) -> Int? {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    var scrollOffset = 0

    func render() {
        let frame = ScreenFrame.current()
        let maxVisible = max(1, frame.statusY - frame.bodyY - 4)
        let statusText = "\(items.count) items"
        let footerText = "\(ANSICode.dim)Controls\(ANSICode.reset)  \(ANSICode.bold)\u{2191}\u{2193}\(ANSICode.reset) Navigate   \(ANSICode.bold)Enter\(ANSICode.reset) Select   \(ANSICode.bold)q\(ANSICode.reset) Quit"

        if cursor < scrollOffset { scrollOffset = cursor }
        if cursor >= scrollOffset + maxVisible { scrollOffset = cursor - maxVisible + 1 }

        var out = renderShell(title: title, status: statusText, footer: footerText)
        out += clearBody(frame)

        let listY = frame.bodyY + 2
        let end = min(items.count, scrollOffset + maxVisible)
        for i in scrollOffset..<end {
            let row = listY + (i - scrollOffset)
            out += ANSICode.moveTo(row: row, col: 3)
            if i == cursor {
                out += "\(ANSICode.cyan)\u{25B6}\(ANSICode.reset) \(ANSICode.bold)\(truncText(items[i], to: frame.width - 8))\(ANSICode.reset)"
            } else {
                out += "  \(truncText(items[i], to: frame.width - 8))"
            }
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(items.count - 1, cursor + 1)
        case .enter, .space: return cursor
        case .char("q"), .escape: return nil
        default: break
        }
        render()
    }
}

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

// MARK: - Playlist browser (3-zone)

func runPlaylistBrowser(
    playlists: [String],
    onMeta: @escaping ([Int]) -> [Int: (Int, Int, Bool, String)],
    onPreview: @escaping (Int) -> [String]?,
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

    var meta: [PlaylistMeta] = playlists.map { PlaylistMeta(name: $0) }
    var loaded: Set<Int> = []
    var fullCache: [Int: PlaylistPreview] = [:]
    var lastLoadedPl = -1

    func currentState() -> BrowserState {
        BrowserState(plCursor: plCursor, plScroll: plScroll,
                     trCursor: trCursor, trScroll: trScroll, focus: focus)
    }

    func loadFull() {
        guard plCursor != lastLoadedPl else { return }
        lastLoadedPl = plCursor
        if fullCache[plCursor] == nil { fullCache[plCursor] = onTracks(plCursor) }
        if savedState == nil || plCursor != (savedState?.plCursor ?? -1) {
            trCursor = 0; trScroll = 0
        }
    }

    func makeContext(trackIndex: Int) -> PlaybackContext {
        let preview = fullCache[plCursor]
        return PlaybackContext(playlistName: playlists[plCursor],
                               tracks: preview?.tracks ?? [], startIndex: trackIndex)
    }

    let metaCol = 6  // reserved right column in the rail for count/badge

    func badgeText(_ m: PlaylistMeta) -> (String, String)? {
        let b = playlistBadge(name: m.name, isSmart: m.isSmart ?? false,
                              specialKind: m.specialKind ?? "none")
        switch b {
        case .radio: return ("RADIO", ANSICode.amber)
        case .smart: return ("SMART", ANSICode.amber)
        case .recent: return ("RECENT", ANSICode.amber)
        case .none: return nil
        }
    }

    func renderRail(_ z: PlaylistZones, into out: inout String, listY: Int, maxVisible: Int) {
        if plCursor < plScroll { plScroll = plCursor }
        if plCursor >= plScroll + maxVisible { plScroll = plCursor - maxVisible + 1 }
        let end = min(meta.count, plScroll + maxVisible)
        let nameWidth = z.railWidth - 2 - metaCol - 1
        for i in plScroll..<end {
            let row = listY + (i - plScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let m = meta[i]
            let display = m.name.hasPrefix("__radio__")
                ? String(m.name.dropFirst("__radio__".count))
                : m.name
            let nm = railName(display, nameWidth: max(1, nameWidth))

            let metaCell: String
            if !m.loaded {
                metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol - 1))\u{00B7}\(ANSICode.reset)"
            } else if let (text, color) = badgeText(m) {
                let padded = String(repeating: " ", count: max(0, metaCol - text.count)) + text
                metaCell = "\(color)\(padded)\(ANSICode.reset)"
            } else {
                let c = "\(m.trackCount ?? 0)"
                let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
            }

            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if i == plCursor {
                let mark = (focus == .playlists) ? ANSICode.cyan : ANSICode.dim
                out += "\(mark)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
            } else {
                out += "  \(padName) \(metaCell)"
            }
        }
    }

    func renderHero(_ z: PlaylistZones, into out: inout String) {
        let y = ScreenFrame.current().bodyY
        let m = meta[plCursor]
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(m.name, to: z.heroWidth))\(ANSICode.reset)"
    }

    func render() {
        let frame = ScreenFrame.current()
        let z = playlistZones(width: frame.width)
        let listY = frame.bodyY + 2
        let maxVisible = max(1, frame.statusY - listY - 1)

        let pending = loaded.count < meta.count
        let statusText = pending
            ? "Loading metadata\u{2026} \(loaded.count)/\(meta.count)"
            : "\(meta.count) playlists"
        let footerText = "\(ANSICode.bold)\u{2191}\u{2193}\(ANSICode.reset) Browse   \(ANSICode.bold)Enter\(ANSICode.reset) Open   \(ANSICode.bold)p\(ANSICode.reset) Play   \(ANSICode.bold)s\(ANSICode.reset) Shuffle   \(ANSICode.bold)/\(ANSICode.reset) Filter   \(ANSICode.bold)b\(ANSICode.reset) Now   \(ANSICode.bold)q\(ANSICode.reset) Quit"

        var out = renderShell(title: "Playlists", status: statusText, footer: footerText)
        out += clearBody(frame)
        renderRail(z, into: &out, listY: listY, maxVisible: maxVisible)
        renderHero(z, into: &out)
        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        let key = KeyPress.read(timeout: 60.0)
        guard let key = key else { continue }

        let trackCount = fullCache[plCursor]?.tracks.count ?? 0

        switch key {
        case .up:
            if focus == .playlists {
                plCursor = max(0, plCursor - 1)
            } else {
                trCursor = max(0, trCursor - 1)
            }

        case .down:
            if focus == .playlists {
                plCursor = min(playlists.count - 1, plCursor + 1)
            } else {
                trCursor = min(trackCount - 1, trCursor + 1)
            }

        case .char("\t"):  // Tab — activate and switch focus
            if focus == .playlists {
                loadFull()
                focus = .tracks
            } else {
                focus = .playlists
            }

        case .enter:
            if focus == .playlists {
                loadFull()
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

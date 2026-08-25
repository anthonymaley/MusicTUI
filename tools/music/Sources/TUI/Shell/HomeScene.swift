// tools/music/Sources/TUI/Shell/HomeScene.swift
import Foundation

// The Home tab: Apple's own For You rails, browsable, with a read-only drill-in
// on albums and playlists.
//
// Enter is deliberately asymmetric, and the asymmetry is a platform fact rather
// than a design preference (all measured 2026-08-25, see docs/platform-notes.md):
//
//   station          -> plays, via the music:// scheme rewrite. Writes nothing.
//   album, playlist  -> drills in to a track list. Does NOT play.
//
// Catalog albums and playlists cannot be played without first adding them to the
// library: music:// does nothing on a non-station URL, and the REST API has no
// play verb. Home is for discovery and listening, not for shopping, so it does
// not quietly write to the library to make a keypress work. The add/play/sweep
// transaction that would let albums play is designed but deliberately unbuilt.
final class HomeScene: Scene {
    let id: SceneID = .home
    let tabTitle = "Home"

    var footerHint: String {
        switch level {
        case .rails: return "\u{2191}\u{2193} Move  Enter Play/Open  r Refresh"
        case .tracks: return "\u{2191}\u{2193} Move  \u{2190} Back"
        }
    }

    private enum Level: Equatable {
        case rails
        case tracks(HomeItem)
    }

    private let feed: HomeFeed?
    private let status: StatusStore
    private let opener: Opener

    private var level: Level = .rails
    private var rails: [HomeRail] = []
    private var cursor = 0            // index into selectableHomeIndices(rows)
    private var scroll = 0
    private var trackRows: [HomeItem] = []
    private var trackCursor = 0
    private var loaded = false
    private var failed = false

    // Background fetch, inbox-under-lock, drained in tick() — the same
    // discipline RadioScene uses, because HomeFeed blocks up to 20s per call and
    // must never run on the UI loop.
    private let inboxLock = NSLock()
    private var fetchStarted = false
    private var railsInbox: [HomeRail]?      // guarded by inboxLock
    private var railsFailed = false          // guarded by inboxLock
    private var tracksInbox: [HomeItem]?     // guarded by inboxLock
    private var tracksInFlight = false       // tick()/handle() thread only

    init(feed: HomeFeed?, status: StatusStore, opener: Opener = SystemOpener()) {
        self.feed = feed
        self.status = status
        self.opener = opener
    }

    // MARK: - Rows

    private var rows: [HomeDisplayRow] {
        homeDisplayRows(rails: orderedHomeRails(rails), perRail: 8)
    }

    private var selectable: [Int] { selectableHomeIndices(rows) }

    private var selection: HomeItem? {
        guard cursor < selectable.count else { return nil }
        if case .item(let item) = rows[selectable[cursor]] { return item }
        return nil
    }

    // MARK: - Input

    func handle(_ key: KeyPress) -> SceneAction {
        let k = vimAlias(key, listScene: true)

        if case .tracks = level {
            switch k {
            case .up: trackCursor = max(0, trackCursor - 1); return .redraw
            case .down: trackCursor = min(max(0, trackRows.count - 1), trackCursor + 1); return .redraw
            case .left, .escape:
                level = .rails
                trackRows = []
                trackCursor = 0
                return .redraw
            default: return .none
            }
        }

        switch k {
        case .up: cursor = max(0, cursor - 1); return .redraw
        case .down: cursor = min(max(0, selectable.count - 1), cursor + 1); return .redraw
        case .home: cursor = 0; return .redraw
        case .end: cursor = max(0, selectable.count - 1); return .redraw
        case .char("r"):
            refresh()
            return .redraw
        case .enter, .right:
            return activate()
        default:
            return .none
        }
    }

    private func activate() -> SceneAction {
        guard let item = selection else { return .none }
        switch item.kind {
        case .station:
            guard let url = item.url else {
                status.post("That station has no play URL.", error: true)
                return .redraw
            }
            do {
                try playStation(Station(id: item.id, name: item.name, url: url,
                                        isLive: nil, artworkURL: item.artworkURL),
                                via: opener)
                status.post("Playing \(item.name)")
            } catch {
                status.post("Could not play \(item.name).", error: true)
            }
            return .redraw
        case .album, .playlist:
            drillIn(item)
            return .redraw
        case .song:
            // Songs only appear inside a drill-in, which has its own handler.
            return .none
        }
    }

    // MARK: - Fetching

    private func refresh() {
        loaded = false
        failed = false
        fetchStarted = false
        cursor = 0
        status.post("Refreshing Home\u{2026}")
    }

    private func drillIn(_ item: HomeItem) {
        guard let feed else { return }
        guard !tracksInFlight else { return }
        level = .tracks(item)
        trackRows = []
        trackCursor = 0
        tracksInFlight = true
        DispatchQueue.global().async { [weak self] in
            let fetched = (try? feed.tracks(for: item)) ?? []
            guard let self else { return }
            self.inboxLock.lock(); self.tracksInbox = fetched; self.inboxLock.unlock()
        }
    }

    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        if !fetchStarted, let feed {
            fetchStarted = true
            DispatchQueue.global().async { [weak self] in
                var fetched: [HomeRail] = []
                var failed = false
                do { fetched = try feed.rails() } catch { failed = true }
                guard let self else { return }
                self.inboxLock.lock()
                self.railsInbox = fetched
                self.railsFailed = failed
                self.inboxLock.unlock()
            }
        }

        inboxLock.lock()
        let incomingRails = railsInbox
        let incomingFailed = railsFailed
        railsInbox = nil
        let incomingTracks = tracksInbox
        tracksInbox = nil
        inboxLock.unlock()

        if let incomingRails {
            rails = incomingRails
            loaded = true
            failed = incomingFailed || incomingRails.isEmpty
            cursor = min(cursor, max(0, selectable.count - 1))
            changed = true
        }
        if let incomingTracks {
            trackRows = incomingTracks
            tracksInFlight = false
            changed = true
        }
        return changed
    }

    // MARK: - Render

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        if case .tracks(let item) = level {
            return out + renderTracks(frame: frame, parent: item)
        }
        return out + renderRails(frame: frame)
    }

    private func renderRails(frame: ShellFrame) -> String {
        var out = ""
        var y = frame.bodyY
        let bottom = frame.bodyY + frame.bodyHeight - 1

        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)Home\(ANSICode.reset)"
        y += 2

        if feed == nil {
            out += ANSICode.moveTo(row: y, col: 3)
            out += "\(ANSICode.dim)Sign in to see your Home feed (music auth setup).\(ANSICode.reset)"
            return out
        }
        if !loaded {
            out += ANSICode.moveTo(row: y, col: 3)
            out += "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return out
        }
        if failed || rails.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            out += "\(ANSICode.dim)No recommendations right now. r to retry.\(ANSICode.reset)"
            return out
        }

        let all = rows
        let visibleHeight = max(1, bottom - y + 1)
        // Keep the cursor on screen by scrolling the flattened row list.
        let cursorRow = cursor < selectable.count ? selectable[cursor] : 0
        if cursorRow < scroll { scroll = cursorRow }
        if cursorRow >= scroll + visibleHeight { scroll = cursorRow - visibleHeight + 1 }
        scroll = max(0, min(scroll, max(0, all.count - visibleHeight)))

        for idx in scroll..<all.count {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: 3)
            switch all[idx] {
            case .header(let title):
                out += "\(ANSICode.bold)\(truncText(title, to: max(10, frame.width - 6)))\(ANSICode.reset)"
            case .item(let item):
                out += renderItemLine(item, selected: idx == cursorRow, width: frame.width)
            }
            y += 1
        }
        return out
    }

    private func renderItemLine(_ item: HomeItem, selected: Bool, width: Int) -> String {
        // Only stations play from Home, so only stations carry the play marker.
        // A marker on a row that cannot play is a promise the tab cannot keep.
        let marker = item.kind == .station ? "\(ANSICode.lime)\u{25B6}\(ANSICode.reset)" : " "
        let subtitle = item.subtitle.map { " \(ANSICode.dim)\u{2014} \($0)\(ANSICode.reset)" } ?? ""
        let nameW = max(12, min(40, width - 24))
        let name = truncText(item.name, to: nameW)
        let padded = name + String(repeating: " ", count: max(0, nameW - name.count))
        let nameStr = selected ? "\(ANSICode.inverse)\(padded)\(ANSICode.reset)" : padded
        return "  \(marker) \(nameStr)\(subtitle)"
    }

    private func renderTracks(frame: ShellFrame, parent: HomeItem) -> String {
        var out = ""
        var y = frame.bodyY
        let bottom = frame.bodyY + frame.bodyHeight - 1

        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)\(truncText(parent.name, to: max(10, frame.width - 6)))\(ANSICode.reset)"
        y += 1
        if let subtitle = parent.subtitle {
            out += ANSICode.moveTo(row: y, col: 3)
            out += "\(ANSICode.dim)\(truncText(subtitle, to: max(10, frame.width - 6)))\(ANSICode.reset)"
        }
        y += 2

        if trackRows.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            out += "\(ANSICode.dim)\(tracksInFlight ? "Loading\u{2026}" : "No tracks.")\(ANSICode.reset)"
            return out
        }

        for (i, track) in trackRows.enumerated() {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: 3)
            let num = String(format: "%2d.", i + 1)
            let nameW = max(12, min(44, frame.width - 26))
            let name = truncText(track.name, to: nameW)
            let padded = name + String(repeating: " ", count: max(0, nameW - name.count))
            let nameStr = i == trackCursor ? "\(ANSICode.inverse)\(padded)\(ANSICode.reset)" : padded
            let artist = track.subtitle.map { " \(ANSICode.dim)\u{2014} \($0)\(ANSICode.reset)" } ?? ""
            out += "\(ANSICode.dim)\(num)\(ANSICode.reset) \(nameStr)\(artist)"
            y += 1
        }
        return out
    }
}

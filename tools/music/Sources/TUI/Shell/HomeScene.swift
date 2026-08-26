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

    private let feed: HomeFeed?
    private let status: StatusStore
    private let opener: Opener

    private var stack: [HomeFrameState] = [HomeFrameState(level: .home, cursor: HomeCursor())]
    private var rails: [HomeRail] = []
    private var trackRows: [HomeItem] = []
    private var loaded = false
    private var failed = false
    private var lastBodyHeight = 1

    /// The active level. Writable so cursorIndex and scroll do not each have to
    /// index the stack's top element themselves — one place owns that arithmetic.
    /// The stack is never empty: it is seeded in init and popLevel refuses to
    /// drop the last frame, so this subscript cannot trap.
    private var current: HomeFrameState {
        get { stack[stack.count - 1] }
        set { stack[stack.count - 1] = newValue }
    }

    private var cursorIndex: Int {
        get { current.cursor.index }
        set { current.cursor.index = newValue }
    }

    private var scroll: Int {
        get { current.cursor.scroll }
        set { current.cursor.scroll = newValue }
    }

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

    /// Home shows five curated rails at four items each. The rail level shows
    /// one rail in full, in Apple's own item order.
    private var rows: [HomeDisplayRow] {
        switch current.level {
        case .home:
            return homeDisplayRows(rails: selectHomeRails(orderedHomeRails(rails),
                                                          currentYear: homeCurrentYear()),
                                   perRail: 4)
        case .rail(let rail):
            return homeDisplayRows(rails: [rail], perRail: rail.items.count)
        case .tracks:
            return trackRows.map { HomeDisplayRow.item($0) }
        }
    }

    private var selection: HomeSelection? { homeSelection(rows: rows, cursor: cursorIndex) }

    private var canGoBack: Bool { stack.count > 1 }

    var footerHint: String { homeFooterHint(selection, canGoBack: canGoBack) }

    // MARK: - Input

    func handle(_ key: KeyPress) -> SceneAction {
        let k = vimAlias(key, listScene: true)
        let count = selectableHomeIndices(rows).count

        switch k {
        case .up:
            cursorIndex = max(0, cursorIndex - 1); clampScroll(); return .redraw
        case .down:
            cursorIndex = min(max(0, count - 1), cursorIndex + 1); clampScroll(); return .redraw
        case .home:
            cursorIndex = 0; clampScroll(); return .redraw
        case .end:
            cursorIndex = max(0, count - 1); clampScroll(); return .redraw
        case .left, .escape:
            guard canGoBack else { return .none }
            // Leaving the track list drops its rows. drillIn resets them before
            // every fetch, so this is memory hygiene rather than correctness —
            // but gating it on landing at .home meant it only fired on the
            // second pop and left the array alive in between.
            if case .tracks = current.level { trackRows = [] }
            stack = popLevel(stack)
            return .redraw
        case .char("r"):
            guard case .home = current.level else { return .none }
            refresh(); return .redraw
        case .enter, .right:
            return activate()
        default:
            return .none
        }
    }

    /// Every level shares one viewport. The track level previously had none,
    /// so a selection past the terminal height became invisible.
    ///
    /// NOTE the index conversion: `cursorIndex` is an ordinal among SELECTABLE
    /// rows, while the viewport scrolls the FULL row array (headers included).
    /// Passing the ordinal straight through would drift the window by one row
    /// per header above the cursor.
    private func clampScroll() {
        let all = rows
        let selectable = selectableHomeIndices(all)
        let cursorRow = cursorIndex < selectable.count ? selectable[cursorIndex] : 0
        scroll = scrollToShow(row: cursorRow, scroll: scroll,
                              visibleHeight: max(1, lastBodyHeight), count: all.count)
    }

    private func activate() -> SceneAction {
        guard let selection else { return .none }
        switch selection {
        case .viewAll(let rail):
            stack = pushLevel(stack, .rail(rail))
            return .redraw
        case .item(let item):
            switch item.detail {
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
                return .none
            }
        }
    }

    // MARK: - Fetching

    private func refresh() {
        loaded = false
        failed = false
        fetchStarted = false
        stack = [HomeFrameState(level: .home, cursor: HomeCursor())]
        status.post("Refreshing Home\u{2026}")
    }

    private func drillIn(_ item: HomeItem) {
        guard let feed else { return }
        guard !tracksInFlight else { return }
        stack = pushLevel(stack, .tracks(item))
        trackRows = []
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
            cursorIndex = min(cursorIndex, max(0, selectableHomeIndices(rows).count - 1))
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

    // NOTE: renderRails/renderTracks below are the pre-stack renderers, adapted
    // just enough to compile against the new state (stack/cursorIndex/scroll
    // instead of level/cursor/trackCursor). They are not the two-pane layout —
    // that is a separate renderer that replaces this method wholesale.
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        // Re-derive the viewport every frame, not only on keypress. The scroll
        // clamp used to live inline in renderRails and therefore ran on every
        // paint, so a resize was reflected on the next frame. Moving it into
        // clampScroll() for uniformity across levels lost that: lastBodyHeight
        // updates here, but nothing recomputed scroll from it until the next
        // arrow key, leaving a resized terminal showing a stale window.
        lastBodyHeight = max(1, frame.bodyHeight - 2)
        clampScroll()
        if case .tracks(let item) = current.level {
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
        let selectable = selectableHomeIndices(all)
        let cursorRow = cursorIndex < selectable.count ? selectable[cursorIndex] : 0

        for idx in scroll..<all.count {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: 3)
            switch all[idx] {
            case .header(let title):
                out += "\(ANSICode.bold)\(truncText(title, to: max(10, frame.width - 6)))\(ANSICode.reset)"
            case .item(let item):
                out += renderItemLine(item, selected: idx == cursorRow, width: frame.width)
            case .viewAll(let rail):
                // This row has a real activation (Enter opens the rail as its
                // own level), but it renders inertly here — no selection
                // marker — because this renderer is a placeholder: the
                // two-pane renderer replaces this method wholesale.
                out += "\(ANSICode.dim)    View all \(rail.items.count)\(ANSICode.reset)"
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
            let nameStr = i == cursorIndex ? "\(ANSICode.inverse)\(padded)\(ANSICode.reset)" : padded
            let artist = track.subtitle.map { " \(ANSICode.dim)\u{2014} \($0)\(ANSICode.reset)" } ?? ""
            out += "\(ANSICode.dim)\(num)\(ANSICode.reset) \(nameStr)\(artist)"
            y += 1
        }
        return out
    }
}

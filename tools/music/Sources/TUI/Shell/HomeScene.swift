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

    /// Bumped every time `rails` or `trackRows` is replaced in tick(), so
    /// `rows` below can invalidate its cache without comparing the arrays
    /// themselves on every access.
    private var feedVersion = 0
    private var rowsCacheKey: RowsCacheKey?
    private var rowsCache: [HomeDisplayRow] = []

    private struct RowsCacheKey: Equatable {
        let level: String    // identity only: comparing a whole HomeRail costs
                             // more than the flatMap the cache is guarding
        let version: Int
    }

    /// Cheap stand-in for `current.level` in the cache key. `.rail`/`.tracks`
    /// carry a whole HomeRail/HomeItem — deep-comparing those on every `rows`
    /// access would cost at least what the flatMap below costs, defeating the
    /// point of caching it.
    private var rowsCacheIdentity: String {
        switch current.level {
        case .home:            return "home"
        case .rail(let rail):  return "rail:\(rail.id)"
        case .tracks(let it):  return "tracks:\(it.id)"
        }
    }

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

    // Real hero cover for the detail panel: store owns fetch/cache/render;
    // onReady sets artDirty under inboxLock (same discipline as the streaming
    // inboxes above) and tick() drains it into `changed` so the swap paints
    // on the next frame. Mirrors RadioScene/LibraryScene/PlaylistsScene exactly.
    private let art = ArtworkStore()
    private let kittyEnabled: Bool
    private var artDirty = false          // guarded by inboxLock
    // Placement-dedup (render-thread-only): the last kitty placement this
    // scene emitted. Reset in artPlacementsInvalidated() on every tab switch
    // (mirrors RadioScene/LibraryScene/PlaylistsScene), and explicitly on
    // every render() path that stops drawing the panel at all (narrow
    // resize, or `selection == nil` while a refresh is in flight) —
    // render()'s `if twoPane, let selection { ... }` has no implicit else,
    // so that cleanup has to be explicit or a cover from the last frame
    // keeps floating over content that no longer describes it. A resize that
    // keeps two-pane mode needs no explicit reset: renderArtHero's dedup
    // already compares the FULL placement (id/row/col/cols/rows), so a
    // geometry change alone is enough to force a delete+redraw.
    private var lastPlaced: ArtPlacement? = nil

    init(feed: HomeFeed?, status: StatusStore, opener: Opener = SystemOpener(),
         kittyEnabled: Bool = false) {
        self.feed = feed
        self.status = status
        self.opener = opener
        self.kittyEnabled = kittyEnabled
    }

    /// The shell calls this right after it clears every kitty placement on a
    /// scene switch (kittyDeletePlacementsEscape, d=a — placements only, data
    /// stays transmitted). Dropping the memo forces a fresh placement on the
    /// next render rather than assuming a placement the shell just deleted is
    /// still on screen.
    func artPlacementsInvalidated() { lastPlaced = nil }

    // MARK: - Rows

    /// Home shows five curated rails at four items each. The rail level shows
    /// one rail in full, in Apple's own item order.
    ///
    /// Memoised: this ran rail selection plus flattening on every access,
    /// measured at 3 evaluations per idle repaint and up to 5 on a keypress
    /// frame. Keyed on (level, feedVersion) rather than level alone — keying
    /// on level alone would fail to invalidate when a background refresh
    /// replaces `rails` while the user is still sitting at `.home`. `.rail`
    /// and `.tracks` are already frozen at push time (the HomeRail/HomeItem
    /// is captured by value), so only `.home` actually depends on mutable
    /// state, but the same key is used for all three levels for uniformity.
    private var rows: [HomeDisplayRow] {
        let key = RowsCacheKey(level: rowsCacheIdentity, version: feedVersion)
        if rowsCacheKey == key {
            return rowsCache
        }
        let computed: [HomeDisplayRow]
        switch current.level {
        case .home:
            computed = homeDisplayRows(rails: resolvedHomeRails(rails), perRail: 4)
        case .rail(let rail):
            computed = homeDisplayRows(rails: [rail], perRail: rail.items.count)
        case .tracks:
            computed = trackRows.map { HomeDisplayRow.item($0) }
        }
        rowsCacheKey = key
        rowsCache = computed
        return computed
    }

    /// nil while a fetch is in flight or has failed. The panel and the footer
    /// both derive from this, and neither is gated on `loaded` the way
    /// renderLeft is — so without this guard, pressing `r` leaves them
    /// describing an item from the previous feed while the left pane says
    /// "Loading…".
    private var selection: HomeSelection? {
        guard loaded, !failed else { return nil }
        return homeSelection(rows: rows, cursor: cursorIndex)
    }

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
        // drillIn always refetches (no dedupe on re-entering the same
        // album), so re-opening it after Back would find a level key equal
        // to the one still cached — same item id, unchanged version — and
        // clampScroll() (which runs in render() before renderLeft's
        // trackRows.isEmpty guard) would compute against the previous
        // visit's rows.
        feedVersion += 1
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
        let artLanded = artDirty
        artDirty = false
        inboxLock.unlock()

        if let incomingRails {
            rails = incomingRails
            feedVersion += 1
            loaded = true
            failed = incomingFailed || incomingRails.isEmpty
            cursorIndex = min(cursorIndex, max(0, selectableHomeIndices(rows).count - 1))
            changed = true
        }
        if let incomingTracks {
            trackRows = incomingTracks
            feedVersion += 1
            tracksInFlight = false
            changed = true
        }
        if artLanded { changed = true }
        return changed
    }

    // MARK: - Render

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        lastBodyHeight = max(1, frame.bodyHeight - 2)
        // Re-derive the viewport every frame, not only on keypress: this ran
        // inline in the pre-stack renderer, so a resize was reflected on the
        // next paint. That was lost once when the clamp moved into
        // clampScroll() for uniformity across levels — lastBodyHeight updated
        // here, but nothing recomputed scroll from it until the next arrow
        // key, leaving a resized terminal showing a stale window. Calling it
        // here keeps that fix in place.
        clampScroll()
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let twoPane = homeIsTwoPane(width: frame.width)
        let leftW = twoPane ? homeLeftWidth(frameWidth: frame.width) : (frame.width - 6)
        out += renderLeft(frame: frame, width: leftW)
        if twoPane, let selection {
            out += renderPanel(frame: frame, x: leftW + 4, selection: selection)
        } else if let last = lastPlaced {
            // The panel isn't drawing this frame — a narrow resize dropped to
            // one pane, or `selection` is nil while a refresh is in flight
            // (reliably reachable: `r` on an art-bearing row is a routine
            // repro, not an edge case). Delete the stale placement rather
            // than leaving last frame's cover floating over content that no
            // longer describes it — the same cleanup NowPlayingScene's menu/
            // empty-state branches do.
            out += kittyDeleteEscape(id: last.id)
            lastPlaced = nil
        }
        return out
    }

    private var levelTitle: String {
        switch current.level {
        case .home:            return "Home"
        case .rail(let rail):  return rail.title
        case .tracks(let it):  return it.name
        }
    }

    private func renderLeft(frame: ShellFrame, width: Int) -> String {
        var out = ""
        var y = frame.bodyY
        let bottom = frame.bodyY + frame.bodyHeight - 1

        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)\(truncText(levelTitle, to: width))\(ANSICode.reset)"
        y += 2

        if feed == nil {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)Sign in to see your Home feed (music auth setup).\(ANSICode.reset)"
        }
        if !loaded {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
        }
        if failed || rails.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)No recommendations right now. r to retry.\(ANSICode.reset)"
        }
        if case .tracks = current.level, trackRows.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)\(tracksInFlight ? "Loading\u{2026}" : "No tracks.")\(ANSICode.reset)"
        }

        let all = rows
        let selectable = selectableHomeIndices(all)
        let cursorRow = cursorIndex < selectable.count ? selectable[cursorIndex] : 0

        for idx in scroll..<all.count {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: 3)
            switch all[idx] {
            case .header(let title):
                out += "\(ANSICode.bold)\(ANSICode.cyan)\(truncText(title, to: width))\(ANSICode.reset)"
            case .item(let item):
                out += renderRow(item, selected: idx == cursorRow, width: width)
            case .viewAll(let rail):
                let label = "View all \(rail.items.count)"
                let text = idx == cursorRow
                    ? "\(ANSICode.inverse)\(label)\(ANSICode.reset)"
                    : "\(ANSICode.dim)\(label)\(ANSICode.reset)"
                out += "    " + text
            }
            y += 1
        }
        return out
    }

    /// The 40-column title cap is gone: the name column now grows with the pane,
    /// which is what reclaimed 48% of a 150-column screen.
    private func renderRow(_ item: HomeItem, selected: Bool, width: Int) -> String {
        // Only stations play from Home, so only stations carry the play marker.
        // A marker on a row that cannot play is a promise the tab cannot keep.
        let marker = item.kind == .station ? "\(ANSICode.lime)\u{25B6}\(ANSICode.reset)" : " "
        let (nameW, subW) = homeRowColumns(width: width, hasSubtitle: item.subtitle != nil)
        let name = truncText(item.name, to: nameW)
        let padded = name + String(repeating: " ", count: max(0, nameW - name.count))
        let nameStr = selected
            ? "\(ANSICode.inverse)\(padded)\(ANSICode.reset)"
            : "\(ANSICode.brightWhite)\(padded)\(ANSICode.reset)"
        let sub = item.subtitle.map {
            " \(ANSICode.dim)\(truncText($0, to: subW))\(ANSICode.reset)"
        } ?? ""
        return "  \(marker) \(nameStr)\(sub)"
    }

    private func renderPanel(frame: ShellFrame, x: Int, selection: HomeSelection) -> String {
        var out = ""
        var y = frame.bodyY + 2
        let bottom = frame.bodyY + frame.bodyHeight - 1
        let w = max(10, frame.width - x - 1)

        // Reuses the shared hero ladder: kitty pixels -> chafa half-blocks ->
        // mono blocks -> gradient identicon. ArtworkStore fetches on its own
        // serial queue and signals via onReady; nothing here blocks.
        //
        // Two rules carried over from the 3.6.0 transmit-once bug: never gate
        // the transmit escape to once per id (ArtworkStore.block already
        // doesn't — revisiting a cover then renders nothing at all), and
        // ALWAYS call renderArtHero below, even when this selection has no
        // artwork URL or the geometry is degenerate. Skipping the call
        // entirely on a nil URL would leave the PREVIOUS selection's
        // placement floating over this item's text — the same class of bug
        // as render()'s twoPane/selection branch above. The `.none` case
        // inside renderArtHero is what deletes that stale placement.
        let artKey: String
        let artTemplate: String?
        switch selection {
        case .item(let item):    artKey = item.id; artTemplate = item.artworkURL
        case .viewAll(let rail): artKey = rail.id; artTemplate = rail.items.first?.artworkURL
        }
        let gw = min(24, max(0, w))
        let gh = min(12, max(0, bottom - y - 8))
        var artBlock: ArtBlock? = nil
        if let artTemplate {
            artBlock = art.block(key: artKey,
                                 url: ArtworkStore.resolveURL(artTemplate, width: 300, height: 300),
                                 // Degenerate geometry skips the kitty path — same guard
                                 // LibraryScene/RadioScene use: PNG conversion doesn't
                                 // depend on gw/gh, so without this it would still return
                                 // .kitty and place a zero-row image.
                                 width: gw, height: gh,
                                 kitty: kittyEnabled && gw > 0 && gh > 0) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        let (afterArtY, placed) = renderArtHero(artBlock: artBlock,
                                                gradientSeedText: artKey,
                                                gw: gw, gh: gh, x: x, y: y,
                                                cellW: frame.cellW, cellH: frame.cellH,
                                                lastPlaced: lastPlaced, into: &out)
        y = afterArtY + 1
        lastPlaced = placed

        func line(_ s: String) {
            guard y <= bottom else { return }
            out += ANSICode.moveTo(row: y, col: x) + s
            y += 1
        }

        switch selection {
        case .viewAll(let rail):
            line("\(ANSICode.amber)RAIL\(ANSICode.reset)")
            line("\(ANSICode.brightWhite)\(truncText(rail.title, to: w))\(ANSICode.reset)")
            line("")
            line("\(ANSICode.dim)\(rail.items.count) items\(ANSICode.reset)")
        case .item(let item):
            line("\(ANSICode.amber)\(homePanelBadge(item.detail))\(ANSICode.reset)")
            line("\(ANSICode.brightWhite)\(truncText(item.name, to: w))\(ANSICode.reset)")
            if let subtitle = item.subtitle {
                line("\(ANSICode.dim)\(truncText(subtitle, to: w))\(ANSICode.reset)")
            }
            if let meta = homePanelMeta(item.detail) {
                line("")
                for chunk in homeWrapText(meta, to: w, maxLines: 4) {
                    line("\(ANSICode.dim)\(chunk)\(ANSICode.reset)")
                }
            }
        }
        let action = homePanelAction(selection)
        if !action.isEmpty {
            line("")
            line("\(ANSICode.dim)\(action)\(ANSICode.reset)")
        }
        return out
    }
}

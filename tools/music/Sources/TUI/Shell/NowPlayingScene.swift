// tools/music/Sources/TUI/Shell/NowPlayingScene.swift
import Foundation

enum ContinuationAction: Equatable { case shuffle, playlist, quiet }

/// Where to snap the Up Next cursor after a track change: the row that is both
/// marked current AND matches the new track. nil when the rows predate the
/// change (the fast-publish window still shows the previous context) — the
/// caller must then NOT consume the change, so the snap retries when the
/// refreshed rows land. Pure.
func snapCursorIndex(rows: [TrackListEntry], currentKey: String) -> Int? {
    rows.firstIndex { $0.isCurrent && trackKey(title: $0.name, artist: $0.artist) == currentKey }
}

/// `q` is deliberately NOT a continuation key: globally it means quit, and a
/// user pressing `q` at a queue-ended TUI must leave the app, not pause it.
func continuationAction(for key: KeyPress) -> ContinuationAction? {
    switch key {
    case .char("s"), .char("S"): return .shuffle
    case .char("p"), .char("P"): return .playlist
    case .char("x"), .char("X"): return .quiet
    default: return nil
    }
}

/// Width of the Now tab's two-pane left column (art + metadata + control
/// grid), in columns. Floors at 44 — the pre-existing width at the twoPane
/// threshold (frameWidth 92), so a narrow-but-two-pane terminal doesn't lose
/// any Up Next room it had before — and scales up to 54, the hero tabs' width
/// (Library/Playlists/Radio, since the 3.6.0 hero-size fix), by frameWidth
/// 180. Wide terminals (e.g. the user's 214) land at the cap, so Now's art
/// matches every other tab's exactly. Pure; one-pane mode (frameWidth < 92)
/// doesn't call this — it keeps `frame.width - 6`.
func nowPlayingLeftWidth(frameWidth: Int) -> Int {
    let minWidth = 92.0, maxWidth = 180.0
    let floorW = 44.0, capW = 54.0
    let t = min(1.0, max(0.0, (Double(frameWidth) - minWidth) / (maxWidth - minWidth)))
    return Int((floorW + (capW - floorW) * t).rounded())
}

final class NowPlayingScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Now"
    var footerHint: String {
        gridFocused
            ? "\u{2191}\u{2193} Row  Enter Set  \u{2192} Up Next  [ ] Seek  \u{2014} controls"
            : "\u{2191}\u{2193} Browse  \u{2190} Controls  Enter Jump  [ ] Seek  l \u{2665}"
    }

    private let backend: AppleScriptBackend
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner
    private var cursor = 0
    private var scroll = 0
    private var rows: [TrackListEntry] = []
    private var lastCurrentKey = ""
    private var manualMenu = false   // user-opened menu (vs poller-detected queueEnded)
    private var menuShownLastFrame = false
    private var pendingSeedTitle = ""
    private var pendingSeedArtist = ""
    private var pendingPlaylist = ""         // context/ended playlist, for the Shuffle action
    private var pendingFromStopped = false   // menu opened from an auto queue-end (playback stopped)
    private var wantsPlaylists = false
    private var contextNameNow = ""          // cleaned context name from the latest snapshot

    // Shuffle/repeat state, fetched on a background inbox (the poller is left
    // untouched). Mirrors SpeakersScene's EQ inbox.
    private var modes: PlaybackModes? = nil
    private let modesLock = NSLock()
    private var inboxModes: PlaybackModes? = nil
    private var modesFetchInFlight = false
    private var modesFetchStartedAt = Date.distantPast
    private var lastModesMutation = Date.distantPast
    private var lastModesKick = Date.distantPast

    // Control grid: ← focuses it (it's the left pane), → returns to the Up Next
    // list. ↑↓ move the row cursor, Enter cycles that row's value. Unfocused,
    // the grid still shows live active state.
    private var gridFocused = false
    private var gridRow = 0

    // Genius Shuffle latch: set when we trigger it, cleared once a real playlist
    // or app queue takes over (Music exposes no genius flag — see geniusShouldClear).
    private var geniusActive = false
    private var geniusTriggeredAt = Date.distantPast

    private let kittyEnabled: Bool
    // Placement-dedup (render-thread-only, per design doc Feature 2 §3): the
    // last kitty placement this scene emitted, so an unchanged frame emits
    // nothing (the placement persists on screen across text repaints) and a
    // changed one deletes the old placement before drawing the new one.
    private var lastPlaced: (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)? = nil
    // Scene-local, render-thread-only: id -> transmit escape, resolved on
    // first sight of an id (file read + PNG conversion) and reused on every
    // later sighting of the same id. A resolved failure caches `nil` so a
    // broken file isn't re-read every frame; `transmitCache[id]` absent means
    // "never attempted" (see kittyTransmitFor's `if let` unwrap of the outer
    // Optional for how this collapses cleanly to a single `String?`).
    private var transmitCache: [UInt32: String?] = [:]

    init(backend: AppleScriptBackend, appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner,
         kittyEnabled: Bool = false) {
        self.backend = backend
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        self.kittyEnabled = kittyEnabled
    }

    func artPlacementsInvalidated() { lastPlaced = nil }

    /// Resolve (and cache) the transmit escape for `id`, reading `path` and
    /// converting to PNG only the first time this id is ever seen. nil means
    /// "no kitty art for this id" (missing/unreadable file, or PNG conversion
    /// failure) — cached so a broken file isn't re-read every frame.
    private func kittyTransmitFor(id: UInt32, path: String) -> String? {
        if let cached = transmitCache[id] { return cached }
        guard let data = FileManager.default.contents(atPath: path),
              let png = imageDataToPNG(data) else {
            transmitCache.updateValue(nil, forKey: id)   // cache the failure (not a dictionary removal)
            return nil
        }
        let escape = kittyTransmitEscape(id: id, png: png)
        transmitCache[id] = escape
        return escape
    }

    // Once the user acts on an auto-detected queue-end, remember which one (by its
    // ended track) so the menu doesn't re-appear for the same event — e.g. after
    // picking Quiet, which leaves playback stopped with queueEnded still set.
    private var dismissedSeed = ""
    private func menuActive(_ snapshot: NowPlayingSnapshot) -> Bool {
        (snapshot.queueEnded && snapshot.endedTrack != dismissedSeed) || manualMenu
    }
    var capturesAllInput: Bool { menuShownLastFrame }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        menuShownLastFrame = menuActive(snapshot)
        pendingFromStopped = snapshot.queueEnded
        if snapshot.queueEnded {
            pendingSeedTitle = snapshot.endedTrack
            pendingSeedArtist = snapshot.endedArtist
            pendingPlaylist = snapshot.endedPlaylist
        } else if case .active(let np) = snapshot.outcome {
            pendingSeedTitle = np.track
            pendingSeedArtist = np.artist
            pendingPlaylist = cleanContextName(snapshot.contextName)
        }
        rows = snapshot.surrounding
        contextNameNow = cleanContextName(snapshot.contextName)
        // Snap the cursor to the current track when the track changes; leave it
        // alone otherwise so the user can browse Up Next. Consume the change
        // only when the rows actually contain the new track as current — the
        // poller's fast-publish snapshot still carries the PREVIOUS window, and
        // snapping against it parked the cursor on a stale row for good (the
        // wrong-track-on-Enter bug).
        if case .active(let np) = snapshot.outcome {
            let key = trackKey(title: np.track, artist: np.artist)
            if key != lastCurrentKey, let i = snapCursorIndex(rows: rows, currentKey: key) {
                lastCurrentKey = key
                cursor = i
            }
        }
        if cursor >= rows.count { cursor = max(0, rows.count - 1) }

        // Shuffle/repeat: drain the background inbox, then kick a fresh fetch
        // every ~2s. A fetch that started before the user's last toggle is
        // stale (would revert the optimistic update), so it's dropped.
        var changed = false
        modesLock.lock()
        let freshModes = inboxModes; inboxModes = nil
        modesLock.unlock()
        if let freshModes, modesFetchStartedAt > lastModesMutation, freshModes != modes {
            modes = freshModes
            changed = true
        }
        let now = Date()
        if !modesFetchInFlight, now.timeIntervalSince(lastModesKick) > 2 {
            modesFetchInFlight = true
            modesFetchStartedAt = now
            lastModesKick = now
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let m = try? fetchPlaybackModes(self.backend)
                self.modesLock.lock()
                self.inboxModes = m
                self.modesFetchInFlight = false
                self.modesLock.unlock()
            }
        }
        // Drop the Genius latch once a real playlist / app queue takes over.
        if geniusActive,
           geniusShouldClear(elapsedSinceTrigger: now.timeIntervalSince(geniusTriggeredAt),
                             hasAppQueue: appQueue.read() != nil,
                             contextName: contextNameNow) {
            geniusActive = false
            changed = true
        }
        // The snapshot-derived state above repaints via the store's generation
        // counter; `changed` covers a modes update that the generation misses.
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        guard frame.bodyHeight > 4, frame.width > 30 else { return out }

        // Neither branch below draws the kitty art path (that lives in the
        // main render further down) — but sharp edge #4 ("images outlive
        // text") applies here too: dropping into the menu or the empty state
        // changes the displayed cover, so a placement from a prior frame must
        // be explicitly deleted or it keeps floating over this content.
        if menuActive(snapshot) {
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            return renderContinuationMenu(frame: frame, snapshot: snapshot, into: out)
        }

        guard case .active(let np) = snapshot.outcome else {
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            // The empty state is the on-ramp, not a dead end.
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3)
            out += "\(ANSICode.dim)Nothing playing \u{2014} press \(ANSICode.reset)2\(ANSICode.dim) to browse playlists, \(ANSICode.reset)z\(ANSICode.dim) to shuffle.\(ANSICode.reset)"
            return out
        }

        // Two-pane when wide enough: left = now-playing (large art + metadata),
        // right = Up Next list. Narrow falls back to stacked (art+meta, list below).
        let twoPane = frame.width >= 92
        let leftX = 3
        let leftW = twoPane ? nowPlayingLeftWidth(frameWidth: frame.width) : (frame.width - 6)
        let listBottom = frame.bodyY + frame.bodyHeight - 1

        // --- Left pane: large album art ---
        // Art is skipped entirely below ~50 columns: the chafa/mono fallback
        // is extracted upstream (PlaybackPoller) at a fixed 44 columns (see
        // the `gw` comment below), and drawing those lines on a narrower
        // frame would wrap into the next row and corrupt the whole screen.
        let showArt = frame.width >= 52
        let artLines = showArt ? snapshot.artLines : []
        // Reserved vertical space for art: metadata (~7 rows) + the control
        // grid (~6) need the rest of bodyHeight. Deliberately NOT derived from
        // artLines.count — that was the void bug: a no-art track has
        // artLines == [], which collapsed this to 0 and skipped both the art
        // AND its layout reservation, instead of falling to the same gradient
        // placeholder every other tab shows. The reservation now holds
        // regardless of content so the layout below never jumps depending on
        // whether the current track happens to have artwork.
        let artRows = showArt ? max(0, frame.bodyHeight - 13) : 0
        // Kitty's bound: matches the (now width-adaptive) left column in
        // two-pane mode, same as the hero panes (gw == the pane's own width).
        // One-pane keeps the original fixed rect. The chafa/mono lines path
        // can't follow this — PlaybackPoller extracts it upstream at a
        // hardcoded 44x22 (currentTrackArtLines(width: 44, height: 22)), on a
        // background poller thread that doesn't know the render width. That's
        // fine: kitty places a PNG and stretches to whatever rect it's given;
        // the lines path below prints pre-rendered text at however wide it
        // was extracted, unaffected by gw.
        let gw = twoPane ? leftW : 44
        var kittyID: UInt32? = nil
        var kittyTransmit: String? = nil
        if kittyEnabled, showArt, artRows > 0, let path = snapshot.artPath {
            let id = kittyImageID(forKey: path + np.track)
            if let escape = kittyTransmitFor(id: id, path: path) {
                kittyID = id
                kittyTransmit = escape
            }
        }
        if let id = kittyID {
            // Square-equivalent rect (in pixels, for the measured cell size):
            // kitty stretches, chafa fits. See kittySquareRect.
            let (pc, pr) = kittySquareRect(maxCols: gw, maxRows: artRows, cellW: frame.cellW, cellH: frame.cellH)
            let current = (id: id, row: frame.bodyY, col: leftX, cols: pc, rows: pr)
            if let last = lastPlaced, last == current {
                // Unchanged: the placement from a prior frame is still on
                // screen — emit nothing (spaces would flicker under the image).
            } else {
                if let last = lastPlaced { out += kittyDeleteEscape(id: last.id) }
                let blank = String(repeating: " ", count: gw)
                for i in 0..<artRows {
                    out += ANSICode.moveTo(row: frame.bodyY + i, col: leftX) + blank
                }
                out += kittyTransmit ?? ""
                out += ANSICode.moveTo(row: frame.bodyY, col: leftX) + kittyPlaceEscape(id: id, cols: pc, rows: pr)
                lastPlaced = current
            }
        } else if !artLines.isEmpty {
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            // Never draw more than reserved — chafa may return fewer rows
            // than requested (letterboxed), never more. Anything left over
            // stays blank: render() clears the whole body up front.
            let linesRows = min(artLines.count, artRows)
            for i in 0..<linesRows {
                out += ANSICode.moveTo(row: frame.bodyY + i, col: leftX) + "\(artLines[i])\(ANSICode.reset)"
            }
        } else if showArt {
            // No usable art for this track (e.g. zero `artworks`, like "Push
            // It Along") — the same gradient placeholder the heroes show,
            // squared to the exact rect real art would occupy so the layout
            // doesn't jump between a track with art and one without.
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            let (pc, pr) = kittySquareRect(maxCols: gw, maxRows: artRows, cellW: frame.cellW, cellH: frame.cellH)
            let gradient = gradientBlock(name: np.track + np.artist, width: pc, height: pr)
            for (i, line) in gradient.enumerated() {
                out += ANSICode.moveTo(row: frame.bodyY + i, col: leftX) + line
            }
        } else {
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
        }

        // --- Left pane: metadata below the art ---
        var my = frame.bodyY + artRows + 1
        let metaW = leftW
        let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
        out += ANSICode.moveTo(row: my, col: leftX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + truncText(np.artist, to: metaW)
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"
        my += 2
        let elapsed = formatTime(np.position)
        let total = formatTime(np.duration)
        let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
        let pbW = min(28, max(8, metaW - 14))
        let knob = max(0, min(pbW - 1, Int(ratio * Double(pbW - 1))))
        var bar = ""
        for i in 0..<pbW { bar += i == knob ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)" }
        out += ANSICode.moveTo(row: my, col: leftX) + "\(elapsed) \(bar) \(total)"
        my += 2
        if geniusActive {
            out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.cyan)\u{2726} \(ANSICode.reset)\(ANSICode.bold)\(ANSICode.brightWhite)Genius Shuffle Active\(ANSICode.reset)"
        } else if !snapshot.contextName.isEmpty {
            out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.cyan)\u{266A} \(ANSICode.reset)\(ANSICode.brightWhite)\(truncText(cleanContextName(snapshot.contextName), to: metaW - 3))\(ANSICode.reset)"
        }

        // Playback-control grid (shuffle/order/repeat/genius). Always shows live
        // active state; `c` focuses it for arrow-navigation + Enter.
        out += renderControlGrid(startY: my + 2, x: leftX, bottom: frame.bodyY + frame.bodyHeight - 1)

        // --- Up Next: right pane (wide) or below the metadata (narrow) ---
        let listX = twoPane ? (leftX + leftW + 2) : leftX
        let listY = twoPane ? frame.bodyY : (my + 2)
        let listW = twoPane ? max(20, frame.width - listX - 1) : (frame.width - 6)
        if geniusActive {
            // Genius's real queue isn't scriptable (the snapshot shows the
            // alphabetical library), so don't present a misleading Up Next.
            if listY + 1 <= listBottom {
                out += ANSICode.moveTo(row: listY, col: listX) + "\(ANSICode.bold)\(ANSICode.cyan)Up Next\(ANSICode.reset)"
                out += ANSICode.moveTo(row: listY + 2, col: listX) + "\(ANSICode.dim)Following Music's Genius queue.\(ANSICode.reset)"
                out += ANSICode.moveTo(row: listY + 3, col: listX) + "\(ANSICode.dim)The track order isn't readable here.\(ANSICode.reset)"
            }
        } else if listY + 1 <= listBottom {
            // Adapt context entries to the timeline-row shape the shared renderer expects.
            let timeline = rows.map { e in
                TimelineRow(
                    index: e.index,
                    label: "\(e.name) \u{2014} \(e.artist)",
                    isCurrent: e.isCurrent, wasPlayed: false
                )
            }
            out += renderTimelineRows(
                rows: timeline,
                header: "Up Next",
                x: listX,
                y: listY,
                width: listW,
                visibleHeight: listBottom - listY + 1,
                cursorIndex: cursor,
                scrollOffset: &scroll
            )
        }
        return out
    }

    /// The playback-control grid: a label column then option cells per row.
    /// Active value is bright; the focused row (when the grid has focus) is
    /// marked with ▸ and Enter cycles its value.
    private func renderControlGrid(startY: Int, x: Int, bottom: Int) -> String {
        var out = ""
        var y = startY
        let labelW = 8
        for row in 0..<ControlGrid.rowCount {
            guard y <= bottom else { break }
            let rowFocused = gridFocused && row == gridRow
            out += ANSICode.moveTo(row: y, col: x)
            let marker = rowFocused ? "\(ANSICode.cyan)\u{25B8}\(ANSICode.reset)" : " "
            let label = ControlGrid.labels[row]
            let padLabel = label + String(repeating: " ", count: max(0, labelW - label.count))
            let labelStyled = rowFocused ? "\(ANSICode.brightWhite)\(padLabel)\(ANSICode.reset)"
                                         : "\(ANSICode.dim)\(padLabel)\(ANSICode.reset)"
            out += "\(marker) \(labelStyled) "
            let active = modes.flatMap { ControlGrid.activeColumn(row: row, modes: $0) }
            var line = ""
            for col in 0..<ControlGrid.cellCount(row: row) {
                let cell = ControlGrid.cells[row][col]
                if col == active {
                    line += "\(ANSICode.brightWhite)[\(cell)]\(ANSICode.reset) "
                } else {
                    line += "\(ANSICode.dim) \(cell) \(ANSICode.reset) "
                }
            }
            // `line` carries ANSI codes, so it isn't truncText'd (that counts
            // escape bytes); the rows are short and fit the metadata column.
            out += line
            y += 1
        }
        return out
    }

    private func renderContinuationMenu(frame: ShellFrame, snapshot: NowPlayingSnapshot, into base: String) -> String {
        var out = base
        let (seedTitle, art): (String, [String]) = snapshot.queueEnded
            ? (snapshot.endedTrack, snapshot.endedArtLines)
            : ({ if case .active(let np) = snapshot.outcome { return np.track } else { return "" } }(), snapshot.artLines)
        let title = snapshot.queueEnded
            ? "Queue ended — what next?"
            : "What next?"
        out += ANSICode.moveTo(row: frame.bodyY, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)\(title)\(ANSICode.reset)"

        // Art thumbnail (shared by Radio/Similar cards), then a labelled option list.
        let artTop = frame.bodyY + 2
        let artRows = min(art.count, max(0, frame.bodyHeight - 8))
        for i in 0..<artRows {
            out += ANSICode.moveTo(row: artTop + i, col: 3) + "\(art[i])\(ANSICode.reset)"
        }
        let lx = 3
        var ly = artTop + artRows + 1
        let shuffleTarget = pendingPlaylist.isEmpty ? seedTitle : pendingPlaylist
        let opts: [(String, String)] = [
            ("[S]", "Shuffle  \(ANSICode.dim)\(truncText(shuffleTarget, to: 28))\(ANSICode.reset)"),
            ("[P]", "Playlist  \(ANSICode.dim)browse\(ANSICode.reset)"),
            ("[X]", "Quiet  \(ANSICode.dim)stop here\(ANSICode.reset)"),
        ]
        for (key, label) in opts {
            out += ANSICode.moveTo(row: ly, col: lx) + "\(ANSICode.lime)\(key)\(ANSICode.reset)  \(label)"
            ly += 1
        }
        return out
    }

    private func act(on action: ContinuationAction) {
        switch action {
        case .shuffle:
            // Replay the just-played playlist shuffled, via the app-owned queue.
            // Falls back to shuffling whatever's playing if there's no playlist name.
            // On the action queue: shufflePlayPlaylist bulk-fetches the whole
            // playlist, which must not stall the input loop.
            let playlist = pendingPlaylist
            let backend = self.backend
            let appQueue = self.appQueue
            actions.run("Shuffle") {
                let ok = playlist.isEmpty
                    ? shufflePlayCurrent(backend: backend, appQueue: appQueue)
                    : shufflePlayPlaylist(backend: backend, appQueue: appQueue, playlist: playlist)
                try require(ok, "Shuffle failed.")
            }
        case .playlist:
            wantsPlaylists = true
        case .quiet:
            appQueue.clear()
            actions.run("Pause") { _ = try syncRun { try await self.backend.runMusic("pause") } }
        }
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Vim aliases first: j/k/h/ctrl-d/ctrl-u everywhere, but NOT l/g/G — this
        // tab binds those to Favorite and Genius Shuffle below.
        let key = vimAlias(key, listScene: false)
        // Continuation menu intercepts its keys when active.
        if menuShownLastFrame {
            if let action = continuationAction(for: key) {
                act(on: action)
                manualMenu = false
                dismissedSeed = pendingSeedTitle   // don't re-show this queue-end's menu
                if wantsPlaylists { wantsPlaylists = false; return .push(.playlists) }
                return .redraw
            }
            // The menu captures all input, so quit must be honored here — `q` at
            // a queue-ended TUI means "leave the app", never a menu action.
            if case .char("q") = key { return .quit }
            // Esc dismisses the menu — manual or auto (the auto menu is keyed by
            // its ended track, so it won't re-appear for the same queue-end).
            if case .escape = key {
                manualMenu = false
                dismissedSeed = pendingSeedTitle
                return .redraw
            }
        }
        // Manual open: 'n' (next-options) when no menu is up.
        if case .char("n") = key, !menuShownLastFrame {
            manualMenu = true; return .redraw
        }

        // Focus model: ← focuses the control grid (left pane), → the Up Next
        // list (right). ↑↓/Enter then act on whichever has focus. Seek lives on
        // [ ] so the arrows are free for navigation.
        switch key {
        case .left:  gridFocused = true; return .redraw
        case .right: gridFocused = false; return .redraw
        case .char("["):
            actions.run("Seek") { _ = try syncRun { try await self.backend.runMusic("set player position to (player position - 30)") } }
            return .redraw
        case .char("]"):
            actions.run("Seek") { _ = try syncRun { try await self.backend.runMusic("set player position to (player position + 30)") } }
            return .redraw
        default:
            break
        }

        // Grid-focused: ↑↓ move the row cursor, Enter cycles its value.
        if gridFocused {
            switch key {
            case .up:    gridRow = max(0, gridRow - 1); return .redraw
            case .down:  gridRow = min(ControlGrid.rowCount - 1, gridRow + 1); return .redraw
            case .home:  gridRow = 0; return .redraw
            case .end:   gridRow = ControlGrid.rowCount - 1; return .redraw
            case .enter: applyControlRow(); return .redraw
            default: break   // s/m/r/g/l fall through below
            }
        }

        switch key {
        case .up:
            guard !gridFocused, !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 1); return .redraw
        case .down:
            guard !gridFocused, !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 1); return .redraw
        case .pageUp:
            guard !gridFocused, !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 10); return .redraw
        case .pageDown:
            guard !gridFocused, !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 10); return .redraw
        case .home:
            guard !rows.isEmpty else { return .none }
            cursor = 0; return .redraw
        case .end:
            guard !rows.isEmpty else { return .none }
            cursor = rows.count - 1; return .redraw
        case .enter:
            guard cursor < rows.count else { return .none }
            // Jump within the app-owned queue by the row's play-order position.
            let backend = self.backend
            if let (pl, pos) = appQueue.jump(to: rows[cursor].index) {
                actions.run("Play") { try require(playQueueTrack(backend: backend, playlist: pl, position: pos), "Couldn't play that track.") }
                return .redraw
            }
            // No app queue: a whole-playlist play (native queue) lands here. Playing
            // the row from the Library would collapse Music's context to the
            // alphabetical library (and `play track N of current playlist` is the
            // macOS 26.x-regressed verb) — so ADOPT the app-owned queue: fetch the
            // context playlist and take over from this row, same as the Playlists
            // tab does. Album/library contexts (the context name isn't a playlist,
            // or the row doesn't line up) fall back to the library lookup.
            let row = rows[cursor]
            let context = contextNameNow
            let store = self.appQueue
            actions.run("Play") {
                if !context.isEmpty, !isLibraryContextName(context) {
                    let tracks = fetchPlaylistTracks(backend: backend, playlist: context)
                    if row.index >= 1, row.index <= tracks.count,
                       trackKey(title: tracks[row.index - 1].name, artist: tracks[row.index - 1].artist)
                           == trackKey(title: row.name, artist: row.artist) {
                        store.set(AppQueue(playlistName: context, tracks: tracks, currentIndex: row.index))
                        try require(playQueueTrack(backend: backend, playlist: context, position: row.index), "Couldn't play that track.")
                        return
                    }
                }
                try require(playLibraryTrack(backend: backend, title: row.name, artist: row.artist), "'\(row.name)' not found in the library.")
            }
            return .redraw
        case .char("l"):
            // Toggle favorite on the current track (macOS 26: `favorited`, the
            // old `loved` property errors). State isn't polled — the toast IS
            // the feedback.
            let status = self.status
            actions.run("Favorite") {
                let result = try syncRun {
                    try await self.backend.runMusic("""
                        if player state is stopped then return "NOTHING"
                        set favorited of current track to (not favorited of current track)
                        if favorited of current track then
                            return "ON" & (ASCII character 31) & name of current track
                        end if
                        return "OFF" & (ASCII character 31) & name of current track
                    """)
                }
                let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: asFieldSep).map(String.init)
                try require(parts.first != "NOTHING", "Nothing playing.")
                let title = parts.count > 1 ? parts[1] : "track"
                status.post(parts.first == "ON" ? "\u{2665} Favorited '\(title)'" : "Unfavorited '\(title)'")
            }
            return .redraw
        case .char("s"), .char("S"):
            toggleShuffle(); return .redraw
        case .char("m"), .char("M"):
            cycleShuffleMode(); return .redraw
        case .char("r"), .char("R"):
            cycleRepeat(); return .redraw
        case .char("g"), .char("G"):
            triggerGenius(); return .redraw
        default:
            return .none
        }
    }

    // MARK: Playback-mode mutators (shared by the s/m/r/g keys and the grid).
    // Each updates `modes` optimistically and writes via the action queue.

    /// Shuffle on/off (Music's `shuffle enabled`). Distinct from the global `z`,
    /// which shuffle-plays the current context.
    private func toggleShuffle() {
        let on = !(modes?.shuffleEnabled ?? false)
        modes?.shuffleEnabled = on
        lastModesMutation = Date()
        actions.run("Shuffle") {
            try require((try? setShuffleEnabled(self.backend, on)) != nil, "Couldn't set shuffle.")
        }
    }
    private func cycleShuffleMode() {
        let next = (modes?.shuffleMode ?? .songs).next
        modes?.shuffleMode = next
        lastModesMutation = Date()
        actions.run("Shuffle mode") {
            try require((try? setShuffleMode(self.backend, next)) != nil, "Couldn't set shuffle mode.")
        }
    }
    private func cycleRepeat() {
        let next = (modes?.songRepeat ?? .off).next
        modes?.songRepeat = next
        lastModesMutation = Date()
        actions.run("Repeat") {
            try require((try? setSongRepeat(self.backend, next)) != nil, "Couldn't set repeat.")
        }
    }
    /// Genius Shuffle rebuilds the queue from the current song (UI-scripted).
    private func triggerGenius() {
        geniusActive = true; geniusTriggeredAt = Date()
        actions.run("Genius") {
            try require((try? triggerGeniusShuffle(self.backend)) != nil, "Genius Shuffle failed.")
        }
    }

    /// Enter on the focused control row cycles its value (same as the shortcut keys).
    private func applyControlRow() {
        switch ControlRow(rawValue: gridRow) {
        case .shuffle:    toggleShuffle()
        case .order:      cycleShuffleMode()
        case .repeatMode: cycleRepeat()
        case .genius, .none: triggerGenius()
        }
    }
}

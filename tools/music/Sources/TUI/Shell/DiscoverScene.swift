// tools/music/Sources/TUI/Shell/DiscoverScene.swift
import Foundation

// The Discover tab: Apple's own For You rails, browsable, with a drill-in on
// albums and playlists that can also play.
//
// Enter is deliberately asymmetric, and the asymmetry is a platform fact rather
// than a design preference (all measured 2026-08-25, see docs/platform-notes.md):
//
//   station                    -> plays, via the music:// scheme rewrite. Writes nothing.
//   album, playlist (rail row) -> drills in to a track list. Does NOT play.
//   track (inside a drill-in)  -> plays from that row to the container's end.
//                                 `p` is still a no-op here (it acts on rail rows).
//
// Catalog albums and playlists cannot be played without first adding them to the
// library: music:// does nothing on a non-station URL, and the REST API has no
// play verb. So `p` on an album/playlist row creates a temp playlist and plays
// it, bounded, from the top, through `DiscoverLifecycleCoordinator`
// (DiscoverLifecycle.swift), which also owns both sweeps — the songs stay in
// the library permanently (no per-track authorship is exposed to sweep them
// back out); only the temp playlist CONTAINER is ever swept, and only by the
// name this app gave it. `→` still never plays — see
// discoverRightArrowActivates.
//
// "Play from here" (2026-08-30) is the SAME transaction over a shorter id
// list: discoverPlaySlice cuts the container from the selected row to its end,
// so the bounded `play playlist` form starts where the user pointed. It also
// turns shuffle off first, because `play playlist` honours Music's
// `shuffle enabled` (measured, six trials) and would otherwise start on some
// other track entirely. `p` deliberately does NOT do that: the guard is scoped
// to Enter, so "play all" never reaches out and clears a setting the user
// turned on somewhere else.
final class DiscoverScene: Scene {
    let id: SceneID = .discover
    let tabTitle = "Discover"

    private let feed: DiscoverFeedReading?
    private let status: StatusStore
    private let opener: Opener
    // nil `api` means no dev+user token pair, same gate makeDiscoverFeed() and
    // makeArtworkAPI() already use — in practice `feed` is also nil whenever
    // `api` is, since both require the same two tokens, but each play path
    // guards `api` independently rather than assuming that correlation holds.
    // The play itself goes through the shell's one lifecycle coordinator, so
    // it is admitted only after the launch sweep and protected at exit.
    private let actions: ActionRunner
    private let api: RESTAPIBackend?
    private let lifecycle: DiscoverLifecycleCoordinator

    private var stack: [DiscoverFrameState] = [DiscoverFrameState(level: .root, cursor: DiscoverCursor())]
    // Readable, not private, so the feed binding is observable from a test.
    private(set) var rails: [DiscoverRail] = []
    private(set) var trackRows: [DiscoverItem] = []
    /// Why the rails did not load, in words for the person. nil while loading,
    /// after a success, and for a web-service failure, which keeps its old line.
    private(set) var loadFailure: String?
    private var loaded = false
    private var failed = false
    private var lastBodyHeight = 1

    /// Bumped every time `rails` or `trackRows` is replaced in tick(), so
    /// `rows` below can invalidate its cache without comparing the arrays
    /// themselves on every access.
    private var feedVersion = 0
    private var rowsCacheKey: RowsCacheKey?
    private var rowsCache: [DiscoverDisplayRow] = []

    private struct RowsCacheKey: Equatable {
        let level: String    // identity only: comparing a whole DiscoverRail costs
                             // more than the flatMap the cache is guarding
        let version: Int
    }

    /// Cheap stand-in for `current.level` in the cache key. `.rail`/`.tracks`
    /// carry a whole DiscoverRail/DiscoverItem — deep-comparing those on every `rows`
    /// access would cost at least what the flatMap below costs, defeating the
    /// point of caching it.
    private var rowsCacheIdentity: String {
        switch current.level {
        case .root:            return "root"
        case .rail(let rail):  return "rail:\(rail.id)"
        case .tracks(let it):  return "tracks:\(it.id)"
        }
    }

    /// The active level. Writable so cursorIndex and scroll do not each have to
    /// index the stack's top element themselves — one place owns that arithmetic.
    /// The stack is never empty: it is seeded in init and popLevel refuses to
    /// drop the last frame, so this subscript cannot trap.
    private var current: DiscoverFrameState {
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
    // discipline RadioScene uses, because DiscoverFeed blocks up to 20s per call and
    // must never run on the UI loop.
    private let inboxLock = NSLock()
    private var fetchStarted = false
    private var railsInbox: [DiscoverRail]?      // guarded by inboxLock
    private var railsFailed = false          // guarded by inboxLock
    private var railsFailure: String?        // guarded by inboxLock
    private var tracksFailure: String?       // guarded by inboxLock
    private var tracksInbox: [DiscoverItem]?     // guarded by inboxLock
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

    /// TEMPORARY, and nil in every shipping path. When present, a track-level
    /// Enter sends ONE catalog id to the MusicTUISource app instead of building
    /// a `__discover__` container in Music.app. Injected rather than read from
    /// the environment here, so `MUSICTUI_SOURCE_APP` keeps exactly one read
    /// site in `Shell.swift` (Anthony's bound, 2026-09-09).
    /// Whether Bridge is the selected output, asked at the moment of use.
    ///
    /// Was `sourcePlayback != nil`, i.e. the `MUSICTUI_SOURCE_APP` env var: the
    /// dogfood switch. Routing now follows the Output tab, so a person selects
    /// Bridge and Discover plays there, with no environment variable involved.
    private let bridgeSelected: () -> Bool
    /// Where a play goes, decided inside the coordinator's own lock rather than
    /// by reading `bridgeSelected()` and hoping the mode holds still.
    private let routing: RoutingCoordinator

    init(feed: DiscoverFeedReading?, status: StatusStore, actions: ActionRunner, api: RESTAPIBackend?,
         lifecycle: DiscoverLifecycleCoordinator, routing: RoutingCoordinator,
         opener: Opener = SystemOpener(),
         bridgeSelected: @escaping () -> Bool = { false },
         kittyEnabled: Bool = false) {
        self.routing = routing
        self.bridgeSelected = bridgeSelected
        self.feed = feed
        self.status = status
        self.actions = actions
        self.api = api
        self.lifecycle = lifecycle
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

    /// Discover shows five curated rails at four items each. The rail level shows
    /// one rail in full, in Apple's own item order.
    ///
    /// Memoised: this ran rail selection plus flattening on every access,
    /// measured at 3 evaluations per idle repaint and up to 5 on a keypress
    /// frame. Keyed on (level, feedVersion) rather than level alone — keying
    /// on level alone would fail to invalidate when a background refresh
    /// replaces `rails` while the user is still sitting at `.root`. `.rail`
    /// and `.tracks` are already frozen at push time (the DiscoverRail/DiscoverItem
    /// is captured by value), so only `.root` actually depends on mutable
    /// state, but the same key is used for all three levels for uniformity.
    private var rows: [DiscoverDisplayRow] {
        let key = RowsCacheKey(level: rowsCacheIdentity, version: feedVersion)
        if rowsCacheKey == key {
            return rowsCache
        }
        let computed: [DiscoverDisplayRow]
        switch current.level {
        case .root:
            computed = discoverDisplayRows(rails: resolvedDiscoverRails(rails), perRail: 4)
        case .rail(let rail):
            computed = discoverDisplayRows(rails: [rail], perRail: rail.items.count)
        case .tracks:
            computed = trackRows.map { DiscoverDisplayRow.item($0) }
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
    private var selection: DiscoverSelection? {
        guard loaded, !failed else { return nil }
        return discoverSelection(rows: rows, cursor: cursorIndex)
    }

    private var canGoBack: Bool { stack.count > 1 }

    /// `r` is guarded to the top level in handle(), because refresh() resets the
    /// stack — offering it deeper would silently teleport the user to Discover. The
    /// footer must not advertise it where it is ignored.
    private var canRefresh: Bool {
        if case .root = current.level { return true }
        return false
    }

    var footerHint: String {
        discoverFooterHint(selection, canGoBack: canGoBack, canRefresh: canRefresh,
                           sourceApp: bridgeSelected())
    }

    // MARK: - Input

    func handle(_ key: KeyPress) -> SceneAction {
        let k = vimAlias(key, listScene: true)
        let count = selectableDiscoverIndices(rows).count

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
            // but gating it on landing at .root meant it only fired on the
            // second pop and left the array alive in between.
            if case .tracks = current.level { trackRows = [] }
            stack = popLevel(stack)
            return .redraw
        case .char("r"):
            guard case .root = current.level else { return .none }
            refresh(); return .redraw
        case .enter:
            return activate()
        case .char("p"):
            return activatePlayAll()
        case .right:
            // → drills in like Enter (vim `l` arrives here as .right),
            // symmetric with ← back — but it never plays. LibraryScene and
            // PlaylistsScene both hold this line: at levels where Enter means
            // play, → stays a no-op. A station's Enter means Listen, so firing
            // it from → would start playback and pull Music.app to the front,
            // which is not what an arrow key should do.
            guard discoverRightArrowActivates(selection) else { return .none }
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
        let selectable = selectableDiscoverIndices(all)
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
                do {
                    // The same station row, routed: `p` on a Radio favourite and
                    // Enter on a Discover station row reach the same op.
                    //
                    // The share URL is how MUSIC.APP plays a station, so needing
                    // one is that branch's precondition. A row Bridge sent
                    // carries none, and checked out here it refused every such
                    // row before the coordinator was ever asked.
                    try routing.perform(.radioStationPlay,
                        musicApp: {
                            guard let url = item.url else {
                                throw ActionError(message: "That station has no play URL.")
                            }
                            try playStation(Station(id: item.id, name: item.name, url: url,
                                                    isLive: nil, artworkURL: item.artworkURL),
                                            via: opener)
                        },
                        source: { try $0.control.playStation(id: item.id, named: item.name) },
                        unaffected: {})
                    status.post("Playing \(item.name)")
                } catch let error as SourceAppError {
                    status.post(error.message, error: true)
                } catch let error as ActionError {
                    status.post(error.message, error: true)
                } catch {
                    status.post("Could not play \(item.name).", error: true)
                }
                return .redraw
            case .album, .playlist:
                drillIn(item)
                return .redraw
            case .song:
                // Play from here: the container sliced from this row to its
                // end. `p` on this same row is still a no-op (it plays a
                // whole RAIL row, and a track row is not one).
                return playFromHere()
            }
        }
    }

    /// `p`: play the whole container, from the top. Reachable only from an
    /// un-drilled album/playlist rail row (fetches the track list itself,
    /// since only a drill-in populates one). A no-op everywhere else —
    /// stations already play on Enter, there is nothing to play at a `View
    /// all` row, and a track row inside a drill-in has no play action at
    /// all (there is no per-track play path; see the module doc).
    private func activatePlayAll() -> SceneAction {
        guard let selection else { return .none }
        switch selection {
        case .item(let item):
            switch item.detail {
            case .station, .song:
                return .none
            case .album, .playlist:
                playAllFromRail(item)
                return .push(.nowPlaying)
            }
        case .viewAll:
            return .none
        }
    }

    // MARK: - Play

    /// Track-level `Enter`: play the drilled-in container from the SELECTED
    /// row to its end, then jump to Now Playing like every other play in the
    /// shell.
    ///
    /// The feature is `discoverPlaySlice` plus the shuffle guard, and nothing
    /// else. The bounded play form starts a playlist from its beginning — the
    /// deferral reason recorded in the docs, and still true — so this makes the
    /// slice's beginning BE the selected track instead of fighting it. Unlike
    /// `playAllFromRail` there is no fetch: a drill-in has already populated
    /// `trackRows`, which is the only level this is reachable from.
    ///
    /// `→` deliberately does not reach here (`discoverRightArrowActivates`).
    private func playFromHere() -> SceneAction {
        guard case .tracks(let container) = current.level else { return .none }
        // A Music.app precondition: Bridge plays with no keys. Read here only to
        // keep Music.app's immediate refusal exactly as it was; `route` checks
        // again inside the Music.app branch, where the mode cannot move.
        guard api != nil || bridgeSelected() else {
            status.post(Self.signInToPlay, error: true)
            return .redraw
        }
        // At the tracks level every display row is a selectable item (`rows`
        // maps trackRows 1:1 with no headers), so the cursor ordinal IS the
        // trackRows index. This is the one level where no header-offset
        // conversion is needed — see clampScroll() for where it is.
        //
        // The slice is the same in both modes; WHERE it plays is the
        // coordinator's decision, not this call site's. An out-of-range cursor
        // yields an empty slice rather than clamping, because clamping would
        // play a DIFFERENT song than the one pointed at.
        let ids = discoverPlaySlice(catalogIDs: trackRows.map { $0.id }, from: cursorIndex)
        guard !ids.isEmpty else {
            status.post("Couldn't tell which track to play from.", error: true)
            return .redraw
        }
        playCatalogSlice(catalogIDs: ids, containerTitle: container.name,
                         trackName: trackRows[cursorIndex].name)
        return .push(.nowPlaying)
    }

    /// `p` on an album/playlist rail row: there is no cached track list yet —
    /// only a drill-in populates `trackRows`, and a track row inside a
    /// drill-in has no play action of its own (see the module doc) — so this
    /// fetches the container's own tracks first, off the input loop, then
    /// hands off to the lifecycle coordinator the same way `refresh`/`drillIn`
    /// dispatch off the input loop for their own fetches.
    // Internal, not private, so the routing binding is reachable from a test.
    func playAllFromRail(_ item: DiscoverItem) {
        // See `playFromHere` for why this door reads the mode.
        guard api != nil || bridgeSelected() else {
            status.post(Self.signInToPlay, error: true)
            return
        }
        let title = item.name
        actions.run("Play") {
            // Two decisions, in order, neither nested in the other: which feed
            // to READ the tracks from, then where to PLAY them. A TUI mode
            // switch runs on this same serial queue, so none can land between
            // them; and both feeds yield catalogue ids either way.
            let tracks: [DiscoverItem]
            do {
                tracks = try self.chooseFeed(.discoverFeed).tracks(for: item)
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            }
            let catalogIDs = tracks.map { $0.id }
            try require(!catalogIDs.isEmpty, "'\(title)': no tracks to play.")
            try self.route(.discoverPlayAll, catalogIDs: catalogIDs, disableShuffle: false,
                       musicAppTitle: title,
                       bridgeToast: "Playing '\(title)' on Bridge — \(catalogIDs.count) tracks.")
        }
    }

    /// Play a catalogue slice: the selected Discover row through the container's
    /// tail. Internal, not private, so the routing binding is reachable from a
    /// test.
    func playCatalogSlice(catalogIDs: [String], containerTitle: String, trackName: String) {
        actions.run("Play") {
            try self.route(.discoverTrackPlay, catalogIDs: catalogIDs, disableShuffle: true,
                       musicAppTitle: containerTitle,
                       bridgeToast: catalogIDs.count == 1
                           ? "Playing \(trackName) on Bridge."
                           : "Playing \(trackName) on Bridge — \(catalogIDs.count) tracks.")
        }
    }

    /// The one place a Discover play chooses its destination.
    ///
    /// Both branches are real, so there is deliberately no `if bridgeSelected()`
    /// here: the coordinator reads the mode inside its own lock, which is what
    /// stops a switch that commits mid-action from driving the wrong player.
    /// Reading `bridgeSelected()` and then acting is the race the coordinator
    /// exists to close.
    private func route(_ action: MusicTUIAction, catalogIDs: [String], disableShuffle: Bool,
                       musicAppTitle: String, bridgeToast: String) throws {
        let lifecycle = self.lifecycle
        let routing = self.routing
        let status = self.status
        let hasAPI = api != nil
        do {
            try routing.perform(action,
                musicApp: {
                    try require(hasAPI, Self.signInToPlay)
                    _ = lifecycle.requestPlay(title: musicAppTitle, catalogIDs: catalogIDs,
                                              disableShuffle: disableShuffle)
                },
                source: {
                    try $0.control.queue(catalogIDs: catalogIDs)
                    status.post(bridgeToast)
                },
                unaffected: {})
        } catch let error as SourceAppError {
            // ActionRunner reduces anything that is not an ActionError to
            // "Play failed.", which would hide the 100-song bound and
            // "unresolvable" alike.
            throw ActionError(message: error.message)
        }
    }

    // MARK: - Fetching

    static let signInToPlay = "Sign in to play Discover music (music auth setup)."
    static let signInToBrowse = "Sign in to see your Discover feed (music auth setup)."

    /// Which feed THIS read uses, asked of the coordinator rather than fixed at
    /// construction (step 3).
    ///
    /// **Only the CHOICE happens inside the lock; the round trip does not**, the
    /// same rule Radio's `/` search follows and for the same reason: a slow read
    /// held across the ordering lock would block a mode switch. A read can
    /// safely use the feed chosen a moment ago - the worst case is rails from
    /// the output you just left, and `r` re-reads them.
    ///
    /// **Call this OFF the main thread.** It waits behind any playback action in
    /// flight, and a 20-track Bridge queue holds the lock for about four seconds.
    ///
    /// No fallback in either direction: Bridge selected means Bridge is read,
    /// whether or not a web-service feed exists.
    private func chooseFeed(_ action: MusicTUIAction) throws -> DiscoverFeedReading {
        var chosen: DiscoverFeedReading?
        try routing.perform(action,
                            musicApp: { chosen = self.feed },
                            source: { chosen = $0.discover },
                            unaffected: {})
        // Music.app mode with no sign-in: the only state with no feed at all.
        guard let chosen else { throw ActionError(message: Self.signInToBrowse) }
        return chosen
    }

    /// A failure in words for the person, or nil for one that has none of its
    /// own. Bridge's refusals and the coordinator's are sentences; a web-service
    /// failure is not, and keeps the line it always had.
    private static func words(for error: Error) -> String? {
        if let error = error as? SourceAppError { return error.message }
        if let error = error as? ActionError { return error.message }
        return nil
    }

    private func refresh() {
        loaded = false
        failed = false
        loadFailure = nil
        fetchStarted = false
        stack = [DiscoverFrameState(level: .root, cursor: DiscoverCursor())]
        status.post("Refreshing Discover\u{2026}")
    }

    // Internal, not private, so the feed binding is reachable from a test.
    func drillIn(_ item: DiscoverItem) {
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
            guard let self else { return }
            var fetched: [DiscoverItem] = []
            var failure: String? = nil
            do {
                fetched = try self.chooseFeed(.discoverFeed).tracks(for: item)
            } catch {
                // This was `try?`, which turned every refusal into an empty list
                // that rendered as "No tracks." A web-service failure still does;
                // a failure with words of its own now keeps them.
                failure = Self.words(for: error)
            }
            self.inboxLock.lock()
            self.tracksInbox = fetched
            self.tracksFailure = failure
            self.inboxLock.unlock()
        }
    }

    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        if !fetchStarted {
            fetchStarted = true
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                var fetched: [DiscoverRail] = []
                var failed = false
                var failure: String? = nil
                do {
                    fetched = try self.chooseFeed(.discoverFeed).rails(limit: 30)
                } catch {
                    failed = true
                    failure = Self.words(for: error)
                }
                self.inboxLock.lock()
                self.railsInbox = fetched
                self.railsFailed = failed
                self.railsFailure = failure
                self.inboxLock.unlock()
            }
        }

        inboxLock.lock()
        let incomingRails = railsInbox
        let incomingFailed = railsFailed
        let incomingFailure = railsFailure
        railsInbox = nil
        let incomingTracks = tracksInbox
        let incomingTracksFailure = tracksFailure
        tracksInbox = nil
        tracksFailure = nil
        let artLanded = artDirty
        artDirty = false
        inboxLock.unlock()

        if let incomingRails {
            rails = incomingRails
            feedVersion += 1
            loaded = true
            failed = incomingFailed || incomingRails.isEmpty
            loadFailure = incomingFailure
            cursorIndex = min(cursorIndex, max(0, selectableDiscoverIndices(rows).count - 1))
            changed = true
        }
        if let incomingTracks {
            trackRows = incomingTracks
            feedVersion += 1
            tracksInFlight = false
            // A refusal to open goes where every other Discover refusal goes.
            if let incomingTracksFailure { status.post(incomingTracksFailure, error: true) }
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
        let twoPane = discoverIsTwoPane(width: frame.width)
        let leftW = twoPane ? discoverLeftWidth(frameWidth: frame.width) : (frame.width - 6)
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
        case .root:            return "Discover"
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
            return out + "\(ANSICode.dim)Sign in to see your Discover feed (music auth setup).\(ANSICode.reset)"
        }
        if !loaded {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
        }
        if failed || rails.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            // A failure with words of its own says them. No automatic fallback
            // means the person has to be able to read WHY.
            if let loadFailure {
                let why = loadFailure.hasSuffix(".") ? String(loadFailure.dropLast()) : loadFailure
                return out + "\(ANSICode.dim)\u{2717} \(why). r to retry.\(ANSICode.reset)"
            }
            return out + "\(ANSICode.dim)No recommendations right now. r to retry.\(ANSICode.reset)"
        }
        if case .tracks = current.level, trackRows.isEmpty {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)\(tracksInFlight ? "Loading\u{2026}" : "No tracks.")\(ANSICode.reset)"
        }

        let all = rows
        let selectable = selectableDiscoverIndices(all)
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
    private func renderRow(_ item: DiscoverItem, selected: Bool, width: Int) -> String {
        // Only stations play from Discover, so only stations carry the play marker.
        // A marker on a row that cannot play is a promise the tab cannot keep.
        let marker = item.kind == .station ? "\(ANSICode.lime)\u{25B6}\(ANSICode.reset)" : " "
        let (nameW, subW) = discoverRowColumns(width: width, hasSubtitle: item.subtitle != nil)
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

    private func renderPanel(frame: ShellFrame, x: Int, selection: DiscoverSelection) -> String {
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
        // Compose the text BEFORE sizing the cover, so the hero is measured
        // against the rows genuinely left rather than a guessed reserve, and so
        // the array measured here is the one drawn below. Was `min(24, w)` by
        // `min(12, ...)`: a fixed box that ignored the pane it sat in, which
        // showed as a small cover beside full-width text on any wide terminal.
        let textLines = discoverPanelLines(selection: selection, width: w)
        let (gw, gh) = discoverHeroBox(panelWidth: w, frameWidth: frame.width,
                                       availableRows: max(0, bottom - y + 1),
                                       textRows: textLines.count)
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

        // The description and everything else wrap beneath the cover, from the
        // same array that sized it. The bottom guard stays: a pane too short for
        // its own text clips the tail rather than drawing past the body.
        for text in textLines {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: x) + text
            y += 1
        }
        return out
    }
}

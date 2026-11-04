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
//   song (directly on a rail)  -> plays that one song. There is no container
//                                 to play on from (rails are heterogeneous).
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
// ALBUMS, since 3.18.1: on the MusicTUI output every one of those routes adds
// the album's songs to his library for good, so an album refused there and
// played nothing (`catalogueAlbumTitle`). Since album-cleanup, with SpanDAC
// data on the MusicTUI output, Enter on an album's song and `p` on an album
// row play from that row to the album's end through a temporary playlist of
// the slice (`discoverAlbumRequest`, `DiscoverAlbumTransaction`); the songs
// it can prove it added leave his library when he stops, unless he loves one
// or adds it to a playlist first. The LAST row is a one-row slice and takes
// the same path, never the single-song add. On MusicTUI's own data every
// such play refuses (N3); a SpanDAC output queues on its own player, as
// before. Playlists are unchanged.
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
    /// The storefront's genres, read after the sections from the same
    /// provider. Empty: no genre row (SpanDAC data, or a read that failed).
    private(set) var genres: [DiscoverGenre] = []
    /// The genre the Top charts show; nil is All genres. Resets with the rows
    /// (refresh, a change of data source) and on every launch.
    private(set) var genre: DiscoverGenre?
    /// The genre whose charts are on screen, which `genre` runs ahead of
    /// while a read is out. A read that finds nothing puts the row back to it.
    private(set) var shownGenre: DiscoverGenre?
    /// Called after each genre or genre-chart inbox write (kept or refused),
    /// with "genres" or "genreCharts". A test's hook to know a background read
    /// is done with the inbox; nil in production.
    var inboxWritten: ((String) -> Void)?
    /// The All-genres chart sections as the sections read served them, so
    /// choosing All genres again puts them back without a read.
    private var allGenreCharts: [DiscoverRail] = []
    /// Bumped per genre choice, so a chart read a later choice replaced is
    /// dropped rather than shown under the wrong genre.
    private var genreRequest = 0
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
        case .genres:          return "genres"
        case .search:          return "search"
        case .dj:              return "dj"
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

    /// The cursor row of the level on screen, for a test.
    var shownCursorIndex: Int { current.cursor.index }

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
    /// `routing.dataEpoch` when the rails fetch was started (tick thread). A
    /// move reloads the tab: rows from before a change of data source are not
    /// left on screen to be played (C-MATRIX's "from before" rule).
    private var fetchDataEpoch = 0
    /// Bumped each time a rails fetch starts (tick thread). The sections that
    /// fetch reads afterwards carry it, so sections from a fetch since
    /// replaced (a refresh, a change of data source) are dropped, never
    /// appended to newer rails.
    private var fetchGeneration = 0
    private var railsInbox: [DiscoverRail]?      // guarded by inboxLock
    /// The self-named sections, which land AFTER the rails so the curated
    /// rails never wait on them (`DiscoverFeed.sectionRails`'s one deadline).
    private var sectionsInbox: (generation: Int, rails: [DiscoverRail])?   // guarded by inboxLock
    private var genresInbox: (generation: Int, genres: [DiscoverGenre])?   // guarded by inboxLock
    private var genreChartsInbox: (generation: Int, request: Int, genre: DiscoverGenre, rails: [DiscoverRail])?   // guarded by inboxLock
    private var railsReadInbox: RowsRead?        // guarded by inboxLock
    private var tracksReadInbox: RowsRead?       // guarded by inboxLock
    /// Where the rows on screen were read (tick/handle thread only). A play
    /// carries the read's data epoch and origin into `routing.perform`, which
    /// checks both inside its boundary before anything plays (C-EPOCH).
    private var railsRead: RowsRead?
    private var tracksRead: RowsRead?
    private var railsFailed = false          // guarded by inboxLock
    private var railsFailure: String?        // guarded by inboxLock
    private var tracksFailure: String?       // guarded by inboxLock
    private var tracksInbox: [DiscoverItem]?     // guarded by inboxLock
    /// The drill token the read in `tracksInbox` was started under. A read
    /// writes the slot only if its token is at least this one, so an older
    /// read finishing late never evicts a newer one before tick() drains it.
    private var tracksInboxToken = 0         // guarded by inboxLock
    private var tracksInFlight = false       // tick()/handle() thread only
    /// Bumped by every drillIn (tick/handle thread only).
    private var drillToken = 0
    /// The drill whose read may still land: its token, the data epoch and the
    /// frame (stack depth, container id) it was opened in. Back from its
    /// track list, a reload, a refresh and a newer drill clear it, and tick()
    /// drops a read whose token is not this one: its rows never appear and
    /// its failure is never posted.
    private var awaitedDrill: (token: Int, dataEpoch: Int, depth: Int, itemID: String)?

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

    /// Where a read or a play goes, decided inside the coordinator's own lock
    /// on both axes (score: data route and output): the rails follow the DATA
    /// selection, a play follows the OUTPUT and the row's origin. The scene
    /// reads `routing.selection` itself and never infers data from the output.
    private let routing: RoutingCoordinator

    /// Plays a single Discover track on the MusicTUI output with SpanDAC data:
    /// SpanDAC on this Mac adds it, then exactly that song plays (C-ADD). Held
    /// for the scene's life so an add whose outcome was unknown is reconciled
    /// on the person's next Enter. Internal so a test can hand in fakes.
    var cataloguePlayer = SpanDACCataloguePlayer(seams: .live(backend: AppleScriptBackend(), showsProgress: false))

    /// SpanDAC's library ops. Nil in production: SpanDAC on this Mac, over the
    /// data client's own socket. A test hands in a fake.
    var libraryOps: SpanDACLibraryAdding?

    /// Where a list of rows came from: the data epoch it was read under, and
    /// whether SpanDAC on this Mac served it.
    struct RowsRead: Equatable {
        let dataEpoch: Int
        let spandacData: Bool

        init<P>(_ choice: ProviderChoice<P>) {
            dataEpoch = choice.dataEpoch
            if case .consistent(.spandacMac, _) = choice.selection { spandacData = true } else { spandacData = false }
        }
    }

    /// Where Discover's data comes from is asked of `routing`, never inferred
    /// from the output.
    init(feed: DiscoverFeedReading?, status: StatusStore, actions: ActionRunner, api: RESTAPIBackend?,
         lifecycle: DiscoverLifecycleCoordinator, routing: RoutingCoordinator,
         opener: Opener = SystemOpener(),
         kittyEnabled: Bool = false) {
        self.routing = routing
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

    /// Discover shows five curated rails at four items each, then the
    /// self-named sections the data source served (under SpanDAC data, only
    /// those SpanDAC advertises), also at four. The rail level shows one rail in
    /// full, in Apple's own item order.
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
            computed = discoverRootRows(rails: resolvedDiscoverRails(rails), genres: genres, genre: genre)
        case .rail(let rail):
            computed = discoverDisplayRows(rails: [rail], perRail: rail.items.count)
        case .tracks:
            computed = trackRows.map { DiscoverDisplayRow.item($0) }
        case .genres:
            computed = [.genreChoice(nil)] + genres.map { DiscoverDisplayRow.genreChoice($0) }
        case .search, .dj:
            // The pane draws its own rows; Discover's list has none here.
            computed = []
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
        // The search reads nothing of the root feed, so an album it opened
        // plays whether the feed is loading, loaded or failed.
        guard (loaded && !failed) || searchPane != nil else { return nil }
        return discoverSelection(rows: rows, cursor: cursorIndex)
    }

    private var canGoBack: Bool { stack.count > 1 }

    // MARK: - Catalogue search state (the host glue is the extension at the end)

    /// The catalogue search pane, while a `.search` frame is in the stack.
    /// Readable, not private, so a test can see what it shows.
    private(set) var searchPane: CatalogueSearchPane?

    /// The level on screen, for a test.
    var currentLevel: DiscoverLevel { current.level }

    /// What a pane intent asked `handle` to return (a play jumps to Now, a
    /// close redraws). Set and read on the handle thread only.
    private var searchIntentAction: SceneAction?

    /// Where the results and the artist's albums on screen were read, so a
    /// play from them carries that read's stamp and origin (tick/handle thread).
    private var searchResultsRead: RowsRead?
    private var searchAlbumsRead: RowsRead?

    /// The track list `/` was pressed on, if any. Discover keeps one
    /// `trackRows`, which an album the search opens replaces (and Back
    /// clears), so it is put back when the search closes; a read still out
    /// when `/` was pressed is left behind and read again then.
    private var trackListUnderSearch: (item: DiscoverItem, rows: [DiscoverItem], read: RowsRead?, reread: Bool)?

    /// One search or artist-albums answer, as the background read left it.
    private enum SearchAnswer {
        case results(CatalogueSearchResults)
        case albums(ArtistAlbums)
        case failure(String)
    }

    /// One search or artist-albums answer in the slot: the search session
    /// and pane request id it was asked under, and the data epoch it was read under.
    private typealias SearchInboxEntry = (session: Int, requestID: Int, dataEpoch: Int, read: RowsRead?, answer: SearchAnswer)

    /// The one slot a search read writes. A read writes only if its
    /// (session, request id) is at least the slot's, so an older one, from
    /// this pane or a pane since closed, never evicts a newer before tick().
    private var searchInbox: SearchInboxEntry?   // guarded by inboxLock

    /// Scene-lifetime count of search panes, moved on by every new pane and
    /// every drop. Each pane numbers its requests from 1, so a read carries
    /// the session it was asked in, and only the current session's answers
    /// are applied: a closed search's late answer cannot pass for the next
    /// search's same-numbered request (handle/tick thread).
    private var searchSession = 0

    // MARK: - The DJ box state (the host glue is the extension at the end)

    /// What the DJ box reads and plays through. Fail-closed defaults; the shell
    /// wires the real ones (`DJSeams.live`) and a test hands in fakes.
    var dj = DJSeams()

    /// The DJ box, while a `.dj` frame is in the stack. Readable, not private,
    /// so a test can see what it shows.
    private(set) var djModel: DJBoxModel?

    /// Scene-lifetime count of DJ boxes, moved on by every open and every drop,
    /// so a closed box's late answer can never pass for the next box's
    /// same-numbered request (handle/tick thread).
    private var djSession = 0

    /// The world the latest request was asked in (handle/tick thread).
    private var djAskedStamp: DJStamp?

    /// An answer in the slot: the box session and request id it was asked under.
    private typealias DJInboxEntry = (session: Int, requestID: Int, outcome: DJOutcome)
    private var djInbox: DJInboxEntry?                       // guarded by inboxLock
    /// The (session, request id) a background job may still deliver for; every
    /// job asks it before each read. (-1, -1) while no box is open.
    private var djLive: (session: Int, requestID: Int) = (-1, -1)   // guarded by inboxLock

    static let djDataSourceChanged = "Data source changed while the DJ was open; ask again."

    static let searchNeedsSpanDAC = "Search needs SpanDAC on this Mac."
    static let searchDataSourceChanged = "Data source changed while searching; search again."
    /// Results per kind (Apple's order), and one artist's albums (one page).
    static let searchLimit = 10
    static let artistAlbumsLimit = 25

    /// The Discover row a catalogue hit plays and drills as: an album is
    /// Discover's album (subtitle the artist), a song its song. An artist is
    /// not a Discover row; it opens its albums inside the pane.
    static func discoverItem(for hit: CatalogueHit) -> DiscoverItem? {
        switch hit.kind {
        case .album:
            return DiscoverItem(id: hit.id, name: hit.title, subtitle: hit.subtitle, url: nil, artworkURL: nil,
                                detail: .album(trackCount: nil, year: nil, genre: nil))
        case .song:
            return DiscoverItem(id: hit.id, name: hit.title, subtitle: hit.subtitle, url: nil, artworkURL: nil,
                                detail: .song)
        case .artist:
            return nil
        }
    }

    /// The box captures every key only while it is being typed in; results
    /// and every other level leave the shell's keys to the shell.
    var capturesAllInput: Bool {
        if case .search = current.level { return searchPane?.isEditing ?? false }
        if case .dj = current.level { return djModel != nil }
        return false
    }

    /// `r` is guarded to the top level in handle(), because refresh() resets the
    /// stack — offering it deeper would silently teleport the user to Discover. The
    /// footer must not advertise it where it is ignored.
    private var canRefresh: Bool {
        if case .root = current.level { return true }
        return false
    }

    var footerHint: String {
        if case .search = current.level, let pane = searchPane {
            return pane.isEditing
                ? "Type to search  Enter Search  Esc Cancel"
                : "\u{2191}\u{2193} Move  Enter Open/Play  p Play album  / Search  \u{2190} Back"
        }
        if case .dj = current.level, djModel != nil {
            return "Type a request  Enter Ask or play the card  Esc Close"
        }
        return discoverFooterHint(selection, canGoBack: canGoBack, canRefresh: canRefresh,
                           inTrackList: { if case .tracks = current.level { return true }; return false }())
    }

    // MARK: - Input

    func handle(_ key: KeyPress) -> SceneAction {
        // The search on top takes every key the shell hands it, raw (before
        // the vim aliases), and passes none on.
        if case .search = current.level, let pane = searchPane {
            searchIntentAction = nil
            let drawn = pane.handle(key)
            let asked = searchIntentAction
            searchIntentAction = nil
            return asked ?? drawn
        }
        // The DJ box takes every key the shell hands it, raw, and passes none on.
        if case .dj = current.level, djModel != nil { return handleDJ(key) }
        if key == .char("/") { return openSearch() }
        if key == .char("d") { return openDJ() }
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
            if case .tracks = current.level {
                trackRows = []
                abandonDrill()
            }
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
        case .genre:
            stack = pushLevel(stack, .genres)
            // Open on the genre shown now, so Enter straight away changes nothing.
            if let genre, let at = genres.firstIndex(of: genre) { cursorIndex = at + 1 }
            clampScroll()
            return .redraw
        case .genreChoice(let choice):
            stack = popLevel(stack)
            choose(choice)
            return .redraw
        case .item(let item):
            switch item.detail {
            case .station:
                playStationRow(item)
                return .redraw
            case .album, .playlist:
                drillIn(item)
                return .redraw
            case .song:
                // Inside a drill-in: play from here, the container sliced from
                // this row to its end. On a rail: that one song, since a rail
                // is not a container. `p` is a no-op on both (it plays a whole
                // album/playlist RAIL row, and a song is not one).
                if case .tracks = current.level { return playFromHere() }
                return playRailSong(item)
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
        case .viewAll, .genre, .genreChoice:
            return .none
        }
    }

    // MARK: - Genre

    /// Show the Top charts for `choice` (nil: All genres). All genres puts
    /// back the charts the sections read served, with no read; a genre reads
    /// its charts in the background from the provider chosen now, and the old
    /// charts stay on screen until they land.
    private func choose(_ choice: DiscoverGenre?) {
        guard choice != genre else { return }
        genre = choice
        genreRequest += 1
        guard let choice else {
            replaceCharts(with: allGenreCharts)
            shownGenre = nil
            return
        }
        status.post("Loading Top charts for \(choice.name)\u{2026}")
        let generation = fetchGeneration
        let request = genreRequest
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let charts = (try? self.chooseFeed(.discoverFeed))?.provider.discoverGenreCharts(choice) ?? []
            self.inboxLock.lock()
            // Only a newer read takes the slot: an older one finishing late
            // must not evict the current result before tick() drains it.
            if (self.genreChartsInbox.map { ($0.generation, $0.request) } ?? (0, 0)) <= (generation, request) {
                self.genreChartsInbox = (generation, request, choice, charts)
            }
            self.inboxLock.unlock()
            self.inboxWritten?("genreCharts")
        }
    }

    /// Swap the chart sections, leaving the rails and the other sections as
    /// they are. Recently Added and Recent Stations sit BELOW the charts, so a
    /// chart block of another size (a genre has no playlist chart) would move
    /// a cursor there onto another row: shift the top level's cursor by the
    /// change, by position, as the genre row's landing does.
    private func replaceCharts(with charts: [DiscoverRail]) {
        let chartsEnd = { (rails: [DiscoverRail]) -> Int in
            selectableDiscoverIndices(discoverRootRows(
                rails: resolvedDiscoverRails(rails).filter { $0.section == nil || ($0.section?.isChart ?? false) },
                genres: self.genres, genre: self.genre)).count
        }
        let before = chartsEnd(rails)
        rails = rails.filter { !($0.section?.isChart ?? false) } + charts
        let after = chartsEnd(rails)
        if after != before && stack[0].cursor.index >= before {
            stack[0].cursor.index += after - before
            if stack.count == 1 { clampScroll() }
        }
        feedVersion += 1
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
        // The shipped path's precondition: SpanDAC data plays with no keys.
        // Read here only to keep the shipped immediate refusal exactly as it
        // was; `route` checks again inside that branch, where nothing moves.
        guard api != nil || !shippedPathNeedsTheSignIn else {
            status.post(Self.signInToPlay, error: true, untilStateChange: true)
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
            status.post("Couldn't tell which track to play from.", error: true, untilStateChange: true)
            return .redraw
        }
        // A catalogue playlist or a Discover album carries the FULL rows and
        // the cursor too: with SpanDAC data on the MusicTUI output a playlist
        // plays on Apple's own copy and an album through a temporary playlist
        // of the slice, positioned at this row. Everything else ignores it.
        playCatalogSlice(catalogIDs: ids, containerTitle: container.name,
                         trackName: trackRows[cursorIndex].name, trackArtist: trackRows[cursorIndex].subtitle,
                         read: tracksRead,
                         copy: discoverCopyRequest(container: container, rows: trackRows, selected: cursorIndex)
                             ?? discoverAlbumRequest(container: container, rows: trackRows, selected: cursorIndex),
                         albumTitle: Self.catalogueAlbumTitle(container),
                         searchOrigin: current.searchOrigin)
        return .push(.nowPlaying)
    }

    /// Enter on a song shown directly on a rail: exactly that song, through
    /// the same single-track play as a one-row slice. The rails' own read
    /// stamps it, so a play whose data or output moved since plays nothing.
    private func playRailSong(_ item: DiscoverItem) -> SceneAction {
        playRailSong(item, read: railsRead, searchOrigin: false)
    }

    /// `read` is where the song's row was read (the rails, or a search);
    /// `searchOrigin` marks a search result for the coordinator.
    private func playRailSong(_ item: DiscoverItem, read: RowsRead?, searchOrigin: Bool) -> SceneAction {
        // See `playFromHere` for why this door reads the selection.
        guard api != nil || !shippedPathNeedsTheSignIn else {
            status.post(Self.signInToPlay, error: true, untilStateChange: true)
            return .redraw
        }
        playCatalogSlice(catalogIDs: [item.id], containerTitle: item.name,
                         trackName: item.name, trackArtist: item.subtitle, read: read,
                         searchOrigin: searchOrigin)
        return .push(.nowPlaying)
    }

    /// Whether a play here would take the shipped path, which needs the REST
    /// backend: MusicTUI's own data on the MusicTUI output. Every other column
    /// is decided by `routing.perform`, keys or no keys.
    private var shippedPathNeedsTheSignIn: Bool {
        routing.selection == .consistent(data: .open, output: .musicApp)
    }

    /// `p` on an album/playlist rail row: there is no cached track list yet —
    /// only a drill-in populates `trackRows`, and a track row inside a
    /// drill-in has no play action of its own (see the module doc) — so this
    /// fetches the container's own tracks first, off the input loop, then
    /// hands off to the lifecycle coordinator the same way `refresh`/`drillIn`
    /// dispatch off the input loop for their own fetches.
    // Internal, not private, so the routing binding is reachable from a test.
    func playAllFromRail(_ item: DiscoverItem) {
        playAllFromRail(item, read: railsRead, searchOrigin: false)
    }

    /// `read` is where the container's row was read (the rails, or a
    /// search); `searchOrigin` marks a search album for the coordinator.
    private func playAllFromRail(_ item: DiscoverItem, read rowRead: RowsRead?, searchOrigin: Bool) {
        // See `playFromHere` for why this door reads the selection.
        guard api != nil || !shippedPathNeedsTheSignIn else {
            status.post(Self.signInToPlay, error: true, untilStateChange: true)
            return
        }
        let title = item.name
        // The output epoch at the keypress: a play pressed for one output
        // never runs on another. The rail row's own read gives the data half.
        let keypressEpoch = routing.epoch
        let railRead = rowRead
        actions.run("Play") {
            // Two decisions, in order, neither nested in the other: which feed
            // to READ the tracks from (the DATA selection), then where to PLAY
            // them (the OUTPUT). Both feeds yield catalogue ids either way. A
            // switch that lands between them moves the stamp, and `perform`
            // refuses before anything plays.
            let tracks: [DiscoverItem]
            let read: RowsRead
            do {
                let choice = try self.chooseFeed(.discoverFeed)
                tracks = try choice.provider.containerTracks(for: item)
                read = railRead ?? RowsRead(choice)
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            }
            let catalogIDs = tracks.map { $0.id }
            try require(!catalogIDs.isEmpty, "'\(title)': no tracks to play.")
            try self.route(.discoverPlayAll, catalogIDs: catalogIDs, disableShuffle: false,
                       musicAppTitle: title,
                       bridgeToast: "Playing '\(title)' on SpanDAC — \(catalogIDs.count) tracks.",
                       expecting: (epoch: keypressEpoch, dataEpoch: read.dataEpoch),
                       origin: Self.origin(of: read, singleTrack: false),
                       copy: discoverCopyRequest(container: item, rows: tracks, selected: 0)
                           ?? discoverAlbumRequest(container: item, rows: tracks, selected: 0),
                       albumTitle: Self.catalogueAlbumTitle(item), searchOrigin: searchOrigin)
        }
    }

    /// The container's title when it is a Discover (catalogue) album, else nil.
    ///
    /// Every route that puts a catalogue album in front of Music.app adds its
    /// songs to his library and keeps them: a user playlist made from catalogue
    /// ids adds its tracks, and deleting the playlist leaves them (probe P-C,
    /// 2026-10-03, one run per arm). The one route with a cleanup is the album
    /// play from here with SpanDAC data on the MusicTUI output: it always
    /// carries an album request, so it takes phase A and never reaches a
    /// refusal keyed on this title. Every other branch that would add refuses
    /// with `albumPlayRefused` (owner's ruling, 3.18.1); on MusicTUI's own data
    /// N3's sentence refuses first. A SpanDAC output, which queues on its own
    /// player and sends no library op, is unchanged.
    static func catalogueAlbumTitle(_ container: DiscoverItem) -> String? {
        if case .album = container.detail { return container.name }
        return nil
    }

    /// Said instead of adding a Discover album to his library (CHOSEN wording).
    static func albumPlayRefused(_ album: String) -> String {
        "Play from here isn't available for albums yet, so '\(album)' wasn't added to your library. Nothing played."
    }

    /// Said instead of building a temporary playlist on MusicTUI's own data (N3).
    static func webDataPlayRefused(_ title: String) -> String {
        "Nothing played: on MusicTUI's own data, playing '\(title)' would add its songs to your library and leave them there, because MusicTUI can't tell which ones it added."
    }

    /// Play a catalogue slice: the selected Discover row through the container's
    /// tail. Internal, not private, so the routing binding is reachable from a
    /// test.
    ///
    /// `read` is where the track list came from. Without one there is no
    /// earlier read to stamp and no origin, so a play that needs an origin (a
    /// SpanDAC row on the MusicTUI output) refuses rather than guessing.
    ///
    /// `copy` is set only for a catalogue playlist or a Discover album. With
    /// one, the origin is the container's whatever the slice's length: the
    /// LAST row of a playlist or an album is a one-row slice, and must not go
    /// down the single-song add path.
    ///
    /// `albumTitle` is set only for a Discover album (`catalogueAlbumTitle`):
    /// every branch that would add to the library without the album request's
    /// clean-up refuses instead.
    func playCatalogSlice(catalogIDs: [String], containerTitle: String, trackName: String,
                          trackArtist: String? = nil, read: RowsRead? = nil,
                          copy: DiscoverCopyRequest? = nil, albumTitle: String? = nil,
                          searchOrigin: Bool = false) {
        let expecting = read.map { (epoch: routing.epoch, dataEpoch: $0.dataEpoch) }
        let origin = read.map { Self.origin(of: $0, singleTrack: copy == nil && catalogIDs.count == 1) }
        actions.run("Play") {
            try self.route(.discoverTrackPlay, catalogIDs: catalogIDs, disableShuffle: true,
                       musicAppTitle: containerTitle,
                       bridgeToast: catalogIDs.count == 1
                           ? "Playing \(trackName) on SpanDAC."
                           : "Playing \(trackName) on SpanDAC — \(catalogIDs.count) tracks.",
                       expecting: expecting, origin: origin,
                       track: (title: trackName, artist: trackArtist), copy: copy,
                       albumTitle: albumTitle, searchOrigin: searchOrigin)
        }
    }

    /// C-MATRIX's row origins for Discover: a SpanDAC single track is a
    /// catalogue row; an album, playlist or play-from-here slice of more than
    /// one track is a container. A row read under MusicTUI's own data is
    /// `openData`, which the coordinator refuses once data is SpanDAC's.
    static func origin(of read: RowsRead, singleTrack: Bool) -> PlayOrigin {
        guard read.spandacData else { return .openData(resultNumber: nil) }
        return singleTrack ? .spandacCatalogue : .spandacDiscoverContainer
    }

    /// The one place a Discover play chooses its destination.
    ///
    /// Every branch is decided by the coordinator, so there is deliberately no
    /// read of the selection here: the coordinator reads both axes inside its
    /// own lock, which is what stops a switch that commits mid-action from
    /// driving the wrong player. Reading the selection and then acting is the
    /// race the coordinator exists to close.
    ///
    /// `expecting` is the read's stamp: checked inside the coordinator's
    /// boundary before any branch runs, so the lifecycle is never asked to
    /// play a list whose output or data source has moved (C-EPOCH).
    ///
    /// `track` is the single track's own title and artist, which the SpanDAC
    /// add path needs to find the row the add made; nil for a container.
    ///
    /// `albumTitle` set: a Discover album. `.shipped` refuses every play (N3).
    /// `.addContainer` with an album request takes phase A, like a playlist's
    /// copy request; without one (unreachable for an album) it refuses, as
    /// does `.add`'s single-song add, before any of it runs. The
    /// SpanDAC-output branch is unchanged.
    private func route(_ action: MusicTUIAction, catalogIDs: [String], disableShuffle: Bool,
                       musicAppTitle: String, bridgeToast: String,
                       expecting: (epoch: Int, dataEpoch: Int)?, origin: PlayOrigin?,
                       track: (title: String, artist: String?)? = nil,
                       copy: DiscoverCopyRequest? = nil, albumTitle: String? = nil,
                       searchOrigin: Bool = false) throws {
        let lifecycle = self.lifecycle
        let routing = self.routing
        let status = self.status
        let player = self.cataloguePlayer
        let injectedOps = self.libraryOps
        func libraryOps() -> SpanDACLibraryAdding {
            injectedOps ?? routing.dataClient().libraryWrites()
        }
        // A catalogue playlist with SpanDAC data on the MusicTUI output plays
        // in two phases. Phase A, inside the boundary, only reserves; this is
        // what it captured, for phase B below.
        var phaseA: DiscoverCopyPhaseA?
        do {
            // `searchOrigin`: a search play refuses on the MusicTUI output
            // inside the coordinator, before any body below runs.
            try routing.perform(action, expecting: expecting, origin: origin, searchOrigin: searchOrigin,
                musicApp: { path in
                    // A Discover album: each branch below that adds to the
                    // library refuses first, before any mutation.
                    func refuseAnAlbum() throws {
                        if let albumTitle { throw ActionError(message: Self.albumPlayRefused(albumTitle)) }
                    }
                    switch path {
                    case .shipped:
                        // MusicTUI's own data: every Discover play here would
                        // build a temporary playlist from catalogue ids, which
                        // adds its songs to the library and keeps them (N3,
                        // CH28). Refuses before anything else, albums too.
                        throw ActionError(message: Self.webDataPlayRefused(musicAppTitle))
                    case .addContainer:
                        if let copy {
                            // PHASE A, for a playlist's copy or an album's
                            // temporary playlist alike. No socket, no
                            // AppleScript, no wait: the one copy-play slot and
                            // the reservation, while the boundary is held, so
                            // they are one instant.
                            phaseA = try discoverCopyPhaseA(copy, lifecycle: lifecycle,
                                                            reservation: { try routing.reservationForThisBranch() })
                            return
                        }
                        // A belt: an album always carries its request.
                        try refuseAnAlbum()
                        // A Discover container with SpanDAC data: SpanDAC on
                        // this Mac makes it, and it plays by the identity
                        // SpanDAC returned. The web-service container path is
                        // never used for SpanDAC data (no fallback on either
                        // axis), and the lifecycle posts its own outcome.
                        _ = lifecycle.requestSpanDACPlay(title: musicAppTitle, catalogIDs: catalogIDs,
                                                         disableShuffle: disableShuffle,
                                                         library: libraryOps(),
                                                         currentStamp: { routing.musicTUISpanDACStamp })
                    case .add:
                        // One Discover track with SpanDAC data: added through
                        // SpanDAC on this Mac, then exactly that song plays.
                        // An album's LAST row carries its album request and
                        // takes `.addContainer`; this refusal is a belt.
                        try refuseAnAlbum()
                        guard catalogIDs.count == 1, let track else { throw ActionError(message: pickASpanDACOutput) }
                        let song = SpanDACCatalogueSong(catalogueID: catalogIDs[0], title: track.title,
                                                        artist: track.artist, album: nil)
                        switch player.play(song, library: libraryOps()) {
                        case .playing(let title, let note):
                            status.post(note.map { "Playing \(title). \($0)" } ?? "Playing \(title)")
                        case .refused(let why):
                            throw ActionError(message: why)
                        case .outcomeUnknown(let title):
                            throw ActionError(message: Self.addOutcomeUnknown(title))
                        }
                    case .handoff, .stationURL:
                        throw ActionError(message: pickASpanDACOutput)
                    }
                },
                source: {
                    // The skip count is not shown here: the toast is today's.
                    _ = try BridgeMusicProvider(control: $0.control).playCatalogue(ids: catalogIDs)
                    status.post(bridgeToast)
                },
                unaffected: {})
        } catch let error as SourceAppError {
            if let phaseA { lifecycle.cancelCopyPlay(phaseA.slot) }
            // ActionRunner reduces anything that is not an ActionError to
            // "Play failed.", which would hide the 100-song bound and
            // "unresolvable" alike.
            throw ActionError(message: error.message)
        } catch {
            if let phaseA { lifecycle.cancelCopyPlay(phaseA.slot) }
            throw error
        }
        // PHASE B. The boundary is free again: the add, every wait and every
        // Music.app read run here, on this thread, and go back into the
        // boundary only through the gate. The lifecycle posts its own outcome.
        if let phaseA {
            _ = lifecycle.runCopyPlay(phaseA.slot,
                                      gate: discoverCopyGate(routing: routing, reservation: phaseA.reservation))
        }
    }

    /// Enter on a station row. The same station op Radio's Enter reaches.
    ///
    /// On the MusicTUI output a station plays by its share URL. A row SpanDAC
    /// sent carries none, so with SpanDAC data it is looked up BY ID through
    /// the data provider first, off the input loop; no URL from that lookup
    /// refuses. Never by name, and never on another output. Every other path
    /// runs at once, as it ships: MusicTUI's own data needs the row's URL, and
    /// a SpanDAC output plays the station by id.
    private func playStationRow(_ item: DiscoverItem) {
        let read = railsRead
        let expecting = read.map { (epoch: routing.epoch, dataEpoch: $0.dataEpoch) }
        let origin = read.map { Self.origin(of: $0, singleTrack: true) }
        if item.url == nil, routing.selection == .consistent(data: .spandacMac, output: .musicApp) {
            lookUpThenPlayStation(item, expecting: expecting, origin: origin)
            return
        }
        do {
            try performStationPlay(item, url: item.url, expecting: expecting, origin: origin)
            status.post("Playing \(item.name)")
        } catch let error as SourceAppError {
            status.post(error.message, error: true, untilStateChange: true)
        } catch let error as ActionError {
            status.post(error.message, error: true, untilStateChange: true)
        } catch {
            status.post("Could not play \(item.name).", error: true, untilStateChange: true)
        }
    }

    /// The lookup is a round trip, so it runs on the action queue. The lookup
    /// is a READ (the data axis, `choose`), and the play after it is stamped
    /// with the rows' read: a switch that lands while it is in flight plays
    /// nothing.
    private func lookUpThenPlayStation(_ item: DiscoverItem, expecting: (epoch: Int, dataEpoch: Int)?,
                                       origin: PlayOrigin?) {
        // No rows read means no stamp; the lookup's own choice gives one.
        let keypressEpoch = routing.epoch
        let routing = self.routing
        let opener = self.opener
        let status = self.status
        actions.run("Play") {
            let choice: ProviderChoice<StationProviding> = try routing.choose(.radioStationLookup,
                musicApp: { OpenMusicProvider(discover: nil, catalog: nil, opener: opener) },
                source: { BridgeMusicProvider(control: $0.control) })
            guard choice.provider.catalogueAvailable else { throw ActionError(message: pickASpanDACOutput) }
            let found: Station?
            do {
                found = try choice.provider.station(id: item.id)
            } catch {
                throw ActionError(message: Self.words(for: error) ?? "Could not look up \(item.name).")
            }
            guard let url = found?.url, stationPlayURL(url) != nil else {
                throw ActionError(message: pickASpanDACOutput)
            }
            do {
                try self.performStationPlay(item, url: url,
                                            expecting: expecting ?? (epoch: keypressEpoch, dataEpoch: choice.dataEpoch),
                                            origin: origin ?? Self.origin(of: RowsRead(choice), singleTrack: true))
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            } catch is StationError {
                throw ActionError(message: "Could not play \(item.name).")
            }
            status.post("Playing \(item.name)")
        }
    }

    /// One station play, routed on both axes. `url` is the row's own, or the
    /// one a lookup by id returned.
    private func performStationPlay(_ item: DiscoverItem, url: String?,
                                    expecting: (epoch: Int, dataEpoch: Int)?, origin: PlayOrigin?) throws {
        let opener = self.opener
        try routing.perform(.radioStationPlay, expecting: expecting, origin: origin,
            musicApp: { path in
                switch path {
                case .shipped:
                    // MusicTUI's own data: the share URL is how the MusicTUI
                    // output plays a station, so needing one is this branch's
                    // precondition, exactly as it ships.
                    guard let url = item.url else {
                        throw ActionError(message: "That station has no play URL.")
                    }
                    try playStation(Station(id: item.id, name: item.name, url: url,
                                            isLive: nil, artworkURL: item.artworkURL), via: opener)
                case .stationURL:
                    guard let url else { throw ActionError(message: pickASpanDACOutput) }
                    try playStation(Station(id: item.id, name: item.name, url: url,
                                            isLive: nil, artworkURL: item.artworkURL), via: opener)
                case .add, .addContainer, .handoff:
                    throw ActionError(message: pickASpanDACOutput)
                }
            },
            source: {
                // D2: the provider rethrows `SourceAppError` unchanged, so the
                // refusal reads as before. A SpanDAC output plays by id.
                try BridgeMusicProvider(control: $0.control)
                    .playStation(id: item.id, name: item.name, url: item.url)
            },
            unaffected: {})
    }

    // MARK: - Fetching

    static let signInToPlay = "Sign in to play Discover music (music auth setup)."

    /// Said when SpanDAC could not confirm a single track's add (CHOSEN
    /// wording, the container sentence's twin).
    static func addOutcomeUnknown(_ title: String) -> String {
        "Couldn't confirm SpanDAC added '\(title)'. Press Enter again to check."
    }
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
    ///
    /// Slice 3, Part 2 (P3): chosen through the provider seam. Music.app mode
    /// is `open`, the shipped feed wrapped; Bridge is `BridgeMusicProvider`.
    /// Discover keeps its documented tolerance of a result from the output
    /// just left (D3), so the choice's epoch is not checked here.
    ///
    /// **Routed by the DATA selection** (score: data route and output): with
    /// SpanDAC data the coordinator hands the Mac's own SpanDAC, whatever the
    /// output is; a blocked output reads MusicTUI's own data. The choice
    /// carries the stamp and selection a later play checks.
    private func chooseFeed(_ action: MusicTUIAction) throws -> ProviderChoice<DiscoverProviding> {
        let choice: ProviderChoice<DiscoverProviding> = try routing.choose(action,
            musicApp: { self.open },
            source: { BridgeMusicProvider(control: $0.control) })
        // MusicTUI's own data with no sign-in: the only state with no feed.
        guard choice.provider.feedAvailable else { throw ActionError(message: Self.signInToBrowse) }
        return choice
    }

    /// Music.app mode's provider: the feed this scene was given, wrapped (D4),
    /// so availability is still `feed != nil` and every read reaches it.
    /// Discover's station play keeps its shipped `musicApp` body, so no
    /// catalogue is needed here.
    private var open: OpenMusicProvider {
        OpenMusicProvider(discover: feed, catalog: nil, opener: opener)
    }

    /// A failure in words for the person, or nil for one that has none of its
    /// own. Bridge's refusals and the coordinator's are sentences; a web-service
    /// failure is not, and keeps the line it always had.
    private static func words(for error: Error) -> String? {
        if let error = error as? SourceAppError { return error.message }
        if let error = error as? ActionError { return error.message }
        if let error = error as? MusicProviderError { return error.errorDescription }
        return nil
    }

    /// `refresh` without the toast: the rows go, and the next tick reads the
    /// rails again from the data source now selected.
    private func reloadForANewDataSource() {
        // A search open now was read from the source just left: it goes, its
        // pending answer with it, and he is told to search again.
        if searchPane != nil {
            dropSearch()
            status.post(Self.searchDataSourceChanged)
        }
        // The same for the DJ box: its card, its reads and its keys go.
        if djModel != nil {
            dropDJ()
            status.post(Self.djDataSourceChanged)
        }
        loaded = false
        failed = false
        loadFailure = nil
        fetchStarted = false
        rails = []
        trackRows = []
        railsRead = nil
        tracksRead = nil
        abandonDrill()
        resetGenre()
        feedVersion += 1
        stack = [DiscoverFrameState(level: .root, cursor: DiscoverCursor())]
    }

    /// The drill in progress, if any, is left behind: its read is dropped
    /// when it lands, and a new drill may start at once.
    private func abandonDrill() {
        awaitedDrill = nil
        tracksInFlight = false
    }

    /// A new read of the sections serves the All-genres charts, so the genre
    /// goes back to All with them.
    private func resetGenre() {
        genres = []
        genre = nil
        shownGenre = nil
        allGenreCharts = []
        genreRequest += 1
    }

    private func refresh() {
        loaded = false
        failed = false
        loadFailure = nil
        fetchStarted = false
        abandonDrill()
        resetGenre()
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
        drillToken += 1
        let token = drillToken
        awaitedDrill = (token, routing.dataEpoch, stack.count, item.id)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var fetched: [DiscoverItem] = []
            var failure: String? = nil
            var read: RowsRead? = nil
            do {
                let choice = try self.chooseFeed(.discoverFeed)
                fetched = try choice.provider.containerTracks(for: item)
                read = RowsRead(choice)
            } catch {
                // This was `try?`, which turned every refusal into an empty list
                // that rendered as "No tracks." A web-service failure still does;
                // a failure with words of its own now keeps them.
                failure = Self.words(for: error)
            }
            self.inboxLock.lock()
            if token >= self.tracksInboxToken {
                self.tracksInboxToken = token
                self.tracksInbox = fetched
                self.tracksFailure = failure
                self.tracksReadInbox = read
            }
            self.inboxLock.unlock()
        }
    }

    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        // A change of data source since the rails were fetched: what is on
        // screen came from the source just left, so it goes and is read again
        // from the new one. Its rows could not play anyway (C-EPOCH).
        if fetchStarted, routing.dataEpoch != fetchDataEpoch {
            reloadForANewDataSource()
            changed = true
        }
        // The demand belongs to the view as it stands now (after the data-epoch
        // reload above), so it is validated before the pump can re-issue a
        // cover this view no longer shows (review, 2026-10-25).
        art.retainDemand(key: selection.flatMap { s in
            let a = panelArt(for: s); return a.template == nil ? nil : a.key
        })
        art.pump()   // cover retry / stale-slot deadlines, independent of painting

        if !fetchStarted {
            fetchStarted = true
            fetchDataEpoch = routing.dataEpoch
            fetchGeneration += 1
            let generation = fetchGeneration
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                var fetched: [DiscoverRail] = []
                var failed = false
                var failure: String? = nil
                var read: RowsRead? = nil
                var provider: DiscoverProviding? = nil
                do {
                    let choice = try self.chooseFeed(.discoverFeed)
                    fetched = try choice.provider.discoverRails(limit: 30)
                    read = RowsRead(choice)
                    provider = choice.provider
                } catch {
                    failed = true
                    failure = Self.words(for: error)
                }
                self.inboxLock.lock()
                self.railsInbox = fetched
                self.railsFailed = failed
                self.railsFailure = failure
                self.railsReadInbox = read
                self.inboxLock.unlock()
                // The rails are posted first, so the curated five show at
                // once. Then the sections, from the SAME provider the rails
                // came from (so the same data source and read stamp): the
                // web service's within its one deadline, none from SpanDAC.
                guard let provider else { return }
                let sections = provider.discoverSections()
                self.inboxLock.lock()
                self.sectionsInbox = (generation, sections)
                self.inboxLock.unlock()
                // The genre row needs the charts it re-reads, so the genres
                // are asked for only when the sections served one.
                guard sections.contains(where: { $0.section?.isChart ?? false }) else { return }
                let genres = provider.discoverGenres()
                self.inboxLock.lock()
                // Newer only, as for the genre charts below.
                if (self.genresInbox?.generation ?? 0) <= generation {
                    self.genresInbox = (generation, genres)
                }
                self.inboxLock.unlock()
                self.inboxWritten?("genres")
            }
        }

        inboxLock.lock()
        let incomingRails = railsInbox
        let incomingFailed = railsFailed
        let incomingFailure = railsFailure
        let incomingRailsRead = railsReadInbox
        railsInbox = nil
        railsReadInbox = nil
        let incomingSections = sectionsInbox
        sectionsInbox = nil
        let incomingGenres = genresInbox
        genresInbox = nil
        let incomingGenreCharts = genreChartsInbox
        genreChartsInbox = nil
        let incomingTracks = tracksInbox
        let incomingTracksToken = tracksInboxToken
        let incomingTracksFailure = tracksFailure
        let incomingTracksRead = tracksReadInbox
        tracksInbox = nil
        tracksFailure = nil
        tracksReadInbox = nil
        let artLanded = artDirty
        artDirty = false
        let incomingSearch = searchInbox
        searchInbox = nil
        let incomingDJ = djInbox
        djInbox = nil
        inboxLock.unlock()

        if let incomingSearch, applySearchAnswer(incomingSearch) { changed = true }
        if tickDJ(incomingDJ) { changed = true }

        if let incomingRails {
            rails = incomingRails
            railsRead = incomingRailsRead
            feedVersion += 1
            loaded = true
            failed = incomingFailed || incomingRails.isEmpty
            loadFailure = incomingFailure
            cursorIndex = min(cursorIndex, max(0, selectableDiscoverIndices(rows).count - 1))
            changed = true
        }
        // Sections append after the rails of the SAME fetch, and only to a
        // successful read (`railsRead` is set only then). Appending never
        // moves a row above them, so the cursor stays where it was.
        if let incomingSections, incomingSections.generation == fetchGeneration,
           loaded, railsRead != nil, !incomingSections.rails.isEmpty {
            rails = rails.filter { $0.section == nil } + incomingSections.rails
            allGenreCharts = incomingSections.rails.filter { $0.section?.isChart ?? false }
            feedVersion += 1
            failed = rails.isEmpty
            changed = true
        }
        // The genre row appears above the charts once the genres land. It is
        // selectable, so a cursor already in the charts would slip a row:
        // keep it on the row it was on, by what that row is.
        if let incomingGenres, incomingGenres.generation == fetchGeneration,
           loaded, railsRead != nil, !incomingGenres.genres.isEmpty {
            // By position, not by value: the same item can sit in a rail and
            // a chart. The row goes in at a known place, after every
            // selectable row of Apple's own rails; every row below it moves.
            let chartsStart = selectableDiscoverIndices(
                discoverRootRows(rails: resolvedDiscoverRails(rails).filter { $0.section == nil },
                                 genres: [], genre: nil)).count
            // The top level's own cursor, whichever level is showing (it is
            // the bottom of the stack, and popLevel never drops it).
            let shiftCursor = genres.isEmpty && stack[0].cursor.index >= chartsStart
            genres = incomingGenres.genres
            feedVersion += 1
            if shiftCursor {
                stack[0].cursor.index += 1
                if stack.count == 1 { clampScroll() }
            }
            changed = true
        }
        if let incomingGenreCharts, incomingGenreCharts.generation == fetchGeneration,
           incomingGenreCharts.request == genreRequest {
            if incomingGenreCharts.rails.isEmpty {
                // The charts on screen stay, and so the row goes back to
                // naming them; the line says what happened.
                genre = shownGenre
                feedVersion += 1
                status.post("No Top charts for \(incomingGenreCharts.genre.name) right now.", error: true)
            } else {
                replaceCharts(with: incomingGenreCharts.rails)
                shownGenre = incomingGenreCharts.genre
                status.post("Top charts for \(incomingGenreCharts.genre.name).")
            }
            changed = true
        }
        if incomingTracks != nil, !isAwaitedDrill(incomingTracksToken) {
            // A read from a drill left behind: dropped whole, rows and failure.
            // If it was the awaited one but its frame or data source has gone,
            // nothing else will clear the drill, so it is abandoned here.
            if awaitedDrill?.token == incomingTracksToken { abandonDrill() }
        } else if let incomingTracks {
            trackRows = incomingTracks
            tracksRead = incomingTracksRead
            feedVersion += 1
            tracksInFlight = false
            // A refusal to open goes where every other Discover refusal goes.
            if let incomingTracksFailure { status.post(incomingTracksFailure, error: true) }
            changed = true
        }
        if artLanded { changed = true }
        return changed
    }

    /// The read under `token` belongs to the drill on screen: the one awaited,
    /// in the frame it opened, under the data epoch it was opened with.
    private func isAwaitedDrill(_ token: Int) -> Bool {
        guard let awaited = awaitedDrill, awaited.token == token,
              stack.count == awaited.depth,
              case .tracks(let item) = current.level, item.id == awaited.itemID,
              routing.dataEpoch == awaited.dataEpoch else { return false }
        return true
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
        if case .search = current.level, let pane = searchPane {
            return renderSearch(pane, frame: frame)
        }
        if case .dj = current.level, let model = djModel {
            return renderDJ(model, frame: frame)
        }
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
        } else {
            art.dropDemand()   // no panel this frame, so no store cover is shown
        }
        if !(twoPane && selection != nil), let last = lastPlaced {
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
        case .genres:          return "Genres"
        case .search:          return "Search"
        case .dj:              return "DJ"
        }
    }

    private func renderLeft(frame: ShellFrame, width: Int) -> String {
        var out = ""
        var y = frame.bodyY
        let bottom = frame.bodyY + frame.bodyHeight - 1

        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)\(truncText(levelTitle, to: width))\(ANSICode.reset)"
        y += 2

        // The web-service feed's absence means "sign in" only with MusicTUI's
        // own data. With SpanDAC data the rails come from SpanDAC on this Mac
        // and need no key, whatever the output, so this door used to hide a
        // working feed behind a sign-in line: found 2026-09-22 by DoD 6's
        // rename-away control, with `config.json` and `user-token` moved
        // aside. It follows the DATA selection, never the output.
        // An album the search opened needs none of the root feed.
        let fromSearch = current.searchOrigin
        if !fromSearch, feed == nil, routing.data != .spandacMac {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)Sign in to see your Discover feed (music auth setup).\(ANSICode.reset)"
        }
        if !fromSearch, !loaded {
            out += ANSICode.moveTo(row: y, col: 3)
            return out + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
        }
        if !fromSearch, failed || rails.isEmpty {
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
            case .genre(let genre):
                let label = "Genre: \(genre?.name ?? "All genres") \u{203A}"
                out += idx == cursorRow
                    ? "    \(ANSICode.inverse)\(label)\(ANSICode.reset)"
                    : "    \(ANSICode.brightWhite)\(label)\(ANSICode.reset)"
            case .genreChoice(let choice):
                let marker = choice == genre ? "\(ANSICode.lime)\u{2022}\(ANSICode.reset)" : " "
                let name = truncText(choice?.name ?? "All genres", to: max(1, width - 4))
                out += "  \(marker) " + (idx == cursorRow
                    ? "\(ANSICode.inverse)\(name)\(ANSICode.reset)"
                    : "\(ANSICode.brightWhite)\(name)\(ANSICode.reset)")
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

    /// The panel cover for `selection`: its store key and artwork template (nil:
    /// the gradient). One definition for the panel and the tick's demand check.
    private func panelArt(for selection: DiscoverSelection) -> (key: String, template: String?) {
        switch selection {
        case .item(let item):    return (item.id, item.artworkURL)
        case .viewAll(let rail): return (rail.id, rail.items.first?.artworkURL)
        case .genre(let g), .genreChoice(let g): return ("genre:\(g?.id ?? "all")", nil)
        }
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
        let (artKey, artTemplate) = panelArt(for: selection)
        // Compose the text BEFORE sizing the cover, so the hero is measured
        // against the rows genuinely left rather than a guessed reserve, and so
        // the array measured here is the one drawn below. Was `min(24, w)` by
        // `min(12, ...)`: a fixed box that ignored the pane it sat in, which
        // showed as a small cover beside full-width text on any wide terminal.
        let textLines = discoverPanelLines(selection: selection, width: w)
        let (gw, gh) = discoverHeroBox(panelWidth: w, frameWidth: frame.width,
                                       availableRows: max(0, bottom - y + 1),
                                       textRows: textLines.count)
        art.dropDemand()   // the ask below, if this view has a store cover, re-sets it
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

// MARK: - Catalogue search host

// Discover hosts the catalogue search pane (catalogue-search score S5, r2
// items 1, 2, 3, 6, 7). The pane owns the box, the rows, the cursors and the
// request ids; this glue does its reads (off the input loop, through
// `routing.choose(.catalogSearch, …)`, by the DATA selection) and its plays
// (Discover's own, each marked as a search play so the coordinator refuses it
// on the MusicTUI output). It lives in this file because Swift's `private` is
// file-scoped.
extension DiscoverScene: CatalogueSearchHost {

    func cataloguePane(_ pane: CatalogueSearchPane, emit intent: CatalogueSearchIntent, requestID: Int) {
        guard pane === searchPane else { return }
        switch intent {
        case .search(let term):
            readCatalogue(requestID: requestID) {
                .results(try $0.browseCatalogue(term: term, limit: Self.searchLimit))
            }
        case .openArtist(let artist):
            readCatalogue(requestID: requestID) {
                .albums(try $0.artistAlbums(artistID: artist.id, limit: Self.artistAlbumsLimit))
            }
        case .openAlbum(let hit):
            guard let item = Self.discoverItem(for: hit) else { return }
            // Discover's own drill (and its drill token); the frame it opens
            // is marked, so a play from its tracks is a search play too.
            let depth = stack.count
            drillIn(item)
            if stack.count > depth { current.searchOrigin = true }
            searchIntentAction = .redraw
        case .playAlbum(let hit):
            guard let item = Self.discoverItem(for: hit) else { return }
            playAllFromRail(item, read: searchReadOnScreen, searchOrigin: true)
            searchIntentAction = .push(.nowPlaying)
        case .playSong(let hit):
            guard let item = Self.discoverItem(for: hit) else { return }
            searchIntentAction = playRailSong(item, read: searchReadOnScreen, searchOrigin: true)
        case .close:
            closeSearch()
            searchIntentAction = .redraw
        }
    }

    /// The read the rows on screen came from: the artist's albums while that
    /// level shows, else the results.
    private var searchReadOnScreen: RowsRead? {
        searchPane?.model.artist != nil ? searchAlbumsRead : searchResultsRead
    }

    /// `/` from any level. With a search already in the stack (an album it
    /// opened is on top), it goes back to that search and reopens its box.
    private func openSearch() -> SceneAction {
        if let at = stack.firstIndex(where: { $0.level == .search }), let pane = searchPane {
            if case .tracks = current.level {
                trackRows = []
                abandonDrill()
            }
            stack = Array(stack.prefix(at + 1))
            _ = pane.handle(.char("/"))
            return .redraw
        }
        if case .tracks(let item) = current.level {
            trackListUnderSearch = (item, trackRows, tracksRead, tracksInFlight)
            if tracksInFlight { abandonDrill() }
        }
        stack = pushLevel(stack, .search)
        searchSession += 1
        searchPane = CatalogueSearchPane(host: self)
        return .redraw
    }

    /// The pane's own close: back to the level `/` was pressed on.
    private func closeSearch() {
        if let at = stack.firstIndex(where: { $0.level == .search }), at > 0 {
            stack = Array(stack.prefix(at))
        }
        let under = trackListUnderSearch
        dropSearch()
        guard let under, case .tracks(let item) = current.level, item.id == under.item.id else { return }
        if under.reread {
            // Its read was left behind: open it again, from the same level.
            stack = popLevel(stack)
            drillIn(item)
        } else {
            trackRows = under.rows
            tracksRead = under.read
            feedVersion += 1
        }
    }

    /// The pane, its reads and any answer still in the slot go.
    private func dropSearch() {
        searchSession += 1
        searchPane = nil
        trackListUnderSearch = nil
        searchResultsRead = nil
        searchAlbumsRead = nil
        inboxLock.lock(); searchInbox = nil; inboxLock.unlock()
    }

    /// One search or artist-albums read, off the input loop. The choice is
    /// made inside the coordinator's lock and the round trip outside it, as
    /// for every Discover read. MusicTUI's own data has no catalogue search
    /// here: nothing is read and the pane says why.
    private func readCatalogue(requestID: Int, _ read: @escaping (CatalogueBrowsing) throws -> SearchAnswer) {
        let fallbackEpoch = routing.dataEpoch
        let session = searchSession
        let routing = self.routing
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var dataEpoch = fallbackEpoch
            var rowsRead: RowsRead?
            let answer: SearchAnswer
            do {
                let choice: ProviderChoice<CatalogueBrowsing?> = try routing.choose(.catalogSearch,
                    musicApp: { nil },
                    source: { BridgeMusicProvider(control: $0.control) })
                dataEpoch = choice.dataEpoch
                if let provider = choice.provider {
                    answer = try read(provider)
                    rowsRead = RowsRead(choice)
                } else {
                    answer = .failure(Self.searchNeedsSpanDAC)
                }
            } catch {
                answer = .failure(Self.words(for: error) ?? "Couldn't search Apple Music.")
            }
            self.inboxLock.lock()
            if let held = self.searchInbox, (held.session, held.requestID) > (session, requestID) {
                // A newer read already holds the slot: this one is dropped.
            } else {
                self.searchInbox = (session, requestID, dataEpoch, rowsRead, answer)
            }
            self.inboxLock.unlock()
            self.inboxWritten?("search")
        }
    }

    /// tick(): an answer reaches the pane only while the search it was asked
    /// in is the one open and its data source is still the selected one; the
    /// pane drops an id it is not waiting on. True when the screen changed.
    private func applySearchAnswer(_ incoming: SearchInboxEntry) -> Bool {
        guard let pane = searchPane, incoming.session == searchSession,
              incoming.dataEpoch == routing.dataEpoch else { return false }
        switch incoming.answer {
        case .results(let results):
            guard pane.didReceive(results: results, requestID: incoming.requestID) else { return false }
            searchResultsRead = incoming.read
            return true
        case .albums(let albums):
            guard pane.didReceive(albums: albums, requestID: incoming.requestID) else { return false }
            searchAlbumsRead = incoming.read
            return true
        case .failure(let message):
            return pane.didFail(message, requestID: incoming.requestID)
        }
    }

    /// The search level: the pane alone, no art panel (his "too busy"), and
    /// any cover still placed is deleted. On MusicTUI's own data the empty
    /// note line says why search will not work here.
    private func renderSearch(_ pane: CatalogueSearchPane, frame: ShellFrame) -> String {
        var out = pane.render(frame: frame)
        if routing.data != .spandacMac, pane.model.note == nil, frame.bodyHeight > 1 {
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 2)
                + "\(ANSICode.dim)\(truncText(Self.searchNeedsSpanDAC, to: max(1, frame.width - 2)))\(ANSICode.reset)"
        }
        art.dropDemand()
        if let last = lastPlaced {
            out += kittyDeleteEscape(id: last.id)
            lastPlaced = nil
        }
        return out
    }
}

// MARK: - The DJ box host

// Discover hosts the DJ box (DJ prompt score, S2 and S3). `DJBoxModel` owns the
// text, the stages and the request ids; this glue does the work (a model read,
// the lookups behind a card, the one play) and feeds each answer back with the
// request id it was asked under. It lives in this file because Swift's
// `private` is file-scoped.
//
// FENCES. Every request carries the box session, its request id, and the stamp
// (both routing epochs and the play serial) it was asked under. A background
// job asks `djIsLive` before each step and drops itself the moment any of them
// moved; `tickDJ` applies an answer only for the current session and request
// and only while the world is still the one it was asked in. A card plays only
// while its stamp still holds, through `routing.perform(expecting:)`, which
// checks both epochs again inside the coordinator's boundary.
extension DiscoverScene {

    private func openDJ() -> SceneAction {
        stack = pushLevel(stack, .dj)
        djSession += 1
        djModel = DJBoxModel()
        djAskedStamp = nil
        inboxLock.lock(); djInbox = nil; djLive = (-1, -1); inboxLock.unlock()
        return .redraw
    }

    /// Esc: back to the level `d` was pressed on; the box, its reads and any
    /// answer still in the slot go.
    private func closeDJ() {
        if let at = stack.firstIndex(where: { $0.level == .dj }), at > 0 {
            stack = Array(stack.prefix(at))
        }
        dropDJ()
    }

    private func dropDJ() {
        djSession += 1
        djModel = nil
        djAskedStamp = nil
        inboxLock.lock(); djInbox = nil; djLive = (-1, -1); inboxLock.unlock()
    }

    private func currentDJStamp() -> DJStamp {
        let stamp = routing.stamp
        return DJStamp(epoch: stamp.epoch, dataEpoch: stamp.dataEpoch, playSerial: routing.playSerial)
    }

    /// Whether the job for (`session`, `requestID`) may still read and deliver:
    /// that request is the box's latest, and the world is the one it began in.
    private func djIsLive(_ session: Int, _ requestID: Int, _ stamp: DJStamp) -> Bool {
        inboxLock.lock()
        let live = djLive.session == session && djLive.requestID == requestID
        inboxLock.unlock()
        return live && currentDJStamp() == stamp
    }

    // MARK: keys

    private func handleDJ(_ key: KeyPress) -> SceneAction {
        guard var model = djModel else { return .none }
        let wasOut = model.isRequestOut
        let out = model.handle(key)
        djModel = model
        // An edit that dropped the request still out: its job is released too,
        // so it stops reading and can deliver nothing.
        if out.emission == nil, wasOut, !model.isRequestOut { djRelease() }
        switch out.emission {
        case .close?:
            closeDJ()
            return .redraw
        case .ask(let prompt, let requestID)?:
            let seams = dj
            startDJRequest(requestID: requestID) { live, stamp, report in
                let reading = Self.blockingRead(seams.reader, prompt, timeout: seams.readerTimeout)
                return self.djOutcome(for: reading, seams: seams, stamp: stamp, report: report, live: live)
            }
            return .redraw
        case .choose(let hit, let requestID)?:
            // The picker's world must still be the one it was read in.
            if let asked = djAskedStamp, asked != currentDJStamp() {
                djDrop(saying: djChangedLine)
                return .redraw
            }
            let seams = dj
            startDJRequest(requestID: requestID) { live, stamp, report in
                self.djArtistMixOutcome(name: hit.title, chosen: hit, seams: seams, stamp: stamp,
                                        report: report, live: live)
            }
            return .redraw
        case .play(let plan)?:
            return playDJ(plan)
        case nil:
            return out.changed ? .redraw : .none
        }
    }

    private func djDrop(saying words: String) {
        guard var model = djModel else { return }
        model.drop(saying: words)
        djModel = model
        djRelease()
    }

    /// Nothing is out for the box any more: the world it was asked in is
    /// forgotten, the slot is emptied, and a job still running finds itself not live.
    private func djRelease() {
        djAskedStamp = nil
        inboxLock.lock(); djInbox = nil; djLive = (-1, -1); inboxLock.unlock()
    }

    // MARK: asking

    /// Starts one background job for a request the model just numbered, under
    /// the session and stamp of now. A nil answer is a job that found itself
    /// stale: nothing is delivered for it.
    private func startDJRequest(requestID: Int,
                                _ work: @escaping (_ live: @escaping () -> Bool, _ stamp: DJStamp,
                                                   _ report: @escaping (DJOutcome) -> Void) -> DJOutcome?) {
        let session = djSession
        let stamp = currentDJStamp()
        djAskedStamp = stamp
        inboxLock.lock(); djLive = (session, requestID); djInbox = nil; inboxLock.unlock()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let live: () -> Bool = { self.djIsLive(session, requestID, stamp) }
            // Everything this job delivers, progress included, goes out under the
            // session and request it began in, never under whatever is current.
            let report: (DJOutcome) -> Void = { self.djDeliver(session: session, requestID: requestID, $0) }
            guard let outcome = work(live, stamp, report), live() else { return }
            report(outcome)
        }
    }

    /// One answer into the slot. Only the request the box is waiting on takes
    /// it, judged here under the lock that guards the slot: an answer from a box
    /// since closed, a request since replaced or a job since released finds the
    /// pair no longer live and is dropped. (A request at least as new as the one
    /// already there replaces it; the older never does.)
    private func djDeliver(session: Int, requestID: Int, _ outcome: DJOutcome) {
        inboxLock.lock()
        var written = false
        if djLive.session == session, djLive.requestID == requestID {
            if let held = djInbox, (held.session, held.requestID) > (session, requestID) {
                // A newer request already holds the slot.
            } else {
                djInbox = (session, requestID, outcome)
                written = true
            }
        }
        inboxLock.unlock()
        if written { inboxWritten?("dj") }
    }

    /// The reader is async; the job is a plain background thread. Never on the
    /// input loop.
    private static func blockingRead(_ reader: DJReader, _ prompt: String, timeout: TimeInterval) -> DJReading {
        final class Slot: @unchecked Sendable { var value: DJReading = .failed("The DJ didn't answer.") }
        let slot = Slot()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let reading = await reader.read(prompt)
            if !Task.isCancelled { slot.value = reading }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            // Abandoned: whatever the reader says later is written nowhere this
            // call (or any box) reads.
            task.cancel()
            return .failed(djReaderTimedOutLine)
        }
        return slot.value
    }

    /// tick(): apply the answer in the slot, and drop what the world has left behind.
    private func tickDJ(_ incoming: DJInboxEntry?) -> Bool {
        guard var model = djModel else { return false }
        var changed = false
        if let incoming, incoming.session == djSession {
            // An answer from a world that has since moved is no answer.
            if let asked = djAskedStamp, asked != currentDJStamp() {
                model.drop(saying: djChangedLine)
                djModel = model
                djAskedStamp = nil
                return true
            }
            if model.receive(incoming.outcome, requestID: incoming.requestID) { changed = true }
        }
        // A card, a picker or a request in flight belongs to the world it was
        // asked in: an output switch or another play drops it, and says so.
        switch model.stage {
        case .reading, .working, .pick, .card:
            if let asked = djAskedStamp, asked != currentDJStamp() {
                model.drop(saying: djChangedLine)
                djAskedStamp = nil
                inboxLock.lock(); djInbox = nil; djLive = (-1, -1); inboxLock.unlock()
                changed = true
            }
        case .typing, .sent, .message:
            break
        }
        djModel = model
        return changed
    }

    // MARK: the answer to one request

    private func djOutcome(for reading: DJReading, seams: DJSeams, stamp: DJStamp,
                           report: @escaping (DJOutcome) -> Void, live: @escaping () -> Bool) -> DJOutcome? {
        guard live() else { return nil }
        switch reading {
        case .unavailable(let reason):
            return .message(reason.message)
        case .failed(let text):
            return .message(text == djReaderTimedOutLine ? text : djFailedLine(text))
        case .card(let card):
            switch card.kind {
            case .unsupported:
                return .message(djUnsupportedRequest)
            case .artistMix:
                guard let artist = card.artist else { return .message(djUnsupportedRequest) }
                return djArtistMixOutcome(name: artist, chosen: nil, seams: seams, stamp: stamp,
                                          report: report, live: live)
            case .genreUnheard:
                guard let genre = card.genre else { return .message(djUnsupportedRequest) }
                return djGenreOutcome(genre: genre, seams: seams, stamp: stamp, live: live)
            }
        }
    }

    /// An artist mix: SpanDAC data on a SpanDAC output only. Every other
    /// combination is told so before anything is read (the coordinator refuses
    /// the play itself again, whatever this says).
    private func djArtistMixOutcome(name: String, chosen: CatalogueHit?, seams: DJSeams, stamp: DJStamp,
                                    report: @escaping (DJOutcome) -> Void, live: @escaping () -> Bool) -> DJOutcome? {
        switch routing.selection {
        case .consistent(.spandacMac, .musicApp): return .message(djArtistMixSpanDACOnly)
        case .consistent(.spandacMac, _): break
        default: return .message(djArtistMixNeedsSpanDACData)
        }
        seams.beforeProgress()
        report(.working(chosen?.title ?? name))
        do {
            let choice: ProviderChoice<DJCatalogue?> = try routing.choose(.catalogSearch,
                musicApp: { nil },
                source: { BridgeMusicProvider(control: $0.control) })
            guard live() else { return nil }
            guard choice.stamp == stamp.routing, let catalogue = choice.provider else { return .message(djChangedLine) }
            let artist: CatalogueHit
            if let chosen {
                artist = chosen
            } else {
                let results = try catalogue.browseCatalogue(term: name, limit: Self.searchLimit)
                guard live() else { return nil }
                guard results.artistsServed else {
                    return .message(results.artistsNote ?? CatalogueSearchResults.artistsNeedNewerSpanDAC)
                }
                switch djResolveArtist(named: name, in: results.artists) {
                case .none: return .message(djNoArtistFound(name))
                case .pick(let hits): return .pick(artist: name, hits: hits)
                case .chosen(let hit): artist = hit
                }
            }
            let mix = try djBuildArtistMix(artist: artist, catalogue: catalogue, shuffler: seams.shuffler,
                                           isCurrent: live)
            return .plan(DJPlan(payload: .artistMix(mix), line: mix.line, stamp: stamp))
        } catch let error as DJArtistMixError {
            return error == .cancelled ? nil : .message(error.message)
        } catch {
            return .message(djErrorText(error))
        }
    }

    /// "A genre I haven't heard lately", from the data source now selected.
    private func djGenreOutcome(genre: String, seams: DJSeams, stamp: DJStamp,
                                live: @escaping () -> Bool) -> DJOutcome? {
        let days = djUnheardDays
        let title = "\(genre) you haven't played"
        do {
            switch routing.selection {
            case .consistent(.open, .musicApp):
                // MusicTUI's own data on the MusicTUI output: a separate timed
                // read of Music's library, in the bulk-column shape.
                try refuseOpenDataPlayBeforeReading(.libraryPlay, routing: routing, spanDACData: false)
                let read = try djReadLibraryForGenre(run: seams.runScript)
                guard live() else { return nil }
                let pick = djPickUnheard(read.songs, genre: genre, now: seams.now(), days: days,
                                         limit: djGenreSongLimit, shuffler: seams.shuffler)
                guard !pick.picked.isEmpty else {
                    let skipped = pick.unreadable > 0
                        ? " (\(pick.unreadable) with an unreadable date skipped.)" : ""
                    return .message(djNoGenreSongs(genre: genre, days: days) + skipped)
                }
                guard let queue = djOpenQueue(pick.picked, title: title) else {
                    return .message("Some of those songs have no identity MusicTUI can play by, so nothing played.")
                }
                return .plan(DJPlan(payload: .genreOpen(queue), line: pick.line(genre: genre, days: days),
                                    stamp: stamp))

            case .consistent(.spandacMac, let output):
                let choice: ProviderChoice<DJSpanDACGenreSource> = try routing.choose(.searchLibrary,
                    musicApp: { throw ActionError(message: djChangedLine) },
                    source: { seams.spandacGenre($0) })
                guard live() else { return nil }
                guard choice.stamp == stamp.routing else { return .message(djChangedLine) }
                let result = try choice.provider.genreUnheard(genre: genre, days: days)
                guard live() else { return nil }
                let rows = seams.shuffler.shuffled(Array(result.rows.prefix(djGenreSongLimit)))
                guard !rows.isEmpty else { return .message(djNoGenreSongs(genre: genre, days: days)) }
                // The MusicTUI output plays only songs with a verified alias; one
                // without fails the whole pick, nothing substituted.
                if output == .musicApp, rows.contains(where: { $0.alias == nil }) {
                    return .message(djGenreNeedsAliases)
                }
                return .plan(DJPlan(payload: .genreSpanDAC(rows: rows, pick: result, title: title),
                                    line: djGenreLine(genre: genre, days: days, songs: rows.count), stamp: stamp))

            default:
                // MusicTUI's own data with a SpanDAC output stored: refuses as
                // a marked play does, before any read.
                try refuseOpenDataPlayBeforeReading(.libraryPlay, routing: routing, spanDACData: false)
                return .message(djChangedLine)
            }
        } catch let error as DJLibraryReadError {
            return .message(error.message)
        } catch let error as DJGenreSourceError {
            return .message(error.message)
        } catch {
            return .message(djErrorText(error))
        }
    }

    // MARK: Enter on the card

    /// Plays exactly the frozen plan, once, on the action queue. The card's
    /// stamp must still hold now (and is checked again inside the coordinator).
    private func playDJ(_ plan: DJPlan) -> SceneAction {
        guard plan.stamp == currentDJStamp() else {
            djDrop(saying: djChangedLine)
            return .redraw
        }
        djAskedStamp = nil
        inboxLock.lock(); djInbox = nil; djLive = (-1, -1); inboxLock.unlock()
        let routing = self.routing
        let status = self.status
        let seams = dj
        let stamp = plan.stamp.routing
        actions.run("Play") {
            do {
                switch plan.payload {
                case .artistMix(let mix):
                    try Self.playDJArtistMix(mix, stamp: stamp, routing: routing, status: status)
                case .genreOpen(let queue):
                    try Self.playDJGenreOpen(queue, stamp: stamp, routing: routing, status: status, seams: seams)
                case .genreSpanDAC(let rows, let pick, let title):
                    try Self.playDJGenreSpanDAC(rows: rows, pick: pick, title: title, stamp: stamp,
                                                routing: routing, status: status, seams: seams)
                }
            } catch let error as ActionError {
                throw error
            } catch {
                // ActionRunner reduces anything but an ActionError to "Play failed."
                throw ActionError(message: djErrorText(error))
            }
        }
        return .push(.nowPlaying)
    }

    /// One `slice.queue` of the frozen catalogue ids on a SpanDAC output. The
    /// coordinator refuses the artist-mix origin on the MusicTUI output before
    /// any body runs.
    private static func playDJArtistMix(_ mix: DJArtistMix, stamp: (epoch: Int, dataEpoch: Int),
                                        routing: RoutingCoordinator, status: StatusStore) throws {
        try routing.perform(.discoverTrackPlay, expecting: stamp, origin: .djArtistMix,
            musicApp: { _ in throw ActionError(message: djArtistMixSpanDACOnly) },
            source: { client in
                let skipped = try BridgeMusicProvider(control: client.control).playCatalogue(ids: mix.ids)
                let base = "Playing \(mix.artistName) mix on SpanDAC \u{2014} \(djCount(mix.ids.count, "song"))."
                status.post(skipped > 0 ? base + " " + bridgeUnavailableSongsNotice(skipped) : base,
                            untilStateChange: skipped > 0)
            },
            unaffected: {})
    }

    /// MusicTUI's own data: the app-owned queue, addressed by persistent ID,
    /// set and started exactly as a marked play does.
    private static func playDJGenreOpen(_ queue: AppQueue, stamp: (epoch: Int, dataEpoch: Int),
                                        routing: RoutingCoordinator, status: StatusStore,
                                        seams: DJSeams) throws {
        let store = seams.appQueue
        try routing.perform(.libraryPlay, expecting: stamp, origin: .openData(resultNumber: nil),
            musicApp: { path in
                guard path == .shipped else { throw ActionError(message: pickASpanDACOutput) }
                store.set(queue)
                guard seams.playFirst(queue) else {
                    store.clear()
                    throw ActionError(message: "Couldn't play '\(queue.contextLabel)'.")
                }
                status.post(LibraryProvenance.playingOnMusicTUI(queue.contextLabel))
            },
            source: { _ in throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) },
            unaffected: {})
    }

    /// SpanDAC's data: the library rows, queued by library id on a SpanDAC
    /// output (as a combined play), or handed to the MusicTUI output by
    /// verified alias. The library is re-checked first; a changed one plays nothing.
    private static func playDJGenreSpanDAC(rows: [MusicRow], pick: DJSpanDACGenrePick, title: String,
                                           stamp: (epoch: Int, dataEpoch: Int), routing: RoutingCoordinator,
                                           status: StatusStore, seams: DJSeams) throws {
        do {
            try seams.spandacGenre(routing.dataClient()).recheck(pick)
        } catch let error as DJGenreSourceError {
            throw ActionError(message: error.message)
        } catch {
            throw ActionError(message: DJGenreSourceError.failed(djErrorText(error)).message)
        }
        try routing.perform(.libraryPlay, expecting: stamp, origin: .spandacLibrary,
            musicApp: { path in
                guard path == .handoff else { throw ActionError(message: pickASpanDACOutput) }
                guard rows.allSatisfy({ $0.alias != nil }) else { throw ActionError(message: djGenreNeedsAliases) }
                let report = try playThroughHandoff(seams.handoff, rows: rows, startAt: 1, startRequired: false,
                                                    shuffle: false, title: title)
                status.post(LibraryProvenance.playingOnMusicTUI(title, report: report),
                            untilStateChange: report.notice != nil)
            },
            source: { client in
                let played = try spanDACOutputPlayer(client).playRetainingToken(ids: rows.map(\.id), startRequired: false)
                routing.recordSpanDACPlay(rows, token: played.queueToken, shuffled: played.skippedUnavailable > 0)
                let base = "Playing \(title) on SpanDAC \u{2014} \(djCount(rows.count, "song"))."
                status.post(played.skippedUnavailable > 0
                                ? base + " " + bridgeUnavailableSongsNotice(played.skippedUnavailable) : base,
                            untilStateChange: played.skippedUnavailable > 0)
            },
            unaffected: {})
    }

    // MARK: render

    /// The DJ box: the line to type in, the line saying where things stand, and
    /// a picker when there is one. No art panel, and any cover still placed is deleted.
    private func renderDJ(_ model: DJBoxModel, frame: ShellFrame) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let width = max(1, frame.width - 2)
        let prefix = DJBoxModel.boxPrefix
        let room = max(1, width - prefix.count - DJBoxModel.caret.count)
        let shown = model.text.count > room ? "\u{2026}" + String(model.text.suffix(max(0, room - 1))) : model.text
        out += ANSICode.moveTo(row: frame.bodyY, col: 2)
            + "\(ANSICode.cyan)\(prefix)\(ANSICode.reset)\(ANSICode.brightWhite)\(shown)\(DJBoxModel.caret)\(ANSICode.reset)"
        if frame.bodyHeight > 1 {
            let words = DJBoxModel.clean(model.statusLine ?? "Ask for an artist mix, or a genre you haven't heard lately.")
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 2)
                + "\(ANSICode.dim)\(truncText(words, to: width))\(ANSICode.reset)"
        }
        if case .pick(let picker) = model.stage {
            for (i, hit) in picker.hits.enumerated() where 2 + i < frame.bodyHeight {
                let selected = i == picker.cursor
                let label = DJBoxModel.clean((selected ? "\u{25B8} " : "  ") + hit.title)
                out += ANSICode.moveTo(row: frame.bodyY + 2 + i, col: 2)
                    + (selected
                        ? "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(label, to: width))\(ANSICode.reset)"
                        : truncText(label, to: width))
            }
        }
        art.dropDemand()
        if let last = lastPlaced {
            out += kittyDeleteEscape(id: last.id)
            lastPlaced = nil
        }
        return out
    }
}

// The Radio tab: Favorites · Live · Personal, cycled with [ / ].
// Playback is the music:// scheme rewrite (StationPlayback). Favorites carry
// their own url+name so this tab paints and plays with NO network and NO token —
// Live/Personal/search degrade to an honest message instead.
//
// Slice 3, Part 2 (P5): every catalogue read and the station play go through
// the provider seam, chosen per action by `routing.choose` — the REST catalogue
// and opener wrapped in an `OpenMusicProvider` (D4) with Music.app selected, a
// `BridgeMusicProvider` with Bridge selected. Every async result carries the
// epoch its provider was chosen at, and one from before a committed output
// switch is dropped when it drains (D3). Favourites stay local in both modes.
import Foundation

final class RadioScene: Scene {
    let id: SceneID = .radio
    let tabTitle = "Radio"

    private var nav = RadioNav.initial
    private let store: StationStore
    private let routing: RoutingCoordinator
    /// Music.app mode's station catalogue (a developer key, `makeCatalog()`).
    /// Read only through `open`, never directly: with Bridge selected nothing
    /// here is reached, key or no key (P5).
    private let catalog: RadioCatalog?
    private let opener: Opener

    // Internal read, private write: a test reads what landed (P5).
    private(set) var live: [Station] = []
    private(set) var personal: [Station] = []
    private var searchHits: [Station] = []
    private(set) var liveLoaded = false
    private(set) var personalLoaded = false
    /// The routing epoch Live and Personal were fetched for. When
    /// `routing.epoch` moves (a committed output switch), both lists are
    /// cleared and fetched again from the new output (D3).
    private var browseEpoch: Int
    /// Which async results were dropped as stale ("live", "personal",
    /// "search", "lookup"), in drain order. Main-thread only. Nothing reads it
    /// but tests: a drop is otherwise silent by design, and a test has to be
    /// able to tell "dropped" from "not arrived yet".
    private(set) var staleDrops: [String] = []

    /// The shown sentence when a `/` search was answered by the output the
    /// person has since switched away from (D10).
    static let staleSearchMessage = "✗ Output changed while searching; search again."

    // Raw text entry. `searching` is the `/` catalog-search flow — a network
    // call fired on Enter (never live per-keystroke; there is no local list to
    // filter). `adding` is the `a` flow — add a station by URL only; a
    // non-URL input redirects the user to `/` instead of silently searching.
    private var searching = false
    private var searchText = ""
    private var adding = false
    private var addText = ""
    // Internal, not private, so a test can read the refusal a person sees.
    var message: String?
    private var searchInFlight = false

    // Off-thread catalog fetches — mirrors LibraryScene's `Thread.detachNewThread`
    // + inbox-under-lock + tick()-drain discipline. RadioCatalog blocks up to 20s
    // per call on its injected fetch's DispatchSemaphore; calling it synchronously
    // on the main thread (as tick()/commitAddURL()/commitSearch() used to) freezes
    // the whole shell loop — no repaint, no input, `q` doesn't quit — because
    // Shell.swift only calls KeyPress.read() AFTER scene.tick() returns. Every
    // field below that a background thread touches is written only under
    // `inboxLock`; every field tick()/handle()/commitAddURL()/commitSearch()
    // write directly (live, personal, message, searchHits, *Loaded,
    // searchInFlight) is main-thread-only, matching LibraryScene's split
    // between inbox state and scene state.
    private let inboxLock = NSLock()
    private var liveFetchStarted = false
    private var liveInbox: BrowsePost? = nil
    private var personalFetchStarted = false
    private var personalInbox: BrowsePost? = nil
    // commitAddURL's add path: the favorite is added synchronously from the
    // slug (no network, so it's never lost), then the chosen provider's
    // station(id:) enriches it in the background. store.add() replaces-by-id,
    // so a landed enrichment can only upgrade the existing favorite in place,
    // never duplicate it.
    private var resolveInbox: (epoch: Int, station: Station)? = nil
    // commitSearch's search path.
    private var searchInbox: (epoch: Int, term: String, hits: [Station], failure: String?)? = nil
    /// How many posts each inbox has been OFFERED ("live", "personal",
    /// "lookup", "search"), accepted or not. Under `inboxLock`. Nothing reads
    /// it but tests: it is how a test knows a background post has been written
    /// before it ticks, so the order two posts arrive in can be pinned.
    private var offered: [String: Int] = [:]
    func postsOffered(_ kind: String) -> Int {
        inboxLock.lock(); defer { inboxLock.unlock() }
        return offered[kind, default: 0]
    }

    /// One Live or Personal read, stamped with the epoch its provider was
    /// chosen at. `failure` is set only on Bridge: open mode keeps its shipped
    /// `try?` → empty.
    private struct BrowsePost {
        let epoch: Int
        let stations: [Station]
        let failure: String?
    }

    // Real hero covers: store owns fetch/cache/render; onReady sets artDirty
    // under inboxLock (same discipline as the streaming inboxes above) and
    // tick drains it into `changed` so the swap paints on the next frame.
    // Mirrors LibraryScene/PlaylistsScene exactly.
    private let artwork = ArtworkStore()
    private var artDirty = false
    private let kittyEnabled: Bool
    // Placement-dedup (render-thread-only): the last kitty placement this
    // scene emitted. Reset in artPlacementsInvalidated() on every tab switch.
    private var lastPlaced: ArtPlacement? = nil
    // Rail scroll offset. Self-corrects each render against nav.cursor (same
    // clamp idiom as LibraryScene's renderArtistList/renderSongList) — no
    // explicit reset needed on sub-view switch since nav.cursor resets to 0
    // there and 0 is always < any positive railScroll.
    private var railScroll = 0

    init(routing: RoutingCoordinator,
store: StationStore, catalog: RadioCatalog?,
         opener: Opener = SystemOpener(), kittyEnabled: Bool = false) {
        self.routing = routing
        self.store = store
        self.catalog = catalog
        self.opener = opener
        self.kittyEnabled = kittyEnabled
        self.browseEpoch = routing.epoch
    }

    /// Music.app mode's provider: the catalogue and opener this scene was
    /// given, wrapped (D4), so availability is still `catalog != nil` and
    /// every read reaches the same object as it ships.
    private var open: OpenMusicProvider {
        OpenMusicProvider(discover: nil, catalog: catalog, opener: opener)
    }

    /// Chooses the station provider for `action` under the coordinator's
    /// ordering boundary. Only construction happens inside it; the caller's
    /// round trip runs afterwards, outside the boundary.
    private static func chooseStations(_ action: MusicTUIAction, routing: RoutingCoordinator,
                                       open: OpenMusicProvider) throws -> ProviderChoice<StationProviding> {
        try routing.choose(action,
                           musicApp: { open },
                           source: { BridgeMusicProvider(control: $0.control) })
    }

    func artPlacementsInvalidated() { lastPlaced = nil }

    var capturesAllInput: Bool { searching || adding }

    var footerHint: String {
        if adding { return "Paste a station URL  Enter Add  Esc Cancel" }
        if searching { return "Enter Search  Esc Cancel" }
        return "[ ] View  Enter Play  f Favorite  / Search  a Add URL"
    }

    private var rows: [Station] {
        if !searchHits.isEmpty { return searchHits }
        switch nav.subView {
        case .favorites: return store.favorites()
        case .live:      return live
        case .personal:  return personal
        }
    }

    private var selection: Station? {
        let r = rows
        guard nav.cursor >= 0, nav.cursor < r.count else { return nil }
        return r[nav.cursor]
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Raw text entry FIRST — before vimAlias, or typed letters get eaten by
        // navigation (the 3.6.0 gotcha; see docs/playbook.md).
        if adding {
            switch key {
            case .enter:  commitAddURL(); adding = false; addText = ""
            case .escape: adding = false; addText = ""; message = nil
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !addText.isEmpty { addText.removeLast() }
            case .char(let c): addText.append(c)
            case .space: addText.append(" ")
            default: break
            }
            return .redraw
        }

        if searching {
            switch key {
            case .enter:  commitSearch(); searching = false; searchText = ""
            case .escape: searching = false; searchText = ""; message = nil
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !searchText.isEmpty { searchText.removeLast() }
            case .char(let c): searchText.append(c)
            case .space: searchText.append(" ")
            default: break
            }
            return .redraw
        }

        let key = vimAlias(key, listScene: true)

        // Esc here (NOT the `searching`/`adding` branches above, which handle
        // their own Esc) clears an active search back to the current sub-view.
        // With no search active there's nothing to clear, so it's a no-op —
        // this must NOT eat Esc for anything else.
        if key == .escape {
            guard !searchHits.isEmpty else { return .none }
            searchHits = []
            nav.cursor = 0
            message = nil
            return .redraw
        }

        let rKey: RadioKey
        switch key {
        case .up:    rKey = .up
        case .down:  rKey = .down
        case .enter, .right: rKey = .enter
        case .char("["):
            // Switching sub-views while search results are showing would
            // otherwise leave `rows` still pinned to `searchHits` (see the
            // `rows` computed property) — the view would appear not to
            // switch at all. Clear the search along with the message that
            // describes it.
            searchHits = []; message = nil
            rKey = .switchPrev
        case .char("]"):
            searchHits = []; message = nil
            rKey = .switchNext
        case .char("f"): rKey = .toggleFav
        case .char("/"): searching = true; searchText = ""; message = nil; return .redraw
        case .char("a"): adding = true; addText = ""; message = nil; return .redraw
        default: return .none
        }

        let (next, action) = radioReduce(nav, rKey, itemCount: rows.count, selection: selection)
        nav = next
        execute(action)
        return .redraw
    }

    // Internal, not private, so the routing binding is reachable from a test.
    func execute(_ action: RadioAction) {
        switch action {
        case .none:
            break
        case .play(let s):
            // Spec 6.3: Radio Enter is Served natively. Both branches are real,
            // so the coordinator picks inside its own lock rather than this call
            // site reading the mode and hoping it holds still.
            //
            // A station Apple's catalogue does not carry refuses here and is
            // never played on Music.app instead (ruling 17). The refusal says so
            // in its own words, which is why they are not replaced with a label.
            do {
                try routing.perform(.radioStationPlay,
                    musicApp: { try playStation(s, via: opener) },
                    source: {
                        // D2: the provider rethrows `SourceAppError`
                        // unchanged, so the refusal below reads as before.
                        try BridgeMusicProvider(control: $0.control)
                            .playStation(id: s.id, name: s.name, url: s.url)
                    },
                    unaffected: {})
                message = "▶ \(s.name)"
            } catch let error as SourceAppError {
                message = "✗ " + error.message
            } catch let error as ActionError {
                message = "✗ " + error.message
            } catch {
                message = "✗ Couldn't start \(s.name)"
            }
        case .toggleFavorite(let s):
            do { try store.toggle(s) } catch { message = "✗ Couldn't save favorite" }
        }
    }

    /// `a` add-by-URL. URL detection is by SCHEME PREFIX only — not a
    /// heuristic. Anything without an http/https/music:// prefix is not a
    /// station URL, full stop; it redirects the user to `/` rather than being
    /// guessed at as a search term (search lives on `/` now).
    ///
    /// Used to call the catalog SYNCHRONOUSLY here, which runs on the main
    /// thread inside handle() — the same freeze as tick()'s old
    /// liveStations()/personalStation() calls, just triggered by Enter instead
    /// of tab entry. resolve() is now backgrounded; results land via
    /// `resolveInbox` and are applied in tick().
    private func commitAddURL() {
        let input = addText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        let isURL = ["http://", "https://", "music://"].contains { input.hasPrefix($0) }
        guard isURL else {
            message = "✗ Not a station URL — press / to search"
            return
        }
        guard stationPlayURL(input) != nil, let p = parseStationURL(input) else {
            message = "✗ Not an Apple Music station URL"
            return
        }
        // Add immediately from the slug — no network involved, so the
        // favorite is never lost even when resolve() is slow or the API
        // can't find it at all (BBC Radio 1 is unresolvable by design; the
        // API is an enrichment, never a dependency). resolve() then runs in
        // the background and upgrades the name/artwork in place if it lands.
        let fallback = Station(
            id: p.id, name: displayNameFromSlug(p.slug), url: input,
            isLive: nil, artworkURL: nil)
        do {
            try store.add(fallback)
            message = "★ \(fallback.name)"
        } catch {
            message = "✗ Couldn't save favorite"
            return
        }
        // Enrichment through the provider chosen for `.radioStationLookup`,
        // chosen on the lookup's own thread so a playback action holding the
        // ordering lock cannot stall this keypress. `try?` in BOTH modes: this
        // enriches a favourite already saved, as ships, and a failure leaves
        // the slug name, which is not a fallback to another output. Music.app
        // mode with no key reaches nothing, exactly as before.
        let id = p.id
        let routing = self.routing
        let open = self.open
        Thread.detachNewThread { [weak self] in
            guard let choice = try? Self.chooseStations(.radioStationLookup, routing: routing, open: open),
                  choice.provider.catalogueAvailable,
                  let resolved = (try? choice.provider.station(id: id)) ?? nil else { return }
            guard let self else { return }
            self.inboxLock.lock()
            self.offered["lookup", default: 0] += 1
            if Self.mayReplace(self.resolveInbox?.epoch, with: choice.epoch) {
                self.resolveInbox = (choice.epoch, resolved)
            }
            self.inboxLock.unlock()
        }
    }

    /// `/` catalog search. Backgrounded — calling the catalog synchronously
    /// here would run on the main thread inside handle() and freeze the whole
    /// shell loop (same hazard as commitAddURL's resolve() above). Results
    /// land via `searchInbox` and are applied in tick().
    private func commitSearch() {
        let input = searchText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        // WHERE the search goes is the coordinator's decision, asked here rather
        // than inferred from an environment variable read at launch (step 3).
        //
        // **Only the CHOICE happens inside the lock; the round trip does not.**
        // Holding the ordering lock across a network call would let a slow
        // search block a mode switch. The result carries the epoch it was
        // chosen at, and one answered by the output the person has since
        // switched away from is shown as stale, never as hits (P5).
        let choice: ProviderChoice<StationProviding>
        do {
            choice = try Self.chooseStations(.radioSearch, routing: routing, open: open)
        } catch let error as ActionError {
            message = "✗ " + error.message
            return
        } catch {
            message = "✗ Search failed"
            return
        }
        // Music.app mode with no developer key: unchanged, and the only state
        // that still refuses here.
        guard choice.provider.catalogueAvailable else {
            message = "✗ Search needs auth (music auth setup)"
            return
        }
        searchInFlight = true
        message = "Searching \u{201C}\(input)\u{201D}\u{2026}"
        let term = input
        let provider = choice.provider
        let epoch = choice.epoch
        Thread.detachNewThread { [weak self] in
            var hits: [Station] = []
            var failure: String? = nil
            do {
                // 25 is what both shipped searches asked for: the REST
                // catalogue fixes it itself, and the Bridge request bytes are
                // the old adapter's (P1).
                hits = try provider.searchStations(term: term, limit: 25)
            } catch let sourceApp as SourceAppError {
                // The source app's refusals say something a person can act on
                // ("not running"), so they are carried through rather than
                // flattened into the generic failure the REST route reports.
                failure = sourceApp.message
            } catch {
                failure = "Search failed"
            }
            guard let self else { return }
            self.inboxLock.lock()
            self.offered["search", default: 0] += 1
            if Self.mayReplace(self.searchInbox?.epoch, with: epoch) {
                self.searchInbox = (epoch, term, hits, failure)
            }
            self.inboxLock.unlock()
        }
    }

    private enum Browse { case live, personal }

    /// Every inbox is ONE slot, so its writes are epoch-monotonic: a post
    /// replaces what is waiting only when its epoch is at least as new. Last
    /// writer wins was the defect (Codex, Part 2 review): after a switch, the
    /// new output's post could land first and the old output's after it; the
    /// stale one took the slot, the drain dropped it, the fetch flags stayed
    /// set, and the fresh result was lost with no retry. Call under `inboxLock`.
    private static func mayReplace(_ storedEpoch: Int?, with incoming: Int) -> Bool {
        guard let storedEpoch else { return true }
        return incoming >= storedEpoch
    }

    /// One Live or Personal read. The CHOICE runs here, on the fetch thread,
    /// never on the main thread: a playback action can hold the ordering lock
    /// for seconds, and the shell loop must keep painting meanwhile (P5).
    ///
    /// A provider that cannot read the catalogue (Music.app mode with no key)
    /// fetches nothing and posts nothing, exactly as today. Open mode keeps
    /// its shipped `try?` → empty. Bridge mode posts a failure's own words, so
    /// a Bridge that cannot answer is never shown as an empty list (D4).
    private func startBrowse(_ which: Browse) {
        let routing = self.routing
        let open = self.open
        let requested = browseEpoch
        Thread.detachNewThread { [weak self] in
            let post: BrowsePost
            do {
                let choice = try Self.chooseStations(.radioCatalogueBrowse, routing: routing, open: open)
                guard choice.provider.catalogueAvailable else { return }
                let provider = choice.provider
                let read: () throws -> [Station] = {
                    which == .live ? try provider.liveStations() : try provider.personalStations()
                }
                switch choice.mode {
                case .musicApp:
                    post = BrowsePost(epoch: choice.epoch, stations: (try? read()) ?? [], failure: nil)
                case .source:
                    do {
                        post = BrowsePost(epoch: choice.epoch, stations: try read(), failure: nil)
                    } catch {
                        post = BrowsePost(epoch: choice.epoch, stations: [], failure: Self.words(for: error))
                    }
                }
            } catch {
                post = BrowsePost(epoch: requested, stations: [], failure: Self.words(for: error))
            }
            guard let self else { return }
            self.inboxLock.lock()
            self.offered[which == .live ? "live" : "personal", default: 0] += 1
            if which == .live {
                if Self.mayReplace(self.liveInbox?.epoch, with: post.epoch) { self.liveInbox = post }
            } else {
                if Self.mayReplace(self.personalInbox?.epoch, with: post.epoch) { self.personalInbox = post }
            }
            self.inboxLock.unlock()
        }
    }

    /// A Bridge-mode browse failure in the words its error carries: the
    /// provider's translated sentence, or the coordinator's refusal.
    private static func words(for error: Error) -> String {
        if let e = error as? MusicProviderError, let why = e.errorDescription { return why }
        if let e = error as? ActionError { return e.message }
        if let e = error as? SourceAppError { return e.message }
        return error.localizedDescription
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        // A committed output switch since the lists were fetched: they came
        // from the output just left, so they go, and are fetched again from
        // the new one (D3). Read once, and every drain below is judged against
        // the same value.
        let epoch = routing.epoch
        if epoch != browseEpoch {
            browseEpoch = epoch
            live = []; personal = []
            liveLoaded = false; personalLoaded = false
            liveFetchStarted = false; personalFetchStarted = false
            changed = true
        }

        // Live/Personal are fetched once per epoch, off-thread, kicked on the
        // first tick after the tab is entered — same one-shot pattern as
        // LibraryScene's loadAlbums/loadSongs/loadArtists. Favorites need no
        // fetch — they're already on disk. Which output answers is chosen on
        // the fetch thread; Music.app mode with no catalog/token reads nothing.
        if !liveFetchStarted {
            liveFetchStarted = true
            startBrowse(.live)
        }
        if !personalFetchStarted {
            personalFetchStarted = true
            startBrowse(.personal)
        }

        inboxLock.lock()
        let freshLive = liveInbox; liveInbox = nil
        let freshPersonal = personalInbox; personalInbox = nil
        let freshResolve = resolveInbox; resolveInbox = nil
        let freshSearch = searchInbox; searchInbox = nil
        let artLanded = artDirty; artDirty = false
        inboxLock.unlock()

        if let freshLive {
            if freshLive.epoch != epoch { staleDrops.append("live") }
            else {
                live = freshLive.stations; liveLoaded = true; changed = true
                if let failure = freshLive.failure { message = "✗ " + failure }
            }
        }
        if let freshPersonal {
            if freshPersonal.epoch != epoch { staleDrops.append("personal") }
            else {
                personal = freshPersonal.stations; personalLoaded = true; changed = true
                if let failure = freshPersonal.failure { message = "✗ " + failure }
            }
        }
        if let freshResolve {
            if freshResolve.epoch != epoch { staleDrops.append("lookup") }
            else {
                try? store.add(freshResolve.station)
                message = "★ \(freshResolve.station.name)"
                changed = true
            }
        }
        if let freshSearch, freshSearch.epoch != epoch {
            staleDrops.append("search")
            searchInFlight = false
            searchHits = []
            message = Self.staleSearchMessage
            changed = true
        } else if let freshSearch {
            searchInFlight = false
            searchHits = freshSearch.hits
            message = freshSearch.failure.map { "✗ \($0)" }
                ?? (freshSearch.hits.isEmpty
                    ? "No stations for \u{201C}\(freshSearch.term)\u{201D} — try pasting the station URL"
                    : "Search \u{201C}\(freshSearch.term)\u{201D} — \(freshSearch.hits.count) result(s) \u{00B7} f favorite \u{00B7} Esc clear")
            changed = true
        }
        if artLanded { changed = true }
        return changed
    }

    /// True when the active sub-view's list hasn't landed yet, so the render
    /// side can show an honest "Loading…" instead of a bare empty list. With no
    /// catalog/token nothing will ever load, so this reads false forever rather
    /// than spinning — Favorites (the only sub-view this applies to: false) must
    /// always work with no network and no token. With Bridge selected a list
    /// always loads (or fails in words). Display only: the mode read here
    /// decides no route.
    private var loading: Bool {
        guard routing.mode == .source || catalog != nil else { return false }
        switch nav.subView {
        case .favorites: return false
        case .live: return !liveLoaded
        case .personal: return !personalLoaded
        }
    }

    // MARK: render

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        // Row bodyTop: Favorites · Live · Personal (active = cyan/bold), same
        // idiom as LibraryScene's subViewHeader — swapped for "Search Results"
        // while a search is active (searchHits non-empty), since `rows` then
        // reads from searchHits instead of the sub-view lists below.
        out += ANSICode.moveTo(row: bodyTop, col: z.railX) + radioSubViewHeader()

        // Row bodyTop+1: raw text capture — `/` search or `a` add-by-URL.
        // Mutually exclusive (capturesAllInput routes every key to whichever
        // is active), mirrors LibraryScene's single reserved filter row.
        if adding {
            out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
            out += "\(ANSICode.cyan)add\u{203A}\(ANSICode.reset) \(ANSICode.brightWhite)\(addText)\(ANSICode.reset)\u{2588}"
        } else if searching {
            out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(searchText)\(ANSICode.reset)\u{2588}"
        }

        // Row bodyTop+2: the scene's own status line — search-result counts,
        // add confirmations, favorite errors. Distinct from the shell's global
        // toast (footer); this is Radio's own transient message state.
        if let m = message {
            out += ANSICode.moveTo(row: bodyTop + 2, col: z.railX)
            out += "\(ANSICode.dim)\(truncText(m, to: max(1, frame.width - z.railX)))\(ANSICode.reset)"
        }

        let contentTop = bodyTop + 3
        guard contentTop <= bodyBottom else { return out }

        renderRail(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
        renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom, cellW: frame.cellW, cellH: frame.cellH)
        return out
    }

    private func radioSubViewName(_ sv: RadioSubView) -> String {
        switch sv {
        case .favorites: return "Favorites"
        case .live: return "Live"
        case .personal: return "Personal"
        }
    }

    private func radioSubViewHeader() -> String {
        guard searchHits.isEmpty else {
            return "\(ANSICode.bold)\(ANSICode.cyan)Search Results\(ANSICode.reset)  \(ANSICode.dim)f favorite \u{00B7} Esc clear\(ANSICode.reset)"
        }
        return RadioSubView.allCases.map { sv -> String in
            let name = radioSubViewName(sv)
            return sv == nav.subView
                ? "\(ANSICode.bold)\(ANSICode.cyan)\(name)\(ANSICode.reset)"
                : "\(ANSICode.dim)\(name)\(ANSICode.reset)"
        }.joined(separator: "\(ANSICode.dim)  \u{00B7}  \(ANSICode.reset)")
    }

    /// Flat station list in the rail zone — same cursor/scroll idiom as
    /// LibraryScene's renderArtistList/renderSongList (Radio never drills into
    /// a station, so there's no album-rail-style highlight split).
    /// `[LIVE]` and `★` (already-favorited) are plain-text suffixes on the
    /// label, appended AFTER truncation so a long name never eats the marker —
    /// kept uncolored, like every other rail label, so the row's single
    /// dim/inverse wrap isn't broken by an embedded reset mid-string.
    private func renderRail(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        let listY = contentTop
        let maxVisible = max(1, bodyBottom - listY + 1)
        let vis = rows
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX)
            let msg: String
            if loading { msg = "Loading\u{2026}" }
            else {
                switch nav.subView {
                case .favorites: msg = "(no favorites — press a to add)"
                case .live: msg = "(no live stations)"
                case .personal: msg = "(no personal stations)"
                }
            }
            out += "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
            return
        }
        let cursorPos = min(max(0, nav.cursor), vis.count - 1)
        if cursorPos < railScroll { railScroll = cursorPos }
        if cursorPos >= railScroll + maxVisible { railScroll = cursorPos - maxVisible + 1 }
        let end = min(vis.count, railScroll + maxVisible)
        let nameWidth = max(1, z.railWidth - 2)
        for p in railScroll..<end {
            let row = listY + (p - railScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let s = vis[p]
            let markers = (s.isLive == true ? " [LIVE]" : "") + (store.isFavorite(id: s.id) ? " \u{2605}" : "")
            let availWidth = max(1, nameWidth - markers.count)
            let nm = railName(s.name, nameWidth: availWidth) + markers
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if p == cursorPos {
                out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset)"
            } else {
                out += "  \(ANSICode.dim)\(padName)\(ANSICode.reset)"
            }
        }
    }

    /// Station hero: name, a LIVE badge (never a progress bar — live stations
    /// carry no duration/position, hard design rule) or a favorited hint, then
    /// artwork via the shared renderArtHero ladder (kitty → chafa → gradient
    /// identicon, same as LibraryScene/PlaylistsScene), then key hints.
    private func renderHero(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int,
                            cellW: Double, cellH: Double) {
        guard let s = selection else { return }
        var y = contentTop
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(s.name, to: z.heroWidth))\(ANSICode.reset)"
        y += 1

        out += ANSICode.moveTo(row: y, col: z.heroX)
        if s.isLive == true {
            out += "\(ANSICode.red)\(ANSICode.inverse)\(ANSICode.bold) LIVE \(ANSICode.reset)"
        } else if store.isFavorite(id: s.id) {
            out += "\(ANSICode.dim)\u{2605} Favorite\(ANSICode.reset)"
        }
        y += 2

        // Fill the hero pane, square: the full hero width and every row left
        // after the art (2 reserved below — blank + hint; Radio has no
        // track-count line, unlike LibraryScene's 4). kittySquareRect derives
        // the actual square placement from whichever of gw/gh binds tighter.
        let gw = z.heroWidth
        let gh = max(0, bodyBottom - y - 2)
        var artBlock: ArtBlock? = nil
        if let template = s.artworkURL {
            artBlock = artwork.block(key: s.id,
                                     url: ArtworkStore.resolveURL(template, width: 300, height: 300),
                                     // Degenerate geometry skips the kitty path — see
                                     // LibraryScene's identical guard.
                                     width: gw, height: gh, kitty: kittyEnabled && gw > 0 && gh > 0) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        let (afterArtY, placed) = renderArtHero(artBlock: artBlock, gradientSeedText: s.name + s.id,
                                                gw: gw, gh: gh, x: z.heroX, y: y,
                                                cellW: cellW, cellH: cellH,
                                                lastPlaced: lastPlaced, into: &out)
        y = afterArtY
        lastPlaced = placed
        y += 1

        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Play   \(ANSICode.lime)[f]\(ANSICode.reset) Favorite   \(ANSICode.lime)[/]\(ANSICode.reset) Search"
    }
}

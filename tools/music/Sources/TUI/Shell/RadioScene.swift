// The Radio tab: Favorites · Live · Personal, cycled with [ / ].
// Playback is the music:// scheme rewrite (StationPlayback). Favorites carry
// their own url+name so this tab paints and plays with NO network and NO token —
// Live/Personal/search degrade to an honest message instead.
import Foundation

final class RadioScene: Scene {
    let id: SceneID = .radio
    let tabTitle = "Radio"

    private var nav = RadioNav.initial
    private let store: StationStore
    private let catalog: RadioCatalog?
    private let opener: Opener

    private var live: [Station] = []
    private var personal: [Station] = []
    private var searchHits: [Station] = []
    private var liveLoaded = false
    private var personalLoaded = false

    // Raw text entry. `capturing` mirrors LibraryScene's filter capture; `adding`
    // is the `a` flow (URL or search term).
    private var capturing = false
    private var filter = ""
    private var adding = false
    private var addText = ""
    private var message: String?
    private var searchInFlight = false

    // Off-thread catalog fetches — mirrors LibraryScene's `Thread.detachNewThread`
    // + inbox-under-lock + tick()-drain discipline. RadioCatalog blocks up to 20s
    // per call on its injected fetch's DispatchSemaphore; calling it synchronously
    // on the main thread (as tick()/commitAdd() used to) freezes the whole shell
    // loop — no repaint, no input, `q` doesn't quit — because Shell.swift only
    // calls KeyPress.read() AFTER scene.tick() returns. Every field below that a
    // background thread touches is written only under `inboxLock`; every field
    // tick()/handle()/commitAdd() write directly (live, personal, message,
    // searchHits, *Loaded, searchInFlight) is main-thread-only, matching
    // LibraryScene's split between inbox state and scene state.
    private let inboxLock = NSLock()
    private var liveFetchStarted = false
    private var liveInbox: [Station]? = nil
    private var personalFetchStarted = false
    private var personalInbox: [Station]? = nil
    // commitAdd's URL-add path: the favorite is added synchronously from the
    // slug (no network, so it's never lost), then resolve() enriches it in the
    // background. store.add() replaces-by-id, so a landed enrichment can only
    // upgrade the existing favorite in place, never duplicate it.
    private var resolveInbox: Station? = nil
    // commitAdd's search path.
    private var searchInbox: (term: String, hits: [Station], failed: Bool)? = nil

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

    init(store: StationStore, catalog: RadioCatalog?, opener: Opener = SystemOpener(),
         kittyEnabled: Bool = false) {
        self.store = store
        self.catalog = catalog
        self.opener = opener
        self.kittyEnabled = kittyEnabled
    }

    func artPlacementsInvalidated() { lastPlaced = nil }

    var capturesAllInput: Bool { capturing || adding }

    var footerHint: String {
        if adding { return "Enter Save/Search  Esc Cancel" }
        if capturing { return "type to filter  Enter Apply  Esc Clear" }
        return "[ ] View  Enter Play  f Favorite  a Add/Search  / Filter"
    }

    private var rows: [Station] {
        let base: [Station]
        if !searchHits.isEmpty {
            base = searchHits
        } else {
            switch nav.subView {
            case .favorites: base = store.favorites()
            case .live:      base = live
            case .personal:  base = personal
            }
        }
        guard !filter.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(filter) }
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
            case .enter:  commitAdd(); adding = false; addText = ""
            case .escape: adding = false; addText = ""; message = nil
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !addText.isEmpty { addText.removeLast() }
            case .char(let c): addText.append(c)
            case .space: addText.append(" ")
            default: break
            }
            return .redraw
        }

        if capturing {
            switch key {
            case .enter:  capturing = false
            case .escape: capturing = false; filter = ""; nav.cursor = 0
            case .up:     nav.cursor = max(0, nav.cursor - 1)
            case .down:   nav.cursor = min(max(0, rows.count - 1), nav.cursor + 1)
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filter.isEmpty { filter.removeLast() }; nav.cursor = 0
            case .char(let c): filter.append(c); nav.cursor = 0
            case .space: filter.append(" "); nav.cursor = 0
            default: break
            }
            return .redraw
        }

        let key = vimAlias(key, listScene: true)

        // Esc here (NOT the `capturing`/`adding` branches above, which handle
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
        case .char("/"): capturing = true; return .redraw
        case .char("a"): adding = true; addText = ""; message = nil; return .redraw
        default: return .none
        }

        let (next, action) = radioReduce(nav, rKey, itemCount: rows.count, selection: selection)
        nav = next
        execute(action)
        return .redraw
    }

    private func execute(_ action: RadioAction) {
        switch action {
        case .none:
            break
        case .play(let s):
            do { try playStation(s, via: opener); message = "▶ \(s.name)" }
            catch { message = "✗ Couldn't start \(s.name)" }
        case .toggleFavorite(let s):
            do { try store.toggle(s) } catch { message = "✗ Couldn't save favorite" }
        }
    }

    /// One affordance, two inputs. URL detection is by SCHEME PREFIX only — not
    /// a heuristic. A bare "music.apple.com/..." is treated as a search term and
    /// simply finds nothing; that's predictable. Do not try to be clever here.
    ///
    /// Both branches used to call the catalog SYNCHRONOUSLY here, which runs on
    /// the main thread inside handle() — the same freeze as tick()'s old
    /// liveStations()/personalStation() calls, just triggered by Enter instead
    /// of tab entry. Both are now backgrounded; results land via the inbox
    /// fields above and are applied in tick().
    private func commitAdd() {
        let input = addText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        let isURL = ["http://", "https://", "music://"].contains { input.hasPrefix($0) }
        if isURL {
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
            if let catalog {
                let id = p.id
                Thread.detachNewThread { [weak self] in
                    guard let resolved = (try? catalog.resolve(id: id)) ?? nil else { return }
                    guard let self else { return }
                    self.inboxLock.lock(); self.resolveInbox = resolved; self.inboxLock.unlock()
                }
            }
        } else {
            guard let catalog else { message = "✗ Search needs auth (music auth setup)"; return }
            searchInFlight = true
            message = "Searching \u{201C}\(input)\u{201D}\u{2026}"
            let term = input
            Thread.detachNewThread { [weak self] in
                var hits: [Station] = []
                var failed = false
                do { hits = try catalog.search(term: term) } catch { failed = true }
                guard let self else { return }
                self.inboxLock.lock(); self.searchInbox = (term, hits, failed); self.inboxLock.unlock()
            }
        }
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        // Live/Personal are fetched once, off-thread, kicked on the first tick
        // after the tab is entered — same one-shot pattern as LibraryScene's
        // loadAlbums/loadSongs/loadArtists. Favorites need no fetch — they're
        // already on disk, so this whole block is skipped with no catalog/token.
        if let catalog {
            if !liveFetchStarted {
                liveFetchStarted = true
                Thread.detachNewThread { [weak self] in
                    let fetched = (try? catalog.liveStations()) ?? []
                    guard let self else { return }
                    self.inboxLock.lock(); self.liveInbox = fetched; self.inboxLock.unlock()
                }
            }
            if !personalFetchStarted {
                personalFetchStarted = true
                Thread.detachNewThread { [weak self] in
                    let fetched = (try? catalog.personalStation()) ?? []
                    guard let self else { return }
                    self.inboxLock.lock(); self.personalInbox = fetched; self.inboxLock.unlock()
                }
            }
        }

        inboxLock.lock()
        let freshLive = liveInbox; liveInbox = nil
        let freshPersonal = personalInbox; personalInbox = nil
        let freshResolve = resolveInbox; resolveInbox = nil
        let freshSearch = searchInbox; searchInbox = nil
        let artLanded = artDirty; artDirty = false
        inboxLock.unlock()

        if let freshLive { live = freshLive; liveLoaded = true; changed = true }
        if let freshPersonal { personal = freshPersonal; personalLoaded = true; changed = true }
        if let freshResolve {
            try? store.add(freshResolve)
            message = "★ \(freshResolve.name)"
            changed = true
        }
        if let freshSearch {
            searchInFlight = false
            searchHits = freshSearch.hits
            message = freshSearch.failed
                ? "✗ Search failed"
                : freshSearch.hits.isEmpty
                    ? "No stations for \u{201C}\(freshSearch.term)\u{201D} — try pasting the station URL"
                    : "Search \u{201C}\(freshSearch.term)\u{201D} — \(freshSearch.hits.count) result(s) \u{00B7} f favorite \u{00B7} Esc clear"
            changed = true
        }
        if artLanded { changed = true }
        return changed
    }

    /// True when the active sub-view's list hasn't landed yet, so the render
    /// side can show an honest "Loading…" instead of a bare empty list. With no
    /// catalog/token nothing will ever load, so this reads false forever rather
    /// than spinning — Favorites (the only sub-view this applies to: false) must
    /// always work with no network and no token.
    private var loading: Bool {
        guard catalog != nil else { return false }
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

        // Row bodyTop+1: raw text capture — `/` filter or `a` add/search.
        // Mutually exclusive (capturesAllInput routes every key to whichever
        // is active), mirrors LibraryScene's single reserved filter row.
        if adding {
            out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
            out += "\(ANSICode.cyan)add\u{203A}\(ANSICode.reset) \(ANSICode.brightWhite)\(addText)\(ANSICode.reset)\u{2588}"
        } else if capturing || !filter.isEmpty {
            out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filter)\(ANSICode.reset)\(capturing ? "\u{2588}" : "")"
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
        renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
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

    /// Flat, filterable station list in the rail zone — same cursor/scroll
    /// idiom as LibraryScene's renderArtistList/renderSongList (Radio never
    /// drills into a station, so there's no album-rail-style highlight split).
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
            else if !filter.isEmpty { msg = "(no matches)" }
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
    private func renderHero(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
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

        // Match the Now tab's art size (44×22), clamped to the hero column and
        // to the rows available so the key hints below always fit. Radio has
        // no track-count line (stations aren't albums), so only 2 rows are
        // reserved after the art (blank + hint), vs LibraryScene's 4.
        let gw = min(44, z.heroWidth)
        let gh = max(0, min(22, bodyBottom - y - 2))
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
                                                lastPlaced: lastPlaced, into: &out)
        y = afterArtY
        lastPlaced = placed
        y += 1

        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Play   \(ANSICode.lime)[f]\(ANSICode.reset) Favorite   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }
}

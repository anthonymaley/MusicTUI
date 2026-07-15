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

    init(store: StationStore, catalog: RadioCatalog?, opener: Opener = SystemOpener()) {
        self.store = store
        self.catalog = catalog
        self.opener = opener
    }

    var capturesAllInput: Bool { capturing || adding }

    var footerHint: String {
        if adding { return "Enter Save/Search  Esc Cancel" }
        if capturing { return "type to filter  Enter Apply  Esc Clear" }
        return "[ ] View  Enter Play  f Favorite  a Add/Search  / Filter"
    }

    private var rows: [Station] {
        let base: [Station]
        switch nav.subView {
        case .favorites: base = store.favorites()
        case .live:      base = live
        case .personal:  base = personal
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
            default: break
            }
            return .redraw
        }

        let key = vimAlias(key, listScene: true)

        let rKey: RadioKey
        switch key {
        case .up:    rKey = .up
        case .down:  rKey = .down
        case .enter, .right: rKey = .enter
        case .char("["): rKey = .switchPrev
        case .char("]"): rKey = .switchNext
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
                    : "\(freshSearch.hits.count) result(s) — f to favorite"
            changed = true
        }
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

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        renderRadioBody(frame: frame, subView: nav.subView, rows: rows,
                        cursor: nav.cursor, filter: filter,
                        adding: adding, addText: addText, message: message,
                        loading: loading)
    }
}

// TEMPORARY — replaced in the next task by the rail+hero renderer.
// A plain list is enough to prove keys, reducer, and tab wiring work.
func renderRadioBody(frame: ShellFrame, subView: RadioSubView, rows: [Station],
                     cursor: Int, filter: String, adding: Bool, addText: String,
                     message: String?, loading: Bool) -> String {
    var out = ""
    var y = frame.bodyY
    let put: (String) -> Void = { line in
        out += "\u{1B}[\(y);1H\u{1B}[K" + String(line.prefix(frame.width))
        y += 1
    }
    put("  \(RadioSubView.allCases.map { $0 == subView ? "[\($0)]" : "\($0)" }.joined(separator: "  "))")
    if adding { put("  add> \(addText)") }
    else if !filter.isEmpty { put("  /\(filter)") }
    if let m = message { put("  \(m)") }
    for (i, s) in rows.enumerated() where y < frame.bodyY + frame.bodyHeight {
        put("\(i == cursor ? " ▸ " : "   ")\(s.name)\(s.isLive == true ? "  [LIVE]" : "")")
    }
    // An empty Live/Personal list reads as "no stations" unless the in-flight
    // fetch is called out honestly — the fetch is backgrounded now, so this can
    // paint on the very first frame after entering the tab or switching view.
    if rows.isEmpty { put(loading ? "   Loading\u{2026}" : "   (empty)") }
    return out
}

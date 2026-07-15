// tools/music/Sources/TUI/Shell/LibraryScene.swift
// The Library tab. Albums (three-zone: rail + hero + track preview), Songs (flat
// filterable list), and Artists (flat list → drill into the artist's albums,
// which reuse the album three-zone render) are all wired end to end.
// All navigation is delegated to the pure `libraryReduce`; the scene owns only
// view state (scroll, filter) and executes the emitted LibraryAction off-thread.
import Foundation

/// Normalize an artist name for cross-list matching (album.artist ↔ artist.name).
/// Lowercase + trim only — a deliberately shallow heuristic; compilation credits
/// ("Various Artists") and "feat." strings can still miss, which is why the
/// album-artists filter is opt-in and defaults off.
func normalizeArtist(_ s: String) -> String {
    s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Which track-count tier the Artists list is filtered to. `a` cycles All → 12"/EP
/// → Albums. Tiers are by an album's IN-LIBRARY track count: a lone playlist track
/// is a 1-track stub (in neither tier); 2–5 tracks reads as a 12"/EP; 6+ as a full
/// album. An artist qualifies for a tier by having ≥1 album in it, so an artist
/// with both a 12" and an LP appears in both filtered views.
enum ArtistFilterMode: Equatable {
    case all, epOr12, albums
    var next: ArtistFilterMode {
        switch self {
        case .all: return .epOr12
        case .epOr12: return .albums
        case .albums: return .all
        }
    }
    var label: String {
        switch self {
        case .all: return "All"
        case .epOr12: return "12\"/EP"
        case .albums: return "Albums"
        }
    }
    /// The album track-count range this tier scopes the drilled album list to
    /// (nil = All → no scoping). Same boundaries as the artist-list membership,
    /// so drilling into an artist shows only the albums that put them in the tier.
    var trackRange: ClosedRange<Int>? {
        switch self {
        case .all: return nil
        case .epOr12: return 2...5
        case .albums: return 6...Int.max
        }
    }
}

/// The visible artist rows for the Artists list, as indices into `artists`. The `/`
/// text filter always applies; when `albumArtistNames` is non-nil the artist must
/// also be in that set (the active tier's artists) — nil is the All tier (no album
/// filter). `albumArtistNames` is expected already-normalized (the scene builds it
/// via `normalizeArtist`). Pure, so it's unit-tested without standing up a scene.
func filteredArtistIndices(artists: [LibraryArtist], albumArtistNames: Set<String>?,
                           filter: String) -> [Int] {
    let q = filter.lowercased()
    return (0..<artists.count).filter { i in
        let name = artists[i].name
        if let set = albumArtistNames, !set.contains(normalizeArtist(name)) { return false }
        if !q.isEmpty, !name.lowercased().contains(q) { return false }
        return true
    }
}

/// The set of artists with a library album whose in-library track count is in
/// `minTracks...maxTracks`. Apple makes a 1-track "album" stub for a loose playlist
/// song, so `minTracks: 2` drops those stubs; a `maxTracks` bound splits 12"/EPs
/// (2–5) from full albums (6+). `LibraryAlbum.trackCount` is the library count (a
/// stub reads as 1). Names normalized to match the artist list. Pure → unit-tested.
func albumArtistSet(from albums: [LibraryAlbum], minTracks: Int = 2,
                    maxTracks: Int = .max) -> Set<String> {
    var set = Set<String>()
    for al in albums where al.trackCount >= minTracks && al.trackCount <= maxTracks {
        set.insert(normalizeArtist(al.artist))
    }
    return set
}

/// Visible album rows as indices into `albums`. `trackRange` (non-nil only in the
/// Artists-drill tier views) scopes to albums whose track count is in range so a
/// drill matches the tier it came from; the `/` text filter (name + artist
/// substring) always applies. Pure → unit-tested.
func filteredAlbumIndices(albums: [LibraryAlbum], trackRange: ClosedRange<Int>?,
                          filter: String) -> [Int] {
    let q = filter.lowercased()
    return (0..<albums.count).filter { i in
        let a = albums[i]
        if let r = trackRange, !r.contains(a.trackCount) { return false }
        if !q.isEmpty, !"\(a.name) \(a.artist)".lowercased().contains(q) { return false }
        return true
    }
}

final class LibraryScene: Scene {
    let id: SceneID = .library
    let tabTitle = "Library"
    var capturesAllInput: Bool { capturing }
    var footerHint: String {
        if capturing { return "type to filter  Enter Apply  Esc Clear" }
        // `/` is a no-op at the tracks level, so drop it from the hint there.
        if isTracksLevel { return "[ ] View  Enter Play  \u{2190} Back  p Play  s Shuffle" }
        // Enter plays a song directly (no drill-in), unlike album/artist "Open".
        if isSongList { return "[ ] View  Enter Play  / Filter  p Play  s Shuffle" }
        // The Artists list carries the tier filter; show the active tier.
        if isArtistList {
            return "[ ] View  Enter Open  / Filter  a View: \(artistFilter.label)  p Play  s Shuffle"
        }
        return "[ ] View  Enter Open  / Filter  p Play  s Shuffle"
    }

    private let backend: AppleScriptBackend
    private let sources: LibraryDataSources
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner

    private var nav = LibraryNav.initial
    private var albums: [LibraryAlbum] = []
    private var albumsLoaded = false
    private var albumsFetchStarted = false
    // Songs load lazily the first time the Songs sub-view is shown (unlike albums,
    // which load in init). songsFetchStarted gates the one-shot kick in tick so a
    // slow fetch isn't re-launched every frame.
    private var songs: [LibrarySong] = []
    private var songsLoaded = false
    private var songsFetchStarted = false
    // Artists load lazily the first time the Artists sub-view is shown (same
    // one-shot pattern as Songs). artistAlbums is the drilled-in album list for
    // one artist, refetched each time an artist is opened.
    private var artists: [LibraryArtist] = []
    private var artistsLoaded = false
    private var artistsFetchStarted = false
    private var artistAlbums: [LibraryAlbum] = []
    private var artistAlbumsLoaded = false
    // Album-artists tier filter (`a` on the Artists list cycles All → 12"/EP →
    // Albums). The two sets are the normalized artist names in each tier, built in
    // tick as album pages stream in (so the filter refines live while albums load)
    // and seeded from the SWR cache on first activation. Session-local.
    private var artistFilter: ArtistFilterMode = .all
    private var epArtists: Set<String> = []      // artists with a 2–5 track album (12"/EP)
    private var albumArtists: Set<String> = []   // artists with a 6+ track album
    private var filter = ""
    private var capturing = false
    private var railScroll = 0
    private var trackScroll = 0

    // One track cache keyed by album id, shared by the right-pane preview (album
    // level) and the drilled-in tracks level. Because render always reads the
    // FOCUSED album's cache — never a stale in-flight result — the wrong-album
    // race can't happen, and Enter is instant when the preview already landed.
    // trackCache / previewInFlight are main-thread-only (tick + handle); the
    // background fetch posts to previewInbox under inboxLock and tick drains it
    // (same inbox+NSLock discipline as SpeakersScene / PlaylistsScene).
    private var trackCache: [String: [String]] = [:]
    private var previewInFlight: Set<String> = []
    private let previewQueue = DispatchQueue(label: "music.library.preview")

    private let inboxLock = NSLock()
    // The three paginated lists stream page-by-page for progressive render: the
    // background walk appends each page to `*Pending` under inboxLock; tick drains
    // and appends to the main list, and `*Done` flips `*Loaded` once the walk
    // finishes (so an empty library shows "(no …)" instead of a stuck "Loading …").
    // A single-optional inbox — like artistAlbums/preview below — can't express
    // "first page here, more coming", which is exactly what progressive render needs.
    private var albumsPending: [LibraryAlbum] = []
    private var albumsDone = false
    private var songsPending: [LibrarySong] = []
    private var songsDone = false
    private var artistsPending: [LibraryArtist] = []
    private var artistsDone = false
    // Tagged with the requested artistID so a slow fetch for a since-abandoned
    // artist can be dropped in tick (last-writer-wins guard, like trackCache).
    private var artistAlbumsInbox: (artistID: String, albums: [LibraryAlbum])? = nil
    private var previewInbox: [(id: String, tracks: [String])] = []

    // Real hero covers: store owns fetch/cache/render; onReady sets artDirty
    // under inboxLock (same discipline as the streaming inboxes) and tick
    // drains it into `changed` so the swap paints on the next frame.
    private let artwork = ArtworkStore()
    private var artDirty = false
    private let kittyEnabled: Bool
    // Placement-dedup (render-thread-only, per design doc Feature 2 §3): the
    // last kitty placement this scene emitted, so an unchanged frame emits
    // nothing (the placement persists on screen across text repaints) and a
    // changed one deletes the old placement before drawing the new one.
    private var lastPlaced: (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)? = nil

    init(backend: AppleScriptBackend, sources: LibraryDataSources,
         appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner,
         kittyEnabled: Bool = false) {
        self.backend = backend
        self.sources = sources
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        self.kittyEnabled = kittyEnabled
        // All three sub-view lists load lazily the first time they're shown (see
        // tick). The default sub-view is Artists, so the first tick kicks that;
        // Albums/Songs load only when the user switches to them — no wasted
        // (now-paginated) fetch of a list you never open.
    }

    func artPlacementsInvalidated() { lastPlaced = nil }

    // MARK: background loads

    /// Off-thread streaming album fetch: each page is appended to albumsPending
    /// under inboxLock and drained in tick, so the rail fills in as pages land
    /// rather than after the whole (paginated) walk. The onPage closure returns
    /// false if the scene has deallocated, which aborts the walk. albumsDone is set
    /// once the walk finishes so tick can flip albumsLoaded. Kicked once (guarded
    /// by albumsFetchStarted) when the Albums sub-view first becomes active.
    private func loadAlbums() {
        albumsFetchStarted = true
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            sources.onAlbums { page in
                guard let self else { return false }   // scene gone → stop the walk
                self.inboxLock.lock()
                self.albumsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
            guard let self else { return }
            self.inboxLock.lock()
            self.albumsDone = true
            self.inboxLock.unlock()
        }
    }

    /// Off-thread streaming song fetch — same page-by-page discipline as loadAlbums.
    /// Kicked once (guarded by songsFetchStarted) when the Songs sub-view first
    /// becomes active.
    private func loadSongs() {
        songsFetchStarted = true
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            sources.onSongs { page in
                guard let self else { return false }
                self.inboxLock.lock()
                self.songsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
            guard let self else { return }
            self.inboxLock.lock()
            self.songsDone = true
            self.inboxLock.unlock()
        }
    }

    /// Off-thread streaming artist-list fetch — same page-by-page discipline as
    /// loadSongs. Kicked once (guarded by artistsFetchStarted) when the Artists
    /// sub-view first becomes active.
    private func loadArtists() {
        artistsFetchStarted = true
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            sources.onArtists { page in
                guard let self else { return false }
                self.inboxLock.lock()
                self.artistsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
            guard let self else { return }
            self.inboxLock.lock()
            self.artistsDone = true
            self.inboxLock.unlock()
        }
    }

    /// Off-thread fetch of one artist's albums, posted to artistAlbumsInbox and
    /// drained in tick. Unlike loadArtists this refetches every time an artist is
    /// opened, so it clears the prior list first (render shows "Loading albums…").
    private func loadArtistAlbums(artistID: String) {
        artistAlbums = []
        artistAlbumsLoaded = false
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            let fetched = sources.onArtistAlbums(artistID)
            guard let self else { return }
            self.inboxLock.lock()
            self.artistAlbumsInbox = (artistID, fetched)
            self.inboxLock.unlock()
        }
    }

    /// Kick a serial background fetch of one album's tracks, unless it's already
    /// cached or in flight. Serial so a fast scroll can't pile concurrent
    /// full-library predicate scans onto Music. Called only from the main thread.
    private func kickTrackFetch(albumID: String, title: String, artist: String) {
        guard trackCache[albumID] == nil, !previewInFlight.contains(albumID) else { return }
        previewInFlight.insert(albumID)
        let sources = self.sources
        previewQueue.async { [weak self] in
            let fetched = sources.onAlbumTracks(title, artist)
            guard let self else { return }
            self.inboxLock.lock()
            self.previewInbox.append((albumID, fetched))
            self.inboxLock.unlock()
        }
    }

    // MARK: Scene

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        inboxLock.lock()
        let newAlbums = albumsPending; albumsPending = []
        let albumsWalkDone = albumsDone
        let newSongs = songsPending; songsPending = []
        let songsWalkDone = songsDone
        let newArtists = artistsPending; artistsPending = []
        let artistsWalkDone = artistsDone
        let freshArtistAlbums = artistAlbumsInbox; artistAlbumsInbox = nil
        let landedPreviews = previewInbox; previewInbox = []
        let artLanded = artDirty; artDirty = false
        inboxLock.unlock()

        // Streaming lists only grow (append), so a landed page can't push the cursor
        // out of range (the count only rises) — no clamp needed here, unlike the old
        // whole-list replace. `*Loaded` flips only when the walk reports done, so a
        // genuinely empty library reads as "(no …)" instead of a stuck "Loading …".
        if !newAlbums.isEmpty {
            albums.append(contentsOf: newAlbums)
            // Feed the tier filter as pages stream in. 1-track stubs (loose playlist
            // songs) fall in neither tier; 2–5 tracks → 12"/EP, 6+ → full album.
            epArtists.formUnion(albumArtistSet(from: newAlbums, minTracks: 2, maxTracks: 5))
            albumArtists.formUnion(albumArtistSet(from: newAlbums, minTracks: 6))
            changed = true
        }
        if albumsWalkDone && !albumsLoaded {
            albumsLoaded = true
            // Walk finished: rebuild the tier sets authoritatively from the full
            // album list (drops any stale cache-seeded names that no longer qualify)
            // and refresh the SWR cache off the main thread (best-effort).
            epArtists = albumArtistSet(from: albums, minTracks: 2, maxTracks: 5)
            albumArtists = albumArtistSet(from: albums, minTracks: 6)
            let (ep, alb) = (epArtists, albumArtists)
            Thread.detachNewThread { ResultCache().rememberArtistTiers(ep: ep, albums: alb) }
            changed = true
        }
        if !newSongs.isEmpty { songs.append(contentsOf: newSongs); changed = true }
        if songsWalkDone && !songsLoaded { songsLoaded = true; changed = true }
        if !newArtists.isEmpty { artists.append(contentsOf: newArtists); changed = true }
        if artistsWalkDone && !artistsLoaded { artistsLoaded = true; changed = true }
        // Apply an artist-albums fetch only if it's still for the current artist
        // (id in the stack's .artistAlbums level); a stale one for an abandoned
        // artist is dropped so it can't overwrite the current one under its
        // breadcrumb (last-writer-wins guard).
        if let freshArtistAlbums, freshArtistAlbums.artistID == currentArtistID() {
            artistAlbums = freshArtistAlbums.albums
            artistAlbumsLoaded = true
            if case .artistAlbums = nav.current {
                let count = visibleAlbumIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        // Lazily load each list the first time its sub-view is shown.
        if nav.subView == .albums && !albumsFetchStarted { loadAlbums() }
        if nav.subView == .songs && !songsFetchStarted { loadSongs() }
        if nav.subView == .artists && !artistsFetchStarted { loadArtists() }
        for item in landedPreviews {
            trackCache[item.id] = item.tracks
            previewInFlight.remove(item.id)
            changed = true
        }
        if artLanded { changed = true }
        // Clamp the track cursor once the drilled album's tracks land.
        if case .tracks(let id, _, _) = nav.current, let t = trackCache[id], nav.cursor >= t.count {
            nav.cursor = max(0, t.count - 1)
        }

        // Lazily fetch the focused album's preview when the right pane is visible
        // (three-zone layout) — mirrors PlaylistsScene's preview kick in tick.
        // Covers both the Albums rail and an artist's albums rail (same layout).
        if isAlbumRail,
           playlistZones(width: ScreenFrame.current().width).mode == .three,
           let a = focusedAlbum(), trackCache[a.id] == nil, !previewInFlight.contains(a.id) {
            kickTrackFetch(albumID: a.id, title: a.name, artist: a.artist)
        }
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        // Sub-view header: Albums · Artists · Songs (active = cyan/bold). When
        // drilled into an artist, a breadcrumb (▸ <artistName>) trails the active
        // Artists tab, reading left-to-right as "Artists ▸ <name>".
        out += ANSICode.moveTo(row: bodyTop, col: z.railX) + subViewHeader()
        if let artistName = breadcrumbArtistName() {
            out += "  \(ANSICode.dim)\u{25B8}\(ANSICode.reset) \(ANSICode.brightWhite)\(artistName)\(ANSICode.reset)"
        }

        let contentTop = bodyTop + 2
        guard contentTop <= bodyBottom else { return out }

        switch nav.subView {
        case .albums:
            renderRail(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
            renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
            renderRightPane(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
        case .songs:
            // Flat filterable list — rail zone only, no hero/preview pane.
            renderSongList(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
        case .artists:
            if case .artistList = nav.current {
                // Flat filterable artist list — rail zone only, like Songs.
                renderArtistList(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
            } else {
                // Drilled into an artist: .artistAlbums (and .tracks below it) are
                // album lists, so reuse the album three-zone render sourced from
                // this artist's albums (currentAlbums switches on nav.subView).
                renderRail(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
                renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
                renderRightPane(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
            }
        }

        if capturing || !filter.isEmpty {
            out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filter)\(ANSICode.reset)\(capturing ? "\u{2588}" : "")"
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Raw filter entry (fzf-style: arrows move the filtered list while typing).
        if capturing {
            switch key {
            case .enter: capturing = false
            case .escape: capturing = false; filter = ""; clampFilterCursor()
            case .up: nav.cursor = max(0, nav.cursor - 1)
            case .down: nav.cursor = min(max(0, currentRowCount() - 1), nav.cursor + 1)
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filter.isEmpty { filter.removeLast() }; clampFilterCursor()
            case .char(let c): filter.append(c); clampFilterCursor()
            default: break
            }
            return .redraw
        }

        // Vim aliases: j/k/h/l/g/G/ctrl-d/ctrl-u. Applied here, after the raw
        // filter-text capture above returns, so typing an album/artist name
        // containing those letters into the filter box isn't intercepted.
        let key = vimAlias(key, listScene: true)

        // pageUp/pageDown/home/end aren't reducer keys (LibraryKey has no page
        // concept) — handled directly against nav.cursor, same idiom as the
        // filter-capture block above and the .up/.down cases in libraryReduce.
        switch key {
        case .pageUp:
            nav.cursor = max(0, nav.cursor - 10)
            return .redraw
        case .pageDown:
            nav.cursor = min(max(0, currentRowCount() - 1), nav.cursor + 10)
            return .redraw
        case .home:
            nav.cursor = 0
            return .redraw
        case .end:
            nav.cursor = max(0, currentRowCount() - 1)
            return .redraw
        default:
            break
        }

        let libKey: LibraryKey
        switch key {
        case .up: libKey = .up
        case .down: libKey = .down
        case .enter: libKey = .enter
        case .right:
            // → drills in like Enter (vim `l` arrives here as .right),
            // symmetric with ← back — but only at levels where Enter means
            // open/drill (album rails, artist list). At the Songs list and
            // the tracks level Enter means play, so → stays a no-op.
            guard isAlbumRail || isArtistList else { return .none }
            libKey = .enter
        case .left, .escape: libKey = .back
        case .char("["): libKey = .switchPrev
        case .char("]"): libKey = .switchNext
        case .char("p"), .char("P"): libKey = .play
        case .char("s"), .char("S"): libKey = .shuffle
        case .char("/"):
            // Filterable at every list level (albums, an artist's albums, artists,
            // songs); a no-op only at the tracks level.
            if isAlbumRail || isSongList || isArtistList { capturing = true; return .redraw }
            return .none
        case .char("a"), .char("A"):
            // Tier filter — Artists list only. `a` cycles All → 12"/EP → Albums.
            // Entering a filtered tier seeds the sets from the SWR cache (instant
            // first paint) and kicks the album walk if it hasn't started (the tiers
            // need album track counts, which otherwise load only when Albums is
            // opened); albums stream, so the walk corrects the seeded sets in the
            // background. Clamp the cursor — the row count can drop when a tier engages.
            guard isArtistList else { return .none }
            artistFilter = artistFilter.next
            if artistFilter != .all {
                if epArtists.isEmpty, albumArtists.isEmpty,
                   let cached = ResultCache().cachedArtistTiers() {
                    epArtists = cached.ep; albumArtists = cached.albums
                }
                if !albumsFetchStarted { loadAlbums() }
            }
            clampFilterCursor()
            return .redraw
        default:
            return .none
        }

        // Back at the root level leaves the tab (mirrors PlaylistsScene's left/esc).
        if libKey == .back && nav.stack.count == 1 { return .pop }

        let count = currentRowCount()
        let sel = selectionUnderCursor()
        let (newNav, action) = libraryReduce(nav, libKey, itemCount: count, selection: sel)
        let subViewChanged = newNav.subView != nav.subView
        let levelChanged = newNav.stack != nav.stack
        nav = newNav
        // Clear the filter on a level change too (drill/back), not just a sub-view
        // switch: a leftover artist-name query would otherwise narrow the drilled
        // artist's ALBUMS wrongly and keep painting a stale /query line.
        if subViewChanged || levelChanged { filter = ""; railScroll = 0; trackScroll = 0 }

        execute(action)
        switch action {
        case .play, .shuffle:
            return .push(.nowPlaying)   // jump to Now Playing on a play, like Playlists
        default:
            return .redraw
        }
    }

    // MARK: action execution

    private func execute(_ action: LibraryAction) {
        switch action {
        case .fetchArtistAlbums(let artistID, _):
            loadArtistAlbums(artistID: artistID)
        case .fetchAlbumTracks(let albumID, let title, let artist):
            // Reuse the shared cache: if the preview already loaded it, this is a
            // no-op and the tracks level paints instantly; otherwise it kicks the
            // same serial fetch and the pane shows "loading…" until it lands.
            kickTrackFetch(albumID: albumID, title: title, artist: artist)
        case .play(.album(_, let title, let artist)):
            // Enter on a row in the album tracklist starts the queue AT that track
            // (nav.cursor is the track index there); elsewhere it's whole-album.
            playAlbum(title: title, artist: artist, shuffle: false,
                      startAt: isTracksLevel ? nav.cursor + 1 : 1)
        case .shuffle(.album(_, let title, let artist)):
            playAlbum(title: title, artist: artist, shuffle: true)
        case .play(.song(_, let title, let artist)):
            playSong(title: title, artist: artist, shuffle: false)
        case .shuffle(.song(_, let title, let artist)):
            playSong(title: title, artist: artist, shuffle: true)
        case .play(.artist(_, let name)):
            playArtist(name: name, shuffle: false)
        case .shuffle(.artist(_, let name)):
            playArtist(name: name, shuffle: true)
        case .none:
            break
        }
    }

    /// Whole-album (or from-a-track) play via the app-owned queue. macOS 26.x
    /// roots ANY scripted play in the whole library (probed live 2026-07-12), so
    /// native `play <tracks>` gives an all-library Up Next that wanders past the
    /// album. Instead we build an AppQueue of just the album's tracks (sourced
    /// from "Library" by position) and let the poller drive it: scoped Up Next,
    /// navigable, stops at the album's end. Autoplay (∞) must be OFF. Track-by-
    /// track, so not gapless — the accepted trade-off. On the action queue; the
    /// bulk fetch never freezes the UI and failures toast.
    private func playAlbum(title: String, artist: String, shuffle: Bool, startAt: Int = 1) {
        let escTitle = escapeAppleScriptString(title)
        let escArtist = escapeAppleScriptString(artist)
        let backend = self.backend
        let store = self.appQueue
        actions.run("Play") {
            // Match on album artist too, not just track artist: remix/compilation
            // albums credit each track to the remixer, so `artist is Y` alone finds
            // nothing (the album shows 0 tracks and won't play). `album is X` scopes
            // to the album; the artist/album-artist clause disambiguates same-named
            // albums by different artists.
            let tracks = fetchLibraryTracksWithPositions(
                backend: backend,
                whereClause: "album is \"\(escTitle)\" and (artist is \"\(escArtist)\" or album artist is \"\(escArtist)\")")
            try require(!tracks.isEmpty, "Couldn't load '\(title)'.")
            let ordered = shuffle ? tracks.shuffled() : tracks
            let idx = shuffle ? 1 : min(max(1, startAt), ordered.count)
            store.set(AppQueue(playlistName: "Library", tracks: ordered, currentIndex: idx, displayName: title))
            try require(playQueueTrack(backend: backend, playlist: "Library", position: ordered[idx - 1].index),
                        "Couldn't play '\(title)'.")
        }
    }

    /// Play one library song as a 1-track app-owned queue — plays it and stops,
    /// instead of the old native `play some track` that dropped into the whole
    /// library and bled into Autoplay. Autoplay (∞) must be OFF. Shuffle is a
    /// no-op for a single track (the param stays for a uniform call site).
    private func playSong(title: String, artist: String, shuffle: Bool) {
        let escTitle = escapeAppleScriptString(title)
        let escArtist = escapeAppleScriptString(artist)
        let backend = self.backend
        let store = self.appQueue
        actions.run("Play") {
            let tracks = fetchLibraryTracksWithPositions(
                backend: backend, whereClause: "name is \"\(escTitle)\" and artist is \"\(escArtist)\"")
            try require(!tracks.isEmpty, "Couldn't play '\(title)'.")
            let one = Array(tracks.prefix(1))
            store.set(AppQueue(playlistName: "Library", tracks: one, currentIndex: 1, displayName: title))
            try require(playQueueTrack(backend: backend, playlist: "Library", position: one[0].index),
                        "Couldn't play '\(title)'.")
        }
    }

    /// Play every library track by one artist as an app-owned queue (scoped,
    /// navigable, stops at the end — same rationale as playAlbum). Autoplay OFF.
    private func playArtist(name: String, shuffle: Bool) {
        let escName = escapeAppleScriptString(name)
        let backend = self.backend
        let store = self.appQueue
        actions.run("Play") {
            let tracks = fetchLibraryTracksWithPositions(
                backend: backend, whereClause: "artist is \"\(escName)\"")
            try require(!tracks.isEmpty, "Couldn't load '\(name)'.")
            let ordered = shuffle ? tracks.shuffled() : tracks
            store.set(AppQueue(playlistName: "Library", tracks: ordered, currentIndex: 1, displayName: name))
            try require(playQueueTrack(backend: backend, playlist: "Library", position: ordered[0].index),
                        "Couldn't play '\(name)'.")
        }
    }

    // MARK: level helpers

    private var isAlbumList: Bool { if case .albumList = nav.current { return true }; return false }
    private var isSongList: Bool { if case .songList = nav.current { return true }; return false }
    private var isArtistList: Bool { if case .artistList = nav.current { return true }; return false }
    private var isTracksLevel: Bool { if case .tracks = nav.current { return true }; return false }
    /// True at either album-rail level: the Albums root or an artist's albums.
    /// Both drive the same three-zone rail·hero·preview render + preview kick.
    private var isAlbumRail: Bool {
        switch nav.current { case .albumList, .artistAlbums: return true; default: return false }
    }

    /// The album collection backing the rail/hero/preview at the current level.
    /// In the Artists sub-view (both .artistAlbums and the .tracks below it) that's
    /// the drilled artist's albums; otherwise the whole-library albums.
    private var currentAlbums: [LibraryAlbum] {
        nav.subView == .artists ? artistAlbums : albums
    }

    /// The drilled artist's name, if we're anywhere inside an artist (.artistAlbums
    /// or the .tracks under it). Read from the stack so it survives the drill into
    /// tracks. nil at .artistList / in other sub-views → no breadcrumb.
    private func breadcrumbArtistName() -> String? {
        for level in nav.stack {
            if case .artistAlbums(_, let name) = level { return name }
        }
        return nil
    }

    /// The drilled artist's id (from the stack's .artistAlbums level), or nil when
    /// not inside an artist. Used to reject stale artist-album fetches in tick.
    private func currentArtistID() -> String? {
        for level in nav.stack {
            if case .artistAlbums(let id, _) = level { return id }
        }
        return nil
    }

    private func currentRowCount() -> Int {
        switch nav.current {
        case .albumList, .artistAlbums: return visibleAlbumIndices().count
        case .songList: return visibleSongIndices().count
        case .artistList: return visibleArtistIndices().count
        case .tracks(let id, _, _): return trackCache[id]?.count ?? 0
        }
    }

    private func selectionUnderCursor() -> LibrarySelection? {
        switch nav.current {
        case .albumList, .artistAlbums:
            let vis = visibleAlbumIndices()
            guard nav.cursor >= 0, nav.cursor < vis.count else { return nil }
            let a = currentAlbums[vis[nav.cursor]]
            return LibrarySelection(id: a.id, primary: a.name, secondary: a.artist)
        case .artistList:
            let vis = visibleArtistIndices()
            guard nav.cursor >= 0, nav.cursor < vis.count else { return nil }
            let ar = artists[vis[nav.cursor]]
            return LibrarySelection(id: ar.id, primary: ar.name, secondary: "")
        case .songList:
            let vis = visibleSongIndices()
            guard nav.cursor >= 0, nav.cursor < vis.count else { return nil }
            let s = songs[vis[nav.cursor]]
            return LibrarySelection(id: s.id, primary: s.title, secondary: s.artist)
        case .tracks(let albumID, let albumTitle, let artist):
            // The reducer plays the album (from the level's stored identity) and
            // ignores the selection's contents at this level, but its Enter path
            // still guards on selection != nil — so hand back the album identity.
            return LibrarySelection(id: albumID, primary: albumTitle, secondary: artist)
        }
    }

    private func visibleAlbumIndices() -> [Int] {
        // Tier-scope the drilled album list to match the tier you came from (Albums
        // view → 6+ albums, 12"/EP → 2–5), so an artist's albums don't mix tiers on
        // drill-in. Only in the Artists sub-view and only when a tier is active; the
        // Albums root sub-view has no tier.
        let range = (nav.subView == .artists) ? artistFilter.trackRange : nil
        return filteredAlbumIndices(albums: currentAlbums, trackRange: range, filter: filter)
    }

    private func visibleArtistIndices() -> [Int] {
        let tierSet: Set<String>?
        switch artistFilter {
        case .all: tierSet = nil
        case .epOr12: tierSet = epArtists
        case .albums: tierSet = albumArtists
        }
        return filteredArtistIndices(artists: artists, albumArtistNames: tierSet, filter: filter)
    }

    private func visibleSongIndices() -> [Int] {
        guard !filter.isEmpty else { return Array(0..<songs.count) }
        let q = filter.lowercased()
        return (0..<songs.count).filter {
            "\(songs[$0].title) \(songs[$0].artist)".lowercased().contains(q)
        }
    }

    /// Clamp the cursor to the current level's filtered row count. Used by the
    /// filter-capture path, which is shared by the album and song lists.
    private func clampFilterCursor() {
        let count = currentRowCount()
        if nav.cursor >= count { nav.cursor = max(0, count - 1) }
        railScroll = 0
    }

    private func focusedAlbum() -> LibraryAlbum? {
        let src = currentAlbums
        switch nav.current {
        case .albumList, .artistAlbums:
            let vis = visibleAlbumIndices()
            guard nav.cursor >= 0, nav.cursor < vis.count else { return nil }
            return src[vis[nav.cursor]]
        case .tracks(let albumID, let albumTitle, let artist):
            return src.first { $0.id == albumID } ?? LibraryAlbum(id: albumID, name: albumTitle, artist: artist, trackCount: 0)
        default:
            return nil
        }
    }

    // MARK: render helpers

    private func subViewName(_ sv: LibrarySubView) -> String {
        switch sv {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        }
    }

    private func subViewHeader() -> String {
        LibrarySubView.allCases.map { sv -> String in
            let name = subViewName(sv)
            return sv == nav.subView
                ? "\(ANSICode.bold)\(ANSICode.cyan)\(name)\(ANSICode.reset)"
                : "\(ANSICode.dim)\(name)\(ANSICode.reset)"
        }.joined(separator: "\(ANSICode.dim)  \u{00B7}  \(ANSICode.reset)")
    }

    private func renderRail(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        let listY = contentTop
        let maxVisible = max(1, bodyBottom - listY + 1)
        let vis = visibleAlbumIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX)
            let loaded = (nav.subView == .artists) ? artistAlbumsLoaded : albumsLoaded
            let msg = loaded ? (filter.isEmpty ? "(no albums)" : "(no matches)") : "Loading albums\u{2026}"
            out += "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
            return
        }
        // Which rail row is highlighted. renderRail runs at three levels: the
        // Albums root (.albumList), an artist's albums (.artistAlbums), and the
        // drilled-in .tracks. At the two LIST levels the highlight follows the
        // cursor; only at .tracks does it instead mark the album whose tracks are
        // showing. Gating on isAlbumList alone pinned the .artistAlbums highlight
        // to row 0 while the right-pane preview tracked the cursor — the bug where
        // the left selection "only appeared on Enter".
        let cursorDriven = !isTracksLevel
        let cursorPos: Int
        if cursorDriven {
            cursorPos = min(max(0, nav.cursor), vis.count - 1)
        } else {
            cursorPos = drilledAlbumPos(in: vis) ?? 0
        }
        if cursorPos < railScroll { railScroll = cursorPos }
        if cursorPos >= railScroll + maxVisible { railScroll = cursorPos - maxVisible + 1 }
        let end = min(vis.count, railScroll + maxVisible)
        let nameWidth = max(1, z.railWidth - 2)
        for p in railScroll..<end {
            let i = vis[p]
            let row = listY + (p - railScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let a = currentAlbums[i]
            let label = "\(a.name) \u{2014} \(a.artist)"
            let nm = railName(label, nameWidth: nameWidth)
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if p == cursorPos {
                if cursorDriven {
                    out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset)"
                } else {
                    out += "\(ANSICode.dim)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
                }
            } else {
                out += "  \(ANSICode.dim)\(padName)\(ANSICode.reset)"
            }
        }
    }

    private func drilledAlbumPos(in vis: [Int]) -> Int? {
        guard case .tracks(let albumID, _, _) = nav.current else { return nil }
        let src = currentAlbums
        return vis.firstIndex { src[$0].id == albumID }
    }

    /// Songs sub-view: a flat, filterable "<title> — <artist>" list in the rail
    /// zone only (no hero/preview). Cursor + scroll mirror renderRail's album path.
    private func renderSongList(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        let listY = contentTop
        let maxVisible = max(1, bodyBottom - listY + 1)
        let vis = visibleSongIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX)
            let msg = songsLoaded ? (filter.isEmpty ? "(no songs)" : "(no matches)") : "Loading songs\u{2026}"
            out += "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
            return
        }
        let cursorPos = min(max(0, nav.cursor), vis.count - 1)
        if cursorPos < railScroll { railScroll = cursorPos }
        if cursorPos >= railScroll + maxVisible { railScroll = cursorPos - maxVisible + 1 }
        let end = min(vis.count, railScroll + maxVisible)
        let nameWidth = max(1, z.railWidth - 2)
        for p in railScroll..<end {
            let i = vis[p]
            let row = listY + (p - railScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let s = songs[i]
            let label = "\(s.title) \u{2014} \(s.artist)"
            let nm = railName(label, nameWidth: nameWidth)
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if p == cursorPos {
                out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset)"
            } else {
                out += "  \(ANSICode.dim)\(padName)\(ANSICode.reset)"
            }
        }
    }

    /// Artists sub-view root: a flat, filterable artist-name list in the rail zone
    /// only (no hero/preview). Cursor + scroll mirror renderSongList.
    private func renderArtistList(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        let listY = contentTop
        let maxVisible = max(1, bodyBottom - listY + 1)
        let vis = visibleArtistIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX)
            // With the album-artists toggle on, an empty list can mean "albums still
            // loading" (the set isn't populated yet) vs "loaded, none owned" — name
            // those honestly instead of a blanket "(no artists)".
            let msg: String
            if !artistsLoaded { msg = "Loading artists\u{2026}" }
            else if artistFilter != .all && !albumsLoaded { msg = "Loading albums\u{2026}" }
            else if !filter.isEmpty { msg = "(no matches)" }
            else {
                switch artistFilter {
                case .all: msg = "(no artists)"
                case .epOr12: msg = "(no 12\" / EP artists)"
                case .albums: msg = "(no album artists)"
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
            let i = vis[p]
            let row = listY + (p - railScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let ar = artists[i]
            let nm = railName(ar.name, nameWidth: nameWidth)
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if p == cursorPos {
                out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset)"
            } else {
                out += "  \(ANSICode.dim)\(padName)\(ANSICode.reset)"
            }
        }
    }

    private func renderHero(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        guard let a = focusedAlbum() else { return }
        var y = contentTop
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(a.name, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.dim)\(truncText(a.artist, to: z.heroWidth))\(ANSICode.reset)"
        y += 2

        // Match the Now tab's art size (44×22), clamped to the hero column and to
        // the rows available so the track count + key hints below always fit
        // (same row-reservation discipline as NowPlayingScene's left pane).
        let gw = min(44, z.heroWidth)
        let gh = max(0, min(22, bodyBottom - y - 4))
        var artBlock: ArtBlock? = nil
        if let template = a.artworkURL {
            artBlock = artwork.block(key: a.id,
                                     url: ArtworkStore.resolveURL(template, width: 300, height: 300),
                                     // Degenerate geometry (very short/narrow terminal) skips the
                                     // kitty path: PNG conversion doesn't depend on gw/gh, so
                                     // without this it would still return .kitty and place a
                                     // zero-row image — route through .lines([]) instead, which
                                     // already no-ops cleanly at gh<=0.
                                     width: gw, height: gh, kitty: kittyEnabled && gw > 0 && gh > 0) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        switch artBlock {
        case .lines(let art):
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            // Pad/cap to exactly gh rows so the hero's height never shifts and
            // stale gradient rows are overwritten (chafa may emit fewer rows).
            let blank = String(repeating: " ", count: gw)
            let rows = art.prefix(gh) + Array(repeating: blank, count: max(0, gh - art.count))
            for line in rows {
                out += ANSICode.moveTo(row: y, col: z.heroX) + line + ANSICode.reset
                y += 1
            }
        case .kitty(let id, let transmit):
            let current = (id: id, row: y, col: z.heroX, cols: gw, rows: gh)
            if let last = lastPlaced, last == current {
                // Unchanged: the placement from a prior frame is still on
                // screen — emit nothing (spaces would flicker under the image).
            } else {
                if let last = lastPlaced { out += kittyDeleteEscape(id: last.id) }
                let blank = String(repeating: " ", count: gw)
                for i in 0..<gh {
                    out += ANSICode.moveTo(row: y + i, col: z.heroX) + blank
                }
                out += transmit ?? ""
                out += ANSICode.moveTo(row: y, col: z.heroX) + kittyPlaceEscape(id: id, cols: gw, rows: gh)
                lastPlaced = current
            }
            y += gh
        case .none:
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            let gradient = gradientBlock(name: a.name + a.artist, width: gw, height: gh)
            var seed = 0; for b in (a.name + a.artist).unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
            let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
            let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
            for line in gradient {
                out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
                y += 1
            }
        }
        y += 1

        // Track count once the album's tracks are cached (line reserved either way
        // so the hint below doesn't jump when the count lands).
        out += ANSICode.moveTo(row: y, col: z.heroX)
        if let cached = trackCache[a.id] {
            out += "\(ANSICode.dim)\(cached.count) tracks\(ANSICode.reset)"
        }
        y += 2

        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Open   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    private func renderRightPane(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX, let a = focusedAlbum() else { return }
        var y = contentTop
        let cached = trackCache[a.id]
        out += ANSICode.moveTo(row: y, col: rx)
        out += "\(ANSICode.cyan)Tracks\(ANSICode.reset)" + (cached.map { " \(ANSICode.dim)\($0.count)\(ANSICode.reset)" } ?? "")
        y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"
        y += 1
        guard let lines = cached else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return
        }
        if lines.isEmpty {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            return
        }
        // Cursor highlight only at the tracks level; the album-level preview is a
        // plain dim list (no cursor), matching PlaylistsScene's preview pane.
        let atTracks = isTracksLevel
        let maxVis = max(1, bodyBottom - y + 1)
        let cur = atTracks ? min(max(0, nav.cursor), lines.count - 1) : -1
        if atTracks {
            if cur < trackScroll { trackScroll = cur }
            if cur >= trackScroll + maxVis { trackScroll = cur - maxVis + 1 }
        } else {
            trackScroll = 0
        }
        let end = min(lines.count, trackScroll + maxVis)
        for i in trackScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let text = truncText(lines[i], to: max(2, z.rightWidth - 4))
            if i == cur {
                out += "\(ANSICode.inverse)\(idx)  \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }
}

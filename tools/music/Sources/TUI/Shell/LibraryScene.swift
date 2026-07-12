// tools/music/Sources/TUI/Shell/LibraryScene.swift
// The Library tab. Albums (three-zone: rail + hero + track preview), Songs (flat
// filterable list), and Artists (flat list → drill into the artist's albums,
// which reuse the album three-zone render) are all wired end to end.
// All navigation is delegated to the pure `libraryReduce`; the scene owns only
// view state (scroll, filter) and executes the emitted LibraryAction off-thread.
import Foundation

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
    private var albumsInbox: [LibraryAlbum]? = nil
    private var songsInbox: [LibrarySong]? = nil
    private var artistsInbox: [LibraryArtist]? = nil
    private var artistAlbumsInbox: [LibraryAlbum]? = nil
    private var previewInbox: [(id: String, tracks: [String])] = []

    init(backend: AppleScriptBackend, sources: LibraryDataSources,
         appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner) {
        self.backend = backend
        self.sources = sources
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        loadAlbums()
    }

    // MARK: background loads

    private func loadAlbums() {
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            let fetched = sources.onAlbums()
            guard let self else { return }
            self.inboxLock.lock()
            self.albumsInbox = fetched
            self.inboxLock.unlock()
        }
    }

    /// Off-thread song fetch, posted to songsInbox and drained in tick — same
    /// inbox+NSLock discipline as loadAlbums. Kicked once (guarded by
    /// songsFetchStarted) when the Songs sub-view first becomes active.
    private func loadSongs() {
        songsFetchStarted = true
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            let fetched = sources.onSongs()
            guard let self else { return }
            self.inboxLock.lock()
            self.songsInbox = fetched
            self.inboxLock.unlock()
        }
    }

    /// Off-thread artist-list fetch, posted to artistsInbox and drained in tick.
    /// Kicked once (guarded by artistsFetchStarted) when the Artists sub-view
    /// first becomes active — same one-shot pattern as loadSongs.
    private func loadArtists() {
        artistsFetchStarted = true
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            let fetched = sources.onArtists()
            guard let self else { return }
            self.inboxLock.lock()
            self.artistsInbox = fetched
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
            self.artistAlbumsInbox = fetched
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
        let freshAlbums = albumsInbox; albumsInbox = nil
        let freshSongs = songsInbox; songsInbox = nil
        let freshArtists = artistsInbox; artistsInbox = nil
        let freshArtistAlbums = artistAlbumsInbox; artistAlbumsInbox = nil
        let landedPreviews = previewInbox; previewInbox = []
        inboxLock.unlock()

        if let freshAlbums {
            albums = freshAlbums
            albumsLoaded = true
            if isAlbumList {
                let count = visibleAlbumIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        if let freshSongs {
            songs = freshSongs
            songsLoaded = true
            if isSongList {
                let count = visibleSongIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        if let freshArtists {
            artists = freshArtists
            artistsLoaded = true
            if isArtistList {
                let count = visibleArtistIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        if let freshArtistAlbums {
            artistAlbums = freshArtistAlbums
            artistAlbumsLoaded = true
            if case .artistAlbums = nav.current {
                let count = visibleAlbumIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        // Lazily load songs / artists the first time their sub-view is shown.
        if nav.subView == .songs && !songsFetchStarted { loadSongs() }
        if nav.subView == .artists && !artistsFetchStarted { loadArtists() }
        for item in landedPreviews {
            trackCache[item.id] = item.tracks
            previewInFlight.remove(item.id)
            changed = true
        }
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
            renderHero(z, into: &out, contentTop: contentTop)
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
                renderHero(z, into: &out, contentTop: contentTop)
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

        let libKey: LibraryKey
        switch key {
        case .up: libKey = .up
        case .down: libKey = .down
        case .enter: libKey = .enter
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
        if subViewChanged { filter = "" }
        if subViewChanged || levelChanged { railScroll = 0; trackScroll = 0 }

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
            playAlbum(title: title, artist: artist, shuffle: false)
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

    /// Whole-album play via Music's native (gapless) queue — relinquish the
    /// app-owned queue so the poller reads Music's context again. Two separate
    /// AppleScript calls (never batched, per the -50 rule); failures toast.
    private func playAlbum(title: String, artist: String, shuffle: Bool) {
        appQueue.clear()
        let escTitle = escapeAppleScriptString(title)
        let escArtist = escapeAppleScriptString(artist)
        let backend = self.backend
        actions.run("Play") {
            try require((try? syncRun { try await backend.runMusic("set shuffle enabled to \(shuffle)") }) != nil,
                        "Couldn't set shuffle for '\(title)'.")
            try require((try? syncRun { try await backend.runMusic("play (every track of playlist \"Library\" whose album is \"\(escTitle)\" and artist is \"\(escArtist)\")") }) != nil,
                        "Couldn't play '\(title)'.")
        }
    }

    /// Play one library song via Music's native queue (matched by name+artist in
    /// the whole-library "Library" playlist). Mirrors playAlbum: relinquish the
    /// app-owned queue, two separate AppleScript calls (never batched, per -50),
    /// failures toast. `set shuffle` runs even on a plain play so a prior shuffle
    /// state is reset.
    private func playSong(title: String, artist: String, shuffle: Bool) {
        appQueue.clear()
        let escTitle = escapeAppleScriptString(title)
        let escArtist = escapeAppleScriptString(artist)
        let backend = self.backend
        actions.run("Play") {
            try require((try? syncRun { try await backend.runMusic("set shuffle enabled to \(shuffle)") }) != nil,
                        "Couldn't set shuffle for '\(title)'.")
            try require((try? syncRun { try await backend.runMusic("play (some track of playlist \"Library\" whose name is \"\(escTitle)\" and artist is \"\(escArtist)\")") }) != nil,
                        "Couldn't play '\(title)'.")
        }
    }

    /// Play every library track by one artist via Music's native queue (matched
    /// by artist in the whole-library "Library" playlist). Mirrors playAlbum:
    /// relinquish the app-owned queue, two separate AppleScript calls (never
    /// batched, per -50), failures toast.
    private func playArtist(name: String, shuffle: Bool) {
        appQueue.clear()
        let escName = escapeAppleScriptString(name)
        let backend = self.backend
        actions.run("Play") {
            try require((try? syncRun { try await backend.runMusic("set shuffle enabled to \(shuffle)") }) != nil,
                        "Couldn't set shuffle for '\(name)'.")
            try require((try? syncRun { try await backend.runMusic("play (every track of playlist \"Library\" whose artist is \"\(escName)\")") }) != nil,
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
        let src = currentAlbums
        guard !filter.isEmpty else { return Array(0..<src.count) }
        let q = filter.lowercased()
        return (0..<src.count).filter {
            "\(src[$0].name) \(src[$0].artist)".lowercased().contains(q)
        }
    }

    private func visibleArtistIndices() -> [Int] {
        guard !filter.isEmpty else { return Array(0..<artists.count) }
        let q = filter.lowercased()
        return (0..<artists.count).filter { artists[$0].name.lowercased().contains(q) }
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
            return src.first { $0.id == albumID } ?? LibraryAlbum(id: albumID, name: albumTitle, artist: artist)
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
        // Which rail row is highlighted: the cursor at the album level, or the
        // drilled-into album while browsing its tracks.
        let atAlbumList = isAlbumList
        let cursorPos: Int
        if atAlbumList {
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
                if atAlbumList {
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
            let msg = artistsLoaded ? (filter.isEmpty ? "(no artists)" : "(no matches)") : "Loading artists\u{2026}"
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

    private func renderHero(_ z: PlaylistZones, into out: inout String, contentTop: Int) {
        guard let a = focusedAlbum() else { return }
        var y = contentTop
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(a.name, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.dim)\(truncText(a.artist, to: z.heroWidth))\(ANSICode.reset)"
        y += 2

        let gw = min(28, z.heroWidth)
        let gh = 10
        let block = gradientBlock(name: a.name + a.artist, width: gw, height: gh)
        var seed = 0; for b in (a.name + a.artist).unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
        let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
        let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
        for line in block {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
            y += 1
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

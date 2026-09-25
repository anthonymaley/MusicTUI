// tools/music/Sources/TUI/Shell/PlaylistsScene.swift
import Foundation

/// C2 (Revision 3, D1). Anthony's decision, 22:32, final: the Playlists
/// header counts the rows a person can actually SEE. `shown` is the wire's
/// rows less MusicTUI's own temp containers (already filtered out of
/// `bridgePlaylistRows` at drain time — `isTempPlaylistName`), never Bridge's own
/// wire `total`, which still includes them (58 today against a wire 59).
/// `wireTotal` is accepted, not read: a call site states both numbers even
/// though only one drives the label, the same "deliberately not read"
/// discipline `SourceAppControl.libraryPage`'s `clamped` comment follows. A
/// test pins this directly.
func bridgePlaylistHeaderCount(shown: Int, wireTotal: Int?) -> Int {
    shown
}

/// C3, D11 (Revision 3). One pure function for every successful Bridge
/// playlist play's footer sentence, so no call site hand-assembles the
/// plurals or picks the wrong form. `queued` is the number of song ids sent;
/// `skippedVideos` is the whole playlist's video count; `startAt` is the
/// 1-based row the play started from.
///
/// `shuffle` never changes which form is picked — `p`, `s` and Enter on the
/// first row all pass `startAt == 1`, which is the actual discriminator — but
/// it stays a parameter because the caller has it in hand and the score's own
/// signature names it.
/// `queued` is the number of ids SENT (`bridgeQueueIDs`'s count); the
/// displayed "N tracks"/"N of N+V" figure is `queued - skippedUnavailable`
/// (Addendum U), because that many of what was sent never actually played.
/// `skippedUnavailable` composes as U-R6's own trailing sentence — added
/// after whatever the video-skip form already produced, never replacing it.
func bridgePlaylistPlayMessage(name: String, queued: Int, skippedVideos: Int, skippedUnavailable: Int,
                               startAt: Int, shuffle: Bool) -> String {
    _ = shuffle
    // The numerator is what actually played; the "of M" denominator (only in
    // the whole-playlist video-skip form) is the ORIGINAL whole-playlist
    // member count — `queued` (songs) + `skippedVideos`, NEVER reduced by
    // `skippedUnavailable` too. Codex's review (f2ac2693) caught this: 40
    // songs + 2 videos + 1 unavailable must read "Playing 39 of 42 …", not
    // "39 of 41" — subtracting the unavailable count from BOTH numbers would
    // silently shrink the whole-playlist total it's supposed to be against.
    let n = queued - skippedUnavailable
    let v = skippedVideos
    let base: String
    if v == 0 {
        // Byte-identical to Part A's shipped album sentence: never singular.
        base = "Playing '\(name)' on Bridge \u{2014} \(n) tracks."
    } else if startAt <= 1 {
        base = "Playing \(n) of \(queued + v) from '\(name)' on Bridge: \(v) video\(v == 1 ? "" : "s") skipped."
    } else {
        base = "Playing '\(name)' on Bridge from track \(startAt) \u{2014} \(n) track\(n == 1 ? "" : "s"); "
             + "\(v) video\(v == 1 ? "" : "s") in this playlist skipped."
    }
    guard skippedUnavailable > 0 else { return base }
    return base + " " + bridgeUnavailableSongsNotice(skippedUnavailable)
}

final class PlaylistsScene: Scene {
    let id: SceneID = .playlists
    let tabTitle = "Playlists"
    var capturesAllInput: Bool { filtering }
    var footerHint: String {
        if filtering { return "type to filter  Enter Apply  Esc Clear" }
        return focus == .tracks
            ? "\u{2191}\u{2193} Track  Enter Play  \u{2190} Back"
            : "\u{2191}\u{2193} Move  Enter Open  p Play  s Shuffle  / Filter"
    }

    /// The rail's last two rows, when there's room for them (D8). Dim, never
    /// selectable, and names no playlist — nothing honest can supply a count
    /// or a name list in Bridge mode (no AppleScript read, and
    /// `playlist-meta.json` is Music.app's own stale, name-keyed data).
    static let bridgeMissingNote = "Some Music.app playlists aren't in Bridge's library."

    // C3: D4's page size (the wire's own maximum) for a drill-in or a fresh
    // play read, and the preview's own much smaller read (decoration, not
    // what plays — D2). Named once so no call site copies the numbers
    // (rule 14).
    static let bridgeTracksPageLimit = 500
    static let bridgePreviewLimit = 50

    private let backend: AppleScriptBackend
    private let routing: RoutingCoordinator
    /// The Music.app rail's names. Empty in Bridge mode, and empty until the
    /// Shell's synchronous initial fetch (Music.app mode) or a later
    /// provenance switch's async reload lands (D7 item 5/C2 item 2). A `var`
    /// since C2: the old `let` only ever held one Shell-supplied list.
    private var playlists: [String]
    private var subscriptionNames: Set<String>
    private var sources: PlaylistDataSources
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner
    private let metaCache: PlaylistMetaCache

    // C2: the provider seam and its two supporting factories, plus the two
    // injected side effects (rule 15/D10) so tests never depend on the real
    // clock or the real terminal.
    private let makeProvider: () -> MusicDataProvider?
    private let loadMusicAppPlaylists: () -> (names: [String], subscription: Set<String>)
    private let makeSources: ([String]) -> PlaylistDataSources
    private let warmUpSleep: (TimeInterval) -> Void
    private let screenWidth: () -> Int

    // D7: which library the rail actually came from, and the epoch every
    // background post (the Bridge walk, and the Music.app async reload) is
    // checked against. `nil` means "hasn't picked a branch yet this tick" —
    // the only state `applyProvenance()` never resets, because there is
    // nothing yet to be wrong about.
    private var railSource: ListSource? = nil
    private var railEpoch = 0
    var railSourceForTest: ListSource? { railSource }
    /// The current rail's names, in rail order — Bridge's (filtered) or
    /// Music.app's, whichever `railSource` says is live.
    var railNamesForTest: [String] {
        railSource == .bridge
            ? bridgeVisibleIndices().map { bridgePlaylistRows[$0].title }
            : visibleIndices().map { playlists[$0] }
    }

    private var focus: BrowserFocus = .playlists
    private var plCursor = 0
    private var plScroll = 0
    private var snapToPlayingPending = false

    /// Rail cursor, an index into the whole playlist list, for tests.
    var railCursorForTest: Int { plCursor }
    private var trCursor = 0
    private var trScroll = 0
    private var meta: [PlaylistMeta]
    private var loaded: Set<Int> = []
    private var fullCache: [Int: PlaylistPreview] = [:]
    private var previewLines: [Int: [String]] = [:]
    private var filterText = ""
    private var filtering = false

    // Off-thread metadata refresh: a background thread fetches via `onMeta` and posts
    // results to `inbox`; tick() drains them on the main thread, so `meta` stays
    // main-thread-only and the slow AppleScript never blocks a render frame.
    //
    // Rule 10: every post carries the epoch its refresh started under
    // (captured at kick time, before the thread detaches — never read live
    // from a background thread, which is how `LibraryScene`'s equivalent
    // guards avoid a data race on the mutable epoch itself). `tick`'s drain
    // is what compares it against the CURRENT `railEpoch`, on the main
    // thread, and drops a mismatch — an abandoned run's post landing on a
    // same-indexed but unrelated later list.
    private let inboxLock = NSLock()
    private var inbox: [Int: (epoch: Int, meta: (Int, Int, Bool, String))] = [:]
    /// C2: the Music.app async reload's landing spot — `nil` until
    /// `loadMusicAppPlaylists()` returns on its detached thread. Guarded by
    /// `inboxLock` alongside `inbox`; carries the epoch its load started
    /// under (rule 10).
    private var musicAppNamesPending: (epoch: Int, names: [String], subscription: Set<String>)? = nil
    /// Set once that reload has landed, so `render()` can tell "still loading"
    /// apart from "loaded, and genuinely empty" — the latter needs its own
    /// message rather than falling into `renderRail`'s `meta[plCursor]`
    /// (which would be a crash on an empty list).
    private var musicAppReloadDone = false

    // Preview fetches follow the same inbox pattern (an inline fetch in tick()
    // froze input for one osascript round-trip per uncached rail row). A serial
    // queue both keeps `onPreview`'s internal cache single-threaded and avoids
    // piling concurrent AppleScript load onto Music while scrolling.
    private let previewQueue = DispatchQueue(label: "music.playlists.preview")
    private let previewInboxLock = NSLock()
    // Rule 10: epoch-carrying, same reasoning as `inbox` above — captured at
    // kick time, compared on the main thread in `tick`.
    private var previewInbox: [Int: (epoch: Int, lines: [String])] = [:]
    private var previewInFlight: Set<Int> = []   // tick()-thread only

    // Full track lists land the same way (Enter kicks the fetch, tick drains).
    private var fullInbox: [Int: (epoch: Int, preview: PlaylistPreview)] = [:]   // guarded by previewInboxLock
    private var fullInFlight: Set<Int> = []               // tick()/handle()-thread only

    // Real hero covers. artMap lands once from a background REST walk (inbox
    // discipline: posted under inboxLock, drained in tick); ArtworkStore then
    // owns per-cover fetch/cache/render. No token → onArtworkMap is nil and
    // gradients stay. Bridge mode's `sources` is `.empty` (`onArtworkMap`
    // nil), so this never kicks off there either (D1: always the gradient).
    private let artwork = ArtworkStore()
    private var artMap: [String: (id: String, url: String)] = [:]
    private var artMapInbox: [String: (id: String, url: String)]? = nil
    private var artMapStarted = false
    private var artDirty = false
    private let kittyEnabled: Bool
    // Placement-dedup (render-thread-only, per design doc Feature 2 §3): the
    // last kitty placement this scene emitted, so an unchanged frame emits
    // nothing (the placement persists on screen across text repaints) and a
    // changed one deletes the old placement before drawing the new one.
    private var lastPlaced: (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)? = nil

    private let metaCol = 6

    // C2: Bridge's own playlist list, one feed — the same walk-and-inbox
    // discipline Part A's Albums/Artists lists share (BridgeListFeed.swift)
    // rather than a hand-rolled copy. `lazy` so the closure is built once, on
    // first Bridge-mode use, and `reset()` (never a fresh instance) is how a
    // provenance switch clears it out.
    private lazy var playlistsFeed: BridgeListFeed<MusicRow> = {
        let sleep = warmUpSleep
        return BridgeListFeed<MusicRow>(
            fetch: { [weak self] cursor, limit in
                guard let self, let provider = self.makeProvider() else {
                    throw MusicProviderError.unavailable("Bridge is not the selected output")
                }
                return try provider.libraryPlaylists(cursor: cursor, limit: limit)
            },
            map: { $0 },
            sleep: sleep)
    }()
    /// Bridge's rows, already stripped of MusicTUI's own temp containers at
    /// drain time (D1) — this IS "the visible rows" the header counts and the
    /// rail shows. `__cfromB` is not a temp name and stays.
    private var bridgePlaylistRows: [MusicRow] = []
    private var bridgeDone = false
    private var bridgeTotal: Int? = nil
    private var bridgeFailure: String? = nil
    private var bridgeWarming = false

    // C3: track counts and skipped-video counts, keyed by Bridge playlist id
    // — shared by the preview, the drill-in and a play, whichever populates
    // them first (D11). Never cleared except by a provenance reset: once
    // read, a count stays good until the library itself changes.
    private var trackCounts: [String: Int] = [:]
    private var skippedVideoCounts: [String: Int] = [:]

    // C3 item 1: the preview — one small read per focused playlist,
    // decoration only (D2), keyed by playlist id.
    private var bridgePreview: [String: [MusicRow]] = [:]
    private var bridgePreviewFailure: [String: String] = [:]
    private var bridgePreviewInFlight: Set<String> = []
    private enum BridgePreviewOutcome {
        case success(rows: [MusicRow], total: Int, skippedVideos: Int)
        case failure(String)
    }
    /// Rule 10: epoch-carrying, same discipline as every other inbox here.
    private var bridgePreviewInbox: [(id: String, epoch: Int, outcome: BridgePreviewOutcome)] = []

    // C3 item 2: the drill-in's own tracks feed. REBUILT, not reset-and-reused,
    // on every drill-in — its `fetch` closure captures the drilled playlist's
    // id, and D2 requires every open to read live regardless of whether it is
    // the same playlist as last time.
    private var bridgeTracksFeed: BridgeListFeed<MusicRow>? = nil
    private var bridgeTracksRows: [MusicRow] = []
    private var bridgeTracksDone = false
    private var bridgeTracksTotal: Int? = nil
    private var bridgeTracksFailure: String? = nil
    private var bridgeTracksWarming = false
    private var bridgeTracksPlaylistID: String? = nil
    private var bridgeTracksPlaylistName: String? = nil

    init(backend: AppleScriptBackend,
         routing: RoutingCoordinator, playlists: [String], subscriptionNames: Set<String> = [],
         sources: PlaylistDataSources,
         appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner,
         kittyEnabled: Bool = false, metaCache: PlaylistMetaCache = PlaylistMetaCache(),
         makeProvider: @escaping () -> MusicDataProvider? = { nil },
         loadMusicAppPlaylists: @escaping () -> (names: [String], subscription: Set<String>) = { ([], []) },
         makeSources: @escaping ([String]) -> PlaylistDataSources = { _ in .empty },
         warmUpSleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         screenWidth: @escaping () -> Int = { ScreenFrame.current().width }) {
        self.routing = routing
        self.backend = backend
        self.playlists = playlists
        self.subscriptionNames = subscriptionNames
        self.sources = sources
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        self.kittyEnabled = kittyEnabled
        self.metaCache = metaCache
        self.makeProvider = makeProvider
        self.loadMusicAppPlaylists = loadMusicAppPlaylists
        self.makeSources = makeSources
        self.warmUpSleep = warmUpSleep
        self.screenWidth = screenWidth
        self.meta = playlists.map { PlaylistMeta(name: $0) }
        if !playlists.isEmpty {
            // C2 item 0: the Shell's synchronous Music.app path (today's
            // construction-time behaviour, unchanged) — seed the rail from
            // the on-disk cache so it paints fully on first frame, then start
            // the background refresh that rewrites the cache.
            seedMetaFromCache()
            startBackgroundRefresh()
            railSource = .musicApp
        }
        // When `playlists` is empty (Bridge mode — the Shell never builds a
        // Music.app-mode scene with none, see `openPlaylistsScene`),
        // `railSource` stays nil: the first `tick()` decides and loads it.
    }

    func artPlacementsInvalidated() { lastPlaced = nil }

    private func seedMetaFromCache() {
        let cache = metaCache.load()
        for i in 0..<meta.count {
            guard let c = cache[meta[i].name] else { continue }
            meta[i].trackCount = c.count
            meta[i].durationSec = c.durationSec
            meta[i].isSmart = c.isSmart
            meta[i].specialKind = c.specialKind
            meta[i].loaded = true
            loaded.insert(i)
        }
    }

    /// Refresh every playlist's metadata off the main thread (so render never
    /// blocks on AppleScript), posting results to `inbox` and rewriting the cache.
    /// Batches can fail transiently when Music is under concurrent AppleScript load
    /// at startup (poller + preview fetches), so any index that doesn't come back is
    /// retried with backoff until all resolve or the attempt cap is hit.
    private func startBackgroundRefresh() {
        let names = playlists
        let sources = self.sources
        // Captured by VALUE, not `self`: the background thread must write
        // wherever this scene was told to (C0), and a weak `self` would race
        // teardown for no reason — the cache itself is what needs to survive.
        let metaCache = self.metaCache
        // Rule 10: captured here, on the main thread, BEFORE the thread
        // detaches — never read live from the background thread itself.
        let epoch = railEpoch
        Thread.detachNewThread { [weak self] in
            var merged = metaCache.load()
            var pending = Set(0..<names.count)
            var attempt = 0
            while !pending.isEmpty && attempt < 5 {
                attempt += 1
                let todo = pending.sorted()
                var i = 0
                while i < todo.count {
                    let batch = Array(todo[i..<min(i + 8, todo.count)])
                    let fetched = sources.onMeta(batch)
                    if !fetched.isEmpty { self?.postMeta(fetched, epoch: epoch) }
                    for (idx, v) in fetched where idx >= 0 && idx < names.count {
                        merged[names[idx]] = CachedPlaylistMeta(count: v.0, durationSec: v.1, isSmart: v.2, specialKind: v.3)
                        pending.remove(idx)
                    }
                    i += 8
                }
                if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.6) } // let Music settle, then retry
            }
            metaCache.save(merged)
        }
    }

    private func postMeta(_ results: [Int: (Int, Int, Bool, String)], epoch: Int) {
        inboxLock.lock(); for (k, v) in results { inbox[k] = (epoch, v) }; inboxLock.unlock()
    }

    private func drainMeta() -> [Int: (epoch: Int, meta: (Int, Int, Bool, String))] {
        inboxLock.lock(); defer { inboxLock.unlock() }
        let r = inbox; inbox = [:]; return r
    }

    // MARK: filter helpers

    /// Move the rail cursor by `delta` positions within the (possibly filtered)
    /// visible list, clamped to its ends. Rule 7: over the CURRENT rail's own
    /// indices, never crossed between modes.
    private func moveRail(by delta: Int) {
        let vis = currentVisibleIndices()
        guard !vis.isEmpty else { return }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        plCursor = vis[max(0, min(vis.count - 1, pos + delta))]
    }

    /// The indices `plCursor` moves over, in the CURRENT rail's own indexing:
    /// Music.app's (into `meta`/`playlists`) or Bridge's (into `bridgePlaylistRows`,
    /// MusicTUI's temp containers already excluded there). Rule 7: a Bridge
    /// cursor value is never read as an index into `playlists`, and the
    /// reverse — every key handler and render path goes through this rather
    /// than assuming which mode is live.
    private func currentVisibleIndices() -> [Int] {
        railSource == .bridge ? bridgeVisibleIndices() : visibleIndices()
    }

    private func visibleIndices() -> [Int] {
        guard !filterText.isEmpty else { return Array(0..<meta.count) }
        let q = filterText.lowercased()
        return (0..<meta.count).filter { meta[$0].name.lowercased().contains(q) }
    }

    private func bridgeVisibleIndices() -> [Int] {
        guard !filterText.isEmpty else { return Array(0..<bridgePlaylistRows.count) }
        let q = filterText.lowercased()
        return (0..<bridgePlaylistRows.count).filter { bridgePlaylistRows[$0].title.lowercased().contains(q) }
    }

    private func clampCursorToFilter() {
        let vis = currentVisibleIndices()
        if !vis.contains(plCursor) { plCursor = vis.first ?? 0 }
        plScroll = 0
    }

    /// After ANY change to `bridgePlaylistRows` — a fresh walk's first page
    /// replacing the list, or a later page appending to it, including after
    /// the C2-item-6 `r` retry restarts the walk from scratch — `plCursor`
    /// must still be a MEMBER of the active filter's visible set, not merely
    /// within its bounds. `plCursor` indexes the WHOLE (unfiltered) list
    /// directly (see `bridgeVisibleIndices()`'s doc comment), so a
    /// bounds-only check (`plCursor >= vis.count`) can leave it sitting at
    /// row 0 of the unfiltered list while the rail renders only the filtered
    /// rows: no cursor mark shows (its render position, found via
    /// `vis.firstIndex(of: plCursor)`, comes back nil), and the hero,
    /// preview, `p` and `s` all read `currentBridgeRow()` ->
    /// `bridgePlaylistRows[plCursor]` directly, so they silently show and
    /// would play the WRONG row. Reproduced live (2026-09-24, coordinator):
    /// a filter typed while Bridge was still warming, the 60s budget gave
    /// up, `r` retried, rows landed — the cursor stayed at 0 while the
    /// filtered rail showed its one match elsewhere in the list, and the
    /// hero showed the unfiltered row 0 instead.
    private func reclampBridgeCursorToFilter() {
        guard railSource == .bridge else { return }
        let vis = bridgeVisibleIndices()
        if !vis.contains(plCursor) { plCursor = vis.first ?? 0; plScroll = 0 }
    }
    /// Kick the full track-list fetch off-thread (inbox pattern); the tracks
    /// pane shows "Loading…" until it lands. The old synchronous version froze
    /// the whole shell for the duration of a 200-track fetch on Enter.
    private func loadFull() {
        trCursor = 0; trScroll = 0
        guard fullCache[plCursor] == nil, !fullInFlight.contains(plCursor) else { return }
        fullInFlight.insert(plCursor)
        let idx = plCursor
        let name = playlists[plCursor]
        let sources = self.sources
        let status = self.status
        let epoch = railEpoch   // rule 10: captured before the fetch, not read live from it
        previewQueue.async { [weak self] in
            let preview = sources.onTracks(idx)
            if preview == nil { status.post("Couldn't load tracks for '\(name)'.", error: true) }
            guard let self else { return }
            self.previewInboxLock.lock()
            self.fullInbox[idx] = (epoch, preview ?? PlaylistPreview(name: name, trackCount: 0, tracks: []))
            self.previewInboxLock.unlock()
        }
    }
    private func badgeText(_ m: PlaylistMeta) -> (String, String)? {
        switch playlistBadge(name: m.name, isSmart: m.isSmart ?? false, specialKind: m.specialKind ?? "none",
                             isSubscription: subscriptionNames.contains(m.name)) {
        case .smart: return ("SMART", ANSICode.amber)
        case .recent: return ("RECENT", ANSICode.amber)
        case .apple: return ("APPLE", ANSICode.amber)
        case .none: return nil
        }
    }

    /// "" when V is 0, else " · V video(s) skipped" (D11's exact plural rule:
    /// one video is "1 video skipped", several are "V videos skipped").
    private func skippedVideosSuffix(_ v: Int) -> String {
        guard v > 0 else { return "" }
        return " \u{00B7} \(v) video\(v == 1 ? "" : "s") skipped"
    }

    // MARK: - D7: provenance

    /// Once per tick, before anything else, compute which library the
    /// selected output implies and reset the rail if its recorded source no
    /// longer matches. Returns whether it reset, so the caller redraws.
    private func applyProvenance() -> Bool {
        let want: ListSource = makeProvider() != nil ? .bridge : .musicApp
        guard let source = railSource, source != want else { return false }
        resetRail(newWant: want)
        return true
    }

    /// C3 item 5: checked at the KEYPRESS for Enter, →, `p` and `s` —
    /// `tick`'s own provenance reset runs once per frame and may not have
    /// caught a flip that happened this same frame, before the next tick.
    /// Returns true (having posted the mismatch sentence, and sent nothing)
    /// when the rail's recorded source disagrees with what is selected RIGHT
    /// NOW; the caller does nothing else.
    private func refuseIfProvenanceMismatch() -> Bool {
        let bridgeSelected = makeProvider() != nil
        if railSource == .bridge, !bridgeSelected {
            status.post(LibraryProvenance.musicAppSelectedBridgeList, error: true)
            return true
        }
        if railSource == .musicApp, bridgeSelected {
            status.post(LibraryProvenance.bridgeSelectedMusicAppList, error: true)
            return true
        }
        return false
    }

    /// Clears every Music.app AND every Bridge structure, bumps the epoch so
    /// every in-flight background post (the Bridge walk, the Music.app async
    /// reload) is dropped on arrival, and leaves `railSource` nil so the very
    /// next step (`loadRail`) reloads from the right source this same tick.
    private func resetRail(newWant: ListSource) {
        railEpoch += 1
        // Music.app list structures.
        playlists = []
        subscriptionNames = []
        sources = .empty
        meta = []
        loaded = []
        fullCache = [:]
        previewLines = [:]
        previewInFlight = []
        fullInFlight = []
        musicAppReloadDone = false
        inboxLock.lock()
        inbox = [:]
        musicAppNamesPending = nil
        inboxLock.unlock()
        previewInboxLock.lock()
        previewInbox = [:]
        fullInbox = [:]
        bridgePreviewInbox = []
        previewInboxLock.unlock()
        // Bridge structures.
        bridgePlaylistRows = []
        bridgeDone = false
        bridgeTotal = nil
        bridgeFailure = nil
        bridgeWarming = false
        playlistsFeed.reset()
        trackCounts = [:]
        skippedVideoCounts = [:]
        bridgePreview = [:]
        bridgePreviewFailure = [:]
        bridgePreviewInFlight = []
        bridgeTracksFeed?.reset()
        bridgeTracksFeed = nil
        bridgeTracksRows = []
        bridgeTracksDone = false
        bridgeTracksTotal = nil
        bridgeTracksFailure = nil
        bridgeTracksWarming = false
        bridgeTracksPlaylistID = nil
        bridgeTracksPlaylistName = nil
        // Cursor, focus, filter.
        focus = .playlists
        plCursor = 0; plScroll = 0
        trCursor = 0; trScroll = 0
        filterText = ""
        filtering = false
        railSource = nil
        status.post(newWant == .bridge ? LibraryProvenance.bridgePlaylistsShown : LibraryProvenance.musicAppPlaylistsShown)
    }

    /// Starts loading the rail from `want`, and records that as its source
    /// immediately (before anything has landed) so a second call this tick,
    /// or next tick, doesn't re-kick it.
    private func loadRail(_ want: ListSource) {
        switch want {
        case .bridge:
            railSource = .bridge
            playlistsFeed.start()
        case .musicApp:
            railSource = .musicApp
            let epoch = railEpoch
            let load = loadMusicAppPlaylists
            Thread.detachNewThread { [weak self] in
                let result = load()
                guard let self else { return }
                self.inboxLock.lock()
                self.musicAppNamesPending = (epoch, result.names, result.subscription)
                self.inboxLock.unlock()
            }
        }
    }

    /// Applies a landed Music.app name load (construction's own seed already
    /// took the synchronous path in `init`; this is only ever the async,
    /// post-switch reload — D7 item 5).
    private func applyMusicAppNames(_ names: [String], _ subscription: Set<String>) {
        playlists = names
        subscriptionNames = subscription
        sources = makeSources(names)
        meta = names.map { PlaylistMeta(name: $0) }
        loaded = []
        seedMetaFromCache()
        startBackgroundRefresh()
    }

    // MARK: Scene

    @discardableResult
    /// Put the rail on the playlist that is playing when the tab is opened —
    /// once, on arrival, never while the person is browsing (2026-09-22).
    func becameActive() { snapToPlayingPending = true }

    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false

        // D7: before anything else this tick, so a rail reset here also
        // reloads from the right source this same tick.
        if applyProvenance() { changed = true }
        if railSource == nil {
            loadRail(makeProvider() != nil ? .bridge : .musicApp)
            changed = true
        }

        // Music.app-only: the playing-playlist snap. `contextName` and
        // `playlists[$0]` are both Music.app concepts (an AppleScript
        // playlist-name context), so this never runs for a Bridge rail —
        // rule 7's "never crossed" applies here too.
        if railSource == .musicApp, snapToPlayingPending, !snapshot.contextName.isEmpty, !playlists.isEmpty {
            snapToPlayingPending = false
            // `plCursor` indexes the WHOLE list, not the filtered view (see
            // clampCursorToFilter), so the match is mapped back through `vis`.
            let vis = visibleIndices()
            if let row = indexOfPlayingPlaylist(vis.map { playlists[$0] },
                                                contextName: snapshot.contextName),
               vis[row] != plCursor {
                plCursor = vis[row]   // renderRail moves `plScroll` to follow it
                changed = true
            }
        }
        if !artMapStarted, let load = sources.onArtworkMap {
            artMapStarted = true
            Thread.detachNewThread { [weak self] in
                let map = load()
                guard let self else { return }
                self.inboxLock.lock(); self.artMapInbox = map; self.inboxLock.unlock()
            }
        }
        // Apply metadata the background refresh thread has fetched (off-main), so
        // the slow AppleScript never blocks a render frame.
        let fresh = drainMeta()
        inboxLock.lock()
        let landedMap = artMapInbox; artMapInbox = nil
        let artLanded = artDirty; artDirty = false
        let landedNames = musicAppNamesPending; musicAppNamesPending = nil
        inboxLock.unlock()
        for (idx, entry) in fresh where entry.epoch == railEpoch && idx >= 0 && idx < meta.count {
            let v = entry.meta
            meta[idx].trackCount = v.0
            meta[idx].durationSec = v.1
            meta[idx].isSmart = v.2
            meta[idx].specialKind = v.3
            meta[idx].loaded = true
            loaded.insert(idx)
            changed = true
        }
        if let m = landedMap { artMap = m; changed = true }
        if artLanded { changed = true }
        // C2 item 2/4: the Music.app async reload's landing — only the
        // POST-SWITCH path posts here (construction's own seed is
        // synchronous), and only if the epoch and the rail's source still
        // agree with what it was kicked under.
        if let landed = landedNames, landed.epoch == railEpoch, railSource == .musicApp {
            applyMusicAppNames(landed.names, landed.subscription)
            musicAppReloadDone = true
            changed = true
        }
        // Landed preview and full-track fetches.
        previewInboxLock.lock()
        let freshPreviews = previewInbox; previewInbox = [:]
        let freshFull = fullInbox; fullInbox = [:]
        let freshBridgePreviews = bridgePreviewInbox; bridgePreviewInbox = []
        previewInboxLock.unlock()
        for (idx, entry) in freshPreviews {
            previewInFlight.remove(idx)
            guard entry.epoch == railEpoch else { continue }   // rule 10: outlived a provenance switch
            previewLines[idx] = entry.lines
            changed = true
        }
        for (idx, entry) in freshFull {
            fullInFlight.remove(idx)
            guard entry.epoch == railEpoch else { continue }   // rule 10: outlived a provenance switch
            fullCache[idx] = entry.preview
            changed = true
        }
        // C3 item 1: the Bridge preview's own landings.
        for (pid, epoch, outcome) in freshBridgePreviews {
            bridgePreviewInFlight.remove(pid)
            guard epoch == railEpoch else { continue }   // rule 10: outlived a provenance switch
            switch outcome {
            case .success(let rows, let total, let skippedVideos):
                bridgePreview[pid] = rows
                trackCounts[pid] = total
                skippedVideoCounts[pid] = skippedVideos
            case .failure(let sentence):
                bridgePreviewFailure[pid] = sentence
            }
            changed = true
        }

        // C2 item 3/rule 9: the Bridge list drain. `replace` and `append` are
        // NOT mutually exclusive within one drain — a fast local-socket walk
        // routinely finishes several pages before the scene's first tick, so
        // both must be applied, every tick, in this order (Part A's live-gate
        // finding).
        let bridgeDrain = playlistsFeed.drain()
        if let replace = bridgeDrain.replace {
            bridgePlaylistRows = replace.filter { !isTempPlaylistName($0.title) }
            reclampBridgeCursorToFilter()
            changed = true
        }
        if !bridgeDrain.append.isEmpty {
            bridgePlaylistRows.append(contentsOf: bridgeDrain.append.filter { !isTempPlaylistName($0.title) })
            // A page appended after an empty-vis replace can be the one that
            // introduces the filter's first match — see
            // `reclampBridgeCursorToFilter`'s doc comment.
            reclampBridgeCursorToFilter()
            changed = true
        }
        if bridgeTotal != bridgeDrain.total { bridgeTotal = bridgeDrain.total; changed = true }
        if bridgeFailure != bridgeDrain.failure { bridgeFailure = bridgeDrain.failure; changed = true }
        if bridgeWarming != bridgeDrain.warming { bridgeWarming = bridgeDrain.warming; changed = true }
        if bridgeDrain.done && !bridgeDone { bridgeDone = true; changed = true }

        // C3 item 2: the drill-in's own tracks feed, same replace-then-append
        // discipline (rule 9) as the list above.
        if let feed = bridgeTracksFeed {
            let drain = feed.drain()
            if let replace = drain.replace {
                bridgeTracksRows = replace
                changed = true
            }
            if !drain.append.isEmpty {
                bridgeTracksRows.append(contentsOf: drain.append)
                changed = true
            }
            if bridgeTracksTotal != drain.total { bridgeTracksTotal = drain.total; changed = true }
            if bridgeTracksFailure != drain.failure {
                bridgeTracksFailure = drain.failure
                // D4: a failure clears the rows and keeps the sentence — a
                // walk that failed never shows a partial list.
                if drain.failure != nil { bridgeTracksRows = [] }
                changed = true
            }
            if bridgeTracksWarming != drain.warming { bridgeTracksWarming = drain.warming; changed = true }
            if drain.done && !bridgeTracksDone { bridgeTracksDone = true; changed = true }
            if let pid = bridgeTracksPlaylistID {
                if let total = drain.total { trackCounts[pid] = total }
                if let skippedVideos = drain.skippedVideos { skippedVideoCounts[pid] = skippedVideos }
            }
        }

        let z = playlistZones(width: screenWidth())
        // Kick off a preview fetch (off-thread) when the pane is shown and empty.
        // Music.app-only: Bridge's own preview kick is the block just below.
        if railSource == .musicApp, focus == .playlists, z.mode == .three,
           previewLines[plCursor] == nil, !previewInFlight.contains(plCursor) {
            previewInFlight.insert(plCursor)
            let idx = plCursor
            let sources = self.sources
            let epoch = railEpoch   // rule 10: captured before the fetch, not read live from it
            previewQueue.async { [weak self] in
                let lines = sources.onPreview(idx) ?? []
                guard let self else { return }
                self.previewInboxLock.lock()
                self.previewInbox[idx] = (epoch, lines)
                self.previewInboxLock.unlock()
            }
        }
        // C3 item 1: Bridge's own preview kick — a small read of the
        // FOCUSED playlist, only at the rail (not while drilled in, where the
        // tracks feed above is the live read) and only in three-zone layout,
        // where the pane is actually shown.
        if railSource == .bridge, focus == .playlists, z.mode == .three, let row = currentBridgeRow() {
            let pid = row.id
            if bridgePreview[pid] == nil, bridgePreviewFailure[pid] == nil, !bridgePreviewInFlight.contains(pid),
               let provider = makeProvider() {
                bridgePreviewInFlight.insert(pid)
                let epoch = railEpoch
                let sleep = warmUpSleep
                previewQueue.async { [weak self] in
                    do {
                        let page = try retryingWhileWarming(budget: WarmUpBudget(), sleep: sleep) {
                            try provider.playlistTracks(playlistID: pid, cursor: nil, limit: PlaylistsScene.bridgePreviewLimit)
                        }
                        guard let self else { return }
                        self.previewInboxLock.lock()
                        self.bridgePreviewInbox.append(
                            (pid, epoch, .success(rows: page.rows, total: page.total ?? page.rows.count,
                                                  skippedVideos: page.skippedVideos)))
                        self.previewInboxLock.unlock()
                    } catch {
                        let sentence = (error as? MusicProviderError)?.errorDescription
                            ?? "Couldn't read that playlist from your library."
                        guard let self else { return }
                        self.previewInboxLock.lock()
                        self.bridgePreviewInbox.append((pid, epoch, .failure(sentence)))
                        self.previewInboxLock.unlock()
                    }
                }
            }
        }
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        // Clear the body region first.
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        if railSource == .bridge {
            renderBridge(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom, cellW: frame.cellW, cellH: frame.cellH)
            if filtering || !filterText.isEmpty {
                out += ANSICode.moveTo(row: bodyTop, col: z.railX)
                out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filterText)\(ANSICode.reset)\(filtering ? "\u{2588}" : "")"
            }
            return out
        }
        // C2 item 2: a post-switch Music.app reload that landed with zero
        // playlists — `meta` would be empty, and `renderHero`'s `meta[plCursor]`
        // must never be reached with nothing in it.
        if railSource == .musicApp, playlists.isEmpty, musicAppReloadDone {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX) + "\(ANSICode.dim)No playlists found.\(ANSICode.reset)"
            return out
        }
        // Nothing decided yet (the very first frame after a Bridge-intended
        // construction, before its first `tick()`), or an async reload still
        // in flight: `meta` is empty and the byte-for-byte Music.app path
        // below must not run over it.
        if meta.isEmpty {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX) + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return out
        }

        // Music.app rendering, byte-for-byte unchanged from before C2.
        renderRail(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        renderHero(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom, cellW: frame.cellW, cellH: frame.cellH)
        if focus == .tracks {
            renderTrackList(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        } else {
            renderPreview(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        }
        if filtering || !filterText.isEmpty {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filterText)\(ANSICode.reset)\(filtering ? "\u{2588}" : "")"
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Mode-aware (C3): Music.app's track count is keyed by `plCursor`
        // into `fullCache`; Bridge's is the drilled-in feed's own row count.
        // Reading the wrong one clamped `trCursor` to 0 forever on a Bridge
        // rail, since `fullCache` is never populated there.
        let trackCount = railSource == .bridge ? bridgeTracksRows.count : (fullCache[plCursor]?.tracks.count ?? 0)

        if filtering {
            switch key {
            case .enter: filtering = false
            case .escape: filtering = false; filterText = ""; clampCursorToFilter()
            // Arrows navigate the filtered list WHILE typing (fzf-style) —
            // having to Enter out of filter mode first was pure friction.
            case .up: moveRail(by: -1)
            case .down: moveRail(by: 1)
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filterText.isEmpty { filterText.removeLast() }
                clampCursorToFilter()
            case .char(let c): filterText.append(c); clampCursorToFilter()
            case .space: filterText.append(" "); clampCursorToFilter()
            default: break
            }
            return .redraw
        }

        // Vim aliases: j/k/h/l/g/G/ctrl-d/ctrl-u. Applied here, after the raw
        // filter-text capture above returns, so typing a playlist name
        // containing those letters into the filter box isn't intercepted.
        let key = vimAlias(key, listScene: true)

        switch key {
        case .up:
            if focus == .playlists { moveRail(by: -1) }
            else { trCursor = max(0, trCursor - 1) }
            return .redraw
        case .down:
            if focus == .playlists { moveRail(by: 1) }
            else { trCursor = min(max(0, trackCount - 1), trCursor + 1) }
            return .redraw
        case .pageUp:
            if focus == .playlists { moveRail(by: -10) }
            else { trCursor = max(0, trCursor - 10) }
            return .redraw
        case .pageDown:
            if focus == .playlists { moveRail(by: 10) }
            else { trCursor = min(max(0, trackCount - 1), trCursor + 10) }
            return .redraw
        case .home:
            if focus == .playlists, let first = currentVisibleIndices().first { plCursor = first }
            else { trCursor = 0 }
            return .redraw
        case .end:
            if focus == .playlists, let last = currentVisibleIndices().last { plCursor = last }
            else { trCursor = max(0, trackCount - 1) }
            return .redraw
        case .char("/"):
            filtering = true
            return .redraw
        case .enter:
            if focus == .playlists {
                if refuseIfProvenanceMismatch() { return .redraw }
                if railSource == .bridge { drillBridgePlaylist(); return .redraw }
                loadFull(); focus = .tracks; trCursor = 0; trScroll = 0
                return .redraw
            } else {
                if refuseIfProvenanceMismatch() { return .redraw }
                if railSource == .bridge {
                    // C3 item 3: matches today's "still loading" guard.
                    guard bridgeTracksDone, bridgeTracksFailure == nil, !bridgeTracksRows.isEmpty,
                          let pid = bridgeTracksPlaylistID, let name = bridgeTracksPlaylistName else { return .none }
                    playBridgePlaylist(playlistID: pid, name: name, shuffle: false, startAt: trCursor + 1,
                                       startRequired: true, rows: bridgeTracksRows,
                                       skippedVideos: skippedVideoCounts[pid] ?? 0)
                    return .push(.nowPlaying)
                }
                guard fullCache[plCursor] != nil else { return .none }   // still loading
                playTrack(trCursor)
                return .push(.nowPlaying)
            }
        case .right:
            // → drills in like Enter on the rail (vim `l` arrives here as
            // .right), symmetric with ← back. At tracks focus Enter means
            // play, so → is a no-op — there's nothing deeper to drill into.
            guard focus == .playlists else { return .none }
            if refuseIfProvenanceMismatch() { return .redraw }
            if railSource == .bridge { drillBridgePlaylist(); return .redraw }
            loadFull(); focus = .tracks; trCursor = 0; trScroll = 0
            return .redraw
        case .left:
            if focus == .tracks {
                // C3 item 2: back to the rail stops the tracks walk.
                if railSource == .bridge { bridgeTracksFeed?.reset(); bridgeTracksFeed = nil }
                focus = .playlists
                return .redraw
            }
            return .pop
        case .escape:
            if focus == .tracks {
                if railSource == .bridge { bridgeTracksFeed?.reset(); bridgeTracksFeed = nil }
                focus = .playlists
                return .redraw
            }
            return .pop
        // C2 item 6: Bridge's own retry, only while a failure is showing —
        // resets and restarts only the Bridge feed, never the Music.app
        // background refresh (which has no such key at all). Otherwise `r`
        // does nothing, as today (falls to `default`).
        case .char("r") where railSource == .bridge && focus == .playlists && bridgeFailure != nil:
            playlistsFeed.reset()
            bridgeFailure = nil
            bridgeDone = false
            playlistsFeed.start()
            status.post("Asking Bridge for your playlists again\u{2026}")
            return .none
        // C3 item 2: the tracks-level retry — starts a new walk, exactly as
        // a drill-in does.
        case .char("r") where railSource == .bridge && focus == .tracks && bridgeTracksFailure != nil:
            drillBridgePlaylist()
            return .none
        case .char("p"):
            if refuseIfProvenanceMismatch() { return .redraw }
            if railSource == .bridge {
                guard let row = currentBridgeRow() else { return .none }
                appQueue.clear()
                let cached = focus == .tracks && bridgeTracksPlaylistID == row.id
                    && bridgeTracksDone && bridgeTracksFailure == nil
                playBridgePlaylist(playlistID: row.id, name: row.title, shuffle: false, startAt: 1,
                                   startRequired: false, rows: cached ? bridgeTracksRows : nil,
                                   skippedVideos: cached ? skippedVideoCounts[row.id] : nil)
                return .push(.nowPlaying)
            }
            playPlaylist(shuffle: false); return .push(.nowPlaying)
        case .char("s"):
            if refuseIfProvenanceMismatch() { return .redraw }
            if railSource == .bridge {
                guard let row = currentBridgeRow() else { return .none }
                appQueue.clear()
                let cached = focus == .tracks && bridgeTracksPlaylistID == row.id
                    && bridgeTracksDone && bridgeTracksFailure == nil
                playBridgePlaylist(playlistID: row.id, name: row.title, shuffle: true, startAt: 1,
                                   startRequired: false, rows: cached ? bridgeTracksRows : nil,
                                   skippedVideos: cached ? skippedVideoCounts[row.id] : nil)
                return .push(.nowPlaying)
            }
            playPlaylist(shuffle: true); return .push(.nowPlaying)
        case .char("b"):
            return .push(.nowPlaying)
        default:
            return .none
        }
    }

    // MARK: playback (user-initiated; brief inline stall acceptable)

    /// C3 item 2: drills into the playlist under the rail cursor. Resets the
    /// old tracks feed (its own epoch drops anything already in flight from
    /// it) and builds a brand-new one bound to THIS playlist's id — every
    /// open re-reads live (D2), even a second drill-in of the same playlist.
    private func drillBridgePlaylist() {
        guard let row = currentBridgeRow() else { return }
        let pid = row.id
        focus = .tracks
        trCursor = 0; trScroll = 0
        bridgeTracksFeed?.reset()
        bridgeTracksRows = []
        bridgeTracksDone = false
        bridgeTracksTotal = nil
        bridgeTracksFailure = nil
        bridgeTracksWarming = false
        bridgeTracksPlaylistID = pid
        bridgeTracksPlaylistName = row.title
        let sleep = warmUpSleep
        let feed = BridgeListFeed<MusicRow>(
            fetch: { [weak self] cursor, limit in
                guard let self, let provider = self.makeProvider() else {
                    throw MusicProviderError.unavailable("Bridge is not the selected output")
                }
                return try provider.playlistTracks(playlistID: pid, cursor: cursor, limit: limit)
            },
            map: { $0 },
            sleep: sleep,
            limit: Self.bridgeTracksPageLimit)
        bridgeTracksFeed = feed
        feed.start()
    }

    /// C3 item 6. Plays a Bridge playlist by exact ids, with no join.
    /// `rows`/`skippedVideos` are the rows already on screen (both non-nil
    /// together, or both nil for a fresh read — D2/item 4).
    ///
    /// `startRequired` (Addendum U): true only for Enter on a specific track
    /// row (`startAt` came from `trCursor`, a row the person was looking at);
    /// false for `p`/`s`, which always start the whole playlist at row 1
    /// regardless of where the cursor happens to be.
    private func playBridgePlaylist(playlistID: String, name: String, shuffle: Bool, startAt: Int,
                                    startRequired: Bool, rows: [MusicRow]?, skippedVideos: Int?) {
        let makeProvider = self.makeProvider
        let routing = self.routing
        let status = self.status
        let warmUpSleep = self.warmUpSleep
        let epoch = railEpoch   // rule 10: this action's own epoch, captured now
        actions.run("Play") { [self] in
            do {
                guard let provider = makeProvider() else {
                    throw ActionError(message: LibraryProvenance.musicAppSelectedBridgeList)
                }
                let budget = WarmUpBudget()
                let onWarming: (TimeInterval) -> Void = { _ in
                    status.post("Preparing your library \u{2014} '\(name)' will play when it's ready\u{2026}")
                }

                let finalRows: [MusicRow]
                let finalSkipped: Int
                if let rows, let skippedVideos {
                    finalRows = rows
                    finalSkipped = skippedVideos
                } else {
                    var collected: [MusicRow] = []
                    var lastSkipped = 0
                    // F4/C4: the FRESH whole-playlist play walk only — the one
                    // path that reads for a `p`/`s` with no cached rows —
                    // hints Bridge with `for_queue` so an over-bound playlist
                    // is refused on page 1 rather than after a full walk.
                    let walkError = walkLibraryPages(
                        fetch: { c, l in try provider.playlistTracksForQueue(playlistID: playlistID, cursor: c, limit: l) },
                        limit: Self.bridgeTracksPageLimit,
                        onPage: { page in
                            collected.append(contentsOf: page.rows)
                            lastSkipped = page.skippedVideos
                            return true
                        },
                        onRestart: { collected = []; lastSkipped = 0 },
                        onWarming: onWarming, sleep: warmUpSleep, budget: budget)
                    if let walkError {
                        throw ActionError(message: walkError.errorDescription ?? "Couldn't read that playlist from your library.")
                    }
                    finalRows = collected
                    finalSkipped = lastSkipped
                    // D2: after a fresh read, the pane shows what was queued.
                    self.previewInboxLock.lock()
                    self.bridgePreviewInbox.append(
                        (playlistID, epoch, .success(rows: finalRows, total: finalRows.count, skippedVideos: finalSkipped)))
                    self.previewInboxLock.unlock()
                }

                try require(!finalRows.isEmpty, "'\(name)' has no songs Bridge can play.")
                let ids = bridgeQueueIDs(finalRows, shuffle: shuffle, startAt: startAt)

                // Addendum U: set only on the attempt that actually succeeds.
                var skippedUnavailable = 0
                _ = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: warmUpSleep) {
                    try routing.perform(.playlistPlay, musicApp: {
                        throw ActionError(message: "Output changed to Music.app before '\(name)' could play on Bridge; nothing was played.")
                    }, source: { _ in
                        skippedUnavailable = try provider.playReportingSkips(
                            ids: ids, startRequired: startRequired).skippedUnavailable
                    }, unaffected: {})
                }
                status.post(bridgePlaylistPlayMessage(name: name, queued: ids.count, skippedVideos: finalSkipped,
                                                       skippedUnavailable: skippedUnavailable,
                                                       startAt: startAt, shuffle: shuffle))
            } catch let e as MusicProviderError {
                // Bridge's own words reach the footer — the over-100 bound,
                // the repeated-title refusal, and every other refusal alike.
                throw ActionError(message: e.errorDescription ?? "Bridge couldn't play that.")
            }
        }
    }

    /// The playlist under the rail cursor, in Bridge's own indexing. `nil`
    /// when the list is empty, AND when `plCursor` is not currently a
    /// VISIBLE (filtered) row.
    ///
    /// A bounds check alone isn't enough: `reclampBridgeCursorToFilter()`
    /// falls back to `vis.first ?? 0` when the active filter matches
    /// NOTHING (or hasn't matched anything YET, mid-walk, before a later
    /// page appends the first match) — that `0` is bounds-valid but HIDDEN
    /// by the filter. Every caller here already guards the optional
    /// (`p`/`s`/drill-in no-op on nil, the hero/preview render nothing), so
    /// making this the single membership check, rather than trusting
    /// `plCursor` to already be correct, is what stops a zero-match filter
    /// from silently showing, previewing, drilling into or playing a row
    /// the rail isn't even rendering (Codex's review, 971b9659).
    private func currentBridgeRow() -> MusicRow? {
        guard plCursor >= 0, plCursor < bridgePlaylistRows.count else { return nil }
        guard bridgeVisibleIndices().contains(plCursor) else { return nil }
        return bridgePlaylistRows[plCursor]
    }

    private func playTrack(_ trackIndex: Int) {
        // App-owned queue (see AppQueue.swift). macOS 26.x broke `play track N of
        // playlist X`, so instead of leaning on Music's queue we hold the playlist
        // ourselves: fetch its tracks, register the queue at position N, and play
        // that one track. The poller advances when it stops at end (Music Autoplay
        // must be off), and next/prev/Enter navigate our list — full up/down. On the
        // action queue so the bulk track fetch never freezes the UI and failures
        // surface as a toast instead of a silent dead Enter.
        let name = playlists[plCursor]
        let pos = trackIndex + 1
        let store = self.appQueue
        let backend = self.backend
        actions.run("Play") { [routing] in
            // C3 item 7 / Codex before-push (reorder, ruled): checked FIRST,
            // before any Music.app read — a residual race (the mode flipped
            // between the keypress's own provenance check and this action
            // finally running on the action queue) must refuse without
            // running `fetchPlaylistTracks`'s AppleScript, not just before
            // resolving by name. Still read live, at execution time, not
            // captured at the keypress.
            if routing.mode == .source {
                throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
            }
            let tracks = fetchPlaylistTracks(backend: backend, playlist: name)
            try require(!tracks.isEmpty, "Couldn't load tracks for '\(name)'.")
            try require(pos >= 1 && pos <= tracks.count, "Track \(pos) is out of range.")
            store.set(AppQueue(playlistName: name, tracks: tracks, currentIndex: pos))
            try require(playQueueTrack(backend: backend, playlist: name, position: pos), "Couldn't play '\(name)'.")
        }
    }
    private func playPlaylist(shuffle: Bool) {
        // Whole-playlist play uses Music's native (gapless) queue — relinquish the
        // app-owned queue so the poller reads Music's context again.
        appQueue.clear()
        let esc = escapeAppleScriptString(playlists[plCursor])
        let name = playlists[plCursor]
        actions.run("Play") { [routing] in
            if routing.mode == .source {
                // C3 item 7: same residual-race refusal as playTrack above.
                throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
            }
            try require((try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }) != nil,
                        "Couldn't set shuffle for '\(name)'.")
            try require((try? syncRun { try await self.backend.runMusic("play playlist \"\(esc)\"") }) != nil,
                        "Couldn't play '\(name)'.")
        }
    }

    // MARK: render helpers (relocated from runPlaylistBrowser, region-relative)

    private func renderRail(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        let listY = bodyTop + 2
        let maxVisible = max(1, bodyBottom - listY)
        let vis = visibleIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX) + "\(ANSICode.dim)(no matches)\(ANSICode.reset)"
            return
        }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        if pos < plScroll { plScroll = pos }
        if pos >= plScroll + maxVisible { plScroll = pos - maxVisible + 1 }
        let end = min(vis.count, plScroll + maxVisible)
        let nameWidth = z.railWidth - 2 - metaCol - 1
        for p in plScroll..<end {
            let i = vis[p]
            let row = listY + (p - plScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let m = meta[i]
            let display = m.name
            let nm = railName(display, nameWidth: max(1, nameWidth))
            let metaCell: String
            if !m.loaded {
                metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol - 1))\u{00B7}\(ANSICode.reset)"
            } else if let (text, color) = badgeText(m) {
                let padded = String(repeating: " ", count: max(0, metaCol - text.count)) + text
                metaCell = "\(color)\(padded)\(ANSICode.reset)"
            } else {
                let c = "\(m.trackCount ?? 0)"
                let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
            }
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if i == plCursor {
                // One selection language across the shell: inverse-video when
                // this zone has focus (matches Up Next), dim bar otherwise.
                if focus == .playlists {
                    out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset) \(metaCell)"
                } else {
                    out += "\(ANSICode.dim)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
                }
            } else {
                out += "  \(ANSICode.white)\(padName)\(ANSICode.reset) \(metaCell)"
            }
        }
    }

    private func renderHero(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int,
                            cellW: Double, cellH: Double) {
        var y = bodyTop
        let m = meta[plCursor]
        let title = m.name
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(title, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        if m.loaded, let c = m.trackCount {
            let dur = m.durationSec.map { " \u{00B7} " + formatPlaylistDuration($0) } ?? ""
            out += "\(ANSICode.dim)\(c) tracks\(dur)\(ANSICode.reset)"
        }
        y += 2
        // Fill the hero pane, square: the full hero width and every row left
        // after the art (4 reserved below — blank, then badge+blank or a
        // single spacer, then hint). kittySquareRect derives the actual
        // square placement from whichever of gw/gh binds tighter, so this is
        // no longer capped to the Now tab's old 44x22.
        let gw = z.heroWidth
        let gh = max(0, bodyBottom - y - 4)
        var artBlock: ArtBlock? = nil
        if let entry = artMap[title.lowercased().trimmingCharacters(in: .whitespaces)] {
            artBlock = artwork.block(key: entry.id,
                                     url: ArtworkStore.resolveURL(entry.url, width: 300, height: 300),
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
        // Square-equivalent rect every branch below must agree on — see
        // ArtworkStore.renderArtHero's identical computation (this hero is a
        // separate copy of that ladder, not a call to the shared function).
        let (pc, pr) = kittySquareRect(maxCols: gw, maxRows: gh, cellW: cellW, cellH: cellH)
        switch artBlock {
        case .lines(let art):
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            // Pad/cap to exactly `pr` rows (the square-equivalent height
            // kitty/the placeholder use), not the full reserved `gh` box —
            // see ArtworkStore.renderArtHero's `.lines` case for why this
            // crops real chafa content on non-kitty terminals rather than
            // just trimming blank padding, and why that trade is worth it.
            let blank = String(repeating: " ", count: gw)
            let rows = art.prefix(pr) + Array(repeating: blank, count: max(0, pr - art.count))
            for line in rows {
                out += ANSICode.moveTo(row: y, col: z.heroX) + line + ANSICode.reset
                y += 1
            }
        case .kitty(let id, let transmit):
            // Square-equivalent rect, in pixels for the measured cell size:
            // see LibraryScene — kitty stretches, chafa fits.
            let current = (id: id, row: y, col: z.heroX, cols: pc, rows: pr)
            if let last = lastPlaced, last == current {
                // Unchanged: the placement from a prior frame is still on
                // screen — emit nothing (spaces would flicker under the image).
            } else {
                if let last = lastPlaced { out += kittyDeleteEscape(id: last.id) }
                // Erase the full reserved box (gh) — safe even though only
                // `pr` rows are actually placed; erasing less than gh would
                // risk a stale row if a resize shrinks pr between frames.
                let blank = String(repeating: " ", count: gw)
                for i in 0..<gh {
                    out += ANSICode.moveTo(row: y + i, col: z.heroX) + blank
                }
                out += transmit ?? ""
                out += ANSICode.moveTo(row: y, col: z.heroX) + kittyPlaceEscape(id: id, cols: pc, rows: pr)
                lastPlaced = current
            }
            // Advance by what was actually drawn (pr), not the reserved box
            // (gh) — advancing by gh left a dead gap once gh (the hero's
            // now-unclamped height) grew past pr.
            y += pr
        case .none:
            if let last = lastPlaced { out += kittyDeleteEscape(id: last.id); lastPlaced = nil }
            // Same square rect a real kitty cover would occupy — see the
            // `.kitty` case above. y now advances by `pr`, same as `.kitty`
            // and `.lines`, so the badge/hint lines below don't shift
            // depending on which art path rendered.
            let gradient = gradientBlock(name: m.name, width: pc, height: pr)
            for (i, line) in gradient.enumerated() {
                out += ANSICode.moveTo(row: y + i, col: z.heroX) + line
            }
            y += pr
        }
        y += 1
        if let (text, c) = badgeText(m) {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(c)\(text)\(ANSICode.reset)"
            y += 2
        } else { y += 1 }
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Browse   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    private func renderPreview(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Preview\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let lines = previewLines[plCursor] {
            if lines.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                let maxLines = max(1, bodyBottom - y + 1)
                for (i, line) in lines.prefix(maxLines).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
    }

    private func renderTrackList(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        let tracks = fullCache[plCursor]?.tracks ?? []
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Tracks\(ANSICode.reset) \(ANSICode.dim)\(tracks.count)\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if fullCache[plCursor] == nil {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return
        }
        let maxVis = max(1, bodyBottom - y)
        if trCursor < trScroll { trScroll = trCursor }
        if trCursor >= trScroll + maxVis { trScroll = trCursor - maxVis + 1 }
        let end = min(tracks.count, trScroll + maxVis)
        for i in trScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let text = truncText(tracks[i], to: max(2, z.rightWidth - 4))
            if i == trCursor {
                out += "\(ANSICode.inverse)\(idx)  \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }

    // MARK: - C2/C3: Bridge rendering

    /// The playlist under the cursor, in Bridge's own indexing. `nil` when
    /// the list is empty — `renderBridgeHero` skips the hero entirely rather
    /// than indexing an empty array, unlike Music.app's `meta[plCursor]`
    /// (which is never reached empty — see `render()`'s guard).
    private func renderBridge(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int,
                              cellW: Double, cellH: Double) {
        renderBridgeRail(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        renderBridgeHero(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom, cellW: cellW, cellH: cellH)
        if focus == .tracks {
            renderBridgeTrackList(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        } else {
            renderBridgeRightPane(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        }
    }

    private func renderBridgeRail(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        // The header, dim, at bodyTop + 1 — bodyTop itself stays reserved for
        // the filter-box overlay, exactly as Music.app's rail leaves it blank
        // today (`listY = bodyTop + 2` there too).
        out += ANSICode.moveTo(row: bodyTop + 1, col: z.railX)
        let header = bridgeDone
            ? "Playlists \u{2014} Bridge library (\(groupedCount(bridgePlaylistHeaderCount(shown: bridgePlaylistRows.count, wireTotal: bridgeTotal))))"
            : "Playlists \u{2014} Bridge library"
        out += "\(ANSICode.dim)\(header)\(ANSICode.reset)"

        let listY = bodyTop + 2
        let bodyHeight = bodyBottom - bodyTop + 1
        let showNote = bodyHeight >= 8
        let listBottom = showNote ? bodyBottom - 2 : bodyBottom
        let maxVisible = max(1, listBottom - listY + 1)
        let vis = bridgeVisibleIndices()

        if vis.isEmpty {
            // D9's empty-state order: a failure, then warming, then loading,
            // then genuinely empty.
            let msg: String
            if let failure = bridgeFailure {
                msg = "\(failure) - press r to retry"
            } else if bridgeWarming {
                msg = "Preparing your library\u{2026}"
            } else if !bridgeDone {
                msg = "Loading playlists\u{2026}"
            } else {
                msg = "(no playlists)"
            }
            out += ANSICode.moveTo(row: listY, col: z.railX) + "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
        } else {
            let pos = vis.firstIndex(of: plCursor) ?? 0
            if pos < plScroll { plScroll = pos }
            if pos >= plScroll + maxVisible { plScroll = pos - maxVisible + 1 }
            let end = min(vis.count, plScroll + maxVisible)
            let nameWidth = z.railWidth - 2 - metaCol - 1
            for p in plScroll..<end {
                let i = vis[p]
                let row = listY + (p - plScroll)
                out += ANSICode.moveTo(row: row, col: z.railX)
                let r = bridgePlaylistRows[i]
                let nm = railName(r.title, nameWidth: max(1, nameWidth))
                // No "·" loading dot and no badge (D1: MusicKit gives no
                // smart flag). C3: the count, once a preview/drill-in/play
                // has read this playlist — "The rail count: N (songs)" (D11).
                let metaCell: String
                if let count = trackCounts[r.id] {
                    let c = "\(count)"
                    let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                    metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
                } else {
                    metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol))\(ANSICode.reset)"
                }
                let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
                if i == plCursor {
                    if focus == .playlists {
                        out += "\u{258C} \(ANSICode.inverse)\(padName)\(ANSICode.reset) \(metaCell)"
                    } else {
                        out += "\(ANSICode.dim)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
                    }
                } else {
                    out += "  \(ANSICode.white)\(padName)\(ANSICode.reset) \(metaCell)"
                }
            }
        }

        if showNote {
            renderBridgeMissingNote(z, into: &out, bodyBottom: bodyBottom)
        }
    }

    /// Word-wraps `Self.bridgeMissingNote` into at most two lines at the
    /// rail's width, truncating the last with an ellipsis if it still
    /// doesn't fit (D8).
    private func renderBridgeMissingNote(_ z: PlaylistZones, into out: inout String, bodyBottom: Int) {
        let lines = wordWrap(Self.bridgeMissingNote, width: z.railWidth, maxLines: 2)
        let startRow = bodyBottom - lines.count + 1
        for (i, line) in lines.enumerated() {
            out += ANSICode.moveTo(row: startRow + i, col: z.railX) + "\(ANSICode.dim)\(line)\(ANSICode.reset)"
        }
    }

    private func renderBridgeHero(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int,
                                  cellW: Double, cellH: Double) {
        guard let row = currentBridgeRow() else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(row.title, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        // "N tracks[ · V videos skipped]" (D11) — blank until a preview, a
        // drill-in or a play has read this playlist (C3).
        if let total = trackCounts[row.id] {
            let skipped = skippedVideoCounts[row.id] ?? 0
            out += "\(ANSICode.dim)\(total) tracks\(skippedVideosSuffix(skipped))\(ANSICode.reset)"
        }
        y += 2
        let gw = z.heroWidth
        let gh = max(0, bodyBottom - y - 4)
        // D1: always the gradient — no artMap lookup and no artwork kick
        // while `railSource == .bridge`. Same square-equivalent sizing as
        // Music.app's hero, for visual consistency between the two rails.
        let (pc, pr) = kittySquareRect(maxCols: gw, maxRows: gh, cellW: cellW, cellH: cellH)
        let gradient = gradientBlock(name: row.title, width: pc, height: pr)
        for (i, line) in gradient.enumerated() {
            out += ANSICode.moveTo(row: y + i, col: z.heroX) + line
        }
        y += pr
        // D1: no badge, ever — Bridge exposes no smart/recent/apple flag.
        // Matches Music.app's own `else { y += 1 }` branch, plus the same
        // +1 art-trailer spacer every branch there takes first.
        y += 2
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Browse   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    /// C3 item 1: the preview pane, "title — artist" lines, numbered as
    /// Music.app's own preview is.
    private func renderBridgeRightPane(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        guard let row = currentBridgeRow() else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Preview\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let failure = bridgePreviewFailure[row.id] {
            // Not truncated — same reasoning as the tracks pane's failure.
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(failure)\(ANSICode.reset)"
        } else if let rows = bridgePreview[row.id] {
            if rows.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                let maxLines = max(1, bodyBottom - y + 1)
                for (i, r) in rows.prefix(maxLines).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    let line = "\(r.title) \u{2014} \(r.artist)"
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
    }

    /// C3 item 2: the tracks pane. Header, then failure/warming/loading, else
    /// "title — artist" rows — the skipped videos are never rows themselves,
    /// the cursor moves over songs only (D11).
    private func renderBridgeTrackList(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        let total = bridgeTracksTotal ?? bridgeTracksRows.count
        let skipped = bridgeTracksPlaylistID.flatMap { skippedVideoCounts[$0] } ?? 0
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Tracks \(total)\(skippedVideosSuffix(skipped))\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let failure = bridgeTracksFailure {
            // Not truncated, matching the rail's own empty-state message
            // (renderBridgeRail) — a long sentence overflows the pane's
            // column rather than losing words a person needs to read.
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(failure) - press r to retry\(ANSICode.reset)"
            return
        }
        if bridgeTracksWarming {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Preparing your library\u{2026}\(ANSICode.reset)"
            return
        }
        if !bridgeTracksDone && bridgeTracksRows.isEmpty {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading\u{2026}\(ANSICode.reset)"
            return
        }
        let maxVis = max(1, bodyBottom - y)
        if trCursor < trScroll { trScroll = trCursor }
        if trCursor >= trScroll + maxVis { trScroll = trCursor - maxVis + 1 }
        let end = min(bridgeTracksRows.count, trScroll + maxVis)
        for i in trScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let r = bridgeTracksRows[i]
            let text = truncText("\(r.title) \u{2014} \(r.artist)", to: max(2, z.rightWidth - 4))
            if i == trCursor {
                out += "\(ANSICode.inverse)\(idx)  \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }

    /// Word-wraps `text` into at most `maxLines` lines of `width` columns,
    /// breaking on spaces; a single word longer than `width`, or leftover
    /// text past `maxLines`, is ellipsis-truncated (`truncText`).
    private func wordWrap(_ text: String, width: Int, maxLines: Int) -> [String] {
        guard width > 0, maxLines > 0 else { return [] }
        var lines: [String] = []
        var current = ""
        var remaining = text.split(separator: " ").map(String.init)[...]
        while let word = remaining.first {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= width {
                current = candidate
                remaining = remaining.dropFirst()
            } else if current.isEmpty {
                current = truncText(word, to: width)
                remaining = remaining.dropFirst()
            } else {
                lines.append(current)
                current = ""
                if lines.count == maxLines { break }
            }
        }
        if lines.count < maxLines, !current.isEmpty {
            lines.append(current)
            current = ""
        }
        if (!remaining.isEmpty || !current.isEmpty), let last = lines.last {
            lines[lines.count - 1] = truncText(last, to: width)
        }
        return lines
    }
}

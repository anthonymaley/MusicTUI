// tools/music/Sources/TUI/Shell/LibraryScene.swift
// The Library tab. Albums (three-zone: rail + hero + track preview), Songs (flat
// filterable list), and Artists (flat list → drill into the artist's albums,
// which reuse the album three-zone render) are all wired end to end.
// All navigation is delegated to the pure `libraryReduce`; the scene owns only
// view state (scroll, filter) and executes the emitted LibraryAction off-thread.
import Foundation

/// Normalize an artist name for cross-list matching (album.artist ↔ artist.name).
/// Lowercase, then split on the full `Character.isWhitespace` class and rejoin,
/// which trims the edges and collapses internal runs in one step. Still a
/// deliberately shallow heuristic; compilation credits ("Various Artists") and
/// "feat." strings can still miss, which is why the album-artists filter is
/// opt-in and defaults off.
///
/// It used to lowercase and trim only, so "A  Tribe  Called  Quest" kept its
/// double spaces and did not match the single-spaced form. The consequence is
/// specific: internal spacing differences made the artist-list row miss the
/// album-credit tier set, hiding that artist from a filtered tier. It never
/// grouped or merged artist rows, and still does not. Measured 2026-09-02
/// (axis 1 of three); corrected 2026-09-03 alongside the whitespace class.
func normalizeArtist(_ s: String) -> String {
    s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
    private let routing: RoutingCoordinator
    private let sources: LibraryDataSources
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner

    /// Albums, songs and artists are three views of ONE bulk read, so the
    /// in-flight guard and the retry budget live here once. Per-list budgets
    /// would be nine reads of a failing Music.app.
    private let loads = LibraryLoadCoordinator()
    /// Mirrored out of `loads` in tick so render and input read plain Bools and
    /// never touch the coordinator's lock.
    private var readFailed = false
    private var retriesExhausted = false

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
    // D7: which library each list's rows ACTUALLY came from, set when its load
    // picks its branch — not which output happens to be selected at the moment
    // it paints. `nil` means "hasn't loaded under any output yet", which is the
    // only state a provenance mismatch can never fire on (there is nothing yet
    // to be wrong about). `tick`'s provenance check (D7 item 4) resets a list
    // whose recorded source differs from the live one.
    private var songsSource: ListSource? = nil
    private var albumsSource: ListSource? = nil
    private var artistsSource: ListSource? = nil
    /// Whether the Songs list is Bridge's, computed from `songsSource` so every
    /// existing read site (render, retry, `tabShowsTwoLibraries`) needed no
    /// change when D7 added the source record.
    private var songsFromBridge: Bool { songsSource == .bridge }
    /// Bumped by a provenance reset (D7 item 4) or a manual Bridge retry.
    /// Every inbox post for a list carries the epoch its load started under;
    /// a post whose epoch has moved on by the time `tick` drains it is
    /// dropped under `inboxLock`, so rows from an abandoned load — Bridge's
    /// walk, or Music.app's shared read — can never land after the list has
    /// already reloaded from the other backend.
    private var songsWalkEpoch = 0
    private var albumsSourceEpoch = 0
    private var artistsSourceEpoch = 0
    private var bridgeSongTotal: Int? = nil
    /// Bridge is preparing its library. Not a failure and not an empty list:
    /// the list says so and the walk keeps asking.
    private var bridgeWarming = false
    /// Bridge's own words for a failed library read, or nil for the AppleScript
    /// path's generic message.
    private var bridgeFailure: String? = nil

    /// The Songs rows, for tests. The list is private; nothing but the scene
    /// writes it.
    var songsForTest: [LibrarySong] { songs }
    // Artists load lazily the first time the Artists sub-view is shown (same
    // one-shot pattern as Songs). artistAlbums is the drilled-in album list for
    // one artist, refetched each time an artist is opened.
    private var artists: [LibraryArtist] = []
    private var artistsLoaded = false
    private var artistsFetchStarted = false
    private var artistAlbums: [LibraryAlbum] = []
    private var artistAlbumsLoaded = false
    /// Bridge's own sentence for a failed artist-albums drill-in (C3 item 4),
    /// shown by the empty rail instead of "Loading albums…" or "(no albums)".
    private var artistAlbumsFailure: String? = nil

    // D1/C2: Albums and Artists from Bridge, each its own BridgeListFeed —
    // shared walk-and-inbox discipline (BridgeListFeed.swift) rather than two
    // more hand-rolled copies of loadSongsFromBridge. `lazy` so the closures
    // are built once, on first Bridge-mode use, and reused for the scene's
    // lifetime; `reset()` (not a fresh instance) is how a provenance switch
    // clears one out.
    private lazy var albumsFeed: BridgeListFeed<LibraryAlbum> = {
        let sleep = warmUpSleep
        return BridgeListFeed<LibraryAlbum>(
            fetch: { [weak self] cursor, limit in
                guard let self, let provider = self.makeProvider() else {
                    throw MusicProviderError.unavailable("Bridge is not the selected output")
                }
                return try provider.libraryAlbums(cursor: cursor, limit: limit)
            },
            map: { LibraryAlbum(id: $0.id, name: $0.title, artist: $0.artist, trackCount: $0.trackCount ?? 0) },
            sleep: sleep)
    }()
    private lazy var artistsFeed: BridgeListFeed<LibraryArtist> = {
        let sleep = warmUpSleep
        return BridgeListFeed<LibraryArtist>(
            fetch: { [weak self] cursor, limit in
                guard let self, let provider = self.makeProvider() else {
                    throw MusicProviderError.unavailable("Bridge is not the selected output")
                }
                return try provider.libraryArtists(cursor: cursor, limit: limit)
            },
            map: { LibraryArtist(id: $0.id, name: $0.title) },
            sleep: sleep)
    }()
    private var bridgeAlbumTotal: Int? = nil
    private var bridgeArtistTotal: Int? = nil
    private var bridgeAlbumsFailure: String? = nil
    private var bridgeArtistsFailure: String? = nil
    private var bridgeAlbumsWarming = false
    private var bridgeArtistsWarming = false

    // C3: an album's tracks and an artist's songs/albums, read from Bridge by
    // id rather than the `(title, artist, album)` AppleScript join. Keyed like
    // `trackCache` but kept separate from it so a Bridge failure never looks
    // like a cached Music.app miss, and cleared whenever a provenance switch
    // clears the Music.app caches (D7).
    private var bridgeTracks: [String: [MusicRow]] = [:]
    private var bridgeTrackFailures: [String: String] = [:]
    /// One album's landed tracks OR its failure sentence, posted under
    /// `inboxLock` from `previewQueue` (or a detached thread — see
    /// `kickTrackFetch`'s Bridge branch) and drained in `tick`, same
    /// discipline as `previewInbox`. Not `Result<[MusicRow], String>`: a
    /// plain `String` failure does not conform to `Error`, and this outcome
    /// is never thrown, only pattern-matched.
    private enum BridgeTracksOutcome {
        case success([MusicRow])
        case failure(String)
    }
    /// Which rail's provenance epoch governs a given track fetch: the Albums
    /// root rail (`albumsSourceEpoch`) or an artist's albums rail
    /// (`artistsSourceEpoch`) — the same distinction `currentAlbumSource`
    /// draws by `nav.subView`. Captured at KICK time alongside the epoch
    /// itself, so a fetch that outlives a provenance switch is dropped even
    /// if the same album id is reopened afterward under the new output.
    private enum AlbumRailEpochSource { case albums, artists }
    private var bridgeTracksInbox:
        [(albumID: String, epochSource: AlbumRailEpochSource, epoch: Int, result: BridgeTracksOutcome)] = []

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
    private var snapToPlayingPending = false

    /// Cursor position within the visible rows, for tests.
    var navCursorForTest: Int { nav.cursor }

    /// Which of artists / albums / songs is showing, for tests.
    var subViewForTest: LibrarySubView { nav.subView }
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

    // Cover ladder cache, same main-thread-only / inbox-under-inboxLock
    // discipline as the track preview above: coverCache/coverInFlight are
    // touched only from tick/handle, coverInbox is appended to under
    // inboxLock from previewQueue and drained in tick. A double-optional
    // entry (nil value) records a tried-and-missed album so it isn't
    // re-scanned every frame (same negative-cache intent as ArtworkStore's
    // `failed` and the Now tab's restAttempted). The ladder runs on
    // previewQueue, not its own queue, so at most one AppleScript scan of
    // the library is in flight for previews and covers together, and a fast
    // scroll can't pile persistent-ID scans onto Music.
    private var coverCache: [String: LibraryCover?] = [:]
    private var coverInFlight: Set<String> = []
    private var coverInbox: [(id: String, cover: LibraryCover?)] = []

    private let inboxLock = NSLock()
    // The three lists come from one bulk read and arrive as a single page each;
    // the inbox/drain shape is kept from when they were paginated. Nothing here
    // paginates any more. The background read appends to `*Pending` under
    // inboxLock; tick drains
    // and appends to the main list, and `*Done` flips `*Loaded` once the walk
    // finishes (so an empty library shows "(no …)" instead of a stuck "Loading …").
    // A single-optional inbox — like artistAlbums/preview below — can't express
    // "first page here, more coming", which is exactly what progressive render needs.
    private var pendingReadFailed: Bool? = nil   // read outcome, drained in tick
    private var pendingExhausted = false
    private var retryScheduled = false           // exactly one shared retry chain
    private var restartRequested = false         // drained in tick -> one new load
    private var albumsPending: [LibraryAlbum] = []
    private var albumsDone = false
    private var songsPending: [LibrarySong] = []
    private var songsDone = false
    // The Bridge songs walk's three extra signals, all drained in tick under
    // inboxLock like every other inbox here.
    //   * songsResetPending — a stale generation restarted the walk, so every row
    //     already collected for this list (inbox AND drained) is from an
    //     observation that no longer exists and must go. Set under the SAME lock
    //     acquisition that clears songsPending, so no page can straddle it.
    //   * songsTotalPending — Bridge's row count for the observation this list
    //     came from, so the header can say 15,646 before it has them all.
    //   * bridgeFailurePending — Bridge's own sentence for a failed read, so the
    //     unreadable message is Bridge's and not a generic Music.app one.
    private var songsResetPending = false
    private var songsTotalPending: Int? = nil
    private var bridgeFailurePending: String? = nil
    /// A restart happened: the rows ON SCREEN are from an observation that no
    /// longer exists, but they stay visible until the new generation's first
    /// page arrives. A list that blanked itself here would flicker to empty on
    /// every background refresh, which is the opposite of what
    /// stale-while-revalidate is for.
    private var songsAwaitingReplacement = false
    /// Set with that first new page, under the same lock acquisition: this
    /// drain REPLACES the list rather than appending to it, so the two
    /// generations are never on screen together.
    private var songsReplacePending = false
    /// Bridge said "not ready yet". Drained like the rest so render never reads
    /// it off the walk's thread.
    private var bridgeWarmingPending = false
    /// This list's OWN in-flight guard. The shared `LibraryLoadCoordinator`
    /// serialises Music.app's bulk reads; a Bridge walk contends for none of
    /// them, so it is kept out of that budget entirely and guarded here.
    private var bridgeWalkInFlight = false
    private var artistsPending: [LibraryArtist] = []
    private var artistsDone = false
    // Tagged with the requested artistID (a since-abandoned artist's slow
    // fetch is dropped in tick, last-writer-wins) AND the `artistsSourceEpoch`
    // captured when the fetch was KICKED (a since-abandoned OUTPUT's slow
    // fetch is dropped too, even if the person has reopened the SAME artist
    // under the new output by the time it lands — an id match alone cannot
    // tell "the same artist, still on this output" apart from "the same
    // artist id, now on the other library", and Bridge's and Music.app's id
    // spaces are not guaranteed disjoint by anything checked here).
    private var artistAlbumsInbox: (artistID: String, epoch: Int, albums: [LibraryAlbum])? = nil
    /// C3 item 4: a failed Bridge artist-albums read, tagged like
    /// `artistAlbumsInbox` so a stale failure for an abandoned artist OR an
    /// abandoned output is dropped rather than overwriting the current
    /// state.
    private var pendingArtistAlbumsFailure: (artistID: String, epoch: Int, sentence: String)? = nil
    private var previewInbox: [(id: String, tracks: [String])] = []

    // Real hero covers: the artwork ladder (embedded, then REST, then the
    // gradient, see coverCache above and kickCoverFetch below) resolves one
    // LibraryCover per focused album; ArtworkStore then owns that cover's
    // fetch/cache/render exactly as it does for Playlists/Radio. onReady sets
    // artDirty under inboxLock (same discipline as the streaming inboxes) and
    // tick drains it into `changed` so the swap paints on the next frame.
    private let artwork = ArtworkStore()
    private var artDirty = false
    private let kittyEnabled: Bool
    // Placement-dedup (render-thread-only, per design doc Feature 2 §3): the
    // last kitty placement this scene emitted, so an unchanged frame emits
    // nothing (the placement persists on screen across text repaints) and a
    // changed one deletes the old placement before drawing the new one.
    private var lastPlaced: (id: UInt32, row: Int, col: Int, cols: Int, rows: Int)? = nil

    /// Seams for the collection reads, so a test can prove the routing binding
    /// without `swift test` running AppleScript against the user's Music.app.
    /// Live by default: no call site passes them.
    private let resolveAlbum: (AppleScriptBackend, String, String) -> AlbumResolution
    private let resolveArtist: (AppleScriptBackend, String) -> AlbumResolution

    /// Where the Songs list's rows and playback come from, asked FRESH at each
    /// load and each play so a mid-session output switch is honoured.
    ///
    /// Non-nil means Bridge is the selected output: the rows are Bridge's own
    /// MusicKit library and a row plays by the id Bridge gave it ("two modes,
    /// two libraries", Anthony 2026-09-23). Nil means Music.app mode and the
    /// AppleScript path below, unchanged. The default returns nil, so nothing
    /// that does not ask for a provider gets one.
    private let makeProvider: () -> MusicDataProvider?

    /// How the Bridge walk waits out a "not ready yet". A seam for the same
    /// reason `resolveAlbum` is one: the bounded-retry rule is worth a test, and
    /// a test should not pay seconds of real wall clock to prove it.
    private let warmUpSleep: (TimeInterval) -> Void

    /// The tier filter's SWR cache (`rememberArtistTiers` / `cachedArtistTiers`),
    /// Music.app's own — never fed from Bridge rows (see the `a` handler and
    /// the walk-done branch in `tick`). Injectable so a test proves its own
    /// behaviour against a temp directory instead of the real
    /// `~/.config/music/artist-tiers.json`; the real cache by default, so
    /// production is unchanged.
    private let resultCache: ResultCache

    init(backend: AppleScriptBackend,
         routing: RoutingCoordinator, sources: LibraryDataSources,
         appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner,
         kittyEnabled: Bool = false,
         resolveAlbum: @escaping (AppleScriptBackend, String, String) -> AlbumResolution
             = { resolveAlbumPlaybackTracks(backend: $0, title: $1, artist: $2) },
         resolveArtist: @escaping (AppleScriptBackend, String) -> AlbumResolution
             = { resolveArtistPlaybackTracks(backend: $0, artist: $1) },
         makeProvider: @escaping () -> MusicDataProvider? = { nil },
         warmUpSleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         resultCache: ResultCache = ResultCache()) {
        self.resolveAlbum = resolveAlbum
        self.resolveArtist = resolveArtist
        self.makeProvider = makeProvider
        self.warmUpSleep = warmUpSleep
        self.resultCache = resultCache
        self.routing = routing
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

    /// Perform the shared bulk read exactly once per round, whichever list asks.
    ///
    /// BACKGROUND THREAD ONLY: it can block in `awaitInFlight`, so it must never
    /// be reached from render or input. A refused caller either waits for the
    /// leader and re-claims (riding a warm cache for free, or becoming the next
    /// budgeted attempt) or stops when the budget is spent. Every hop re-checks
    /// `self`, so nothing retries once the scene is gone.
    private func runSharedRead(_ invoke: @escaping () -> Bool, markDone: @escaping () -> Void) {
        // The coordinator is captured directly rather than reached through
        // `self`: `awaitInFlight` blocks, and going through `self` would hold a
        // strong reference for the whole wait, keeping a dismissed scene alive
        // and letting its retry continue. Held weakly, the next hop sees nil and
        // stops.
        let coordinator = loads
        Thread.detachNewThread { [weak self] in
            var outcome: Bool?
            while outcome == nil {
                guard self != nil else { return }     // scene gone -> stop entirely
                switch coordinator.claim() {
                case .granted:
                    let ok = invoke()
                    coordinator.finishRead(success: ok)
                    outcome = ok
                case .inFlight:
                    coordinator.awaitInFlight()       // no strong self held here
                case .stopped:
                    outcome = false
                }
            }
            guard let self else { return }
            self.publishReadOutcome(ok: outcome ?? false)
            markDone()
        }
    }

    /// Hand the read outcome back through the scene's existing serialized path.
    private func publishReadOutcome(ok: Bool) {
        inboxLock.lock()
        pendingReadFailed = !ok
        pendingExhausted = loads.exhausted
        inboxLock.unlock()
        if !ok { scheduleSharedRetry() }
    }

    /// One retry chain for the whole tab, never one per sub-view. A second
    /// caller finds `retryScheduled` already set and returns.
    ///
    /// Measured live 2026-09-01, and the behaviour to preserve: leaving the
    /// Library tab PARKS the chain once any in-flight read finishes, because
    /// `restartRequested` is drained in `tick` and `tick` does not run for an
    /// inactive scene. Returning resumes the remaining bounded attempts. It
    /// neither multiplies the budget nor resets it - eight sub-view switches
    /// during a live chain produced three reads, not nine.
    private func scheduleSharedRetry() {
        guard !loads.exhausted else { return }   // budget spent: wait for `r`
        inboxLock.lock()
        let already = retryScheduled
        retryScheduled = true
        inboxLock.unlock()
        guard !already else { return }           // a chain is already pending
        let delay = loads.retryDelay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }           // scene gone -> chain dies
            self.inboxLock.lock()
            self.retryScheduled = false
            self.restartRequested = true
            self.inboxLock.unlock()
        }
    }

    /// Failure text for a sub-view with nothing to show, or nil when the normal
    /// empty/loading text applies. A failure REPLACES the empty state: "(no
    /// albums)" must never stand in for "couldn't read the library".
    /// Bridge's failures keep Bridge's own sentence. The generic "Couldn't read
    /// the Music library" would be a lie in Bridge mode — it names the wrong
    /// library — and it would hide the one thing a person could act on ("Bridge
    /// has not been granted Apple Music access"). Only the retry affordance is
    /// this scene's to add.
    ///
    /// `bridgeFailure` is per-LIST, not per-scene: a caller passes its OWN
    /// list's Bridge sentence (nil when that list is Music.app-sourced), so
    /// only the list whose rows Bridge actually serves ever speaks for Bridge.
    private func unreadableMessage(_ st: LibraryStatus, bridgeFailure: String? = nil) -> String? {
        guard st == .unreadableRetrying || st == .unreadableExhausted else { return nil }
        guard let bridgeFailure else { return libraryStatusMessage(st) }
        return st == .unreadableExhausted ? "\(bridgeFailure) - press r to retry"
                                          : "\(bridgeFailure) - retrying"
    }

    /// Off-thread album fetch (D1/C2). In Bridge mode this is MusicKit's own
    /// album entities via `albumsFeed`, drained in `tick`; otherwise the
    /// existing AppleScript-backed shared read, unchanged except for the
    /// epoch guard D7 adds so a page from an abandoned Music.app read (the
    /// output switched to Bridge while it was in flight) cannot land after
    /// the list has already reloaded from Bridge. The onPage closure returns
    /// false if the scene has deallocated OR the epoch has moved on, either of
    /// which aborts the read. albumsDone is set once the read finishes so
    /// tick can flip albumsLoaded. Kicked once (guarded by albumsFetchStarted)
    /// when the Albums sub-view first becomes active.
    private func loadAlbums() {
        albumsFetchStarted = true
        if makeProvider() != nil {
            albumsSource = .bridge
            albumsFeed.start()
            return
        }
        albumsSource = .musicApp
        let sources = self.sources
        let epoch = albumsSourceEpoch
        runSharedRead({ [weak self] in
            sources.onAlbums { page in
                guard let self else { return false }   // scene gone -> stop the walk
                self.inboxLock.lock()
                guard self.albumsSourceEpoch == epoch else { self.inboxLock.unlock(); return false }
                self.albumsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
        }, markDone: { [weak self] in
            guard let self else { return }
            self.inboxLock.lock()
            defer { self.inboxLock.unlock() }
            guard self.albumsSourceEpoch == epoch else { return }
            self.albumsDone = true
        })
    }

    /// Off-thread streaming song fetch — same page-by-page discipline as loadAlbums.
    /// Kicked once (guarded by songsFetchStarted) when the Songs sub-view first
    /// becomes active.
    private func loadSongs() {
        if let provider = makeProvider() { return loadSongsFromBridge(provider) }
        songsSource = .musicApp
        songsFetchStarted = true
        let sources = self.sources
        let epoch = songsWalkEpoch
        runSharedRead({ [weak self] in
            sources.onSongs { page in
                guard let self else { return false }   // scene gone -> stop the walk
                self.inboxLock.lock()
                guard self.songsWalkEpoch == epoch else { self.inboxLock.unlock(); return false }
                self.songsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
        }, markDone: { [weak self] in
            guard let self else { return }
            self.inboxLock.lock()
            defer { self.inboxLock.unlock() }
            guard self.songsWalkEpoch == epoch else { return }
            self.songsDone = true
        })
    }

    /// The Songs list from BRIDGE's own MusicKit library, page by page into the
    /// same inbox the AppleScript path uses — so the list streams exactly as it
    /// does today: the first page visible fast, the rest arriving behind it.
    ///
    /// **The row's id is Bridge's and travels unchanged.** It is what playback
    /// now uses (`playSong`), which is the whole of the 2026-09-23 decision: no
    /// `(title, artist, album)` join, so the 338 rows that join could not resolve
    /// stop being a category.
    ///
    /// **There is no fall back to AppleScript here.** A Bridge failure is
    /// reported as Bridge's failure, in Bridge's own sentence (rule 3), and it
    /// never quietly becomes a Music.app library instead.
    ///
    /// **It does not go through `runSharedRead`, and that is the point.** The
    /// shared `LibraryLoadCoordinator` exists to serialise EXPENSIVE AppleScript
    /// reads of Music.app and to share one retry budget across the three lists
    /// that come from that one bulk read. A Bridge page walk contends for none
    /// of it: it is a socket round trip, ~1ms a page once the app has drained
    /// (measured 2026-09-23: 6.4s for the drain on the first page, then 157
    /// pages in 0.18s). Routing it through the coordinator made the two
    /// backends speak for each other — a Bridge refusal set `readFailed` for
    /// the whole tab, so Albums said "Couldn't read the Music library -
    /// retrying" without Music.app having been asked anything, and a Music.app
    /// failure marked the Bridge list unreadable. Under "two modes, two
    /// libraries" neither is entitled to report the other's state, so this walk
    /// has its own in-flight guard and its own failure state and touches
    /// neither the coordinator's outcome nor its budget.
    ///
    /// **No automatic retry chain.** The shared one exists because a Music.app
    /// bulk read fails transiently under load; Bridge's failures here are a
    /// refusal, a missing authorization or a missing app, none of which a
    /// second attempt two seconds later fixes. It stops and says so, and `r`
    /// asks again — one cheap round trip, on a person's decision.
    private func loadSongsFromBridge(_ provider: MusicDataProvider) {
        inboxLock.lock()
        let alreadyWalking = bridgeWalkInFlight
        if !alreadyWalking {
            bridgeWalkInFlight = true
            bridgeFailurePending = nil
        }
        inboxLock.unlock()
        guard !alreadyWalking else { return }   // one walk at a time, this list's own guard
        songsSource = .bridge
        songsFetchStarted = true
        let sleep = self.warmUpSleep
        // D7: captured once, so a page from THIS walk landing after a
        // provenance reset bumped the epoch (the output switched away from
        // Bridge while this walk was in flight) is dropped rather than
        // resurrecting a list that has already reloaded from the other
        // backend.
        let epoch = songsWalkEpoch
        // `self` is captured weakly and touched only per page, so a walk of 157
        // pages cannot keep a dismissed scene alive to its end, and a torn-down
        // scene stops the walk at its next page.
        Thread.detachNewThread { [weak self] in
            let failure = walkLibrarySongs(provider, limit: 100,
                onPage: { [weak self] page in
                    guard let self else { return false }   // scene gone -> stop the walk
                    // `stale` and `refreshing` are read and deliberately not
                    // acted on: a page from an older snapshot is a page, and
                    // the rows render exactly as a fresh one's do.
                    let rows = page.rows.map {
                        LibrarySong(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album ?? "")
                    }
                    self.inboxLock.lock()
                    defer { self.inboxLock.unlock() }
                    guard self.songsWalkEpoch == epoch else { return false }   // reset since -> stop
                    if self.songsAwaitingReplacement {
                        // First page of the new generation: it REPLACES what is
                        // on screen, wholesale, in one drain.
                        self.songsAwaitingReplacement = false
                        self.songsReplacePending = true
                        self.songsPending = rows
                    } else {
                        self.songsPending.append(contentsOf: rows)
                    }
                    if let total = page.total { self.songsTotalPending = total }
                    self.bridgeWarmingPending = false
                    return true
                },
                onRestart: { [weak self] in
                    guard let self else { return }
                    // One lock acquisition: the flag and the discarded inbox can
                    // never be observed apart, so no page straddles the restart.
                    //
                    // The rows ALREADY on screen are deliberately left alone
                    // here. They are the last complete thing this list had, and
                    // they stay until the new generation's page 1 lands — the
                    // list never blinks to empty just because the library moved
                    // underneath it.
                    self.inboxLock.lock()
                    defer { self.inboxLock.unlock() }
                    guard self.songsWalkEpoch == epoch else { return }
                    self.songsAwaitingReplacement = true
                    self.songsPending = []
                    self.songsTotalPending = nil
                },
                onWarming: { [weak self] _ in
                    guard let self else { return }
                    self.inboxLock.lock()
                    defer { self.inboxLock.unlock() }
                    guard self.songsWalkEpoch == epoch else { return }
                    self.bridgeWarmingPending = true
                },
                sleep: sleep)
            guard let self else { return }
            let sentence = failure.map { $0.errorDescription ?? "Bridge couldn't read your library" }
            self.inboxLock.lock()
            self.bridgeWalkInFlight = false
            let stillCurrent = self.songsWalkEpoch == epoch   // else: reset since -> the ending is dropped too
            if stillCurrent {
                self.songsDone = true
                self.bridgeFailurePending = sentence
                self.bridgeWarmingPending = false   // it is over, one way or the other
            }
            self.inboxLock.unlock()
            // Also on the footer, because the list's own message only shows
            // while the list is EMPTY (`libraryStatus` has no "rows present but
            // the read failed" state). A walk that dies after its third page
            // would otherwise leave a partial library looking complete —
            // exactly the silence rule 3 forbids.
            if stillCurrent, let sentence { self.status.post(sentence, error: true) }
        }
    }

    /// Ask Bridge for the Songs list again, on a person's `r`. Its own retry,
    /// because its failure is its own: the shared budget is not spent, reset or
    /// consulted here.
    private func retryBridgeSongs() {
        inboxLock.lock()
        songsResetPending = true
        songsPending = []
        songsTotalPending = nil
        bridgeFailurePending = nil
        bridgeWarmingPending = false
        songsAwaitingReplacement = false
        songsReplacePending = false
        songsDone = false
        inboxLock.unlock()
        songsLoaded = false
        songsFetchStarted = false   // tick re-kicks the one-shot load
    }

    /// Off-thread streaming artist-list fetch (D1/C2). Bridge mode drains
    /// `artistsFeed`; otherwise the existing AppleScript-backed shared read,
    /// with the same epoch guard `loadAlbums` adds. Kicked once (guarded by
    /// artistsFetchStarted) when the Artists sub-view first becomes active.
    private func loadArtists() {
        artistsFetchStarted = true
        if makeProvider() != nil {
            artistsSource = .bridge
            artistsFeed.start()
            return
        }
        artistsSource = .musicApp
        let sources = self.sources
        let epoch = artistsSourceEpoch
        runSharedRead({ [weak self] in
            sources.onArtists { page in
                guard let self else { return false }   // scene gone -> stop the walk
                self.inboxLock.lock()
                guard self.artistsSourceEpoch == epoch else { self.inboxLock.unlock(); return false }
                self.artistsPending.append(contentsOf: page)
                self.inboxLock.unlock()
                return true
            }
        }, markDone: { [weak self] in
            guard let self else { return }
            self.inboxLock.lock()
            defer { self.inboxLock.unlock() }
            guard self.artistsSourceEpoch == epoch else { return }
            self.artistsDone = true
        })
    }

    /// Off-thread fetch of one artist's albums, posted to artistAlbumsInbox and
    /// drained in tick. Unlike loadArtists this refetches every time an artist is
    /// opened, so it clears the prior list first (render shows "Loading albums…").
    ///
    /// C3 item 4: in Bridge mode this reads `slice.libraryArtistAlbums` by id —
    /// `sources.onArtistAlbums` (the AppleScript join) is never called.
    private func loadArtistAlbums(artistID: String) {
        artistAlbums = []
        artistAlbumsLoaded = false
        artistAlbumsFailure = nil
        // Captured at kick time: whichever result lands, it is only accepted
        // if `artistsSourceEpoch` is STILL this value when it lands — a
        // provenance switch (or a manual Bridge retry) bumps it, and either
        // branch below (Bridge or Music.app) can equally outlive one.
        let epoch = artistsSourceEpoch
        if let provider = makeProvider() {
            let sleep = warmUpSleep
            Thread.detachNewThread { [weak self] in
                do {
                    let list = try retryingWhileWarming(sleep: sleep) {
                        try provider.artistAlbums(artistID: artistID)
                    }
                    let mapped = list.rows.map {
                        LibraryAlbum(id: $0.id, name: $0.title, artist: $0.artist, trackCount: $0.trackCount ?? 0)
                    }
                    guard let self else { return }
                    self.inboxLock.lock()
                    self.artistAlbumsInbox = (artistID, epoch, mapped)
                    self.inboxLock.unlock()
                } catch {
                    guard let self else { return }
                    let sentence = (error as? MusicProviderError)?.errorDescription
                        ?? "Couldn't read that artist's albums from Bridge."
                    self.inboxLock.lock()
                    self.pendingArtistAlbumsFailure = (artistID, epoch, sentence)
                    self.inboxLock.unlock()
                }
            }
            return
        }
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            let fetched = sources.onArtistAlbums(artistID)
            guard let self else { return }
            self.inboxLock.lock()
            self.artistAlbumsInbox = (artistID, epoch, fetched)
            self.inboxLock.unlock()
        }
    }

    /// Kick a serial background fetch of one album's tracks, unless it's already
    /// cached or in flight. Serial so a fast scroll can't pile concurrent
    /// full-library predicate scans onto Music. Called only from the main thread.
    ///
    /// C3 item 2: for a Bridge-sourced album (`currentAlbumSource == .bridge`)
    /// this reads `slice.libraryAlbumTracks` by id instead of AppleScript.
    /// A previously-failed Bridge album is NOT retried by this call (the tick
    /// preview-kick calls this on every focus) — only `execute`'s
    /// `.fetchAlbumTracks` (an explicit Enter/drill) clears the failure first,
    /// which is what "fetched again on the next Enter, not on every focus"
    /// means in practice.
    private func kickTrackFetch(albumID: String, title: String, artist: String) {
        guard trackCache[albumID] == nil, !previewInFlight.contains(albumID) else { return }
        if currentAlbumSource == .bridge {
            guard bridgeTrackFailures[albumID] == nil else { return }
            guard let provider = makeProvider() else { return }   // output changed under us; do nothing
            previewInFlight.insert(albumID)
            let sleep = warmUpSleep
            // Captured at kick time, same reasoning as `loadArtistAlbums`:
            // whichever rail this album's tracks belong to (`currentAlbumSource`
            // already tells us it is Bridge's; this remembers WHICH Bridge
            // epoch), a result that lands after that rail's provenance has
            // moved on is dropped, even if the same album id is reopened
            // under the new output before it lands.
            let epochSource: AlbumRailEpochSource = nav.subView == .artists ? .artists : .albums
            let epoch = epochSource == .artists ? artistsSourceEpoch : albumsSourceEpoch
            Thread.detachNewThread { [weak self] in
                do {
                    let list = try retryingWhileWarming(sleep: sleep) { try provider.albumTracks(albumID: albumID) }
                    guard let self else { return }
                    self.inboxLock.lock()
                    self.bridgeTracksInbox.append((albumID, epochSource, epoch, .success(list.rows)))
                    self.inboxLock.unlock()
                } catch {
                    guard let self else { return }
                    let sentence = (error as? MusicProviderError)?.errorDescription
                        ?? "Couldn't read that album's tracks from Bridge."
                    self.inboxLock.lock()
                    self.bridgeTracksInbox.append((albumID, epochSource, epoch, .failure(sentence)))
                    self.inboxLock.unlock()
                }
            }
            return
        }
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

    /// Kick a serial background run of the cover ladder for one album, unless
    /// it's already cached (hit or negative) or in flight. Shares previewQueue
    /// with kickTrackFetch so at most one full-library AppleScript scan is in
    /// flight for previews and covers together. Called only from the main
    /// thread.
    private func kickCoverFetch(albumID: String) {
        guard coverCache[albumID] == nil, !coverInFlight.contains(albumID) else { return }
        coverInFlight.insert(albumID)
        let sources = self.sources
        previewQueue.async { [weak self] in
            let hit = sources.onAlbumCover(albumID)
            guard let self else { return }
            self.inboxLock.lock()
            self.coverInbox.append((albumID, hit))
            self.inboxLock.unlock()
        }
    }

    // MARK: Scene

    @discardableResult
    /// Put the cursor on the playing song when the tab is opened — once, on
    /// arrival, never while the person is browsing (2026-09-22, from the
    /// competitor scan's "scroll/focus to the currently playing row"). Held as
    /// a flag because the songs may not have streamed in yet at the moment of
    /// arrival; `tick` spends it on the first snapshot that can answer.
    func becameActive() { snapToPlayingPending = true }

    // MARK: provenance (D7)

    /// Once per tick, compute which library the selected output implies and
    /// reset any list whose recorded source no longer matches it. Called
    /// before the inbox drain and the lazy-loader kicks below, so a list this
    /// tick resets is also reloaded from the right source this same tick.
    /// Returns whether anything reset, so the caller knows to redraw and post
    /// the one shared message.
    private func applyProvenance() -> Bool {
        let want: ListSource = makeProvider() != nil ? .bridge : .musicApp
        var resetAny = false
        if let source = songsSource, source != want { resetSongsList(); resetAny = true }
        if let source = albumsSource, source != want { resetAlbumsList(); resetAny = true }
        if let source = artistsSource, source != want { resetArtistsList(); resetAny = true }
        if resetAny {
            clearAlbumCentricCaches()
            status.post("Output changed \u{2014} showing \(want == .bridge ? "Bridge's" : "the Music.app") library")
        }
        return resetAny
    }

    private func resetSongsList() {
        songs = []
        songsLoaded = false
        songsFetchStarted = false
        songsDone = false
        bridgeSongTotal = nil
        bridgeFailure = nil
        bridgeWarming = false
        songsSource = nil
        songsWalkEpoch += 1
        if nav.subView == .songs { returnToRoot(.songs) }
    }

    private func resetAlbumsList() {
        albums = []
        albumsLoaded = false
        albumsFetchStarted = false
        albumsDone = false
        bridgeAlbumTotal = nil
        bridgeAlbumsFailure = nil
        bridgeAlbumsWarming = false
        albumsSource = nil
        albumsSourceEpoch += 1
        albumsFeed.reset()
        // Tier sets are derived from `albums`; a library switch invalidates
        // them along with it.
        epArtists = []
        albumArtists = []
        if nav.subView == .albums { returnToRoot(.albums) }
    }

    private func resetArtistsList() {
        artists = []
        artistsLoaded = false
        artistsFetchStarted = false
        artistsDone = false
        bridgeArtistTotal = nil
        bridgeArtistsFailure = nil
        bridgeArtistsWarming = false
        artistsSource = nil
        artistsSourceEpoch += 1
        artistsFeed.reset()
        artistAlbums = []
        artistAlbumsLoaded = false
        artistAlbumsFailure = nil
        // Defense in depth: the epoch bump above already makes tick's drain
        // drop these two on arrival (they are checked against
        // `artistsSourceEpoch`), but clearing them here too means a stale
        // one already sitting in the inbox is gone immediately rather than
        // lingering, unread, until the next background post replaces it.
        inboxLock.lock()
        artistAlbumsInbox = nil
        pendingArtistAlbumsFailure = nil
        inboxLock.unlock()
        if nav.subView == .artists { returnToRoot(.artists) }
    }

    /// Album-preview and cover caches are keyed by album id, and both the
    /// Music.app and Bridge album rails share them — a provenance switch
    /// invalidates every entry regardless of which list triggered the reset,
    /// because an id from the OLD library means nothing to the new one (the
    /// two id spaces never collide, but a stale entry would still paint the
    /// wrong tracks/cover under a NEW row that happens to reuse a position).
    private func clearAlbumCentricCaches() {
        trackCache = [:]
        previewInFlight = []
        coverCache = [:]
        coverInFlight = []
        bridgeTracks = [:]
        bridgeTrackFailures = [:]
        // Same defense-in-depth as `resetArtistsList`'s inbox clear: the
        // epoch bumps in `resetAlbumsList`/`resetArtistsList` already make
        // tick's drain drop a stale entry on arrival, but dropping it here
        // too means it is gone immediately.
        inboxLock.lock()
        bridgeTracksInbox = []
        inboxLock.unlock()
    }

    /// Drop back to a sub-view's root level when a provenance reset catches it
    /// mid-drill: the drilled identity (an album id, an artist id) belongs to
    /// the library that is no longer selected, so there is nothing left for it
    /// to mean.
    private func returnToRoot(_ sub: LibrarySubView) {
        nav = LibraryNav(subView: sub, stack: [LibraryNav.root(for: sub)], cursor: 0)
        railScroll = 0
        trackScroll = 0
        filter = ""
    }

    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        if snapToPlayingPending, case .songList = nav.current,
           case .active(let np) = snapshot.outcome, !songs.isEmpty {
            snapToPlayingPending = false
            let vis = visibleSongIndices()
            let rows = vis.map { (title: songs[$0].title, artist: songs[$0].artist) }
            if let row = indexOfPlayingRow(rows, track: np.track, artist: np.artist), row != nav.cursor {
                nav.cursor = row   // renderSongList moves `railScroll` to follow it
                changed = true
            }
        }

        // D7: before anything else this tick, so a list reset here also
        // reloads from the right source this same tick.
        if applyProvenance() { changed = true }

        inboxLock.lock()
        let newAlbums = albumsPending; albumsPending = []
        let albumsWalkDone = albumsDone
        let newSongs = songsPending; songsPending = []
        let songsWalkDone = songsDone
        let songsRestarted = songsResetPending; songsResetPending = false
        let songsReplaced = songsReplacePending; songsReplacePending = false
        let landedSongTotal = songsTotalPending
        let landedBridgeFailure = bridgeFailurePending
        let landedWarming = bridgeWarmingPending
        let newArtists = artistsPending; artistsPending = []
        let artistsWalkDone = artistsDone
        let freshArtistAlbums = artistAlbumsInbox; artistAlbumsInbox = nil
        let freshArtistAlbumsFailure = pendingArtistAlbumsFailure; pendingArtistAlbumsFailure = nil
        let landedPreviews = previewInbox; previewInbox = []
        let landedCovers = coverInbox; coverInbox = []
        let artLanded = artDirty; artDirty = false
        let landedReadFailed = pendingReadFailed; pendingReadFailed = nil
        let landedExhausted = pendingExhausted
        let wantsRestart = restartRequested; restartRequested = false
        let landedBridgeTracks = bridgeTracksInbox; bridgeTracksInbox = []
        inboxLock.unlock()

        // Mirror the shared load state so render and input never touch the
        // coordinator's lock.
        if let landedReadFailed {
            if landedReadFailed != readFailed || landedExhausted != retriesExhausted { changed = true }
            readFailed = landedReadFailed
            retriesExhausted = landedExhausted
        }

        // One shared retry: reopen only the lists that have nothing to show, so
        // the active sub-view re-kicks below and exactly one new read happens.
        // D7 extends slice 1's `!songsFromBridge` guard to Albums and Artists:
        // this coordinator only ever reads Music.app, so a Bridge-sourced list
        // is never its to reopen.
        if wantsRestart {
            if albums.isEmpty, albumsSource != .bridge {
                albumsFetchStarted = false; albumsDone = false; albumsLoaded = false
            }
            if songs.isEmpty && !songsFromBridge {
                songsFetchStarted = false; songsDone = false; songsLoaded = false
            }
            if artists.isEmpty, artistsSource != .bridge {
                artistsFetchStarted = false; artistsDone = false; artistsLoaded = false
            }
            changed = true
        }

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
            //
            // This branch only ever fires for the Music.app path: `albumsDone`
            // is set only by `loadAlbums`'s AppleScript closure, never by
            // `albumsFeed`, so a Bridge-sourced album list finishing (drained
            // below) cannot reach here. That is D1's tier-filter rule (C2
            // item 8): Bridge's tiers are session-local and never touch
            // Music.app's SWR cache.
            epArtists = albumArtistSet(from: albums, minTracks: 2, maxTracks: 5)
            albumArtists = albumArtistSet(from: albums, minTracks: 6)
            let (ep, alb) = (epArtists, albumArtists)
            let cache = resultCache
            Thread.detachNewThread { cache.rememberArtistTiers(ep: ep, albums: alb) }
            changed = true
        }

        // D1/C2: Albums and Artists from Bridge, drained the same way Songs'
        // walk is — a replace (first page of a fresh attempt) then appends,
        // total/failure/warming as level state, and `done` becoming `*Loaded`.
        // A feed drains to nothing when its list isn't Bridge-sourced, so this
        // runs unconditionally rather than gated on `albumsSource == .bridge`.
        let albumsDrain = albumsFeed.drain()
        // FIX (live-gate finding, 2026-09-23): `replace` and `append` are NOT
        // mutually exclusive within one drain. `BridgeListFeed` accumulates
        // every page an attempt lands between two `drain()` calls — page 1
        // into `replace`, every later page into `append` — and a fast local
        // socket walk (measured elsewhere at ~1ms/page) routinely finishes
        // ALL of a multi-thousand-row list before the scene's first tick ever
        // drains it. An `if replace … else if append …` here applied only
        // page 1 and SILENTLY DISCARDED every later page's rows on that same
        // drain, while the header still showed Bridge's wire `total` (read
        // separately, never from `albums.count`) — so the list looked
        // populated and the count looked right, but only the first page's
        // rows actually existed in `albums`. Filtering for anything past
        // page 1 (alphabetically: any title/artist starting after wherever
        // page 1's sort order ended) always found nothing, which is exactly
        // what the live gate saw ("Drone Logic" / "Daniel Avery", both
        // sorted well past a small first page). Both must apply, every tick.
        if let replace = albumsDrain.replace {
            albums = replace
        }
        if !albumsDrain.append.isEmpty {
            albums.append(contentsOf: albumsDrain.append)
        }
        if albumsDrain.replace != nil || !albumsDrain.append.isEmpty {
            epArtists = albumArtistSet(from: albums, minTracks: 2, maxTracks: 5)
            albumArtists = albumArtistSet(from: albums, minTracks: 6)
            let visible = visibleAlbumIndices().count
            if isAlbumRail, nav.cursor >= visible { nav.cursor = max(0, visible - 1); railScroll = 0 }
            changed = true
        }
        if let newFailure = albumsDrain.failure, newFailure != bridgeAlbumsFailure {
            status.post(newFailure, error: true)
        }
        if bridgeAlbumTotal != albumsDrain.total { bridgeAlbumTotal = albumsDrain.total; changed = true }
        if bridgeAlbumsFailure != albumsDrain.failure { bridgeAlbumsFailure = albumsDrain.failure; changed = true }
        if bridgeAlbumsWarming != albumsDrain.warming { bridgeAlbumsWarming = albumsDrain.warming; changed = true }
        if albumsDrain.done && !albumsLoaded { albumsLoaded = true; changed = true }

        let artistsDrain = artistsFeed.drain()
        // Same fix as Albums above, same reason: `replace` and `append` can
        // both be non-empty in one drain, and both must be applied.
        if let replace = artistsDrain.replace {
            artists = replace
        }
        if !artistsDrain.append.isEmpty {
            artists.append(contentsOf: artistsDrain.append)
        }
        if artistsDrain.replace != nil || !artistsDrain.append.isEmpty {
            let visible = visibleArtistIndices().count
            if isArtistList, nav.cursor >= visible { nav.cursor = max(0, visible - 1); railScroll = 0 }
            changed = true
        }
        if let newFailure = artistsDrain.failure, newFailure != bridgeArtistsFailure {
            status.post(newFailure, error: true)
        }
        if bridgeArtistTotal != artistsDrain.total { bridgeArtistTotal = artistsDrain.total; changed = true }
        if bridgeArtistsFailure != artistsDrain.failure { bridgeArtistsFailure = artistsDrain.failure; changed = true }
        if bridgeArtistsWarming != artistsDrain.warming { bridgeArtistsWarming = artistsDrain.warming; changed = true }
        if artistsDrain.done && !artistsLoaded { artistsLoaded = true; changed = true }

        // A person asked for a fresh read (`r`): start from nothing, visibly.
        if songsRestarted {
            songs = []
            if case .songList = nav.current { nav.cursor = 0; railScroll = 0 }
            changed = true
        }
        if bridgeSongTotal != landedSongTotal { bridgeSongTotal = landedSongTotal; changed = true }
        if bridgeFailure != landedBridgeFailure { bridgeFailure = landedBridgeFailure; changed = true }
        if bridgeWarming != landedWarming { bridgeWarming = landedWarming; changed = true }
        // The new generation's first page. It REPLACES the list rather than
        // appending, in one drain, so the old observation's rows and the new
        // one's are never on screen together — the rule a restart exists for.
        // Until this lands the old rows stay up, which is the other half: a
        // library changing underneath must not blank the list a person is
        // reading.
        if songsReplaced {
            songs = newSongs
            let visible = visibleSongIndices().count
            if case .songList = nav.current, nav.cursor >= visible {
                nav.cursor = max(0, visible - 1); railScroll = 0
            }
            changed = true
        } else if !newSongs.isEmpty { songs.append(contentsOf: newSongs); changed = true }
        if songsWalkDone && !songsLoaded { songsLoaded = true; changed = true }
        if !newArtists.isEmpty { artists.append(contentsOf: newArtists); changed = true }
        if artistsWalkDone && !artistsLoaded { artistsLoaded = true; changed = true }
        // Apply an artist-albums fetch only if it's still for the current artist
        // (id in the stack's .artistAlbums level) AND the same provenance epoch
        // it was kicked under: an id match alone is not enough (Codex review) —
        // a fetch that outlives a provenance switch must be dropped even if the
        // person has reopened the SAME artist id under the new output by the
        // time it lands, or a Music.app result could paint under a
        // Bridge-labelled artist (or the reverse).
        if let freshArtistAlbums, freshArtistAlbums.artistID == currentArtistID(),
           freshArtistAlbums.epoch == artistsSourceEpoch {
            artistAlbums = freshArtistAlbums.albums
            artistAlbumsLoaded = true
            artistAlbumsFailure = nil
            if case .artistAlbums = nav.current {
                let count = visibleAlbumIndices().count
                if nav.cursor >= count { nav.cursor = max(0, count - 1) }
            }
            changed = true
        }
        // C3 item 4: same last-writer-wins-and-same-epoch guard as the
        // success case above — a failure for an artist the person has since
        // backed out of, OR whose output has since switched, is dropped
        // rather than painting under the current breadcrumb.
        if let freshArtistAlbumsFailure, freshArtistAlbumsFailure.artistID == currentArtistID(),
           freshArtistAlbumsFailure.epoch == artistsSourceEpoch {
            artistAlbumsFailure = freshArtistAlbumsFailure.sentence
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
        for item in landedCovers {
            coverCache[item.id] = item.cover
            coverInFlight.remove(item.id)
            changed = true
        }
        // C3 item 2: Bridge album-tracks reads, drained like `previewInbox`
        // but into the separate `bridgeTracks`/`bridgeTrackFailures` caches so
        // a Bridge failure never looks like a cached Music.app miss.
        //
        // Every item's epoch is checked against whichever rail's CURRENT
        // epoch it claims to belong to, same reasoning as the artist-albums
        // guard above: `previewInFlight` is cleared unconditionally (the fetch
        // this album was waiting on is over, one way or the other, so a fresh
        // kick must be allowed), but the cache writes only happen for a
        // result whose provenance hasn't moved on since it was kicked.
        for item in landedBridgeTracks {
            previewInFlight.remove(item.albumID)
            let currentEpoch = item.epochSource == .artists ? artistsSourceEpoch : albumsSourceEpoch
            guard item.epoch == currentEpoch else { continue }   // obsolete output/list -> drop
            switch item.result {
            case .success(let rows):
                bridgeTracks[item.albumID] = rows
                // Also into `trackCache`, so the existing render, count and
                // cursor-clamp code (all keyed by title strings) works
                // unchanged for a Bridge-sourced album exactly as it does for
                // a Music.app one — `bridgeTracks` exists ADDITIONALLY, so
                // `playBridgeAlbum` can queue by the rows' own ids.
                trackCache[item.albumID] = rows.map(\.title)
                bridgeTrackFailures.removeValue(forKey: item.albumID)
            case .failure(let sentence):
                // `trackCache` deliberately left unset: the right pane reads
                // `bridgeTrackFailures` first and shows the sentence exactly
                // where it would otherwise say "Loading…".
                bridgeTrackFailures[item.albumID] = sentence
            }
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
        // Cover ladder kick: after the preview kick so the tracklist lands
        // first on the shared serial previewQueue. The hero renders in every
        // zone mode (not just .three, unlike the track preview above), so no
        // .three gate here.
        //
        // C3 item 3: NEVER for a Bridge-sourced album — it gets the gradient
        // (gap G3). A transportable artwork URL for a MusicKit library item is
        // its own unmeasured question, not this slice's to answer.
        if (isAlbumRail || isTracksLevel), currentAlbumSource != .bridge, let a = focusedAlbum() {
            kickCoverFetch(albumID: a.id)
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

        var contentTop = bodyTop + 2
        guard contentTop <= bodyBottom else { return out }

        // Which library this list is showing. Drawn HERE rather than inside each
        // list so the rail, the hero and the preview pane all start on the same
        // row: shifting only the rail would misalign the three-zone layout.
        if let line = librarySourceLine() {
            out += ANSICode.moveTo(row: contentTop, col: z.railX)
            out += "\(ANSICode.dim)\(line)\(ANSICode.reset)"
            contentTop += 1
            guard contentTop <= bodyBottom else { return out }
        }

        switch nav.subView {
        case .albums:
            renderRail(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom)
            renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom, cellW: frame.cellW, cellH: frame.cellH)
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
                renderHero(z, into: &out, contentTop: contentTop, bodyBottom: bodyBottom, cellW: frame.cellW, cellH: frame.cellH)
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
            case .space: filter.append(" "); clampFilterCursor()
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
        // Manual retry: resets the shared budget and asks tick to start exactly
        // one new load. Never blocks the input loop, and is only claimed while a
        // failure is showing, so `r` keeps any other meaning the rest of the time.
        case .char("r") where retryOffered, .char("R") where retryOffered:
            // Each backend's own retry. A Bridge failure never resets the shared
            // AppleScript budget and a Music.app failure never re-walks Bridge:
            // "press r to retry" retries the list the person is looking at.
            if songsFromBridge, isSongList, bridgeFailure != nil {
                retryBridgeSongs()
                status.post("Asking Bridge for your library again\u{2026}")
                return .none
            }
            // C2 item 7: a failed Bridge Albums or Artists list resets and
            // restarts only that list's own feed — never the shared budget
            // `loads` owns, which is Music.app's alone.
            if albumsSource == .bridge, isAlbumList, bridgeAlbumsFailure != nil {
                albumsFeed.reset()
                albumsFetchStarted = false
                albumsDone = false
                bridgeAlbumsFailure = nil
                status.post("Asking Bridge for your library again\u{2026}")
                return .none
            }
            if artistsSource == .bridge, isArtistList, bridgeArtistsFailure != nil {
                artistsFeed.reset()
                artistsFetchStarted = false
                artistsDone = false
                bridgeArtistsFailure = nil
                status.post("Asking Bridge for your library again\u{2026}")
                return .none
            }
            loads.manualRetry()
            inboxLock.lock()
            pendingReadFailed = false
            pendingExhausted = false
            restartRequested = true
            inboxLock.unlock()
            status.post("Retrying the Music library read\u{2026}")
            return .none
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
                // C2 item 8: the SWR cache is Music.app's alone. Seeding from
                // it ahead of a Bridge album load would paint Music.app
                // artist names as this tier's members until Bridge's own
                // rows land and correct them — a real (if brief) library mix.
                // Once Bridge rows exist, `epArtists`/`albumArtists` are
                // already computed live from them (the feed's drain), so this
                // seed only ever matters for the empty, not-yet-loaded case.
                if makeProvider() == nil, epArtists.isEmpty, albumArtists.isEmpty,
                   let cached = resultCache.cachedArtistTiers() {
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
            // A retry on Enter: clearing the failure first is what lets a
            // person retry a failed Bridge album by drilling in again,
            // without the tick-driven preview kick retrying it on every focus
            // (kickTrackFetch's own guard).
            bridgeTrackFailures.removeValue(forKey: albumID)
            // Reuse the shared cache: if the preview already loaded it, this is a
            // no-op and the tracks level paints instantly; otherwise it kicks the
            // same serial fetch and the pane shows "loading…" until it lands.
            kickTrackFetch(albumID: albumID, title: title, artist: artist)
        case .play(.album(let id, let title, let artist)):
            // Enter on a row in the album tracklist starts the queue AT that track
            // (nav.cursor is the track index there); elsewhere it's whole-album.
            // Addendum U: the SAME `isTracksLevel` check also decides
            // `startRequired` — a track-level `.play` (Enter, or `p` pressed
            // while browsing that row) is the person choosing exactly where
            // to start, whether `nav.cursor` happens to be 0 or not; at the
            // rail level `.play` always starts the whole album from track 1,
            // never a chosen row.
            dispatchAlbumPlay(id: id, title: title, artist: artist, shuffle: false,
                              startAt: isTracksLevel ? nav.cursor + 1 : 1, startRequired: isTracksLevel)
        case .shuffle(.album(let id, let title, let artist)):
            // Shuffle always plays the whole set in random order (D3/6.5) —
            // never a chosen start song, so never `startRequired`.
            dispatchAlbumPlay(id: id, title: title, artist: artist, shuffle: true, startAt: 1, startRequired: false)
        case .play(.song(let id, let title, let artist)):
            dispatchSongPlay(id: id, title: title, artist: artist, shuffle: false)
        case .shuffle(.song(let id, let title, let artist)):
            dispatchSongPlay(id: id, title: title, artist: artist, shuffle: true)
        case .play(.artist(let id, let name)):
            dispatchArtistPlay(id: id, name: name, shuffle: false)
        case .shuffle(.artist(let id, let name)):
            dispatchArtistPlay(id: id, name: name, shuffle: true)
        case .none:
            break
        }
    }

    /// C3 item 5: decided by the source of the list the action came from, not
    /// by the live output alone — a stale Music.app-sourced list played while
    /// Bridge is now selected refuses, exactly as a stale Bridge-sourced one
    /// played after switching to Music.app does (rule 3, both directions).
    private func dispatchAlbumPlay(id: String, title: String, artist: String, shuffle: Bool, startAt: Int,
                                   startRequired: Bool) {
        if currentAlbumSource == .bridge {
            playBridgeAlbum(albumID: id, title: title, shuffle: shuffle, startAt: startAt,
                            startRequired: startRequired, rows: bridgeTracks[id])
        } else if makeProvider() != nil {
            actions.run("Play") { throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) }
        } else {
            playAlbum(title: title, artist: artist, shuffle: shuffle, startAt: startAt)
        }
    }

    private func dispatchArtistPlay(id: String, name: String, shuffle: Bool) {
        if artistsSource == .bridge {
            playBridgeArtist(artistID: id, name: name, shuffle: shuffle)
        } else if makeProvider() != nil {
            actions.run("Play") { throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) }
        } else {
            playArtist(name: name, shuffle: shuffle)
        }
    }

    private func dispatchSongPlay(id: String, title: String, artist: String, shuffle: Bool) {
        if songsFromBridge, makeProvider() == nil {
            actions.run("Play") { throw ActionError(message: LibraryProvenance.musicAppSelectedBridgeList) }
            return
        }
        if !songsFromBridge, makeProvider() != nil {
            actions.run("Play") { throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) }
            return
        }
        playSong(id: id, title: title, artist: artist, shuffle: shuffle)
    }

    /// Whole-album (or from-a-track) play via the app-owned queue. macOS 26.x
    /// roots ANY scripted play in the whole library (probed live 2026-07-12), so
    /// native `play <tracks>` gives an all-library Up Next that wanders past the
    /// album. Instead we build an AppQueue of just the album's tracks (sourced
    /// from "Library" by position) and let the poller drive it: scoped Up Next,
    /// navigable, stops at the album's end. Autoplay (∞) must be OFF. Track-by-
    /// track, so not gapless — the accepted trade-off. On the action queue; the
    /// bulk fetch never freezes the UI and failures toast.
    // Internal, not private, so the routing binding is reachable from a test.
    //
    // C3 item 8: this is now the MUSIC.APP-SOURCED album's play path only.
    // Bridge-sourced albums play through `playBridgeAlbum`, dispatched by
    // `execute` from `currentAlbumSource`; a Music.app-sourced album played
    // while Bridge is selected refuses here (rule 3: no join, in either
    // direction) rather than resolving by title against whichever backend
    // Bridge would otherwise join to.
    func playAlbum(title: String, artist: String, shuffle: Bool, startAt: Int = 1) {
        let backend = self.backend
        let store = self.appQueue
        let routing = self.routing
        let status = self.status
        let resolve = self.resolveAlbum
        let makeProvider = self.makeProvider
        actions.run("Play") {
            if makeProvider() != nil {
                throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
            }
            // Binding rule 9's named exception: the library READ stays on
            // AppleScript in BOTH modes, so the two branches resolve from the
            // same rows and cannot play a different album than the one listed.
            // A read is not a playback action, so rule 3 is untouched.
            //
            // resolveAlbumPlaybackTracks tries the strict album+artist clause first
            // (remix/compilation albums credit each track to the remixer, so
            // `album artist` catches those, and the artist clause disambiguates
            // same-named albums), then falls back to matching by album title alone
            // when the library credit has drifted from the stored album artist:
            // the pre-release "Mere Mortals" case, where the exact clause
            // matched 0 of 14 tracks. It also drops tracks Music can't play yet
            // (pre-release/removed), on which `play track` would silently no-op.
            let res = resolve(backend, title, artist)
            try require(!res.tracks.isEmpty, emptyResolutionMessage(res, name: title,
                unavailable: "'\(title)': no tracks available to play yet.",
                notFound: "Couldn't load '\(title)'."))
            do {
                // Both branches are real, so there is deliberately no
                // `if routing.mode == .source` above: the coordinator picks the
                // destination inside its own lock. An outer check would leave a
                // no-op Music.app branch for a switch that commits mid-action.
                try routing.perform(.libraryPlay,
                    musicApp: {
                        let ordered = shuffle ? res.tracks.shuffled() : res.tracks
                        let idx = shuffle ? 1 : min(max(1, startAt), ordered.count)
                        store.set(AppQueue(playlistName: "Library", tracks: ordered, currentIndex: idx, displayName: title))
                        try require(playQueueTrack(backend: backend, playlist: "Library", position: ordered[idx - 1].index),
                                    "Couldn't play '\(title)'.")
                        // Pre-release albums surface every planned track but only stream some;
                        // say so rather than silently playing a partial album.
                        if res.matched > ordered.count {
                            status.post("Playing \(ordered.count) of \(res.matched) — the rest aren't available yet.")
                        }
                    },
                    source: { _ in
                        // The join is gone: a Music.app-sourced list played
                        // while Bridge is selected refuses rather than joining
                        // Bridge on `(title, artist, album)`.
                        throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
                    },
                    unaffected: {})
            } catch let error as SourceAppError {
                // ActionRunner prints an ActionError's message and reduces
                // anything else to "Play failed.", which would hide the
                // 100-song bound and "no unique match" alike.
                throw ActionError(message: error.message)
            }
        }
    }

    /// Play one library song as a 1-track app-owned queue — plays it and stops,
    /// instead of the old native `play some track` that dropped into the whole
    /// library and bled into Autoplay. Autoplay (∞) must be OFF. Shuffle is a
    /// no-op for a single track (the param stays for a uniform call site).
    ///
    /// **No `album` parameter.** Before C3 this needed the song's album to
    /// build Bridge's `(title, artist, album)` queue row when there was no
    /// provider; that fallback is gone (D3/C3 item 8 — a Music.app-sourced
    /// song played while Bridge is selected refuses in `dispatchSongPlay`
    /// before this function is ever called), so nothing here reads it any
    /// more. `songs[].album` still exists on the row for display.
    ///
    /// `id` is the id of whichever backend produced the row, and it is opaque
    /// here: in Bridge mode it is the MusicKit library id a Bridge page carried,
    /// and it is what plays the row. Nothing compares it to a Music.app id.
    private func playSong(id: String, title: String, artist: String, shuffle: Bool) {
        let backend = self.backend
        let store = self.appQueue
        let routing = self.routing
        let provider = makeProvider()
        let status = self.status
        let warmUpSleep = self.warmUpSleep
        actions.run("Play") {
            // Bridge mode: the row plays by the id Bridge gave it. No
            // `(title, artist, album)` triple is built, and no album is required
            // — the whole reason a row with no album used to refuse.
            if let provider {
                do {
                    // A cold Bridge answers a queue with `warming` rather than
                    // blocking for its drain, so the play waits on the hint
                    // exactly as the library read does — bounded, visible, and
                    // never a silent failure to play. Re-sending is safe:
                    // Bridge acquires its snapshot before it touches the player,
                    // so a queue that answered `warming` mutated nothing.
                    //
                    // **The wait is OUTSIDE `perform`, one attempt at a time.**
                    // Sleeping inside the branch would hold the coordinator's
                    // ordering lock for the whole warm-up and block every other
                    // playback action and mode switch behind it. Taking the lock
                    // per attempt also means the route is re-decided each time,
                    // which is the rule that lock exists for.
                    try retryingWhileWarming(
                        onWarming: { _ in
                            status.post("Preparing your library \u{2014} '\(title)' will play when it's ready\u{2026}")
                        },
                        sleep: warmUpSleep) {
                        // The destination is still chosen inside the
                        // coordinator's lock, not by the `if` above: a switch
                        // that commits between the keypress and this closure
                        // must not reach the wrong player. The musicApp branch
                        // is deliberately empty — a switch to Music.app
                        // mid-action plays nothing rather than playing a row
                        // from a library it is no longer showing.
                        try routing.perform(.libraryPlay, musicApp: {},
                            source: { _ in _ = try provider.play(ids: [id]) },
                            unaffected: {})
                    }
                } catch let error as MusicProviderError {
                    // Bridge's own sentence, or the footer reduces it to the
                    // four useless words "Play failed."
                    throw ActionError(message: error.errorDescription ?? "Couldn't play '\(title)' on Bridge.")
                } catch let error as SourceAppError {
                    throw ActionError(message: error.message)
                }
                return
            }
            if routing.mode == .source {
                // C3 item 8: the join is gone. This is a Music.app-sourced
                // song (no provider, checked above) played while Bridge is
                // selected — rule 3, no silent fallback in either direction.
                // After this, this file sends no title-and-credit queue shape at all.
                throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
            }
            // Same credit drift as playAlbum: the song row's artist is the library
            // credit and can differ from the stored credit (comma vs ampersand,
            // per-track soloists), so the strict name+artist clause matches nothing.
            // Falls back to a title-only fetch resolved in Swift, and refuses
            // rather than guesses when nothing folds.
            let res = resolveSongPlaybackTrack(backend: backend, title: title, artist: artist)
            try require(!res.tracks.isEmpty, emptyResolutionMessage(res, name: title,
                unavailable: "'\(title)' isn't available to play yet.",
                notFound: "Couldn't play '\(title)'."))
            let one = Array(res.tracks.prefix(1))
            store.set(AppQueue(playlistName: "Library", tracks: one, currentIndex: 1, displayName: title))
            try require(playQueueTrack(backend: backend, playlist: "Library", position: one[0].index),
                        "Couldn't play '\(title)'.")
        }
    }

    /// Play every library track by one artist as an app-owned queue (scoped,
    /// navigable, stops at the end — same rationale as playAlbum). Autoplay OFF.
    // Internal, not private, so the routing binding is reachable from a test.
    //
    // C3 item 8: Music.app-sourced artists only, same as `playAlbum`.
    // Bridge-sourced artists play through `playBridgeArtist`.
    func playArtist(name: String, shuffle: Bool) {
        let backend = self.backend
        let store = self.appQueue
        let routing = self.routing
        let status = self.status
        let resolve = self.resolveArtist
        let makeProvider = self.makeProvider
        actions.run("Play") {
            if makeProvider() != nil {
                throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
            }
            // Rule 9's named exception again: the read runs in both modes.
            //
            // `name` is the library credit (album artist, else artist), so the
            // strict `artist is` clause now usually hits. The loose fallback stays
            // for per-track soloist credits: on the live repro ("Floating Points,
            // San Francisco Ballet Orchestra") the four movements each credit a
            // different soloist while the album artist is uniform, so the strict
            // clause matched nothing there. The resolver keeps that strict clause
            // as the fast path, then falls back to a loose fetch on the primary
            // credit narrowed in Swift, and drops tracks Music silently refuses to play.
            let res = resolve(backend, name)
            try require(!res.tracks.isEmpty, emptyResolutionMessage(res, name: name,
                unavailable: "'\(name)': no tracks available to play yet.",
                notFound: "Couldn't load '\(name)'."))
            do {
                try routing.perform(.libraryPlay,
                    musicApp: {
                        let ordered = shuffle ? res.tracks.shuffled() : res.tracks
                        store.set(AppQueue(playlistName: "Library", tracks: ordered, currentIndex: 1, displayName: name))
                        try require(playQueueTrack(backend: backend, playlist: "Library", position: ordered[0].index),
                                    "Couldn't play '\(name)'.")
                        if res.matched > ordered.count {
                            status.post("Playing \(ordered.count) of \(res.matched) — the rest aren't available yet.")
                        }
                    },
                    source: { _ in
                        throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
                    },
                    unaffected: {})
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            }
        }
    }

    /// C3 item 6: whole-album (or from-a-track) play via Bridge, by the ids
    /// the rows this person was looking at carry. `rows`, when non-nil, is
    /// the already-cached list — captured on the main thread by `execute`, so
    /// it is exactly the list `nav.cursor` indexed; a fresh read only happens
    /// when nothing is cached yet.
    // Internal, not private, so it is reachable from a test.
    func playBridgeAlbum(albumID: String, title: String, shuffle: Bool, startAt: Int, startRequired: Bool,
                         rows: [MusicRow]?) {
        let routing = self.routing
        let status = self.status
        let makeProvider = self.makeProvider
        let sleep = self.warmUpSleep
        actions.run("Play") {
            guard let provider = makeProvider() else {
                // Output changed to Music.app between the keypress and this
                // closure running: the list WAS Bridge's, but Bridge is no
                // longer selected.
                throw ActionError(message: LibraryProvenance.musicAppSelectedBridgeList)
            }
            do {
                // ONE budget for the whole action (read + queue), so D5's
                // 60s is the action's total patience, not 60s per call.
                let budget = WarmUpBudget()
                let onWarming: (TimeInterval) -> Void = { _ in
                    status.post("Preparing your library \u{2014} '\(title)' will play when it's ready\u{2026}")
                }
                let trackRows = try rows ?? retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                    try provider.albumTracks(albumID: albumID)
                }.rows
                try require(!trackRows.isEmpty, "'\(title)' has no songs Bridge can play.")
                let ids = bridgeQueueIDs(trackRows, shuffle: shuffle, startAt: startAt)
                // Addendum U: how many of `ids` Bridge dropped as unavailable,
                // set only on the attempt that actually succeeds (U-R5/U-R6).
                var skippedUnavailable = 0
                try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                    try routing.perform(.libraryPlay,
                        musicApp: {
                            throw ActionError(message:
                                "Output changed to Music.app before '\(title)' could play on Bridge; nothing was played.")
                        },
                        source: { _ in
                            skippedUnavailable = try provider.playReportingSkips(
                                ids: ids, startRequired: startRequired).skippedUnavailable
                        },
                        unaffected: {})
                }
                let queuedCount = ids.count - skippedUnavailable
                var footer = "Playing '\(title)' on Bridge \u{2014} \(queuedCount) tracks."
                if skippedUnavailable > 0 { footer += " " + bridgeUnavailableSongsNotice(skippedUnavailable) }
                status.post(footer)
            } catch let error as MusicProviderError {
                throw ActionError(message: error.errorDescription ?? "Couldn't play '\(title)' on Bridge.")
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            }
        }
    }

    /// C3 item 7: every library track by one Bridge artist — the same shape
    /// as `playBridgeAlbum` through `provider.artistSongs(artistID:)`, one
    /// budget shared by the read and the queue, no start row, and `too_large`
    /// reaching the footer verbatim with no queue sent.
    // Internal, not private, so it is reachable from a test.
    func playBridgeArtist(artistID: String, name: String, shuffle: Bool) {
        let routing = self.routing
        let status = self.status
        let makeProvider = self.makeProvider
        let sleep = self.warmUpSleep
        actions.run("Play") {
            guard let provider = makeProvider() else {
                throw ActionError(message: LibraryProvenance.musicAppSelectedBridgeList)
            }
            do {
                let budget = WarmUpBudget()
                let onWarming: (TimeInterval) -> Void = { _ in
                    status.post("Preparing your library \u{2014} '\(name)' will play when it's ready\u{2026}")
                }
                let songRows = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                    try provider.artistSongs(artistID: artistID)
                }.rows
                try require(!songRows.isEmpty, "'\(name)' has no songs Bridge can play.")
                let ids = bridgeQueueIDs(songRows, shuffle: shuffle, startAt: 1)
                // Addendum U: same as playBridgeAlbum above. An artist play is
                // always whole-collection — there is no track-level entry for
                // an artist, so `startRequired` is always false.
                var skippedUnavailable = 0
                try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                    try routing.perform(.libraryPlay,
                        musicApp: {
                            throw ActionError(message:
                                "Output changed to Music.app before '\(name)' could play on Bridge; nothing was played.")
                        },
                        source: { _ in
                            skippedUnavailable = try provider.playReportingSkips(
                                ids: ids, startRequired: false).skippedUnavailable
                        },
                        unaffected: {})
                }
                let queuedCount = ids.count - skippedUnavailable
                var footer = "Playing '\(name)' on Bridge \u{2014} \(queuedCount) tracks."
                if skippedUnavailable > 0 { footer += " " + bridgeUnavailableSongsNotice(skippedUnavailable) }
                status.post(footer)
            } catch let error as MusicProviderError {
                throw ActionError(message: error.errorDescription ?? "Couldn't play '\(name)' on Bridge.")
            } catch let error as SourceAppError {
                throw ActionError(message: error.message)
            }
        }
    }

    // MARK: level helpers

    /// Whether `r` means anything right now. Either backend can be the one
    /// offering it, and neither answers for the other.
    private var retryOffered: Bool {
        readFailed
            || (songsFromBridge && isSongList && bridgeFailure != nil)
            || (albumsSource == .bridge && isAlbumList && bridgeAlbumsFailure != nil)
            || (artistsSource == .bridge && isArtistList && bridgeArtistsFailure != nil)
    }

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

    /// Which library the album rail/hero/preview at the CURRENT level is
    /// showing (C3 item 1). At `.albumList` it's `albumsSource`. At
    /// `.artistAlbums`, and at `.tracks` inside the Artists sub-view, it's
    /// `artistsSource` (an artist's albums are Artists' rows, not Albums').
    /// At `.tracks` inside the Albums sub-view it's `albumsSource`. `nil`
    /// (the Songs sub-view, or nothing drilled) means the question does not
    /// apply here.
    private var currentAlbumSource: ListSource? {
        switch nav.current {
        case .albumList:
            return albumsSource
        case .artistAlbums:
            return artistsSource
        case .tracks:
            return nav.subView == .artists ? artistsSource : albumsSource
        default:
            return nil
        }
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

    /// True while this tab is showing MORE THAN ONE library: some list here is
    /// Bridge's and some Music.app's. Since D1 that can be Songs alongside a
    /// Music.app-sourced Albums/Artists only in the narrow window right after
    /// a provenance switch, before the lazy loaders have picked their branch
    /// (`applyProvenance` resets `*Source` to nil, and the SAME tick's lazy
    /// load fills it back in — see D7). In steady state Albums and Artists
    /// follow Songs to whichever library is selected.
    private var tabShowsTwoLibraries: Bool { songsFromBridge || routing.mode == .source }

    /// Which library the showing list is reading, and how big it is once that is
    /// known.
    ///
    /// **Required by the design, not decoration.** A list that named neither
    /// library would be telling a person the same thing whichever one it
    /// happened to be showing. **No count is invented**: every branch shows
    /// the backend's own count — Bridge's wire `total` first, else the rows
    /// in hand once THAT list's own read is done — never a number computed
    /// here.
    private func librarySourceLine() -> String? {
        switch nav.subView {
        case .songs:
            guard songsFromBridge else { return nil }
            return sourceLine("Songs", "Bridge library",
                              count: bridgeSongTotal ?? (songsLoaded ? songs.count : nil))
        case .albums:
            switch albumsSource {
            case .bridge:
                return sourceLine("Albums", "Bridge library",
                                  count: bridgeAlbumTotal ?? (albumsLoaded ? albums.count : nil))
            case .musicApp:
                guard tabShowsTwoLibraries else { return nil }
                return sourceLine("Albums", "Music.app library", count: albumsLoaded ? albums.count : nil)
            case nil:
                return nil   // hasn't picked a branch yet this session
            }
        case .artists:
            // Drilled into one artist the rows are that artist's albums, so the
            // artist count would be a number about a different list. Left off
            // rather than made up — "Artists count shows only at the list level".
            switch artistsSource {
            case .bridge:
                return sourceLine("Artists", "Bridge library",
                                  count: (isArtistList && artistsLoaded) ? (bridgeArtistTotal ?? artists.count) : nil)
            case .musicApp:
                guard tabShowsTwoLibraries else { return nil }
                return sourceLine("Artists", "Music.app library",
                                  count: (isArtistList && artistsLoaded) ? artists.count : nil)
            case nil:
                return nil
            }
        }
    }

    private func sourceLine(_ list: String, _ library: String, count: Int?) -> String {
        guard let count else { return "\(list) \u{2014} \(library)" }
        return "\(list) \u{2014} \(library) (\(groupedCount(count)))"
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
            let msg: String
            if nav.subView == .artists {
                // The drilled artist's albums (C3 item 4): Bridge's own
                // sentence replaces "Loading albums…"/"(no albums)". No
                // separate `r` here — drilling out and back in retries it.
                if let failure = artistAlbumsFailure {
                    msg = failure
                } else {
                    msg = artistAlbumsLoaded ? (filter.isEmpty ? "(no albums)" : "(no matches)") : "Loading albums\u{2026}"
                }
            } else if albumsSource == .bridge {
                // C2 item 6: Bridge's own failure/warming, never the shared
                // `readFailed` — a Music.app read that failed says nothing
                // about a list Music.app was never asked for.
                let st = libraryStatus(hasData: !albums.isEmpty, lastReadFailed: bridgeAlbumsFailure != nil,
                                       retriesExhausted: true)
                if let failure = unreadableMessage(st, bridgeFailure: bridgeAlbumsFailure) { msg = failure }
                else if bridgeAlbumsWarming { msg = "Preparing your library\u{2026}" }
                else { msg = albumsLoaded ? (filter.isEmpty ? "(no albums)" : "(no matches)") : "Loading albums\u{2026}" }
            } else {
                let st = libraryStatus(hasData: !albums.isEmpty, lastReadFailed: readFailed,
                                       retriesExhausted: retriesExhausted)
                if let failure = unreadableMessage(st) { msg = failure }
                else { msg = albumsLoaded ? (filter.isEmpty ? "(no albums)" : "(no matches)") : "Loading albums\u{2026}" }
            }
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
            // The Songs list reports its OWN backend. In Bridge mode that is
            // Bridge's failure state, never the shared AppleScript one: a
            // Music.app read that failed says nothing about a list Music.app
            // was never asked for. Bridge has no automatic retry chain, so a
            // failure is immediately "stopped, waiting for a person".
            let st = songsFromBridge
                ? libraryStatus(hasData: !songs.isEmpty, lastReadFailed: bridgeFailure != nil,
                                retriesExhausted: true)
                : libraryStatus(hasData: !songs.isEmpty, lastReadFailed: readFailed,
                                retriesExhausted: retriesExhausted)
            let msg: String
            if let failure = unreadableMessage(st, bridgeFailure: songsFromBridge ? bridgeFailure : nil) { msg = failure }
            // Not ready YET. Ahead of "Loading songs…" because it says something
            // truer — the wait is Bridge's, not the read's — and ahead of any
            // empty text, because an empty list here would be a lie.
            else if bridgeWarming { msg = "Preparing your library\u{2026}" }
            else { msg = songsLoaded ? (filter.isEmpty ? "(no songs)" : "(no matches)") : "Loading songs\u{2026}" }
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
            if artistsSource == .bridge {
                // C2 item 6: Bridge's own failure/warming, never `readFailed`.
                let st = libraryStatus(hasData: !artists.isEmpty, lastReadFailed: bridgeArtistsFailure != nil,
                                       retriesExhausted: true)
                if let failure = unreadableMessage(st, bridgeFailure: bridgeArtistsFailure) { msg = failure }
                else if bridgeArtistsWarming { msg = "Preparing your library\u{2026}" }
                else if !artistsLoaded { msg = "Loading artists\u{2026}" }
                else if artistFilter != .all && albumsSource == .bridge && !albumsLoaded { msg = "Loading albums\u{2026}" }
                else if !filter.isEmpty { msg = "(no matches)" }
                else {
                    switch artistFilter {
                    case .all: msg = "(no artists)"
                    case .epOr12: msg = "(no 12\" / EP artists)"
                    case .albums: msg = "(no album artists)"
                    }
                }
            } else {
                let st = libraryStatus(hasData: !artists.isEmpty, lastReadFailed: readFailed,
                                       retriesExhausted: retriesExhausted)
                if let failure = unreadableMessage(st) { msg = failure }
                else if !artistsLoaded { msg = "Loading artists\u{2026}" }
                else if artistFilter != .all && !albumsLoaded { msg = "Loading albums\u{2026}" }
                else if !filter.isEmpty { msg = "(no matches)" }
                else {
                    switch artistFilter {
                    case .all: msg = "(no artists)"
                    case .epOr12: msg = "(no 12\" / EP artists)"
                    case .albums: msg = "(no album artists)"
                    }
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

    private func renderHero(_ z: PlaylistZones, into out: inout String, contentTop: Int, bodyBottom: Int,
                            cellW: Double, cellH: Double) {
        guard let a = focusedAlbum() else { return }
        var y = contentTop
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(a.name, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.dim)\(truncText(a.artist, to: z.heroWidth))\(ANSICode.reset)"
        y += 2

        // Fill the hero pane, square: the full hero width and every row left
        // after the art (4 reserved below — blank, track count, blank, hint).
        // kittySquareRect derives the actual square placement from whichever
        // of gw/gh binds tighter, so this is no longer capped to the Now
        // tab's old 44x22.
        let gw = z.heroWidth
        let gh = max(0, bodyBottom - y - 4)
        var artBlock: ArtBlock? = nil
        if let hit = coverCache[a.id] ?? nil {
            artBlock = artwork.block(key: hit.key,
                                     url: hit.url,
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
            // Covers are square. Kitty placement STRETCHES to the rect (chafa
            // letterboxes), so clamp to square-equivalent IN PIXELS for the
            // measured cell size, or a narrow hero stretches art tall.
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
            // and `.lines`, so the track-count/hint lines below don't shift
            // depending on which art path rendered.
            let gradient = gradientBlock(name: a.name + a.artist, width: pc, height: pr)
            for (i, line) in gradient.enumerated() {
                out += ANSICode.moveTo(row: y + i, col: z.heroX) + line
            }
            y += pr
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
            // C3 item 2: a Bridge failure shows its own sentence exactly where
            // "Loading…" would otherwise sit — `trackCache` is left unset on
            // a Bridge failure, so this is the one place that tells the two
            // apart.
            let text = bridgeTrackFailures[a.id] ?? "Loading\u{2026}"
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(text)\(ANSICode.reset)"
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

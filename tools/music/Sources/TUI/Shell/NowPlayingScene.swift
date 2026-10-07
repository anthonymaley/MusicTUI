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

/// The continuation menu's entries for the selected output (spec 6.2's `n` row).
///
/// **Bridge offers no Shuffle.** It would shuffle "the current collection", and
/// in Bridge mode nothing on this side knows what that is (see `act(on:)`): the
/// entry could only name Music.app's last context and then refuse. Playlist is
/// navigation and Quiet pauses Bridge, so both stay.
func continuationOptions(bridge: Bool) -> [ContinuationAction] {
    bridge ? [.playlist, .quiet] : [.shuffle, .playlist, .quiet]
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

/// Square-equivalent clamp for the art LINES size published to the poller
/// each render — the SAME rows = min(artRows, gw / 2), cols = 2 * rows
/// formula the kitty rect (`gw`, below) already renders at, so the chafa/mono
/// lines path follows the same proportions kitty stretches its PNG to.
/// Floors at (20, 10): `rows` floors at 10, and since `cols` is always
/// exactly `2 * rows`, that floor already puts `cols` at its own floor of 20.
/// Pure.
func clampedArtSize(artRows: Int, gw: Int) -> (cols: Int, rows: Int) {
    let rows = max(10, min(artRows, gw / 2))
    return (cols: 2 * rows, rows: rows)
}

final class NowPlayingScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Now"
    var footerHint: String {
        // On SpanDAC the grid's live rows and seek and Quiet are the keys; Up
        // Next can be browsed when SpanDAC reports its rows, but Enter's jump
        // is refused there (ruling 12.13), so it is not advertised. `x` became
        // a Now key in its own right on 2026-09-22 (spec 6.2's row); it pauses
        // Bridge, never Music.app (ruling 12.7).
        // Every SpanDAC-shaped choice on this tab follows where the sound is
        // (`effectiveOutput`), never the stored output (Codex review 101,
        // blocking 1): with SpanDAC on this Mac not serving, MusicTUI's
        // controls are the live ones.
        if routing.effectiveOutput.usesSource {
            if spanDACGridShown {
                return gridFocused ? "\u{2191}\u{2193} Row  Enter Set  \u{2192} Release  [ ] Seek  x Quiet"
                                   : "\u{2190} Controls  s Shuffle  r Repeat  [ ] Seek  x Quiet"
            }
            return "[ ] Seek  x Quiet"
        }
        return gridFocused
            ? "\u{2191}\u{2193} Row  Enter Set  \u{2192} Up Next  [ ] Seek  \u{2014} controls"
            : "\u{2191}\u{2193} Browse  \u{2190} Controls  Enter Jump  [ ] Seek  l \u{2665}"
    }

    private let backend: AppleScriptBackend
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner
    // REST fallback for tracks with no embedded artwork (see NowArtwork.swift).
    // nil when the user isn't signed in / no dev token configured — the token-
    // less path then falls straight to the gradient, exactly today's behavior.
    private let restArtworkAPI: RESTAPIBackend?
    // Publishes the desired art LINES size to PlaybackPoller each render —
    // Shell wires this to poller.setDesiredArtSize so this scene never needs
    // to know PlaybackPoller exists (mirrors how the other scene deps below
    // are injected). No-op default so scenes built without art-size wiring
    // (e.g. existing tests) don't need to change.
    private let setArtSize: (Int, Int) -> Void
    private var cursor = 0
    private var scroll = 0
    private var rows: [TrackListEntry] = []
    private var lastCurrentKey = ""
    private var manualMenu = false   // user-opened menu (vs poller-detected queueEnded)
    private var menuShownLastFrame = false
    private var pendingSeedTitle = ""
    private var pendingSeedArtist = ""
    private var pendingSource: ContinuationSource? = nil  // what ended, for the Shuffle action
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

    // SpanDAC's grid. `spanDACGridShown`: whether the last frame drew it (keys
    // only act on it while it is on screen). `lastBridge`: what the last tick or
    // render saw, which the keys read to decide offered / current. A press
    // overrides SpanDAC's own state for a moment, so the cell moves at once
    // instead of after the next poll; it is guarded by `bridgeModesLock` because
    // a failed press clears it from the action queue.
    private var spanDACGridShown = false
    private var lastBridge: BridgeNow? = nil
    private let bridgeModesLock = NSLock()
    private var bridgeModesOverride: (shuffle: Bool?, repeatMode: String?, at: Date)? = nil
    static let bridgeModesOverrideSeconds: TimeInterval = 2.5

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
    // "never attempted" (see kittyIdentity's `if let` unwrap of the outer
    // Optional for how this collapses cleanly to a single `String?`).
    private var transmitCache: [UInt32: String?] = [:]
    // path -> content-hash id, resolved once per path and reused thereafter
    // (see kittyIdentity(forPath:) for why the id must come from the file's
    // BYTES, not a caller-supplied label like the track name).
    private var idCache: [String: UInt32] = [:]

    // REST artwork fallback (reached only when the poller's embedded extraction
    // found nothing for the current track — see render()'s art ladder). The
    // same store class the Library/Playlists hero panes use, so Now's covers
    // go through the identical fetch/cache/render path; this scene just owns
    // its own instance, like every other art scene. `restArt`/`restAttempted`/
    // `restInFlight` are tick()-thread-only (drained from the locked inbox,
    // the same discipline as every other background-fetch cache here);
    // `restInbox`/`artDirty` are the cross-thread handoff, guarded by artLock.
    private let artwork = ArtworkStore()
    // albumKey -> the library album's REST id + {w}x{h} artwork template. The
    // id is what ArtworkStore is keyed on, so a cover the Library tab already
    // fetched is a disk-cache HIT here rather than a second download.
    private var restArt: [String: (id: String, url: String)] = [:]
    // Tried-once set, keyed by TRACK (not album): Apple's library search misses
    // some titles outright (see NowArtwork.swift), so an album whose first
    // played track can't be resolved still gets a chance on the next track —
    // one attempt per track, and none at all once the album's cover is cached
    // in `restArt`. tick()-thread only, like restInFlight.
    private var restAttempted: Set<String> = []
    private var restInFlight: Set<String> = []
    private let artLock = NSLock()
    private var restInbox: [(track: String, album: String, hit: (id: String, url: String)?)] = []
    private var artDirty = false

    // SpanDAC cover by persistent ID (no fetchable artwork URL). The extraction
    // is an osascript run, so it goes on its own serial queue from tick(), never
    // from render(); `bridgeCoverPaths` (hit) and `bridgeCoverTried` (hit OR
    // miss, so a song with no embedded art is asked once) are guarded by
    // artLock, the same handoff as the REST fallback. Keyed by the hex ID.
    private let bridgeCoverQueue = DispatchQueue(label: "music.now.bridgecover")
    private var bridgeCoverPaths: [String: String] = [:]
    private var bridgeCoverTried: Set<String> = []
    /// (hex persistent ID, temp path) -> path of the written cover, or nil.
    /// Production runs the Library tab's `extractLibraryTrackArtwork`; tests
    /// inject a fake so nothing touches a real Music.app.
    private let bridgeCoverExtractor: (String, String) -> String?

    /// Blocks until queued cover extractions finish. Tests only.
    func waitForBridgeCover() { bridgeCoverQueue.sync {} }

    init(backend: AppleScriptBackend, appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner,
         routing: RoutingCoordinator,
         restArtworkAPI: RESTAPIBackend? = nil, kittyEnabled: Bool = false,
         setArtSize: @escaping (Int, Int) -> Void = { _, _ in },
         bridgeCoverExtractor: ((String, String) -> String?)? = nil) {
        self.bridgeCoverExtractor = bridgeCoverExtractor ?? { pid, path in
            extractLibraryTrackArtwork(backend: backend, persistentID: pid, to: path)
        }
        self.routing = routing
        self.backend = backend
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
        self.restArtworkAPI = restArtworkAPI
        self.kittyEnabled = kittyEnabled
        self.setArtSize = setArtSize
    }

    private let routing: RoutingCoordinator

    func artPlacementsInvalidated() { lastPlaced = nil }

    /// Resolve (and cache) the content-derived id + transmit escape for the
    /// artwork at `path`. The id is a hash of the file's BYTES
    /// (`kittyImageID(forBytes:)`), not the path or track name — the prior
    /// scheme (`kittyImageID(forKey: path + trackName)`) let a NEW track's id
    /// get permanently associated with STALE bytes: `path` was a single
    /// fixed poller temp file, and a track whose album was already cached
    /// (lines-only) skipped re-extraction entirely, so a revisit read
    /// whatever album's raw bytes the file last happened to hold and pinned
    /// that under the new (correct-looking) id forever. PlaybackPoller now
    /// writes each album to its own stable temp path (never overwritten by a
    /// different album for the life of the process), so in practice this id
    /// only needs to be computed once per distinct path — but hashing the
    /// actual bytes rather than trusting the path is the belt-and-suspenders
    /// invariant: if a path's content were ever wrong, the id would reflect
    /// that content honestly instead of silently mismatching it.
    ///
    /// Both the id (one file read) and the PNG conversion (the expensive
    /// part) are resolved once per path and reused on every later call for
    /// the same path — this does NOT re-read the file every frame.
    private func kittyIdentity(forPath path: String) -> (id: UInt32, transmit: String?)? {
        if let id = idCache[path], let cached = transmitCache[id] {
            return (id, cached)
        }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let id = kittyImageID(forBytes: data)
        idCache[path] = id
        guard let png = imageDataToPNG(data) else {
            transmitCache.updateValue(nil, forKey: id)   // cache the failure (not a dictionary removal)
            return (id, nil)
        }
        let escape = kittyTransmitEscape(id: id, png: png)
        transmitCache[id] = escape
        return (id, escape)
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
        lastBridge = snapshot.bridge
        pendingFromStopped = snapshot.queueEnded
        if snapshot.queueEnded {
            pendingSeedTitle = snapshot.endedTrack
            pendingSeedArtist = snapshot.endedArtist
            pendingSource = snapshot.endedSource
        } else if case .active(let np) = snapshot.outcome {
            pendingSeedTitle = np.track
            pendingSeedArtist = np.artist
            // Not ended: resolved lazily in `continuationSource()` so `tick` never
            // copies the queue's track array once per frame.
            pendingSource = nil
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

        var changed = false

        // REST artwork fallback: reached only when the poller found NO embedded
        // artwork for this track (extractArtwork returned nothing — true of
        // every track on "People's Instinctive Travels a") and both auth tokens
        // are configured. Kicked off-thread: the lookup is up to three network
        // round-trips (see NowArtwork.swift) and must never touch tick()'s or
        // render()'s latency. The result lands in restInbox under artLock — the
        // same inbox+NSLock handoff as Library/Playlists' artMap — and render()
        // turns a hit into pixels via ArtworkStore, which fetches on its own
        // serial queue and signals back through artDirty.
        if case .active(let np) = snapshot.outcome, let api = restArtworkAPI,
           snapshot.artLines.isEmpty, snapshot.artPath == nil,
           // Bridge's album line is the sent row's; it must not start a REST
           // lookup for a player whose cover has its own rung.
           snapshot.bridge == nil,
           !np.album.isEmpty, !np.artist.isEmpty {
            let albumKey = nowAlbumKey(album: np.album, artist: np.artist)
            let trackTag = trackKey(title: np.track, artist: np.artist)
            if restArt[albumKey] == nil, !restAttempted.contains(trackTag), !restInFlight.contains(trackTag) {
                restInFlight.insert(trackTag)
                Thread.detachNewThread { [weak self] in
                    let hit = lookupAlbumArtwork(api: api, title: np.track, artist: np.artist, album: np.album)
                    guard let self else { return }
                    self.artLock.lock()
                    self.restInbox.append((trackTag, albumKey, hit))
                    self.artLock.unlock()
                }
            }
        }
        // SpanDAC cover by persistent ID: ask Music's library once per song,
        // off this thread. Only when there is no fetchable URL (bridgeCoverSource).
        if let bridge = snapshot.bridge,
           case .library(let pid) = bridgeCoverSource(artworkURL: bridge.artworkURL, persistentID: bridge.persistentID) {
            artLock.lock()
            let fresh = bridgeCoverTried.insert(pid).inserted
            artLock.unlock()
            if fresh {
                bridgeCoverQueue.async { [weak self] in
                    guard let self else { return }
                    let path = self.bridgeCoverExtractor(pid, libraryCoverTempPath(albumID: "spandac-\(pid)"))
                    guard let path else { return }
                    self.artLock.lock()
                    self.bridgeCoverPaths[pid] = path
                    self.artDirty = true
                    self.artLock.unlock()
                }
            }
        }
        artLock.lock()
        let landed = restInbox; restInbox = []
        let artLanded = artDirty; artDirty = false
        artLock.unlock()
        for (trackTag, albumKey, hit) in landed {
            // Recorded on a MISS too, so an unresolvable track isn't re-searched
            // every second for the rest of the session (same negative-cache
            // intent as ArtworkStore's `failed`). A hit caches under the ALBUM,
            // so the rest of that album needs no lookup at all.
            restAttempted.insert(trackTag)
            restInFlight.remove(trackTag)
            if let hit { restArt[albumKey] = hit }
            changed = true
        }
        if artLanded { changed = true }

        // Shuffle/repeat: drain the background inbox, then kick a fresh fetch
        // every ~2s. A fetch that started before the user's last toggle is
        // stale (would revert the optimistic update), so it's dropped.
        modesLock.lock()
        let freshModes = inboxModes; inboxModes = nil
        modesLock.unlock()
        if let freshModes, modesFetchStartedAt > lastModesMutation, freshModes != modes {
            modes = freshModes
            changed = true
        }
        let now = Date()
        // Not in Bridge mode: these are Music.app's modes, and Bridge draws no
        // grid to show them in.
        if snapshot.bridge == nil, !modesFetchInFlight, now.timeIntervalSince(lastModesKick) > 2 {
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
        spanDACGridShown = false
        lastBridge = snapshot.bridge
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
            // A blocked output: nothing is read and nothing plays until the
            // person finishes the switch or stops using SpanDAC (C-REPAIR).
            if case .outputBlocked = routing.selection {
                out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3)
                out += "\(ANSICode.dim)\(truncText(finishSwitchingToSpanDAC, to: max(10, frame.width - 6)))\(ANSICode.reset)"
                return out
            }
            if let bridge = snapshot.bridge {
                return renderBridgeEmpty(bridge, frame: frame, into: out)
            }
            // The empty state is the on-ramp, not a dead end.
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3)
            out += "\(ANSICode.dim)Nothing playing \u{2014} press \(ANSICode.reset)4\(ANSICode.dim) to browse playlists, \(ANSICode.reset)z\(ANSICode.dim) to shuffle.\(ANSICode.reset)"
            return out
        }

        // Two-pane when wide enough: left = now-playing (large art + metadata),
        // right = Up Next list. Narrow falls back to stacked (art+meta, list below).
        let twoPane = frame.width >= 92
        let leftX = 3
        let leftW = twoPane ? nowPlayingLeftWidth(frameWidth: frame.width) : (frame.width - 6)
        let listBottom = frame.bodyY + frame.bodyHeight - 1

        // --- Left pane: large album art ---
        // Art is skipped entirely below ~50 columns: the chafa/mono lines
        // path renders at `gw` columns (see the `gw` comment below — fixed 44
        // one-pane, up to 54 two-pane), and drawing lines that wide on a
        // narrower frame would wrap into the next row and corrupt the whole
        // screen.
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
        // now follows `gw` too, published to the poller below — but bounded
        // to one poll interval (~1s), not instant: PlaybackPoller runs on its
        // own background thread and only reads the published size once per
        // poll, checking the CURRENT track's sized-lines cache on every tick
        // (not just on a track change), so a mid-track resize misses the
        // (now stale) sized cache key and re-renders on its next tick. Kitty
        // has no such lag; it stretches the same transmitted PNG to whatever
        // rect it's given, instantly.
        let gw = twoPane ? leftW : 44
        if showArt {
            let size = clampedArtSize(artRows: artRows, gw: gw)
            setArtSize(size.cols, size.rows)
        }
        // The art source ladder, in priority order. EMBEDDED FIRST: the poller
        // has already extracted it (no network, no token, no wait), and it is
        // the track's own cover rather than a title+artist guess. REST SECOND:
        // when the track carries no embedded artwork at all — "Push It Along"
        // and every other track on People's Instinctive Travels report `count
        // of artworks == 0` — resolve the same library album the Library tab
        // renders and hand it to the same ArtworkStore, keyed on the same
        // library album id, so both tabs read the same cached bytes. GRADIENT
        // LAST (artBlock stays nil): no token, no match, or still in flight.
        //
        // Everything below the source choice is the shared hero ladder
        // (renderArtHero) that Library/Playlists/Radio already use — this tab
        // used to hand-roll its own copy of it. ArtworkStore.block fetches on
        // its own serial queue and signals via onReady; nothing here blocks.
        var artBlock: ArtBlock? = nil
        if showArt, artRows > 0 {
            if kittyEnabled, let path = snapshot.artPath, let (id, escape) = kittyIdentity(forPath: path) {
                artBlock = .kitty(id: id, transmit: escape)
            } else if !artLines.isEmpty {
                artBlock = .lines(artLines)
            } else if let block = bridgeCoverBlock(snapshot.bridge, gw: gw, artRows: artRows) {
                artBlock = block
            } else if let hit = restArt[nowAlbumKey(album: np.album, artist: np.artist)] {
                artBlock = artwork.block(key: hit.id,
                                         url: ArtworkStore.resolveURL(hit.url, width: 300, height: 300),
                                         width: gw, height: artRows,
                                         kitty: kittyEnabled && gw > 0) { [weak self] in
                    guard let self else { return }
                    self.artLock.lock(); self.artDirty = true; self.artLock.unlock()
                }
            }
        }
        let (afterArtY, placed) = renderArtHero(artBlock: artBlock,
                                                gradientSeedText: np.track + np.artist,
                                                gw: gw, gh: artRows, x: leftX, y: frame.bodyY,
                                                cellW: frame.cellW, cellH: frame.cellH,
                                                lastPlaced: lastPlaced, into: &out)
        lastPlaced = placed

        // --- Left pane: metadata below the art ---
        // renderArtHero advances by the square-equivalent height it actually
        // drew (pr), not the full reserved `artRows` box — advancing by
        // artRows left a 9-row dead gap before the track title once artRows
        // grew past pr.
        var my = afterArtY + 1
        let metaW = leftW
        let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
        out += ANSICode.moveTo(row: my, col: leftX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + truncText(np.artist, to: metaW)
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"
        my += 2
        // No duration means no progress is KNOWN, which is not the same as a
        // zero-length track at position zero. A SpanDAC that sends no duration
        // leaves it at zero, and the old bar rendered "0:00 ●──── 0:00" over a
        // playing song and never moved — a reading invented by the renderer
        // rather than reported by anything.
        // Radio already refuses to draw one for live stations, for this reason.
        if np.duration > 0 {
            let elapsed = formatTime(np.position)
            let total = formatTime(np.duration)
            let ratio = Double(np.position) / Double(np.duration)
            let pbW = min(28, max(8, metaW - 14))
            let knob = max(0, min(pbW - 1, Int(ratio * Double(pbW - 1))))
            var bar = ""
            for i in 0..<pbW { bar += i == knob ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)" }
            out += ANSICode.moveTo(row: my, col: leftX) + "\(elapsed) \(bar) \(total)"
        }
        my += 2
        if geniusActive {
            out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.cyan)\u{2726} \(ANSICode.reset)\(ANSICode.bold)\(ANSICode.brightWhite)Genius Shuffle Active\(ANSICode.reset)"
        } else if !snapshot.contextName.isEmpty {
            out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.cyan)\u{266A} \(ANSICode.reset)\(ANSICode.brightWhite)\(truncText(cleanContextName(snapshot.contextName), to: metaW - 3))\(ANSICode.reset)"
        }

        let gridStartY: Int
        if let bridge = snapshot.bridge {
            let hasContextLine = geniusActive || !snapshot.contextName.isEmpty
            let drawn = renderBridgeActive(bridge, startY: hasContextLine ? my + 1 : my, x: leftX, width: metaW,
                                           bottom: frame.bodyY + frame.bodyHeight - 1, into: out)
            out = drawn.out
            gridStartY = drawn.gridStartY
            // SpanDAC's Up Next is drawn by the same code below, from the rows
            // the poller built out of its `row` / `next_rows`. With none (an
            // older SpanDAC, or a play this process did not send) there is
            // nothing honest to list, so no header either.
            if rows.isEmpty { return out }
        } else {
            // Playback-control grid (shuffle/order/repeat/genius). Always shows live
            // active state; `c` focuses it for arrow-navigation + Enter.
            gridStartY = my + 2
            out += renderControlGrid(startY: gridStartY, x: leftX, bottom: frame.bodyY + frame.bodyHeight - 1)
        }

        // --- Up Next: right pane (wide) or below the metadata (narrow) ---
        // Stacked mode used to start the list at the same row as the control
        // grid (`my + 2`) — the grid and the "Up Next" header overprinted each
        // other. stackedListStartY mirrors the grid's own row-count/clamp math
        // so the list always starts below wherever the grid actually stopped.
        let listX = twoPane ? (leftX + leftW + 2) : leftX
        let listY = twoPane ? frame.bodyY : NowPlayingScene.stackedListStartY(gridStartY: gridStartY, gridBottom: listBottom)
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

    /// SpanDAC's cover through the same ArtworkStore and hero ladder as the REST
    /// fallback. A fetchable http(s) URL goes in as it is; failing that, the
    /// cover extracted from the library by persistent ID goes in as a file URL
    /// once tick()'s extraction has landed (nil, so the gradient, until then).
    private func bridgeCoverBlock(_ bridge: BridgeNow?, gw: Int, artRows: Int) -> ArtBlock? {
        guard let bridge else { return nil }
        let onReady: () -> Void = { [weak self] in
            guard let self else { return }
            self.artLock.lock(); self.artDirty = true; self.artLock.unlock()
        }
        switch bridgeCoverSource(artworkURL: bridge.artworkURL, persistentID: bridge.persistentID) {
        case .remote(let url):
            // Keyed on a hash of the URL so the on-disk cache name stays short and stable.
            return artwork.block(key: "spandac-\(String(format: "%08x", kittyImageID(forKey: url)))",
                                 url: ArtworkStore.resolveURL(url, width: 600, height: 600),
                                 width: gw, height: artRows,
                                 kitty: kittyEnabled && gw > 0, onReady: onReady)
        case .library(let pid):
            artLock.lock(); let path = bridgeCoverPaths[pid]; artLock.unlock()
            guard let path else { return nil }
            return artwork.block(key: "spandac-lib-\(pid)",
                                 url: URL(fileURLWithPath: path).absoluteString,
                                 width: gw, height: artRows,
                                 kitty: kittyEnabled && gw > 0, onReady: onReady)
        case .none:
            return nil
        }
    }

    /// Bridge's empty state: what Bridge is doing, then the way in.
    ///
    /// The digits are the tab strip's real ones (`tabs` in Shell.swift: 3 is
    /// Library, 4 is Playlists). `z` is not offered: collection shuffle is
    /// refused on Bridge.
    private func renderBridgeEmpty(_ bridge: BridgeNow, frame: ShellFrame, into base: String) -> String {
        var out = base
        out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3)
        out += truncText(bridgeStatusLine(bridge) ?? "Nothing playing on SpanDAC.", to: frame.width - 6)
        out += ANSICode.moveTo(row: frame.bodyY + 2, col: 3)
        out += "\(ANSICode.dim)Press \(ANSICode.reset)4\(ANSICode.dim) to browse playlists, \(ANSICode.reset)3\(ANSICode.dim) for Library.\(ANSICode.reset)"
        return out
    }

    /// Bridge's lines below the track metadata, in place of Music.app's
    /// control grid. Returns the row the grid (or its sentence) starts on, so
    /// the shared Up Next below can stack under it in a narrow frame.
    ///
    /// The status and position lines, then the same Shuffle / Order / Repeat /
    /// Genius grid Music.app shows, driven by SpanDAC's own shuffle and repeat
    /// when the app lists the ops; an older build gets the sentence it always
    /// did. Up Next is not drawn here: it is the shared list in `render`.
    private func renderBridgeActive(_ bridge: BridgeNow, startY: Int, x: Int, width: Int,
                                    bottom: Int, into base: String) -> (out: String, gridStartY: Int) {
        var out = base
        var y = startY
        for line in [bridgeStatusLine(bridge), bridgePositionLine(bridge)].compactMap({ $0 }) {
            guard y <= bottom else { return (out, y + 1) }
            out += ANSICode.moveTo(row: y, col: x) + "\(ANSICode.dim)\(truncText(line, to: width))\(ANSICode.reset)"
            y += 1
        }
        y += 1
        if bridge.offersShuffle || bridge.offersRepeat {
            if y <= bottom { spanDACGridShown = true }
            out += renderControlGrid(startY: y, x: x, bottom: bottom, bridge: bridge)
        } else if y <= bottom {
            out += ANSICode.moveTo(row: y, col: x)
                + "\(ANSICode.dim)\(truncText(spanDACNoModesSentence, to: width))\(ANSICode.reset)"
        }
        return (out, y)
    }

    /// Stacked-mode Up Next start row: one blank spacer row below wherever the
    /// control grid actually stopped drawing. Mirrors renderControlGrid's own
    /// clamp (`ControlGrid.rowCount` rows from `gridStartY`, cut off at
    /// `gridBottom`) instead of assuming the grid always reaches its full row
    /// count, so the two never land on the same row. When there's no room left
    /// after the grid, this returns a row past `gridBottom` — the caller's
    /// existing `listY + 1 <= listBottom` guard then skips the list (grid
    /// wins). Pure; two-pane mode doesn't call this — its list start is simply
    /// `frame.bodyY`, sharing no row with the grid.
    static func stackedListStartY(gridStartY: Int, gridBottom: Int) -> Int {
        min(gridStartY + ControlGrid.rowCount, gridBottom + 1) + 1
    }

    /// The playback-control grid: a label column then option cells per row.
    /// Active value is bright; the focused row (when the grid has focus) is
    /// marked with ▸ and Enter cycles its value.
    ///
    /// With a `bridge`, SpanDAC's state fills the cells and the rows it has no
    /// control for (Order, Genius, or an op the app does not list) are dimmed
    /// whole: no active cell, never the focus marker.
    private func renderControlGrid(startY: Int, x: Int, bottom: Int, bridge: BridgeNow? = nil) -> String {
        var out = ""
        let live = bridge.map { effectiveBridgeModes($0) }
        var y = startY
        let labelW = 8
        for row in 0..<ControlGrid.rowCount {
            guard y <= bottom else { break }
            let enabled = bridge.map {
                ControlGrid.spanDACEnabled(row: row, offersShuffle: $0.offersShuffle, offersRepeat: $0.offersRepeat)
            } ?? true
            let rowFocused = gridFocused && row == gridRow && enabled
            out += ANSICode.moveTo(row: y, col: x)
            let marker = rowFocused ? "\(ANSICode.cyan)\u{25B8}\(ANSICode.reset)" : " "
            let label = ControlGrid.labels[row]
            let padLabel = label + String(repeating: " ", count: max(0, labelW - label.count))
            let labelStyled = rowFocused ? "\(ANSICode.brightWhite)\(padLabel)\(ANSICode.reset)"
                                         : "\(ANSICode.dim)\(padLabel)\(ANSICode.reset)"
            out += "\(marker) \(labelStyled) "
            let active: Int?
            if let live {
                active = enabled ? ControlGrid.spanDACActiveColumn(row: row, shuffle: live.shuffle, repeatMode: live.repeatMode) : nil
            } else {
                active = modes.flatMap { ControlGrid.activeColumn(row: row, modes: $0) }
            }
            var line = ""
            for col in 0..<ControlGrid.cellCount(row: row) {
                let cell = ControlGrid.cells[row][col]
                if !enabled {
                    // Dim and struck through (a terminal without strikethrough
                    // still shows it dim, with no active cell).
                    line += "\(ANSICode.dim)\u{1B}[9m \(cell) \(ANSICode.reset) "
                } else if col == active {
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
        // The label is the queue's human-facing name ("Moon Safari"), never its
        // addressable source ("Library") — that distinction is the whole point
        // of ContinuationSource.
        let opts: [(String, String)] = continuationOptions(bridge: routing.effectiveOutput.usesSource).map { action in
            switch action {
            case .shuffle:
                let shuffleTarget = continuationSourceNow()?.label ?? seedTitle
                return ("[S]", "Shuffle  \(ANSICode.dim)\(truncText(shuffleTarget, to: 28))\(ANSICode.reset)")
            case .playlist:
                return ("[P]", "Playlist  \(ANSICode.dim)browse\(ANSICode.reset)")
            case .quiet:
                return ("[X]", "Quiet  \(ANSICode.dim)stop here\(ANSICode.reset)")
            }
        }
        for (key, label) in opts {
            out += ANSICode.moveTo(row: ly, col: lx) + "\(ANSICode.lime)\(key)\(ANSICode.reset)  \(label)"
            ly += 1
        }
        return out
    }

    /// What the continuation menu is offering right now.
    ///
    /// At queue-end the poller has already classified it (the app queue is
    /// cleared immediately after, so it cannot be recovered later). Otherwise
    /// resolve from the live queue, falling back to the raw context name.
    private func continuationSourceNow() -> ContinuationSource? {
        if let ended = pendingSource { return ended }
        if let q = appQueue.read() { return continuationSource(for: q) }
        let ctx = contextNameNow
        return ctx.isEmpty ? nil : .playlist(ctx)
    }

    private func act(on action: ContinuationAction) {
        switch action {
        case .shuffle:
            // A bounded album/artist queue shuffles the tracks it already holds:
            // its source is the library, and `play playlist "Library"` is 14k
            // tracks, not the album that just ended. A real playlist still
            // shuffles by name through the existing bulk-fetch path, which must
            // stay off the input loop.
            let source = continuationSourceNow()
            let backend = self.backend
            let appQueue = self.appQueue
            let routing = self.routing
            actions.run("Shuffle") {
                // Through the coordinator like the global `z`: the one
                // play-out gate refuses it while a SpanDAC queue plays out
                // (Anthony, 2026-10-05 16:07), and a SpanDAC output takes the
                // refusing `source` branch below.
                //
                // On a SpanDAC output it STAYS REFUSED after step 2, for a
                // different reason than before: not "unbuilt", but unanswerable.
                //
                // This shuffles the CURRENT collection, and in Bridge mode
                // nothing on this side knows what that is. `continuationSourceNow()`
                // reads `appQueue`, which no Bridge branch ever writes, and
                // `contextNameNow`, which comes from the Music.app poller — so
                // both name whatever Music.app was last left on. `slice.status`
                // returns queue COUNTS (phase/requested/present) and the playing
                // title, never the track list, so the set cannot be recovered
                // from Bridge either.
                //
                // Shuffling the stale Music.app queue onto Bridge would play a
                // different set than the one on screen, silently and plausibly:
                // the exact defect class the fail-closed sweep removed. Giving
                // Bridge a remembered collection is new state and its own
                // decision, so it is not taken here.
                try routing.perform(.collectionShuffle,
                    musicApp: {
                        let ok: Bool
                        switch source {
                        case .bounded(let label, let src, let tracks):
                            ok = shufflePlayBounded(backend: backend, appQueue: appQueue,
                                                    label: label, source: src, tracks: tracks)
                        case .playlist(let name):
                            ok = shufflePlayPlaylist(backend: backend, appQueue: appQueue, playlist: name)
                        case nil:
                            ok = shufflePlayCurrent(backend: backend, appQueue: appQueue)
                        }
                        try require(ok, "Shuffle failed.")
                    },
                    source: { _ in throw bridgeNotWiredYet("Collection shuffle") },
                    unaffected: {})
            }
        case .playlist:
            wantsPlaylists = true
        case .quiet:
            appQueue.clear()
            actions.run("Pause") { [routing] in
                try routing.perform(.quiet,
                    musicApp: { _ = try syncRun { try await self.backend.runMusic("pause") } },
                    // Ruling 12.7: Quiet pauses the SELECTED output, not
                    // Music.app. Taken literally the old line paused Music.app
                    // from Bridge, against rule 3.
                    // An idle Bridge refuses `slice.pause` ("did not reach
                    // paused within 3s"), and Quiet on a quiet player is not a
                    // failure — it showed "Pause failed." until 2026-09-22.
                    // Same positive-evidence check as leaving Bridge for
                    // Music.app: the pause is attempted, then its own status
                    // decides, and only a player still going is an error.
                    source: { try require(try confirmBridgeNotPlaying($0.control),
                                          "Couldn't pause SpanDAC.") },
                    unaffected: {})
            }
        }
    }

    /// Ask the routing matrix whether this key may act, and post the refusal if
    /// not. Returns false when the caller must not proceed.
    ///
    /// The matrix has always decided these rows; the KEYS never asked it. In
    /// Bridge mode `s`, `m`, `r`, `g` and the control grid drove Music.app —
    /// and `l` wrote `favorited of current track`, which is Anthony's ruling of
    /// 2026-09-16 exactly: while Bridge plays, Music.app's current track is
    /// whatever it was left on, so the favourite lands on the wrong song.
    /// Silent and plausible, which is the worst shape for this defect.
    ///
    /// Asked on both axes: the SOUND route decides, so a blocked output
    /// (C-REPAIR) refuses in its own sentence, and SpanDAC data with the
    /// MusicTUI output keeps these keys as shipped.
    private func askMatrix(_ action: MusicTUIAction) -> Bool {
        if case .refused(let why) = routeAction(action, selection: routing.selection, from: .tui).sound {
            // A refused jump or Genius play means nothing started: it stays.
            // A refused mode toggle or favorite is a transient status.
            status.post(why, error: true, untilStateChange: action == .queueJump || action == .genius)
            return false
        }
        return true
    }

    /// Seek on whichever player is selected. `slice.seek` refuses a forward seek
    /// past the end, or when the track's length is unknown, with its own reason
    /// — the TUI shows that rather than a generic failure.
    private func seek(by offset: Double) {
        actions.run("Seek") { [routing, backend] in
            try routing.perform(.seek,
                musicApp: {
                    _ = try syncRun {
                        try await backend.runMusic("set player position to (player position \(offset < 0 ? "-" : "+") \(abs(offset)))")
                    }
                },
                source: { try $0.control.seek(byOffset: offset) },
                unaffected: {})
        }
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Vim aliases first: j/k/h/ctrl-d/ctrl-u everywhere, but NOT l/g/G — this
        // tab binds those to Favorite and Genius Shuffle below.
        let key = vimAlias(key, listScene: false)
        // Continuation menu intercepts its keys when active.
        if menuShownLastFrame {
            if let action = continuationAction(for: key),
               continuationOptions(bridge: routing.effectiveOutput.usesSource).contains(action) {
                act(on: action)
                manualMenu = false
                dismissedSeed = pendingSeedTitle   // don't re-show this queue-end's menu
                if wantsPlaylists { wantsPlaylists = false; return .push(.playlists) }
                return .redraw
            }
            // A menu key this output does not offer (Bridge's `s`) is swallowed,
            // not passed on to the tab's own `s`, which would answer a menu the
            // person never saw with a refusal.
            if continuationAction(for: key) != nil { return .none }
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
        // Spec 6.2's own row: `x` is Quiet on Now, not only inside the menu.
        // It was reachable only from the "What next?" card until 2026-09-22,
        // so the documented key did nothing on the screen that documents it.
        // Quiet is "stop here": it drops the queue and pauses the SELECTED
        // output (ruling 12.7), which is why it is not a second `space`.
        if case .char("x") = key { act(on: .quiet); return .redraw }
        if case .char("X") = key { act(on: .quiet); return .redraw }

        // Manual open: 'n' (next-options) when no menu is up.
        if case .char("n") = key, !menuShownLastFrame {
            manualMenu = true; return .redraw
        }

        // Bridge draws no grid, so nothing may focus it: the grid keys become
        // no-ops, and a focus left over from Music.app mode is dropped.
        if routing.effectiveOutput.usesSource {
            if !spanDACGridShown { gridFocused = false }
            switch key {
            case .char("s"), .char("S"): guard askMatrix(.persistentShuffleMode) else { return .redraw }
                                         spanDACToggleShuffle(); return .redraw
            case .char("r"), .char("R"): guard askMatrix(.persistentRepeatMode) else { return .redraw }
                                         spanDACCycleRepeat(); return .redraw
            case .char("m"), .char("M"): status.post(spanDACRowUnavailable(ControlRow.order.rawValue), error: true)
                                         return .redraw
            default: break
            }
            if !spanDACGridShown {
                // Nothing to focus.
                if case .left = key { return .none }
            } else if let b = lastBridge {
                let enabled = { (r: Int) in ControlGrid.spanDACEnabled(row: r, offersShuffle: b.offersShuffle, offersRepeat: b.offersRepeat) }
                func step(_ d: Int) -> Int {
                    ControlGrid.spanDACStep(from: gridRow, by: d, offersShuffle: b.offersShuffle, offersRepeat: b.offersRepeat)
                }
                switch key {
                case .left:
                    // Focus lands on a live row, never a disabled one.
                    if !enabled(gridRow) { gridRow = step(1) }
                    if !enabled(gridRow) { gridRow = step(-1) }
                case .up where gridFocused:    gridRow = step(-1); return .redraw
                case .down where gridFocused:  gridRow = step(1); return .redraw
                case .home where gridFocused:  gridRow = enabled(0) ? 0 : step(1); return .redraw
                case .end where gridFocused:
                    gridRow = enabled(ControlGrid.rowCount - 1) ? ControlGrid.rowCount - 1 : step(-1); return .redraw
                case .enter where gridFocused:
                    guard askMatrix(.persistentShuffleMode) else { return .redraw }
                    switch ControlRow(rawValue: gridRow) {
                    case .shuffle:    spanDACToggleShuffle()
                    case .repeatMode: spanDACCycleRepeat()
                    default:          status.post(spanDACRowUnavailable(gridRow), error: true)
                    }
                    return .redraw
                default: break
                }
            }
        }

        // Focus model: ← focuses the control grid (left pane), → the Up Next
        // list (right). ↑↓/Enter then act on whichever has focus. Seek lives on
        // [ ] so the arrows are free for navigation.
        switch key {
        case .left:  gridFocused = true; return .redraw
        case .right: gridFocused = false; return .redraw
        case .char("["):
            seek(by: -30)
            return .redraw
        case .char("]"):
            seek(by: 30)
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
            case .enter:
                // The grid sets the same persistent modes as s/m/r, plus Genius.
                guard askMatrix(.persistentShuffleMode) else { return .redraw }
                applyControlRow(); return .redraw
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
            guard askMatrix(.queueJump) else { return .redraw }
            // The play itself goes through the coordinator, which decides when
            // the action RUNS: the one play-out gate refuses it while a
            // SpanDAC queue plays out (Anthony, 2026-10-05 16:07; Codex review
            // 104), before the app queue moves or any AppleScript runs.
            let backend = self.backend
            let row = rows[cursor]
            let context = contextNameNow
            let store = self.appQueue
            let routing = self.routing
            actions.run("Play") {
                try routing.perform(.queueJump,
                    musicApp: {
                        // Jump within the app-owned queue by the row's play-order position.
                        if let (pl, pos) = store.jump(to: row.index) {
                            try require(playQueueTrack(backend: backend, playlist: pl, position: pos), "Couldn't play that track.")
                            return
                        }
                        // No app queue: a whole-playlist play (native queue) lands here. Playing
                        // the row from the Library would collapse Music's context to the
                        // alphabetical library (and `play track N of current playlist` is the
                        // macOS 26.x-regressed verb) — so ADOPT the app-owned queue: fetch the
                        // context playlist and take over from this row, same as the Playlists
                        // tab does. Album/library contexts (the context name isn't a playlist,
                        // or the row doesn't line up) fall back to the library lookup.
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
                    },
                    // The matrix refuses a queue-row jump on every SpanDAC
                    // output, so this is never reached; it fails closed.
                    source: { _ in throw bridgeNotWiredYet("Jumping to a queue row") },
                    unaffected: {})
            }
            return .redraw
        case .char("l"):
            guard askMatrix(.loveTrack) else { return .redraw }
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
            guard askMatrix(.persistentShuffleMode) else { return .redraw }
            toggleShuffle(); return .redraw
        case .char("m"), .char("M"):
            guard askMatrix(.persistentShuffleMode) else { return .redraw }
            cycleShuffleMode(); return .redraw
        case .char("r"), .char("R"):
            guard askMatrix(.persistentRepeatMode) else { return .redraw }
            cycleRepeat(); return .redraw
        case .char("g"), .char("G"):
            guard askMatrix(.genius) else { return .redraw }
            triggerGenius(); return .redraw
        default:
            return .none
        }
    }

    // MARK: SpanDAC's shuffle and repeat (the grid's two live rows, and `s` / `r`).

    /// SpanDAC's shuffle and repeat as the grid shows them: its own state from
    /// the last status, unless a press of ours is newer than the poll could know.
    private func effectiveBridgeModes(_ b: BridgeNow, now: Date = Date()) -> (shuffle: Bool?, repeatMode: String?) {
        bridgeModesLock.lock(); defer { bridgeModesLock.unlock() }
        if let o = bridgeModesOverride, now.timeIntervalSince(o.at) < Self.bridgeModesOverrideSeconds {
            return (o.shuffle ?? b.shuffle, o.repeatMode ?? b.repeatMode)
        }
        return (b.shuffle, b.repeatMode)
    }

    private func setBridgeModesOverride(shuffle: Bool? = nil, repeatMode: String? = nil) {
        // Merged, so a press of one row keeps the other row's pending press.
        bridgeModesLock.lock()
        let now = Date()
        let live = bridgeModesOverride.flatMap { now.timeIntervalSince($0.at) < Self.bridgeModesOverrideSeconds ? $0 : nil }
        bridgeModesOverride = (shuffle ?? live?.shuffle, repeatMode ?? live?.repeatMode, now)
        bridgeModesLock.unlock()
    }

    private func clearBridgeModesOverride() {
        bridgeModesLock.lock(); bridgeModesOverride = nil; bridgeModesLock.unlock()
    }

    /// Why a row cannot be set: Order and Genius have no SpanDAC equivalent.
    private func spanDACRowUnavailable(_ row: Int) -> String {
        "\(ControlGrid.labels[row]) isn't available on SpanDAC."
    }

    /// Shuffle on SpanDAC. An older build that does not list `slice.shuffle`
    /// gets the sentence the Now tab always showed and nothing is sent.
    private func spanDACToggleShuffle() {
        guard let b = lastBridge, b.offersShuffle else {
            status.post(spanDACNoModesSentence, error: true); return
        }
        let on = !(effectiveBridgeModes(b).shuffle ?? false)
        setBridgeModesOverride(shuffle: on)
        actions.run("Shuffle") { [routing] in
            do {
                try routing.perform(.persistentShuffleMode, musicApp: {},
                                    source: { try $0.control.setShuffle(on) }, unaffected: {})
            } catch { self.clearBridgeModesOverride(); throw error }
        }
    }

    /// Repeat on SpanDAC: off, all, one, as the Music.app grid cycles.
    private func spanDACCycleRepeat() {
        guard let b = lastBridge, b.offersRepeat else {
            status.post(spanDACNoModesSentence, error: true); return
        }
        let current = effectiveBridgeModes(b).repeatMode.flatMap(RepeatMode.init(rawValue:)) ?? .off
        let next = current.next
        setBridgeModesOverride(repeatMode: next.rawValue)
        actions.run("Repeat") { [routing] in
            do {
                try routing.perform(.persistentRepeatMode, musicApp: {},
                                    source: { try $0.control.setRepeat(next) }, unaffected: {})
            } catch { self.clearBridgeModesOverride(); throw error }
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
    ///
    /// Through the coordinator, so the one play-out gate refuses it while a
    /// SpanDAC queue plays out (Anthony, 2026-10-05 16:07; Codex review 104):
    /// Genius Shuffle starts Apple's Music player.
    private func triggerGenius() {
        geniusActive = true; geniusTriggeredAt = Date()
        let backend = self.backend
        let routing = self.routing
        actions.run("Genius") {
            try routing.perform(.genius,
                musicApp: { try require((try? triggerGeniusShuffle(backend)) != nil, "Genius Shuffle failed.") },
                // The matrix refuses Genius on every SpanDAC output, so this
                // is never reached; it fails closed.
                source: { _ in throw bridgeNotWiredYet("Genius") },
                unaffected: {})
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

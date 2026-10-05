// tools/music/Sources/TUI/Shell/Shell.swift
import Foundation

/// The REST backend the art surfaces use for real cover artwork, or nil when
/// the user isn't signed in / no developer token is configured. Artwork is
/// decoration: every caller treats nil as "keep the gradient placeholder", so
/// a token-less user sees no error and no dead surface — never a thrown or
/// toasted failure. Local work only (config read + JWT sign, no network), so
/// it's safe on the startup path. Shared by the Now tab's embedded-artwork
/// fallback and the Playlists hero covers, which had separate copies of this
/// exact gate.
func makeArtworkAPI() -> RESTAPIBackend? {
    let auth = AuthManager()
    guard let devToken = try? auth.requireDeveloperToken(), let userToken = auth.userToken() else { return nil }
    return RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
}

/// The always-on playback keys in the footer, for the selected output.
///
/// **Bridge drops `z` and `+/−`.** Both are refused there (spec 6.1: collection
/// shuffle has no set to shuffle, and MusicKit exposes no player volume), so
/// listing them would advertise keys that only ever answer with a refusal.
func shellFooterGlobals(mode: PlaybackMode) -> String {
    mode.usesSource
        ? "Space \u{23EF}  < > Skip"
        : "Space \u{23EF}  < > Skip  z Reshuffle  +/\u{2212} Vol"
}

/// MusicTUI's own Next (`step` 1) or Previous (`-1`): the app-owned queue
/// when one is active (the poller can't rely on Music's queue post-26.x),
/// otherwise the player's own next/previous track. `step()` commits the index
/// before the play attempt, so a failed play rolls the step back; otherwise the
/// Up Next highlight desyncs from the audio and every later next/prev walks
/// from the wrong baseline. (`playQueueTrack` is false only on an osascript
/// ERROR, i.e. transient; rolling back keeps the position honest and the next
/// press retries.)
func musicTUISkip(_ step: Int, backend: AppleScriptBackend, appQueue: AppQueueStore) throws {
    if let (pl, pos) = appQueue.step(step) {
        guard playQueueTrack(backend: backend, playlist: pl, position: pos) else {
            _ = appQueue.step(-step)
            throw ActionError(message: "Couldn't play that track.")
        }
        return
    }
    let verb = step > 0 ? "next track" : "previous track"
    _ = try syncRun { try await backend.runMusic(verb) }
}

/// The global Next (`step` 1) and Previous (`-1`) keys (Codex review 101,
/// blocking 1). Both branches are always handed to the coordinator, which
/// picks one when the action RUNS, from where the sound is then
/// (`effectiveOutput`'s state), never from the stored mode at the keypress.
/// Until this, a stored SpanDAC output took a SpanDAC-only path whose MusicTUI
/// body was empty, so after a replacement (ruling A8), or with SpanDAC on this
/// Mac not serving, Next and Previous did nothing. The coordinator also hands
/// MusicTUI off first when serving has returned (amended A8).
func globalSkip(_ step: Int, routing: RoutingCoordinator,
                musicTUI: @escaping () throws -> Void,
                run: (_ label: String, _ body: @escaping () throws -> Void) -> Void) {
    let action: MusicTUIAction = step > 0 ? .next : .previous
    run(step > 0 ? "Skip" : "Back") {
        try routing.perform(action, musicApp: musicTUI,
                            source: { step > 0 ? try $0.control.next() : try $0.control.previous() },
                            unaffected: {})
    }
}

/// The footer's playback keys for where the sound is now, not the stored
/// choice (Codex review 101, blocking 1).
func shellFooterGlobals(for routing: RoutingCoordinator) -> String {
    shellFooterGlobals(mode: routing.effectiveOutput)
}

/// Which library the Library and Playlists tabs read, from the DATA
/// selection, never the output (score: data route and output, step 4).
///
/// With SpanDAC accepted as the data source, it is SpanDAC on this Mac's
/// MusicKit library, whatever the output is: a SpanDAC on an iPhone or iPad
/// is an output only, so its library is never read. Nil is MusicTUI's own
/// data, the AppleScript path as shipped, and that includes a blocked stored
/// output (C-REPAIR): `routing.data` reads `.open` there, so no SpanDAC
/// client is constructed at all. Asked fresh at each load and each play, so
/// a switch of data source is honoured mid-session. Module-internal so a
/// test can prove the composition itself.
func spanDACDataProvider(routing: RoutingCoordinator) -> MusicDataProvider? {
    routing.data == .spandacMac ? BridgeMusicProvider(control: routing.dataClient().control) : nil
}

/// The first notice when SpanDAC stops serving and the person had accepted it
/// as their music source: the one line the Output tab's Mac row opens with
/// (`spanDACNotLicensedLine`), without SpanDAC's own sentence, then where to
/// read it.
let licenceFallbackNotice = spanDACNotLicensedLine("") + " The Output tab says why."

/// What to tell the person when SpanDAC's serving changes from `previous` to
/// `current`, or nil. Pure.
///
/// Once per flip into not serving: from serving or from unknown (a fresh
/// process meeting a lapsed licence) to false, and again only after serving
/// has been seen in between. Nothing for a repeat of false, for any change
/// to serving or unknown, or when `dataAccepted` is false: with MusicTUI's own
/// data nothing fell back, and the Output tab already says what SpanDAC said.
func licenceNotice(previous: Bool?, current: Bool?, dataAccepted: Bool) -> String? {
    guard current == false, previous != false, dataAccepted else { return nil }
    return licenceFallbackNotice
}

/// How often, at most, the shell loop re-reads SpanDAC's `slice.status` while
/// its licence is known not to be serving. Low on purpose: it is a recovery
/// poll for a person who has just entered a key in SpanDAC, not a heartbeat.
let licenceReprobeIntervalSeconds: TimeInterval = 30

/// Whether the shell loop should start a licence reprobe now. Only while the
/// cache says serving is FALSE (true and unknown, which is today's behaviour,
/// never probe), never with one already in flight, and not before `interval`
/// has passed since the last start. A clock that stepped backwards waits.
func licenceReprobeDue(serving: Bool?, lastProbe: Date?, now: Date,
                       interval: TimeInterval, inFlight: Bool) -> Bool {
    guard serving == false, !inFlight else { return false }
    guard let lastProbe else { return true }
    return now.timeIntervalSince(lastProbe) >= interval
}

/// Notices SpanDAC regaining its licence when nothing else is asking it: once
/// serving is false the Now poller reads Music.app and only the visible Output
/// tab probes, so without this a stored SpanDAC choice would not resume until
/// that tab was opened.
///
/// `tick()` is called from the shell loop and returns at once. When due it
/// hands ONE bounded `slice.status` read to `async` (a global queue in the
/// shell), through the coordinator's own `.source` client, which is wrapped to
/// feed its licence cache, so the cache flips from the reply by the same path
/// every other reply takes. It never starts SpanDAC: the read goes through
/// `primeLicence`, which sends nothing without the Mac's socket file or when
/// SpanDAC is not involved in the stored selection. The read is bounded by the
/// transport's own timeout, and a failed read changes nothing.
final class LicenceReprobe {
    private let routing: RoutingCoordinator
    private let interval: TimeInterval
    private let now: () -> Date
    private let socketExists: () -> Bool
    private let async: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var lastProbe: Date?
    private var inFlight = false

    init(routing: RoutingCoordinator,
         interval: TimeInterval = licenceReprobeIntervalSeconds,
         now: @escaping () -> Date = Date.init,
         socketExists: @escaping () -> Bool = {
             FileManager.default.fileExists(atPath: SourceAppStationSearch.socketPath)
         },
         async: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.global().async(execute: work) }) {
        self.routing = routing
        self.interval = interval
        self.now = now
        self.socketExists = socketExists
        self.async = async
    }

    func tick() {
        guard let licence = routing.licence else { return }
        let at = now()
        lock.lock()
        let go = licenceReprobeDue(serving: licence.snapshot().serving, lastProbe: lastProbe, now: at,
                                   interval: interval, inFlight: inFlight)
        if go { inFlight = true; lastProbe = at }
        lock.unlock()
        guard go else { return }
        async { [self] in
            _ = routing.primeLicence(socketExists: socketExists,
                                     readStatus: { _ = try routing.client(for: .source).control.status() })
            lock.lock(); inFlight = false; lock.unlock()
        }
    }
}

/// Opens the Playlists tab (C2, D7 item 5): which library it opens FROM
/// follows the data selection, decided here rather than inside
/// `PlaylistsScene` so the Bridge branch is provable with no AppleScript
/// reached — module-internal (not `private`) so a test can call it directly.
///
/// **Bridge mode never calls `loadMusicAppPlaylists`.** The scene is built
/// with empty names and no subscription set; it walks `slice.libraryPlaylists`
/// itself on its first `tick()` (D1).
///
/// **Music.app mode is today's behaviour, unchanged.** The names are fetched
/// synchronously, right here, exactly as `ensureScene`'s `.playlists` case did
/// before C2; an empty result refuses the tab with "No playlists found."
/// rather than building a scene with nothing to show.
func openPlaylistsScene(bridgeSelected: Bool, status: StatusStore,
                        loadMusicAppPlaylists: () -> (names: [String], subscription: Set<String>),
                        build: (_ names: [String], _ subscription: Set<String>) -> PlaylistsScene)
                        -> PlaylistsScene? {
    if bridgeSelected {
        return build([], [])
    }
    let fetched = loadMusicAppPlaylists()
    guard !fetched.names.isEmpty else {
        status.post("No playlists found.", error: true)
        return nil
    }
    return build(fetched.names, fetched.subscription)
}

func runShell() {
    let backend = AppleScriptBackend()
    let store = NowPlayingStore()
    let appQueue = AppQueueStore()
    let queueStore = QueueStore()
    // Source Mode's routing seam, composed once for this process. `.tui` is the
    // surface: ruling 12.14 refuses playback-changing CLI verbs while Bridge is
    // selected, and that distinction is only meaningful if each process says
    // which one it is.
    let routing = RoutingCoordinator.live(surface: .tui)
    // A committed output or data-source switch clears a won't-play message.
    let status = StatusStore(switchStamp: {
        let stamp = routing.stamp
        return StatusSwitchStamp(epoch: stamp.epoch, dataEpoch: stamp.dataEpoch)
    })
    let actions = ActionRunner(status: status)
    let volumeDelta = DeltaAccumulator()

    let poller = PlaybackPoller(store: store, backend: backend, appQueue: appQueue, queueStore: queueStore,
                                routing: routing)
    // One owner for Discover containers: admission after the launch sweep,
    // protection at exit, confirmation of ownership in between
    // (docs/plans/2026-09-03-discover-lifecycle-design.md).
    // Play from here on Apple's own copy of a playlist: the journal lives in
    // ~/.config/music/discover-copies, and a copy he has stopped listening to
    // is ended on the action queue, so it never interleaves with a play.
    // A Discover album plays from here through a temporary playlist of the
    // slice on the same runtime (album-cleanup): the songs it can prove it
    // added leave when he stops, one action-queue item per song.
    let discoverPlay = makeDiscoverPlayRuntime(backend: backend, routing: routing, paths: .live,
                                               status: status, enqueue: { actions.enqueueQuiet($0) })
    let discoverLifecycle = makeDiscoverLifecycleCoordinator(backend: backend, status: status,
                                                             copy: discoverPlay.copy,
                                                             album: discoverPlay.album)
    let terminal = TerminalState.shared
    // Computed once (env-based, no stdin response parsing — design doc sharp
    // edge #5) and threaded into every art-rendering scene.
    let kittyEnabled = kittyGraphicsSupported(env: ProcessInfo.processInfo.environment)

    // `MUSICTUI_SOURCE_APP` IS GONE FROM THE CODE (step 3, 2026-09-18). It was a
    // session-scoped dogfood option routing two things through the source app:
    // Radio's `/` search and a Discover track-level Enter. Both now follow the
    // OUTPUT TAB instead, decided per action by the routing coordinator, so the
    // variable decided nothing and reading it here would have been a comment
    // that lied.
    //
    // The `music-source` shell alias and the dogfood section of the private
    // record are what remain of step 6; the alias is now a no-op.


    // Now's REST artwork fallback, for tracks whose embedded artwork is absent
    // (the Library tab runs the same ladder per focused album). Built
    // once at startup on the same both-tokens gate Playlists' hero covers use;
    // nil (no token) simply leaves Now on embedded-or-gradient — its exact
    // pre-REST behavior, no error, no dead tab.
    let router = Router(root: .nowPlaying)
    var lastActiveScene = router.active
    var scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend, appQueue: appQueue, status: status, actions: actions, routing: routing, restArtworkAPI: makeArtworkAPI(), kittyEnabled: kittyEnabled,
                                                                  setArtSize: { cols, rows in poller.setDesiredArtSize(cols: cols, rows: rows) })]
    // Declaration order IS the tab strip order and the 1-6 digit shortcuts.
    // Ordered by how often the user reaches for them: Now, then the browse
    // surfaces, then Speakers last (set once, rarely touched mid-session).
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now"), (.discover, "Discover"), (.library, "Library"), (.playlists, "Playlists"), (.radio, "Radio"), (.speakers, "Output")]

    // Scene switches must delete every kitty placement (data stays
    // transmitted, d=a) and let each built scene reset its own placement-
    // dedup state, or the outgoing scene's cover keeps floating over the
    // incoming scene's content (design doc sharp edge #4: "images outlive
    // text"). Called after every router mutation below.
    func invalidateArtOnSwitch() {
        guard kittyEnabled else { return }
        print(kittyDeletePlacementsEscape(), terminator: "")
        fflush(stdout)
        for scene in scenes.values { scene.artPlacementsInvalidated() }
    }

    // Lazily build a scene the first time it's shown. Returns nil if it can't be
    // built (e.g. no playlists), so the caller can refuse the switch.
    func ensureScene(_ id: SceneID) -> Scene? {
        if let s = scenes[id] { return s }
        switch id {
        case .playlists:
            // D7/C2: which library the tab opens from follows the DATA
            // selection (`spanDACDataProvider`), decided by
            // `openPlaylistsScene` so the SpanDAC branch is provable with no
            // AppleScript reached — see its own doc comment.
            guard let scene = openPlaylistsScene(
                bridgeSelected: routing.data == .spandacMac, status: status,
                loadMusicAppPlaylists: { fetchUserPlaylistNames(backend: backend) },
                build: { names, subscription in
                    PlaylistsScene(backend: backend, routing: routing,
                                   playlists: names, subscriptionNames: subscription,
                                   sources: names.isEmpty
                                       ? .empty
                                       : makePlaylistDataSources(backend: backend, names: names, artworkAPI: makeArtworkAPI()),
                                   appQueue: appQueue, status: status, actions: actions,
                                   kittyEnabled: kittyEnabled,
                                   makeProvider: { spanDACDataProvider(routing: routing) },
                                   loadMusicAppPlaylists: { fetchUserPlaylistNames(backend: backend) },
                                   makeSources: { makePlaylistDataSources(backend: backend, names: $0, artworkAPI: makeArtworkAPI()) },
                                   // A SpanDAC playlist on the MusicTUI output plays
                                   // its owned songs by exact persistent ID.
                                   handoff: liveMusicTUIHandoff(backend: backend, appQueue: appQueue, routing: routing))
                }
            ) else { return nil }
            scenes[id] = scene
            return scene
        case .speakers:
            // SpanDACs on the network: reached through the coordinator's own
            // factory, so the Output tab and every other surface build the
            // same client for the same SpanDAC.
            let spandac = SpanDACOutputs(makeClient: { routing.client(for: .networkSource($0)) },
                                         post: { text, error, ttl in status.post(text, error: error, ttl: ttl) })
            let scene = SpeakersScene(backend: backend, status: status, actions: actions, routing: routing,
                                      makeNetworkClient: { routing.client(for: .networkSource($0)) },
                                      spandac: spandac)
            scenes[id] = scene
            return scene
        case .library:
            // Keyless: the lists come from one AppleScript bulk read of playlist
            // "Library" (0.85s for 14k tracks, measured 2026-08-28). makeArtworkAPI()
            // is nil without both tokens and only feeds the cover ladder's REST
            // fallback; nil leaves covers on embedded-or-gradient, never a dead tab.
            // The lists follow the DATA selection, not the output: with
            // SpanDAC accepted as the data source they are SpanDAC on this
            // Mac's own MusicKit library, read by its ids ("two modes, two
            // libraries", 2026-09-23), whichever output plays them. The
            // factory is asked fresh at each load and each play, so a
            // mid-session switch is honoured; nil is MusicTUI's own data and
            // the AppleScript path. Plays go to the OUTPUT through
            // `routing.perform`; on the MusicTUI output a SpanDAC row goes to
            // `handoff`.
            let scene = LibraryScene(backend: backend, routing: routing,
                                     sources: makeLibraryDataSources(backend: backend, artworkAPI: makeArtworkAPI()),
                                     appQueue: appQueue, status: status, actions: actions, kittyEnabled: kittyEnabled,
                                     makeProvider: { spanDACDataProvider(routing: routing) },
                                     // Owned songs by exact persistent ID.
                                     handoff: liveMusicTUIHandoff(backend: backend, appQueue: appQueue, routing: routing))
            scenes[id] = scene
            return scene
        case .discover:
            // The door follows the DATA selection: SpanDAC data needs no
            // user token, MusicTUI's own data does.
            guard discoverTabAdmitted(selection: routing.selection,
                                      hasUserToken: AuthManager().userToken() != nil) else {
                status.post(DiscoverScene.signInToBrowse, error: true)
                return nil
            }
            // Play (Enter/p) needs the same both-tokens REST backend the artwork
            // fallback uses — makeArtworkAPI() nil means no dev token, same gate
            // makeDiscoverFeed() applies to `feed`.
            // Only a track-level Enter moves. `p` (Play all) keeps building a
            // container in Music.app, on his ruling: the wire has no queue, so
            // an album cannot honestly be sent to the source app yet.
            let scene = DiscoverScene(feed: makeDiscoverFeed(), status: status, actions: actions,
                                      api: makeArtworkAPI(), lifecycle: discoverLifecycle,
                                      // Always available; whether it is USED follows
                                      // the Output tab's selection, not an env var.
                                      routing: routing,
                                      kittyEnabled: kittyEnabled)
            scenes[id] = scene
            return scene
        case .radio:
            // makeCatalog() already returns nil with no developer token.
            //
            // Only `/` moves. Live, Personal and station resolution keep using
            // `catalog`, so with no key those stay empty exactly as they do
            // today and Favorites keep working with no network at all.
            let scene = RadioScene(routing: routing, store: StationStore(), catalog: makeCatalog(),
                                   kittyEnabled: kittyEnabled)
            scenes[id] = scene
            return scene
        default:
            return nil
        }
    }

    // Refusing a tab switch must say why — a dead keypress reads as a broken key.
    func switchOrExplain(_ id: SceneID) {
        // Each ensureScene refusal owns its toast (Playlists: "No playlists found.";
        // Discover: "Sign in…"), so there is no generic cross-tab fallback here.
        guard ensureScene(id) != nil else { return }
        // A tab the person chose is a state change: a won't-play message goes.
        if id != router.active { status.stateChanged() }
        router.switchTo(id); invalidateArtOnSwitch()
    }

    terminal.enterRawMode()
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
    // Queue resume: adopt the last session's app-owned queue if it still
    // matches what's actually playing.
    // Must run before poller.start() — after this line only the poller
    // touches queueStore, so there's no concurrent access and no lock needed.
    restoreQueueOnLaunch(queueStore: queueStore, appQueue: appQueue, backend: backend)
    // The end watcher, the album proof collector and the album cleaner ride
    // the poller's tick; none runs a script while it has nothing to do.
    poller.onTick = {
        discoverPlay.watcher.tick()
        discoverPlay.collector.tick()
        discoverPlay.cleaner.tick()
    }
    poller.start()
    // Records Bridge's finished library plays in Music.app, on a thread of its
    // own (not the poller's, not this input loop), and only while Bridge is the
    // selected output. It never launches Music.app: with Music.app not running,
    // plays wait for the next pass.
    //
    // The Mac's own SpanDAC only (`.source`), deliberately not a SpanDAC on the
    // network: `feed` reads THIS Mac's play record, and plays made on another
    // device are not in it. Recording those is its own decision.
    let playSync = PlaySyncWorker(
        isBridgeSelected: { routing.mode == .source },
        runner: PlaySyncEngine(paths: .live,
                               feed: SourceAppControl(),
                               writer: MusicPlayCountWriter(),
                               inspector: ProcMusicInstanceInspector()),
        post: { text, error, ttl in status.post(text, error: error, ttl: ttl) })
    playSync.start()
    // Sweep temp queue playlists left by a prior session (sparing the one still
    // playing). Off-main so a slow Music doesn't delay first paint.
    DispatchQueue.global().async { sweepQueuePlaylists(backend: backend) }
    // Same sweep for Discover's temp playlists, containers only, owned by the
    // lifecycle coordinator: it marks the sweep running BEFORE returning, so a
    // Discover play requested from here on waits for it to finish rather than
    // racing it (Rule 1). The body still runs off-main for the same reason.
    discoverLifecycle.startLaunchSweep()
    defer {
        // Rule 2, phase 1, FIRST: close admission before the poller's bounded
        // wait, so nothing queued behind `q` can mint a name and start a
        // create after the user asked to leave. Synchronous, no waiting.
        discoverLifecycle.closeAdmission()
        // Bounded (2s); a pass still writing is left to finish, and whatever it
        // had begun is settled by the next pass.
        playSync.stop()
        poller.stop()
        // Rule 2, phase 2: sweep Discover temp playlists now that the poller
        // is confirmed stopped, i.e. this is a genuine exit — never on a
        // mid-session stop event: the poller tolerates four consecutive
        // stopped polls because inter-track gaps look like stops, and
        // sweeping on a false stop would churn a live queue. The names of
        // every transaction this session could not confirm as its own travel
        // into the script as protected.
        discoverLifecycle.finishExit()
        // Delete this session's per-album art temp files (/tmp/music-now-art-*.dat)
        // now that the poller thread is confirmed stopped — a graceful exit
        // shouldn't leak one file per distinct album played.
        poller.cleanupArtFiles()
        // Same sweep for the Library tab's cover ladder temp files
        // (/tmp/music-lib-art-*.dat): the bytes already live in the art
        // cache by now, so nothing is lost.
        sweepLibraryArtFiles()
        // Free every transmitted image, alongside the terminal restore below,
        // so no image ghosts survive into scrollback (design doc sharp edge #4).
        if kittyEnabled {
            print(kittyDeleteAllEscape(), terminator: "")
            fflush(stdout)
        }
        terminal.exitRawMode()
    }

    func dims() -> ScreenFrame {
        ScreenFrame.current()
    }

    // Render only when something can have changed: a new poller snapshot (the
    // store generation moved), scene-local state (tick reports it), a handled
    // key, or a resize. The loop still spins at the input-poll cadence (~10/s),
    // but idle iterations skip the full-screen truecolor repaint.
    var lastGeneration = -1
    var lastToast: StatusToast? = nil
    var needsRender = true
    // What SpanDAC last said about serving, as this loop saw it, so a flip
    // into not serving is told once (`licenceNotice`).
    var lastServing: Bool? = nil
    // While serving is false, a low-rate asynchronous status read notices the
    // licence coming back (review finding 7); it never blocks this loop.
    let licenceReprobe = LicenceReprobe(routing: routing)

    while true {
        licenceReprobe.tick()
        if let licence = routing.licence {
            let serving = licence.snapshot().serving
            if let notice = licenceNotice(previous: lastServing, current: serving,
                                          dataAccepted: routing.ceremony == .accepted) {
                status.post(notice, ttl: 8)
            }
            lastServing = serving
        }
        if terminalResized {
            terminalResized = false
            print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
            fflush(stdout)
            needsRender = true
        }

        let (snap, generation) = store.readWithGeneration()
        if generation != lastGeneration {
            lastGeneration = generation
            needsRender = true
        }
        // The next track playback reports clears a won't-play message.
        status.observe(track: statusTrackKey(snap))
        // Toast appearing, changing, or expiring all repaint the footer.
        let toast = status.current()
        if toast != lastToast {
            lastToast = toast
            needsRender = true
        }
        let screen = dims()
        let frame = shellLayout(width: screen.width, height: screen.height, cellW: screen.cellW, cellH: screen.cellH)
        guard let scene = ensureScene(router.active) ?? scenes[.nowPlaying] else { continue }
        // One place catches every arrival, however the tab changed — a digit, Tab,
        // a `.push` from a scene, a `.pop` back. Before `tick`, so a scene can set
        // its cursor and have that same tick publish it.
        if router.active != lastActiveScene {
            lastActiveScene = router.active
            scene.becameActive()
        }
        // tick runs every iteration (it drains inboxes and kicks off background
        // fetches) even when the frame isn't repainted.
        if scene.tick(snapshot: snap) { needsRender = true }

        if needsRender {
            needsRender = false
            var out = renderShellChrome(frame: frame)
            out += renderTabStrip(active: router.active, tabs: tabs, frame: frame)
            out += scene.render(frame: frame, snapshot: snap)
            // No persistent now-playing bar — playback (incl. live progress) lives on
            // the Now tab. Just the footer hint line at the bottom.
            // Footer = tab nav + the active scene's own keys + the always-on playback
            // globals (so shuffle/skip/volume are discoverable from any tab).
            out += ANSICode.moveTo(row: frame.footerY, col: 3) + ANSICode.clearLine
            if let t = toast {
                // The toast borrows the footer line until it expires.
                let color = t.isError ? ANSICode.red : ANSICode.amber
                out += "\(color)\(truncText(t.text, to: max(1, frame.width - 4)))\(ANSICode.reset)"
            } else {
                let globals = shellFooterGlobals(for: routing)
                out += "\(ANSICode.dim)1-\(tabs.count) Tabs   \(scene.footerHint)   \(globals)  q Quit\(ANSICode.reset)"
            }
            // Synchronized output (terminals that don't support it ignore the
            // escapes): the clear-then-paint inside one frame can't tear.
            print("\u{1B}[?2026h" + out + "\u{1B}[?2026l", terminator: "")
            fflush(stdout)
        }

        // 100ms input poll; on timeout, loop to pick up poller/inbox changes.
        guard let key = KeyPress.read(timeout: 0.1) else { continue }
        needsRender = true

        // First decision, before anything else sees the key: typed Ctrl-C
        // quits from every scene through the same `return` as `q`, so the
        // exit `defer` runs once; raw-input scenes (filter/search) otherwise
        // get every key, unmediated.
        switch shellRoute(for: key, sceneCapturing: scene.capturesAllInput) {
        case .quit:
            return
        case .scene:
            switch scene.handle(key) {
            case .none, .redraw: break
            case .push(let id): router.push(id); invalidateArtOnSwitch()
            case .pop: status.stateChanged(); router.pop(); invalidateArtOnSwitch()
            case .quit: return
            }
            continue
        case .globals:
            break
        }

        // 1) Globals (work in every non-capturing scene). Each runs on the serial
        //    action queue so the input loop never blocks on osascript; failures
        //    surface as a footer toast instead of vanishing into `try?`.
        if let action = resolveGlobalKey(key) {
            switch action {
            case .playPause:
                actions.run("Play/pause") {
                    try routing.perform(.playPause,
                        musicApp: { _ = try syncRun { try await backend.runMusic("playpause") } },
                        source: { client in
                            // The wire has play and pause, not a toggle, so the
                            // current state decides which one this press means.
                            if try client.control.status().playback == "playing" {
                                try client.control.pause()
                            } else {
                                try client.control.resume()
                            }
                        },
                        unaffected: {})
                }
            case .volumeUp, .volumeDown:
                // Coalesced: holding the key accumulates one delta, applied once.
                volumeDelta.add(action == .volumeUp ? 5 : -5)
                actions.run("Volume") {
                    let d = volumeDelta.take()
                    guard d != 0 else { return }
                    // Refused in Source Mode: MusicKit exposes no player volume,
                    // and the Mac's output level is not the player's to set.
                    try routing.perform(.volume,
                        musicApp: { _ = try syncRun { try await backend.runMusic("set sound volume to (sound volume + \(d))") } },
                        source: { _ in },
                        unaffected: {})
                }
            // next/prev drive the app-owned queue when one is active (the poller
            // can't rely on Music's queue post-26.x); otherwise Music's own controls.
            // step() commits the index before the play attempt, so a failed play
            // rolls the step back — otherwise the Up Next highlight desyncs from
            // the audio and every later next/prev walks from the wrong baseline.
            // (playQueueTrack is false only on an osascript ERROR, i.e. transient;
            // rolling back keeps the position honest and the next press retries.)
            case .next, .prev:
                let step = action == .next ? 1 : -1
                globalSkip(step, routing: routing,
                           musicTUI: { try musicTUISkip(step, backend: backend, appQueue: appQueue) },
                           run: { actions.run($0, $1) })
            case .shuffle:
                actions.run("Shuffle") {
                    // The global `z` shuffles the CURRENT collection, which in
                    // Bridge mode nothing here can name: `shufflePlayCurrent`
                    // reads `appQueue`, and no Bridge branch writes it. See the
                    // long note at NowPlayingScene's `.shuffle` case — same
                    // reason, same decision, deliberately still refused.
                    try routing.perform(.collectionShuffle,
                        musicApp: { try require(shufflePlayCurrent(backend: backend, appQueue: appQueue), "Shuffle failed.") },
                        source: { _ in throw bridgeNotWiredYet("Collection shuffle") },
                        unaffected: {})
                }
            case .switchScene(let n):
                if n >= 1 && n <= tabs.count { switchOrExplain(tabs[n - 1].id) }
            case .quit:       return
            }
            continue
        }

        // 2) Tab cycles scenes; Shift-Tab cycles backwards.
        if case .char("\t") = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                switchOrExplain(tabs[(idx + 1) % tabs.count].id)
            }
            continue
        }
        if case .shiftTab = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                switchOrExplain(tabs[(idx + tabs.count - 1) % tabs.count].id)
            }
            continue
        }

        // 3) Everything else (including Esc) goes to the scene; it decides whether
        //    Esc means an internal back (.redraw) or leaving the scene (.pop).
        switch scene.handle(key) {
        case .none, .redraw: break
        // `.push` is a scene's own play jumping to Now: that play already
        // cleared any won't-play message at its keypress, and what it posts
        // now is its own news, so the push does not clear it. `.pop` is the
        // person leaving, and does.
        case .push(let id): router.push(id); invalidateArtOnSwitch()
        case .pop: status.stateChanged(); router.pop(); invalidateArtOnSwitch()
        case .quit: return
        }
    }
}

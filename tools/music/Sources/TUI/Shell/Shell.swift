// tools/music/Sources/TUI/Shell/Shell.swift
import Foundation

func runShell() {
    let backend = AppleScriptBackend()
    let store = NowPlayingStore()
    let appQueue = AppQueueStore()
    let status = StatusStore()
    let actions = ActionRunner(status: status)
    let volumeDelta = DeltaAccumulator()
    let poller = PlaybackPoller(store: store, backend: backend, appQueue: appQueue)
    let terminal = TerminalState.shared
    // Computed once (env-based, no stdin response parsing — design doc sharp
    // edge #5) and threaded into every art-rendering scene.
    let kittyEnabled = kittyGraphicsSupported(env: ProcessInfo.processInfo.environment)

    let router = Router(root: .nowPlaying)
    var scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend, appQueue: appQueue, status: status, actions: actions, kittyEnabled: kittyEnabled)]
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now"), (.playlists, "Playlists"), (.speakers, "Speakers"), (.library, "Library"), (.radio, "Radio")]

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
            let fetched = fetchUserPlaylistNames(backend: backend)
            let names = fetched.names
            guard !names.isEmpty else {
                status.post("No playlists found.", error: true)
                return nil
            }
            let auth = AuthManager()
            var artworkAPI: RESTAPIBackend? = nil
            if let devToken = try? auth.requireDeveloperToken(), auth.userToken() != nil {
                artworkAPI = RESTAPIBackend(developerToken: devToken,
                                            userToken: auth.userToken(),
                                            storefront: auth.storefront())
            }
            let scene = PlaylistsScene(backend: backend,
                                       playlists: names,
                                       subscriptionNames: fetched.subscription,
                                       sources: makePlaylistDataSources(backend: backend, names: names, artworkAPI: artworkAPI),
                                       appQueue: appQueue,
                                       status: status,
                                       actions: actions,
                                       kittyEnabled: kittyEnabled)
            scenes[id] = scene
            return scene
        case .speakers:
            let scene = SpeakersScene(backend: backend, status: status, actions: actions)
            scenes[id] = scene
            return scene
        case .library:
            // Library browse needs a signed-in user (library endpoints) and a
            // configured developer token. Refuse with a toast rather than a dead
            // key when either is missing.
            let auth = AuthManager()
            guard auth.userToken() != nil else {
                status.post("Sign in to browse your library (music auth login).", error: true)
                return nil
            }
            guard let devToken = try? auth.requireDeveloperToken() else {
                status.post("Apple Music isn't configured (music auth setup).", error: true)
                return nil
            }
            let api = RESTAPIBackend(developerToken: devToken,
                                     userToken: auth.userToken(),
                                     storefront: auth.storefront())
            let scene = LibraryScene(backend: backend,
                                     sources: makeLibraryDataSources(api: api, backend: backend),
                                     appQueue: appQueue,
                                     status: status,
                                     actions: actions,
                                     kittyEnabled: kittyEnabled)
            scenes[id] = scene
            return scene
        case .radio:
            // makeCatalog() already returns nil with no developer token.
            let scene = RadioScene(store: StationStore(), catalog: makeCatalog(), kittyEnabled: kittyEnabled)
            scenes[id] = scene
            return scene
        default:
            return nil
        }
    }

    // Refusing a tab switch must say why — a dead keypress reads as a broken key.
    func switchOrExplain(_ id: SceneID) {
        // Each ensureScene refusal owns its toast (Playlists: "No playlists found.";
        // Library: "Sign in…"), so there is no generic cross-tab fallback here.
        if ensureScene(id) != nil { router.switchTo(id); invalidateArtOnSwitch() }
    }

    terminal.enterRawMode()
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
    poller.start()
    // Sweep temp queue playlists left by a prior session (sparing the one still
    // playing). Off-main so a slow Music doesn't delay first paint.
    DispatchQueue.global().async { sweepQueuePlaylists(backend: backend) }
    defer {
        poller.stop()
        // Free every transmitted image, alongside the terminal restore below,
        // so no image ghosts survive into scrollback (design doc sharp edge #4).
        if kittyEnabled {
            print(kittyDeleteAllEscape(), terminator: "")
            fflush(stdout)
        }
        terminal.exitRawMode()
    }

    func dims() -> (Int, Int) {
        let f = ScreenFrame.current()
        return (f.width, f.height)
    }

    // Render only when something can have changed: a new poller snapshot (the
    // store generation moved), scene-local state (tick reports it), a handled
    // key, or a resize. The loop still spins at the input-poll cadence (~10/s),
    // but idle iterations skip the full-screen truecolor repaint.
    var lastGeneration = -1
    var lastToast: StatusToast? = nil
    var needsRender = true

    while true {
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
        // Toast appearing, changing, or expiring all repaint the footer.
        let toast = status.current()
        if toast != lastToast {
            lastToast = toast
            needsRender = true
        }
        let (w, h) = dims()
        let frame = shellLayout(width: w, height: h)
        guard let scene = ensureScene(router.active) ?? scenes[.nowPlaying] else { continue }
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
                let globals = "Space \u{23EF}  < > Skip  z Reshuffle  +/\u{2212} Vol"
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

        // Raw-input scenes (filter/search) get every key, unmediated.
        if !shellShouldResolveGlobals(forSceneCapturing: scene.capturesAllInput) {
            switch scene.handle(key) {
            case .none, .redraw: break
            case .push(let id): router.push(id); invalidateArtOnSwitch()
            case .pop: router.pop(); invalidateArtOnSwitch()
            case .quit: return
            }
            continue
        }

        // 1) Globals (work in every non-capturing scene). Each runs on the serial
        //    action queue so the input loop never blocks on osascript; failures
        //    surface as a footer toast instead of vanishing into `try?`.
        if let action = resolveGlobalKey(key) {
            switch action {
            case .playPause:
                actions.run("Play/pause") { _ = try syncRun { try await backend.runMusic("playpause") } }
            case .volumeUp, .volumeDown:
                // Coalesced: holding the key accumulates one delta, applied once.
                volumeDelta.add(action == .volumeUp ? 5 : -5)
                actions.run("Volume") {
                    let d = volumeDelta.take()
                    guard d != 0 else { return }
                    _ = try syncRun { try await backend.runMusic("set sound volume to (sound volume + \(d))") }
                }
            // next/prev drive the app-owned queue when one is active (the poller
            // can't rely on Music's queue post-26.x); otherwise Music's own controls.
            case .next:
                if let (pl, pos) = appQueue.step(1) {
                    actions.run("Play") { try require(playQueueTrack(backend: backend, playlist: pl, position: pos), "Couldn't play that track.") }
                } else {
                    actions.run("Skip") { _ = try syncRun { try await backend.runMusic("next track") } }
                }
            case .prev:
                if let (pl, pos) = appQueue.step(-1) {
                    actions.run("Play") { try require(playQueueTrack(backend: backend, playlist: pl, position: pos), "Couldn't play that track.") }
                } else {
                    actions.run("Back") { _ = try syncRun { try await backend.runMusic("previous track") } }
                }
            case .shuffle:
                actions.run("Shuffle") { try require(shufflePlayCurrent(backend: backend, appQueue: appQueue), "Shuffle failed.") }
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
        case .push(let id): router.push(id); invalidateArtOnSwitch()
        case .pop: router.pop(); invalidateArtOnSwitch()
        case .quit: return
        }
    }
}

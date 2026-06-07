// tools/music/Sources/TUI/Shell/Shell.swift
import Foundation

func runShell() {
    let backend = AppleScriptBackend()
    let store = NowPlayingStore()
    let poller = PlaybackPoller(store: store, backend: backend)
    let terminal = TerminalState.shared

    let router = Router(root: .nowPlaying)
    let scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend)]
    // v1 tab order; Milestone 1 ships only Now Playing.
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now")]

    terminal.enterRawMode()
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
    poller.start()
    defer {
        poller.stop()
        terminal.exitRawMode()
    }

    func dims() -> (Int, Int) {
        let f = ScreenFrame.current()
        return (f.width, f.height)
    }

    while true {
        if terminalResized {
            terminalResized = false
            print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
            fflush(stdout)
        }

        let snap = store.read()
        let (w, h) = dims()
        let frame = shellLayout(width: w, height: h)
        guard let scene = scenes[router.active] else { continue }
        scene.tick(snapshot: snap)

        var out = renderShellChrome(frame: frame)
        out += renderTabStrip(active: router.active, tabs: tabs, frame: frame)
        out += scene.render(frame: frame, snapshot: snap)
        out += renderNowPlayingBar(snapshot: snap, frame: frame)
        // Footer hint line (skipped in Bare tier where the bar occupies the footer).
        if frame.barTier != .bare {
            out += ANSICode.moveTo(row: frame.footerY, col: 3) + ANSICode.clearLine
            out += "\(ANSICode.dim)\u{2191}\u{2193} Album  Enter Play  Space \u{23EF}  </> Track  +/- Vol  r Radio  q Quit\(ANSICode.reset)"
        }
        print(out, terminator: "")
        fflush(stdout)

        // 100ms tick: redraw on timeout so the live bar advances while idle.
        guard let key = KeyPress.read(timeout: 0.1) else { continue }

        // 1) Globals (work in every scene).
        if let action = resolveGlobalKey(key) {
            switch action {
            case .playPause:
                _ = try? syncRun { try await backend.runMusic("playpause") }
            case .volumeUp:
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume + 5)") }
            case .volumeDown:
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume - 5)") }
            case .next:
                _ = try? syncRun { try await backend.runMusic("next track") }
            case .prev:
                _ = try? syncRun { try await backend.runMusic("previous track") }
            case .shuffle:
                _ = try? syncRun { try await backend.runMusic("set shuffle enabled to (not shuffle enabled)") }
            case .radio:
                _ = startRadioStation()
                router.switchTo(.nowPlaying)
            case .switchScene(let n):
                if n >= 1 && n <= tabs.count { router.switchTo(tabs[n - 1].id) }
            case .quit:
                return
            }
            continue
        }

        // 2) Shell navigation keys.
        if case .char("\t") = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                router.switchTo(tabs[(idx + 1) % tabs.count].id)
            }
            continue
        }
        if case .escape = key {
            if router.stack.count > 1 { router.pop() } else { return }
            continue
        }

        // 3) Delegate to the active scene.
        switch scene.handle(key) {
        case .none, .redraw: break
        case .push(let id): router.push(id)
        case .pop: router.pop()
        case .quit: return
        }
    }
}

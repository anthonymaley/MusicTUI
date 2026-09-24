import XCTest
@testable import music

/// Shared support for the Playlists tab's Bridge scene tests (C2, C3):
/// `PlaylistAppleScriptSpy`, `playlistsTestScene`, and the `PlaylistsScene`
/// overload of `settleScene`. Reuses Part A's `BridgeLibraryReadsWire` and
/// `BridgeSelectedFlag` from `BridgeLibraryTestSupport.swift` — the same
/// provenance seam, a different scene.

/// Counts every closure `PlaylistsScene` can call on the Music.app side, so a
/// test can prove Bridge mode never reaches AppleScript at all, and that a
/// post-switch reload calls `loadMusicAppPlaylists`/`makeSources` exactly
/// once each.
final class PlaylistAppleScriptSpy {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// What `loadMusicAppPlaylists()` answers.
    var names: [String] = []
    var subscription: Set<String> = []

    private func bump(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }

    /// The Shell's own initial, SYNCHRONOUS Music.app build — the direct
    /// `makePlaylistDataSources(...)` call `openPlaylistsScene`'s `build`
    /// closure makes, never through the `makeSources` closure below. Bumps
    /// the same `onMeta`/`onPreview`/`onTracks`/`onArtworkMap` counts.
    func sources() -> PlaylistDataSources { countedSources() }

    /// The `makeSources` closure `PlaylistsScene.init` is given: only ever
    /// called by a POST-SWITCH async reload (C2's `applyMusicAppNames`), never
    /// by construction itself.
    func makeSources(_ names: [String]) -> PlaylistDataSources {
        bump("makeSources")
        return countedSources()
    }

    func loadMusicAppPlaylists() -> (names: [String], subscription: Set<String>) {
        bump("loadMusicAppPlaylists")
        return (names, subscription)
    }

    private func countedSources() -> PlaylistDataSources {
        PlaylistDataSources(
            onMeta: { [self] _ in bump("onMeta"); return [:] },
            onPreview: { [self] _ in bump("onPreview"); return nil },
            onTracks: { [self] _ in bump("onTracks"); return nil },
            onArtworkMap: { [self] in bump("onArtworkMap"); return [:] })
    }
}

/// The production shape of the factory: a provider only while `flag.selected`
/// is true (same seam `libraryTestScene` uses). `playlists` is what a real
/// `openPlaylistsScene` build closure would be handed — non-empty only for
/// the Shell's Music.app-mode SYNCHRONOUS path; empty (the default) is the
/// Bridge path, where `railSource` stays nil until the first `tick()`.
func playlistsTestScene(flag: BridgeSelectedFlag, wire: BridgeLibraryReadsWire, spy: PlaylistAppleScriptSpy,
                        status: StatusStore = StatusStore(), names: [String] = [],
                        warmUpSleep: @escaping (TimeInterval) -> Void = { _ in },
                        width: Int = 138) -> PlaylistsScene {
    // `names` (this construction's own `playlists:`) and `spy.names` (what a
    // LATER async reload answers) are different concerns — only set the spy's
    // when the caller is using the direct-construction path and hasn't
    // already configured the spy itself for a reload scenario.
    if !names.isEmpty { spy.names = names }
    let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
    store.set(.source)
    let routing = RoutingCoordinator(store: store, surface: .tui,
                                     makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
    return PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                          playlists: names, sources: names.isEmpty ? .empty : spy.sources(),
                          appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                          // Never the real ~/.config/music/playlist-meta.json (C0 isolation).
                          metaCache: temporaryPlaylistMetaCache().cache,
                          makeProvider: {
                              flag.selected
                                  ? BridgeMusicProvider(control: SourceAppControl(
                                      path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                                  : nil
                          },
                          loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                          makeSources: { spy.makeSources($0) },
                          warmUpSleep: warmUpSleep,
                          // Injected (rule 15/D10): tests never depend on the
                          // real terminal. 138 defaults to three-zone.
                          screenWidth: { width })
}

@discardableResult
func settleScene(_ s: PlaylistsScene, snapshot: NowPlayingSnapshot = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []),
                 seconds: Double = 3.0, until: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = s.tick(snapshot: snapshot)
        if until() { return true }
        usleep(5_000)
    }
    return until()
}

/// Counts real AppleScript invocations, for the one thing `AppleScriptBackend(executable:
/// "/usr/bin/true")` can't prove: not just "no crash", but ZERO calls. `AppleScriptBackend`
/// is a struct that always spawns `executable`, so the spy IS the executable — a tiny shell
/// script that appends one byte to a counter file and exits 0 — rather than a protocol mock.
///
/// Built for the Codex before-push finding on `playTrack`'s residual race (mode flips to
/// Bridge between the keypress's own provenance check and the action finally running): proves
/// the fix by counting, not just by not crashing on `/usr/bin/true`.
final class AppleScriptCallCounter {
    private let scriptPath: String
    private let countPath: String

    init() {
        let dir = FileManager.default.temporaryDirectory
        countPath = dir.appendingPathComponent("applescript-count-\(UUID().uuidString).txt").path
        scriptPath = dir.appendingPathComponent("applescript-counter-\(UUID().uuidString).sh").path
        // `printf`, not `echo -n`: `/bin/sh`'s builtin `echo` does not treat
        // `-n` as a flag portably (found while proving this counter — it
        // wrote the LITERAL "-n 1" per call, not "1"), so byte-length as a
        // call count would have been wrong from the first invocation.
        let script = "#!/bin/sh\nprintf 1 >> \"\(countPath)\"\nexit 0\n"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    var backend: AppleScriptBackend { AppleScriptBackend(executable: scriptPath) }

    /// One byte per invocation (the script appends "1" each time), so the
    /// file's length IS the call count — 0 when the file was never created.
    var callCount: Int {
        (try? Data(contentsOf: URL(fileURLWithPath: countPath)))?.count ?? 0
    }
}

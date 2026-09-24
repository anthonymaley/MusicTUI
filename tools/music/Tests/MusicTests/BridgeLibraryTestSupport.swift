import XCTest
@testable import music

/// Shared support for the Bridge library scene tests (C2, C3):
/// `BridgeLibraryReadsWire`, `LibraryAppleScriptSpy`, `libraryTestScene`, and
/// the `ResultCache` isolation helper. Used by `BridgeListFeedTests`,
/// `BridgeLibraryListsSceneTests`, `LibrarySceneCacheIsolationTests` and
/// `BridgeLibraryPlaySceneTests`.

/// A `ResultCache` rooted in a fresh, unique temporary directory, so a test
/// that exercises `LibraryScene`'s tier-cache read or write never touches the
/// real `~/.config/music/artist-tiers.json`.
///
/// The directory is created empty; `ResultCache` creates it lazily on its own
/// first write (`ensureDirectory()`), so this only needs to hand back a path
/// nothing else is using. Call `FileManager.default.removeItem(at:)` on the
/// returned directory during teardown if a test wants to leave nothing behind;
/// leaving it is otherwise harmless because it is under the system temp root.
func temporaryResultCache() -> (cache: ResultCache, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("music-test-result-cache-\(UUID().uuidString)", isDirectory: true)
    let cache = ResultCache(directory: directory.path)
    return (cache, directory)
}

/// A canned Bridge that answers PER OP from its own scripted reply queue —
/// unlike `BridgeLibrarySceneTests`' file-local `Wire` (Songs-only, kept as
/// slice 1 left it), this one serves every `slice.library*` op the same way,
/// which is what a scene test exercising Albums, Artists and their
/// containers together needs.
///
/// An unscripted request answers a LOUD `bad_request` — "unscripted <op>" —
/// rather than silently reading as an empty or successful page, so an
/// over-walk or an unexpected extra request fails the test that triggered it
/// instead of the next one.
final class BridgeLibraryReadsWire {
    private let lock = NSLock()
    private(set) var requests: [[String: Any]] = []
    private var repliesByOp: [String: [String]]
    private var countByOp: [String: Int] = [:]
    private var gates: [String: [Int: DispatchSemaphore]] = [:]

    init(_ repliesByOp: [String: [String]] = [:]) {
        self.repliesByOp = repliesByOp
    }

    /// Script more replies for `op`, appended after whatever is already
    /// queued for it.
    func script(_ op: String, _ replies: [String]) {
        lock.lock(); repliesByOp[op, default: []].append(contentsOf: replies); lock.unlock()
    }

    /// Hold the Nth (0-based) request of `op` until `release(op:at:)`.
    func gate(op: String, at n: Int) {
        lock.lock(); gates[op, default: [:]][n] = DispatchSemaphore(value: 0); lock.unlock()
    }
    func release(op: String, at n: Int = 0) {
        lock.lock(); let g = gates[op]?[n]; lock.unlock()
        g?.signal()
    }
    /// Whether the gated request has actually been issued, so a test waits
    /// for the walk to arrive rather than for a duration.
    func reached(op: String, at n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (countByOp[op] ?? 0) > n
    }

    func transport(_ path: String, _ line: String) throws -> String {
        let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
        let op = body["op"] as? String ?? ""
        lock.lock()
        requests.append(body)
        let n = countByOp[op, default: 0]
        countByOp[op] = n + 1
        let replies = repliesByOp[op] ?? []
        let reply = n < replies.count ? replies[n] : Self.unscripted(op)
        let gate = gates[op]?[n]
        lock.unlock()
        _ = gate?.wait(timeout: .now() + 5)
        return reply
    }

    private static func unscripted(_ op: String) -> String {
        """
        {"ok":false,"op":"\(op)","error":{"kind":"bad_request","detail":"unscripted \(op)"}}
        """
    }

    func sent(_ op: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { ($0["op"] as? String) == op }
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

/// Counts each `LibraryDataSources` closure, so a test can prove the
/// AppleScript source was — or, in Bridge mode, was NOT — asked at all.
final class LibraryAppleScriptSpy {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var albums: [LibraryAlbum] = []
    var songs: [LibrarySong] = []
    var artists: [LibraryArtist] = []
    /// false makes the bulk read FAIL — proving a Music.app failure never
    /// reaches a Bridge-sourced list, the D7/rule-3 property.
    var succeed = true

    private func bump(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }

    func sources() -> LibraryDataSources {
        LibraryDataSources(
            onAlbums: { [self] page in
                bump("onAlbums")
                guard succeed else { return false }
                return albums.isEmpty ? true : page(albums)
            },
            onSongs: { [self] page in
                bump("onSongs")
                guard succeed else { return false }
                return songs.isEmpty ? true : page(songs)
            },
            onArtists: { [self] page in
                bump("onArtists")
                guard succeed else { return false }
                return artists.isEmpty ? true : page(artists)
            },
            onAlbumTracks: { [self] _, _ in bump("onAlbumTracks"); return [] },
            onArtistAlbums: { [self] _ in bump("onArtistAlbums"); return [] },
            onAlbumCover: { [self] _ in bump("onAlbumCover"); return nil })
    }
}

/// Flips `makeProvider()` between Bridge and Music.app WITHOUT a routing
/// switch transaction — D7's provenance reset is provable in isolation from
/// `RoutingCoordinator`'s own switch machinery this way, exactly the seam
/// `LibraryScene.makeProvider` exists for.
final class BridgeSelectedFlag {
    var selected: Bool
    init(_ selected: Bool) { self.selected = selected }
}

/// The production shape of the factory: a provider only while `flag.selected`
/// is true. `routing`'s own mode is fixed at `.source` for the whole scene's
/// life (only `makeProvider` moves), because these tests are about the
/// PROVENANCE seam (D7), not the switch transaction (which `RoutingCoordinator`
/// and `BridgeSwitchPauseTests` already cover).
func libraryTestScene(flag: BridgeSelectedFlag, wire: BridgeLibraryReadsWire,
                      spy: LibraryAppleScriptSpy, status: StatusStore = StatusStore(),
                      warmUpSleep: @escaping (TimeInterval) -> Void = { _ in }) -> LibraryScene {
    let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
    store.set(.source)
    let routing = RoutingCoordinator(store: store, surface: .tui,
                                     makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
    return LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                        sources: spy.sources(), appQueue: AppQueueStore(), status: status,
                        actions: ActionRunner(status: status),
                        makeProvider: {
                            flag.selected
                                ? BridgeMusicProvider(control: SourceAppControl(
                                    path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                                : nil
                        },
                        warmUpSleep: warmUpSleep,
                        // Never the real ~/.config/music/artist-tiers.json (C2 isolation).
                        resultCache: temporaryResultCache().cache)
}

/// `[` / `]` cycles Artists → Albums → Songs; lands on `sub` from wherever
/// the scene starts.
func goToSubView(_ s: LibraryScene, _ sub: LibrarySubView) {
    for _ in 0..<LibrarySubView.allCases.count where s.subViewForTest != sub {
        _ = s.handle(.char("]"))
    }
    XCTAssertEqual(s.subViewForTest, sub)
}

@discardableResult
func settleScene(_ s: LibraryScene, snapshot: NowPlayingSnapshot = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []),
                 seconds: Double = 3.0, until: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = s.tick(snapshot: snapshot)
        if until() { return true }
        usleep(5_000)
    }
    return until()
}

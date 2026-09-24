import XCTest
@testable import music

/// Step 2's call-site bindings: proof that the collection keys actually CONSULT
/// the routing coordinator, not merely that the matrix would answer correctly.
///
/// **Why this file is separate from `BridgeCollectionQueueTests`.** The
/// 2026-09-17 review found `routeAction` bound only where a call site asked it,
/// and most did not — with `ActionRoutingTests` passing throughout, because a
/// total matrix and a consulted matrix are different claims. These tests fail if
/// a guard is reinstated or a branch is bypassed, which is the only shape of
/// test that would have caught that defect.
///
/// No AppleScript runs here: the collection reads are injected, so `swift test`
/// never touches the user's Music.app.
final class BridgeCollectionCallSiteTests: XCTestCase {

    // MARK: - Harness

    /// Captures what Bridge was asked to do.
    private final class Wire {
        private(set) var lines: [String] = []
        var reply = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T1","artist":"A"}}"#

        var transport: (String, String) throws -> String {
            { [self] _, line in lines.append(line); return reply }
        }

        var queued: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                 .filter { $0["op"] as? String == "slice.queue" }
        }

        /// The row titles of the single queue request, in the order sent.
        var queuedTitles: [String] {
            guard let rows = queued.first?["rows"] as? [[String: String]] else { return [] }
            return rows.compactMap { $0["title"] }
        }
    }

    private func tracks(_ n: Int, album: String? = "Album") -> [TrackListEntry] {
        (1...n).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false, album: album) }
    }

    private func emptySources() -> LibraryDataSources {
        LibraryDataSources(onAlbums: { _ in true }, onSongs: { _ in true },
                           onArtists: { _ in true },
                           onAlbumTracks: { _, _ in [] }, onArtistAlbums: { _ in [] },
                           onAlbumCover: { _ in nil })
    }

    /// A LibraryScene whose mode, wire and collection reads are all controlled.
    /// The injected resolvers ignore `backend`, but the Music.app branch of a
    /// play does NOT: it sends `play track N of playlist "Library"`. With the
    /// real interpreter the two Music.app-mode tests below played a real library
    /// track aloud on every run (2026-09-23), so the backend here is inert.
    private func scene(mode: PlaybackMode, wire: Wire, status: StatusStore,
                       resolved: AlbumResolution) -> LibraryScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: wire.transport) })
        return LibraryScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                            sources: emptySources(), appQueue: AppQueueStore(),
                            status: status, actions: ActionRunner(status: status),
                            resolveAlbum: { _, _, _ in resolved },
                            resolveArtist: { _, _ in resolved },
                            // Never the real ~/.config/music/artist-tiers.json (C2 isolation).
                            resultCache: temporaryResultCache().cache)
    }

    /// `ActionRunner` runs on its own serial queue, so the assertion has to wait
    /// for the action rather than the keypress.
    private func settle(_ wire: Wire, expecting: Int = 1, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if wire.queued.count >= expecting { return }
            usleep(10_000)
        }
    }

    private func settleStatus(_ status: StatusStore, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if status.current() != nil { return }
            usleep(10_000)
        }
    }

    // MARK: - Album play

    /// C3 item 8 rewrite (was `testAlbumPlayInBridgeModeQueuesOnTheWire`,
    /// `testAlbumPlayFromARowQueuesThatRowToTheEnd` and
    /// `testAlbumShuffleQueuesTheWholeSet`, three variants of the same now-gone
    /// behaviour). `playAlbum` is the Music.app-SOURCED path; this harness
    /// never gives it a provider, so `s.playAlbum` here models a Music.app
    /// list played while `routing.mode == .source` (Bridge selected) — the
    /// join is gone (rule 3, no silent fallback): nothing reaches the wire,
    /// and the footer says why in `LibraryProvenance.bridgeSelectedMusicAppList`'s
    /// own words, not "Play failed.".
    func testAMusicAppListsAlbumPlayInBridgeModeSendsNothingAndSaysWhy() {
        let wire = Wire()
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      resolved: AlbumResolution(tracks: tracks(3), matched: 3))

        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        settleStatus(status)

        XCTAssertTrue(wire.queued.isEmpty, "a Music.app-sourced album reached Bridge's wire")
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
        XCTAssertEqual(status.current()?.isError, true)
    }

    /// Music.app mode must not reach the wire at all. This is the other half of
    /// the binding: a test that only proved Bridge works could pass with the
    /// mode ignored entirely.
    func testAlbumPlayInMusicAppModeNeverTouchesTheWire() {
        let wire = Wire()
        let s = scene(mode: .musicApp, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(3), matched: 3))

        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        // Give the action the same window the Bridge tests get.
        settle(wire, expecting: 1, seconds: 0.6)

        XCTAssertTrue(wire.queued.isEmpty, "Music.app mode sent a Bridge request")
    }

    // MARK: - Artist play

    /// C3 item 8 rewrite (was `testArtistPlayInBridgeModeQueuesEveryTrack`).
    /// Same property as the album case above: `playArtist` is the
    /// Music.app-SOURCED path, and played while Bridge is selected it refuses
    /// rather than joining.
    func testAMusicAppListsArtistPlayInBridgeModeSendsNothingAndSaysWhy() {
        let wire = Wire()
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      resolved: AlbumResolution(tracks: tracks(4), matched: 4))

        s.playArtist(name: "A", shuffle: false)
        settleStatus(status)

        XCTAssertTrue(wire.queued.isEmpty, "a Music.app-sourced artist reached Bridge's wire")
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
        XCTAssertEqual(status.current()?.isError, true)
    }

    func testArtistPlayInMusicAppModeNeverTouchesTheWire() {
        let wire = Wire()
        let s = scene(mode: .musicApp, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(4), matched: 4))

        s.playArtist(name: "A", shuffle: false)
        settle(wire, expecting: 1, seconds: 0.6)

        XCTAssertTrue(wire.queued.isEmpty, "Music.app mode sent a Bridge request")
    }

    // C3 item 8: `testABridgeRefusalReachesTheFooterInItsOwnWords` moved to
    // the Bridge path in `BridgeLibraryPlaySceneTests`, with the same
    // property (a Bridge refusal reaches the footer in its own words, never
    // reduced to "Play failed."), now exercised through `playBridgeAlbum`.
    //
    // `testAnUndescribableTrackRefusesBeforeSendingAnything` is deleted: "no
    // album, so Bridge cannot identify it" was the join's own rule, and the
    // join is gone from the Library tab. Its sibling in
    // `BridgeCollectionQueueTests` still pins the helper directly.
}

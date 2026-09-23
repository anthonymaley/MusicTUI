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
                            resolveArtist: { _, _ in resolved })
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

    /// The binding itself: in Bridge mode the album reaches the WIRE. Fails if
    /// `bridgeNotWiredYet` is reinstated at this call site.
    func testAlbumPlayInBridgeModeQueuesOnTheWire() {
        let wire = Wire()
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      resolved: AlbumResolution(tracks: tracks(3), matched: 3))

        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        settle(wire)

        XCTAssertEqual(wire.queued.count, 1, "the album never reached Bridge")
        XCTAssertEqual(wire.queuedTitles, ["T1", "T2", "T3"])
    }

    /// Start-at-row travels to the wire, not just through the pure helper.
    func testAlbumPlayFromARowQueuesThatRowToTheEnd() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(5), matched: 5))

        s.playAlbum(title: "Album", artist: "A", shuffle: false, startAt: 4)
        settle(wire)

        XCTAssertEqual(wire.queuedTitles, ["T4", "T5"])
    }

    /// Shuffle sends the whole set, in some order, and never the start row only.
    func testAlbumShuffleQueuesTheWholeSet() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(6), matched: 6))

        s.playAlbum(title: "Album", artist: "A", shuffle: true, startAt: 4)
        settle(wire)

        XCTAssertEqual(Set(wire.queuedTitles), Set(["T1", "T2", "T3", "T4", "T5", "T6"]))
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

    func testArtistPlayInBridgeModeQueuesEveryTrack() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(4), matched: 4))

        s.playArtist(name: "A", shuffle: false)
        settle(wire)

        XCTAssertEqual(wire.queuedTitles, ["T1", "T2", "T3", "T4"])
    }

    func testArtistPlayInMusicAppModeNeverTouchesTheWire() {
        let wire = Wire()
        let s = scene(mode: .musicApp, wire: wire, status: StatusStore(),
                      resolved: AlbumResolution(tracks: tracks(4), matched: 4))

        s.playArtist(name: "A", shuffle: false)
        settle(wire, expecting: 1, seconds: 0.6)

        XCTAssertTrue(wire.queued.isEmpty, "Music.app mode sent a Bridge request")
    }

    // MARK: - Failures stay visible

    /// A Bridge refusal must reach the footer in its OWN words. `ActionRunner`
    /// reduces anything that is not an `ActionError` to "Play failed.", which is
    /// how the 100-song bound and "no unique match" became four useless words
    /// twice already.
    func testABridgeRefusalReachesTheFooterInItsOwnWords() {
        let wire = Wire()
        wire.reply = #"{"ok":false,"op":"slice.queue","error":{"kind":"unresolvable","detail":"2 of 25 tracks have no unique match (2 ambiguous)"}}"#
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      resolved: AlbumResolution(tracks: tracks(25), matched: 25))

        s.playAlbum(title: "Top 25", artist: "A", shuffle: false)
        settleStatus(status)

        let text = status.current()?.text ?? ""
        XCTAssertTrue(text.contains("2 of 25 tracks have no unique match (2 ambiguous)"),
                      "the app's own reason was lost; got: \(text)")
        XCTAssertNotEqual(text, "Play failed.", "the refusal was reduced to the label")
        XCTAssertEqual(status.current()?.isError, true)
    }

    /// A track with no album refuses before anything is sent, naming the count.
    func testAnUndescribableTrackRefusesBeforeSendingAnything() {
        let wire = Wire()
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      resolved: AlbumResolution(tracks: tracks(2, album: nil), matched: 2))

        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        settleStatus(status)

        XCTAssertTrue(wire.queued.isEmpty, "sent a queue it could not describe")
        XCTAssertEqual(status.current()?.text,
                       "2 of 2 tracks in 'Album' have no album, so Bridge cannot identify them")
    }
}

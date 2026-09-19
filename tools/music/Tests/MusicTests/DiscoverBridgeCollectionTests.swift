import XCTest
@testable import music

/// Step 2's Discover collection paths: `p` on a rail row and Enter on a track
/// row both reach Bridge as a catalogue-id queue.
///
/// **What these prove that the pure tests cannot.** `discoverPlaySlice` has been
/// correct since 2026-08-30; what was missing was any call site asking the
/// coordinator where the play should go. Each test here fails if the guard is
/// reinstated or the branch is bypassed.
///
/// No network and no AppleScript: the feed's fetch and the lifecycle's side
/// effects are injected.
final class DiscoverBridgeCollectionTests: XCTestCase {

    // MARK: - Harness

    private final class Wire {
        private(set) var lines: [String] = []
        var reply = #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"S1","artist":"A"}}"#

        /// Step 3: in Bridge mode the container's tracks are READ over the wire
        /// too, so one `p` spends two requests. The track read always answers;
        /// `reply` stays the answer to everything else, which is the queue.
        static let tracksReply = """
        {"ok":true,"op":"slice.containerTracks","items":[
          {"id":"801","kind":"song","name":"S1","subtitle":"A"},
          {"id":"802","kind":"song","name":"S2","subtitle":"A"},
          {"id":"803","kind":"song","name":"S3","subtitle":"A"}]}
        """

        var transport: (String, String) throws -> String {
            { [self] _, line in
                lines.append(line)
                return line.contains("slice.containerTracks") ? Self.tracksReply : reply
            }
        }

        var queued: [[String: Any]] {
            lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                 .filter { $0["op"] as? String == "slice.queue" }
        }

        var queuedIDs: [String] { queued.first?["ids"] as? [String] ?? [] }
    }

    /// An album whose three tracks come back from the injected fetch.
    private static let albumTracksJSON = """
    {"data":[{"relationships":{"tracks":{"data":[
      {"id":"801","type":"songs","attributes":{"name":"S1","artistName":"A"}},
      {"id":"802","type":"songs","attributes":{"name":"S2","artistName":"A"}},
      {"id":"803","type":"songs","attributes":{"name":"S3","artistName":"A"}}
    ]}}}]}
    """

    private func feed() -> DiscoverFeed {
        DiscoverFeed(storefront: "us", token: { "t" },
                     fetch: { _ in Data(Self.albumTracksJSON.utf8) })
    }

    /// A lifecycle that records the ids it was asked to create and then stops.
    ///
    /// **Why `create` throws.** These tests assert WHICH branch ran, not that
    /// the Music.app transaction completes — `DiscoverLifecycleTests` owns that,
    /// with its own clock. Letting the real coordinator proceed past `create`
    /// here makes it poll readiness against a stub scheduler and spin forever
    /// (measured: a 600s timeout). Throwing returns `.createFailed` immediately,
    /// after the ids have been captured, which is exactly the observation this
    /// file needs and nothing more.
    private enum StopAfterCreate: Error { case stop }

    private func lifecycle(playsRecorded: @escaping ([String]) -> Void) -> DiscoverLifecycleCoordinator {
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in },
            create: { _, ids in playsRecorded(ids); throw StopAfterCreate.stop },
            readCount: { _ in 0 },
            play: { _ in },
            confirmRead: { _ in "" },
            post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() },
                                         deadline: { _ in Date() },
                                         delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        // `admit` waits for the launch sweep to FINISH before it will mint a
        // transaction, so a coordinator that never ran one blocks every play
        // (measured: the 600s hang above). Production runs it at startup.
        c.completeLaunchSweep(.swept)
        return c
    }

    private func scene(mode: PlaybackMode, wire: Wire, status: StatusStore,
                       lifecycle: DiscoverLifecycleCoordinator) -> DiscoverScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: wire.transport) })
        return DiscoverScene(feed: feed(), status: status,
                             actions: ActionRunner(status: status),
                             api: RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us"),
                             lifecycle: lifecycle,
                             routing: routing,
                             bridgeSelected: { routing.mode == .source })
    }

    private func settle(_ check: @escaping () -> Bool, seconds: Double = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if check() { return }
            usleep(10_000)
        }
    }

    /// The ids arrive on ActionRunner's queue while the test polls, so they
    /// cross a thread boundary and need a lock.
    private final class Recorder {
        private let lock = NSLock()
        private var stored: [String] = []
        func set(_ v: [String]) { lock.lock(); stored = v; lock.unlock() }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private var albumRow: DiscoverItem {
        DiscoverItem(id: "700", name: "An Album", subtitle: "A", url: nil, artworkURL: nil,
                     detail: .album(trackCount: 3, year: 2001, genre: nil))
    }

    // MARK: - `p` on a rail row

    /// The binding: in Bridge mode the whole rail reaches the wire as ids.
    func testPlayAllFromRailInBridgeModeQueuesTheContainersIDs() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      lifecycle: lifecycle(playsRecorded: { _ in }))

        s.playAllFromRail(albumRow)
        settle { !wire.queued.isEmpty }

        XCTAssertEqual(wire.queuedIDs, ["801", "802", "803"])
    }

    /// And Music.app mode still builds its container instead, so the test above
    /// cannot pass with the mode ignored.
    func testPlayAllFromRailInMusicAppModeStillBuildsTheContainer() {
        let wire = Wire()
        let created = Recorder()
        let s = scene(mode: .musicApp, wire: wire, status: StatusStore(),
                      lifecycle: lifecycle(playsRecorded: { created.set($0) }))

        s.playAllFromRail(albumRow)
        settle { !created.ids.isEmpty }

        XCTAssertEqual(created.ids, ["801", "802", "803"])
        XCTAssertTrue(wire.queued.isEmpty, "Music.app mode sent a Bridge request")
    }

    // MARK: - Enter on a track row

    /// Enter means the same thing in both modes now: this row to the end of the
    /// container. Anthony's 2026-09-10 ruling made the one-track behaviour
    /// explicitly TEMPORARY, pending a queue on the wire ("Don't pretend queue
    /// semantics exist yet"); `slice.queue` is that queue.
    func testASelectedSliceInBridgeModeQueuesEveryIDInOrder() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      lifecycle: lifecycle(playsRecorded: { _ in }))

        s.playCatalogSlice(catalogIDs: ["802", "803"], containerTitle: "An Album", trackName: "S2")
        settle { !wire.queued.isEmpty }

        XCTAssertEqual(wire.queuedIDs, ["802", "803"])
    }

    /// A one-row slice is still a queue request, which the app completes at once.
    func testALastRowSliceIsStillAQueueRequest() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, status: StatusStore(),
                      lifecycle: lifecycle(playsRecorded: { _ in }))

        s.playCatalogSlice(catalogIDs: ["803"], containerTitle: "An Album", trackName: "S3")
        settle { !wire.queued.isEmpty }

        XCTAssertEqual(wire.queuedIDs, ["803"])
    }

    func testASelectedSliceInMusicAppModeStillBuildsTheContainer() {
        let wire = Wire()
        let created = Recorder()
        let s = scene(mode: .musicApp, wire: wire, status: StatusStore(),
                      lifecycle: lifecycle(playsRecorded: { created.set($0) }))

        s.playCatalogSlice(catalogIDs: ["802", "803"], containerTitle: "An Album", trackName: "S2")
        settle { !created.ids.isEmpty }

        XCTAssertEqual(created.ids, ["802", "803"])
        XCTAssertTrue(wire.queued.isEmpty, "Music.app mode sent a Bridge request")
    }

    // MARK: - Failures stay visible

    func testABridgeRefusalReachesTheFooterInItsOwnWords() {
        let wire = Wire()
        wire.reply = #"{"ok":false,"op":"slice.queue","error":{"kind":"too_many","detail":"142 songs requested, limit 100"}}"#
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status,
                      lifecycle: lifecycle(playsRecorded: { _ in }))

        s.playAllFromRail(albumRow)
        settle { status.current() != nil }

        let text = status.current()?.text ?? ""
        XCTAssertTrue(text.contains("142 songs requested, limit 100"),
                      "the app's own reason was lost; got: \(text)")
        XCTAssertNotEqual(text, "Play failed.", "the refusal was reduced to the label")
    }
}

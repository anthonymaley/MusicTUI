import XCTest
@testable import music

/// Step 4: the Now tab's view of Bridge, from `slice.status` alone.
///
/// Three counters live on the wire and none may stand in for another: songs
/// ready while building, the playback index, and the songs built before an
/// invalid queue failed. Most of these tests exist to keep them apart.
final class BridgeNowTests: XCTestCase {

    private func status(playback: String = "playing", readiness: SourceReadiness = .ready,
                        phase: String? = nil, requested: Int? = nil, present: Int? = nil,
                        reason: String? = nil, built: Int? = nil, index: Int? = nil) -> SourceStatus {
        SourceStatus(playback: playback, title: "Teardrop", artist: "Massive Attack",
                     readiness: readiness, queuePhase: phase, queueRequested: requested,
                     queuePresent: present, queueReason: reason, queueBuiltBeforeFailure: built,
                     queueIndex: index)
    }

    private struct Down: Error {}

    // MARK: - bridgeNow(from:)

    func testEveryPhaseMapsForEveryPlayback() {
        for playback in ["playing", "paused", "loading", "idle", "stopped"] {
            XCTAssertEqual(bridgeNow(from: status(playback: playback)).queue, BridgeNow.Queue.none)
            XCTAssertEqual(bridgeNow(from: status(playback: playback, phase: "none", requested: 0)).queue,
                           BridgeNow.Queue.none)
            XCTAssertEqual(bridgeNow(from: status(playback: playback, phase: "building",
                                                  requested: 12, present: 5)).queue,
                           .building(ready: 5, requested: 12))
            XCTAssertEqual(bridgeNow(from: status(playback: playback, phase: "complete",
                                                  requested: 12, present: 12)).queue,
                           .complete(requested: 12))
            XCTAssertEqual(bridgeNow(from: status(playback: playback, phase: "mystery", requested: 3)).queue,
                           BridgeNow.Queue.none, "an unknown phase must not be guessed at")
            let b = bridgeNow(from: status(playback: playback))
            XCTAssertEqual(b.playback, playback)
            XCTAssertEqual(b.link, .answering)
            XCTAssertEqual(b.title, "Teardrop")
            XCTAssertEqual(b.artist, "Massive Attack")
        }
    }

    func testInvalidKeepsReasonAndHistoryAndDoesNotReadPresentAsZero() {
        let b = bridgeNow(from: status(playback: "stopped", phase: "invalid", requested: 12,
                                       present: nil, reason: "a song was removed", built: 7))
        XCTAssertEqual(b.queue, .invalid(reason: "a song was removed", built: 7, requested: 12))
        XCTAssertEqual(bridgeStatusLine(b), "Stopped: a song was removed. 7 of 12 built.")
        XCTAssertFalse(bridgeStatusLine(b)!.contains("0 of"), "nil present rendered as zero")
    }

    /// Bridge's reason can end with a system error's own full stop
    /// (`insert 3 of 9 failed: <error>`); the line must not double it.
    func testAReasonEndingInAStopIsNotDoubled() {
        let b = bridgeNow(from: status(playback: "stopped", phase: "invalid", requested: 9,
                                       present: nil, reason: "insert 3 of 9 failed: The operation couldn't be completed.",
                                       built: 2))
        XCTAssertEqual(bridgeStatusLine(b),
                       "Stopped: insert 3 of 9 failed: The operation couldn't be completed. 2 of 9 built.")
    }

    func testInvalidWithNoReasonUsesTheDefault() {
        let b = bridgeNow(from: status(phase: "invalid", requested: 4))
        XCTAssertEqual(b.queue, .invalid(reason: "the queue could not be built", built: nil, requested: 4))
        XCTAssertEqual(bridgeStatusLine(b), "Stopped: the queue could not be built.")
    }

    func testAnUnreadyReplyShowsItsReasonAtOnce() {
        for reason in ["Bridge was denied Apple Music access",
                       "Bridge speaks a different version (3); update one of them"] {
            let b = bridgeNow(from: status(readiness: .unavailable(reason)))
            XCTAssertEqual(b.link, .unavailable(reason))
            XCTAssertEqual(bridgeStatusLine(b), reason + ".")
            // Through the tracker too: a successful reply is never graced.
            var t = BridgeLinkTracker()
            XCTAssertEqual(bridgeStatusLine(t.record(.success(status(readiness: .unavailable(reason))))),
                           reason + ".")
        }
        XCTAssertEqual(bridgeStatusLine(bridgeNow(from: status(readiness: .unavailable("Already said.")))),
                       "Already said.", "a full stop is added only when missing")
    }

    // MARK: - BridgeLinkTracker

    func testOneMissAfterAGoodStateKeepsIt() {
        var t = BridgeLinkTracker()
        let good = t.record(.success(status(phase: "complete", requested: 3, index: 1)))
        XCTAssertEqual(t.record(.failure(Down())), good)
        XCTAssertTrue(t.inGrace)
    }

    func testTwoConsecutiveMissesAreNotResponding() {
        var t = BridgeLinkTracker()
        _ = t.record(.success(status(phase: "complete", requested: 3, index: 1)))
        _ = t.record(.failure(Down()))
        let gone = t.record(.failure(Down()))
        XCTAssertEqual(gone.link, .notResponding)
        XCTAssertEqual(gone.playback, "stopped")
        XCTAssertEqual(gone.queue, BridgeNow.Queue.none)
        XCTAssertNil(gone.index)
        XCTAssertEqual(bridgeStatusLine(gone), "Bridge is not responding.")
        XCTAssertFalse(t.inGrace)
    }

    func testAlternatingFailuresAreNeverNotResponding() {
        var t = BridgeLinkTracker()
        for _ in 0..<5 {
            XCTAssertNotEqual(t.record(.failure(Down())).link, .notResponding)
            XCTAssertEqual(t.record(.success(status())).link, .answering)
        }
    }

    func testFirstEverFailureIsChecking() {
        var t = BridgeLinkTracker()
        let b = t.record(.failure(Down()))
        XCTAssertEqual(b, BridgeNow.empty)
        XCTAssertEqual(b.link, .checking)
        XCTAssertEqual(bridgeStatusLine(b), "Checking Bridge\u{2026}")
    }

    // MARK: - Lines

    private func now(link: BridgeNow.Link = .answering, playback: String = "playing",
                     queue: BridgeNow.Queue = .none, index: Int? = nil) -> BridgeNow {
        BridgeNow(link: link, playback: playback, title: "", artist: "", queue: queue, index: index)
    }

    func testEveryStatusString() {
        XCTAssertEqual(bridgeStatusLine(now(link: .checking)), "Checking Bridge\u{2026}")
        XCTAssertEqual(bridgeStatusLine(now(link: .notResponding)), "Bridge is not responding.")
        XCTAssertEqual(bridgeStatusLine(now(link: .unavailable("Nope"))), "Nope.")
        XCTAssertEqual(bridgeStatusLine(now(queue: .invalid(reason: "r", built: 2, requested: 9))),
                       "Stopped: r. 2 of 9 built.")
        XCTAssertEqual(bridgeStatusLine(now(queue: .invalid(reason: "r", built: nil, requested: 9))),
                       "Stopped: r.")
        XCTAssertEqual(bridgeStatusLine(now(playback: "loading")), "Loading\u{2026}")
        XCTAssertEqual(bridgeStatusLine(now(queue: .building(ready: 3, requested: 10))),
                       "Building queue: 3 of 10 ready.")
        XCTAssertEqual(bridgeStatusLine(now(queue: .building(ready: nil, requested: 10))),
                       "Building queue of 10\u{2026}")
        XCTAssertNil(bridgeStatusLine(now()))
        XCTAssertNil(bridgeStatusLine(now(queue: .complete(requested: 10), index: 2)))
    }

    func testStatusPrecedence() {
        let building = BridgeNow.Queue.building(ready: 3, requested: 10)
        let invalid = BridgeNow.Queue.invalid(reason: "r", built: 2, requested: 9)
        XCTAssertEqual(bridgeStatusLine(now(link: .checking, playback: "loading", queue: invalid)),
                       "Checking Bridge\u{2026}", "link comes first")
        XCTAssertEqual(bridgeStatusLine(now(link: .unavailable("x"), queue: building)), "x.")
        XCTAssertEqual(bridgeStatusLine(now(playback: "loading", queue: invalid)),
                       "Stopped: r. 2 of 9 built.", "invalid before loading")
        XCTAssertEqual(bridgeStatusLine(now(playback: "loading", queue: building)),
                       "Loading\u{2026}", "loading before building")
    }

    func testPositionLine() {
        XCTAssertEqual(bridgePositionLine(now(queue: .complete(requested: 12), index: 0)), "Song 1 of 12")
        XCTAssertEqual(bridgePositionLine(now(queue: .building(ready: 4, requested: 12), index: 3)),
                       "Song 4 of 12")
        XCTAssertNil(bridgePositionLine(now(queue: .complete(requested: 12), index: nil)))
        XCTAssertNil(bridgePositionLine(now(queue: .complete(requested: 12), index: 12)))
        XCTAssertNil(bridgePositionLine(now(queue: .complete(requested: 0), index: 0)))
        XCTAssertNil(bridgePositionLine(now(queue: .none, index: 0)))
        XCTAssertNil(bridgePositionLine(now(queue: .invalid(reason: "r", built: 5, requested: 9), index: 1)))
        // Never inferred from ready-count: building with 5 ready and no index says nothing.
        XCTAssertNil(bridgePositionLine(now(queue: .building(ready: 5, requested: 9), index: nil)))
    }

    // MARK: - The wire

    func testStatusDecodesReasonBuiltAndIndex() throws {
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"stopped","contract":2,"authorization":"authorized","title":"T","artist":"A","queue":{"phase":"invalid","requested":12,"present":null,"reason":"a song was removed","built_before_failure":7,"index":3}}}"#
        let control = SourceAppControl(path: "/nonexistent", transport: { _, _ in reply })
        let s = try control.status()
        XCTAssertEqual(s.queuePhase, "invalid")
        XCTAssertEqual(s.queueRequested, 12)
        XCTAssertNil(s.queuePresent)
        XCTAssertEqual(s.queueReason, "a song was removed")
        XCTAssertEqual(s.queueBuiltBeforeFailure, 7)
        XCTAssertEqual(s.queueIndex, 3)
    }

    func testStatusWithoutTheNewFieldsDecodesThemAsNil() throws {
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":2,"authorization":"authorized","queue":{"phase":"building","requested":5,"present":2}}}"#
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
        XCTAssertEqual(s.queuePresent, 2)
        XCTAssertNil(s.queueReason)
        XCTAssertNil(s.queueBuiltBeforeFailure)
        XCTAssertNil(s.queueIndex)
    }

    // MARK: - Now scene and footer

    private func scene(mode: PlaybackMode) -> NowPlayingScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let statusStore = StatusStore()
        return NowPlayingScene(backend: AppleScriptBackend(), appQueue: AppQueueStore(),
                               status: statusStore, actions: ActionRunner(status: statusStore),
                               routing: RoutingCoordinator(store: store, surface: .tui,
                                                           makeSource: { SourceAppClient(path: "/nonexistent") }))
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private let frame = shellLayout(width: 120, height: 40)

    func testMusicAppEmptyStateAndFooterAreUnchanged() {
        let s = scene(mode: .musicApp)
        let out = s.render(frame: frame, snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
        XCTAssertTrue(out.contains("\(ANSICode.dim)Nothing playing \u{2014} press \(ANSICode.reset)2\(ANSICode.dim) to browse playlists, \(ANSICode.reset)z\(ANSICode.dim) to shuffle.\(ANSICode.reset)"))
        XCTAssertEqual(s.footerHint,
                       "\u{2191}\u{2193} Browse  \u{2190} Controls  Enter Jump  [ ] Seek  l \u{2665}")
        _ = s.handle(.left)
        XCTAssertEqual(s.footerHint,
                       "\u{2191}\u{2193} Row  Enter Set  \u{2192} Up Next  [ ] Seek  \u{2014} controls")
        XCTAssertEqual(shellFooterGlobals(mode: .musicApp),
                       "Space \u{23EF}  < > Skip  z Reshuffle  +/\u{2212} Vol")
    }

    func testBridgeFooterAndGridKeys() {
        let s = scene(mode: .source)
        XCTAssertEqual(s.footerHint, "[ ] Seek")
        XCTAssertEqual(s.handle(.left), .none, "← must not focus a grid Bridge does not draw")
        XCTAssertEqual(s.footerHint, "[ ] Seek")
        XCTAssertEqual(shellFooterGlobals(mode: .source), "Space \u{23EF}  < > Skip")
    }

    /// Codex review `3e0b9efd`: `n` opened a menu whose Shuffle named Music.app's
    /// last context and refused only once chosen. On Bridge the menu offers what
    /// Bridge honours (spec 6.2): Playlist and Quiet.
    func testBridgeContinuationMenuOffersNoShuffle() {
        XCTAssertEqual(continuationOptions(bridge: true), [.playlist, .quiet])
        let s = scene(mode: .source)
        var snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        snap.bridge = BridgeNow(link: .answering, playback: "idle", title: "", artist: "", queue: .none, index: nil)
        XCTAssertEqual(s.handle(.char("n")), .redraw)
        s.tick(snapshot: snap)
        let out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("What next?"))
        XCTAssertTrue(out.contains("[P]  Playlist"))
        XCTAssertTrue(out.contains("[X]  Quiet"))
        XCTAssertFalse(out.contains("Shuffle  "), "Bridge menu must not offer Shuffle")
        // `s` is swallowed while the menu is up: no action, no refusal, menu stays.
        XCTAssertEqual(s.handle(.char("s")), .none)
        s.tick(snapshot: snap)
        XCTAssertTrue(plain(s.render(frame: frame, snapshot: snap)).contains("What next?"))
    }

    func testMusicAppContinuationMenuStillOffersShuffle() {
        XCTAssertEqual(continuationOptions(bridge: false), [.shuffle, .playlist, .quiet])
        let s = scene(mode: .musicApp)
        let snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        _ = s.handle(.char("n"))
        s.tick(snapshot: snap)
        let out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("[S]  Shuffle"))
        XCTAssertTrue(out.contains("[P]  Playlist"))
        XCTAssertTrue(out.contains("[X]  Quiet"))
    }

    func testBridgeEmptyState() {
        let s = scene(mode: .source)
        var snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        snap.bridge = BridgeNow(link: .answering, playback: "idle", title: "", artist: "", queue: .none, index: nil)
        var out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("Nothing playing on Bridge."))
        XCTAssertTrue(out.contains("Press 4 to browse playlists, 3 for Library."))
        XCTAssertFalse(out.contains("z to shuffle"))

        snap.bridge = BridgeNow(link: .notResponding, playback: "stopped", title: "", artist: "", queue: .none, index: nil)
        out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("Bridge is not responding."))
        XCTAssertFalse(out.contains("Nothing playing"))
    }

    func testBridgeActiveShowsStatusPositionAndNoGridOrUpNext() {
        let s = scene(mode: .source)
        var np = NowPlayingState()
        np.track = "Teardrop"; np.artist = "Massive Attack"; np.state = "playing"
        var snap = NowPlayingSnapshot(outcome: .active(np), history: [],
                                      surrounding: [TrackListEntry(index: 1, name: "Stale", artist: "Music.app", isCurrent: true)])
        snap.bridge = BridgeNow(link: .answering, playback: "playing", title: "Teardrop", artist: "Massive Attack",
                                queue: .building(ready: 4, requested: 12), index: 1)
        let out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("Teardrop"))
        XCTAssertTrue(out.contains("Building queue: 4 of 12 ready."))
        XCTAssertTrue(out.contains("Song 2 of 12"))
        XCTAssertTrue(out.contains("Shuffle and repeat are not available on Bridge."))
        XCTAssertFalse(out.contains("Up Next"))
        XCTAssertFalse(out.contains("Stale"))
        XCTAssertFalse(out.contains("Order") || out.contains("Genius"), "the control grid was drawn")
    }

    // MARK: - Poller

    private func poller(mode: PlaybackMode, store: NowPlayingStore,
                        reply: @escaping () throws -> String) -> PlaybackPoller {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(mode)
        let client = { SourceAppClient(path: "/nonexistent", transport: { _, _ in try reply() }) }
        return PlaybackPoller(store: store, backend: AppleScriptBackend(), appQueue: AppQueueStore(),
                              queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                              routing: RoutingCoordinator(store: modeStore, surface: .tui, makeSource: client),
                              makeSourceClient: client)
    }

    func testPollerCarriesBridgeAndKeepsTheOutcomeThroughOneMiss() {
        let playing = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":2,"authorization":"authorized","title":"Teardrop","artist":"Massive Attack","queue":{"phase":"complete","requested":3,"present":3,"index":0}}}"#
        var fail = false
        let store = NowPlayingStore()
        let p = poller(mode: .source, store: store, reply: {
            if fail { throw SourceAppError.timedOut }
            return playing
        })

        p.tick()
        var snap = store.read()
        guard case .active(let np) = snap.outcome else { return XCTFail("expected active, got \(snap.outcome)") }
        XCTAssertEqual(np.track, "Teardrop")
        XCTAssertEqual(snap.bridge?.link, .answering)
        XCTAssertEqual(snap.bridge.flatMap(bridgePositionLine), "Song 1 of 3")

        fail = true
        p.tick()
        snap = store.read()
        guard case .active(let kept) = snap.outcome else { return XCTFail("one miss dropped the outcome") }
        XCTAssertEqual(kept.track, "Teardrop")
        XCTAssertEqual(snap.bridge?.link, .answering)

        p.tick()
        snap = store.read()
        guard case .stopped = snap.outcome else { return XCTFail("two misses should stop") }
        XCTAssertEqual(snap.bridge?.link, .notResponding)
    }

    func testMusicAppSnapshotHasNoBridge() {
        XCTAssertNil(NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []).bridge)
    }
}

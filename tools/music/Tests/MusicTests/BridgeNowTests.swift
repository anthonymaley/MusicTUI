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
        for reason in ["SpanDAC was denied Apple Music access",
                       "SpanDAC speaks a different version (3); update one of them"] {
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
        XCTAssertEqual(bridgeStatusLine(gone), "SpanDAC is not responding.")
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
        XCTAssertEqual(bridgeStatusLine(b), "Checking SpanDAC\u{2026}")
    }

    // MARK: - Fewer songs present than requested

    /// SpanDAC may queue fewer songs than the client asked for. That is a
    /// complete queue of the songs it has, never a failure and never retried.
    func testACompleteQueueWithFewerPresentThanRequestedIsComplete() {
        let b = bridgeNow(from: status(phase: "complete", requested: 800, present: 796, index: 0))
        XCTAssertEqual(b.queue, .complete(requested: 800, present: 796))
        XCTAssertEqual(b.link, .answering)
        XCTAssertEqual(bridgeStatusLine(b), "796 of 800 queued.")
    }

    func testAFullCompleteQueueSaysNothingAboutCounts() {
        XCTAssertNil(bridgeStatusLine(bridgeNow(from: status(phase: "complete", requested: 800, present: 800))))
        XCTAssertNil(bridgeStatusLine(bridgeNow(from: status(phase: "complete", requested: 800))),
                     "a SpanDAC that sends no present count is read as before")
    }

    func testThePositionOfAShortQueueCountsOnlyTheSongsThatAreThere() {
        XCTAssertEqual(bridgePositionLine(now(queue: .complete(requested: 800, present: 796), index: 4)),
                       "Song 5 of 796")
        XCTAssertNil(bridgePositionLine(now(queue: .complete(requested: 800, present: 796), index: 796)))
    }

    func testAShortCompleteQueueKeepsLoadingAndLinkPrecedence() {
        let short = BridgeNow.Queue.complete(requested: 800, present: 796)
        XCTAssertEqual(bridgeStatusLine(now(playback: "loading", queue: short)), "Loading\u{2026}")
        XCTAssertEqual(bridgeStatusLine(now(link: .notResponding, queue: short)), "SpanDAC is not responding.")
    }

    func testTheNowJSONCarriesBothCountsUntouched() {
        let json = bridgeNowJSON(status(phase: "complete", requested: 800, present: 796))
        let queue = json["queue"] as? [String: Any]
        XCTAssertEqual(queue?["requested"] as? Int, 800)
        XCTAssertEqual(queue?["present"] as? Int, 796)
    }

    // MARK: - Lines

    private func now(link: BridgeNow.Link = .answering, playback: String = "playing",
                     queue: BridgeNow.Queue = .none, index: Int? = nil) -> BridgeNow {
        BridgeNow(link: link, playback: playback, title: "", artist: "", queue: queue, index: index)
    }

    func testEveryStatusString() {
        XCTAssertEqual(bridgeStatusLine(now(link: .checking)), "Checking SpanDAC\u{2026}")
        XCTAssertEqual(bridgeStatusLine(now(link: .notResponding)), "SpanDAC is not responding.")
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
                       "Checking SpanDAC\u{2026}", "link comes first")
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
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"stopped","contract":3,"authorization":"authorized","title":"T","artist":"A","queue":{"phase":"invalid","requested":12,"present":null,"reason":"a song was removed","built_before_failure":7,"index":3}}}"#
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
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","queue":{"phase":"building","requested":5,"present":2}}}"#
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
        XCTAssertEqual(s.queuePresent, 2)
        XCTAssertNil(s.queueReason)
        XCTAssertNil(s.queueBuiltBeforeFailure)
        XCTAssertNil(s.queueIndex)
    }

    func testStatusDecodesFewerPresentThanRequested() throws {
        let reply = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"T","artist":"A","queue":{"phase":"complete","requested":800,"present":796,"index":2}}}"#
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
        XCTAssertEqual(s.queuePhase, "complete")
        XCTAssertEqual(s.queueRequested, 800)
        XCTAssertEqual(s.queuePresent, 796)
        XCTAssertEqual(s.readiness, .ready)
    }

    // MARK: - Now scene and footer

    private func scene(mode: PlaybackMode) -> NowPlayingScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let statusStore = StatusStore()
        return NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
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
        XCTAssertTrue(out.contains("\(ANSICode.dim)Nothing playing \u{2014} press \(ANSICode.reset)4\(ANSICode.dim) to browse playlists, \(ANSICode.reset)z\(ANSICode.dim) to shuffle.\(ANSICode.reset)"))
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
        XCTAssertEqual(s.footerHint, "[ ] Seek  x Quiet")
        XCTAssertEqual(s.handle(.left), .none, "← must not focus a grid SpanDAC does not draw")
        XCTAssertEqual(s.footerHint, "[ ] Seek  x Quiet")
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
        XCTAssertFalse(out.contains("Shuffle  "), "SpanDAC menu must not offer Shuffle")
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
        XCTAssertTrue(out.contains("Nothing playing on SpanDAC."))
        XCTAssertTrue(out.contains("Press 4 to browse playlists, 3 for Library."))
        XCTAssertFalse(out.contains("z to shuffle"))

        snap.bridge = BridgeNow(link: .notResponding, playback: "stopped", title: "", artist: "", queue: .none, index: nil)
        out = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("SpanDAC is not responding."))
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
        XCTAssertTrue(out.contains("Shuffle and repeat aren't available on SpanDAC."))
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
        return PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                              queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                              routing: RoutingCoordinator(store: modeStore, surface: .tui, makeSource: client),
                              makeSourceClient: client)
    }

    func testPollerCarriesBridgeAndKeepsTheOutcomeThroughOneMiss() {
        let playing = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"Teardrop","artist":"Massive Attack","queue":{"phase":"complete","requested":3,"present":3,"index":0}}}"#
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

    // MARK: - Optional elapsed time, duration and artwork (SpanDAC 2026-10-05)

    private let cover = "https://is1-ssl.mzstatic.com/image/thumb/Music/house/600x600bb.jpg"

    private func playingReply(extra: String) -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"playing","contract":3,"authorization":"authorized","title":"Teardrop","artist":"Massive Attack"\#(extra),"queue":{"phase":"complete","requested":275,"present":275,"index":0}}}"#
    }

    func testStatusDecodesTimesAndArtworkWhenPresent() throws {
        let reply = playingReply(extra: #","position_s":65.4,"duration_s":312,"artwork_url":"\#(cover)""#)
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
        XCTAssertEqual(s.positionSeconds, 65.4)
        XCTAssertEqual(s.durationSeconds, 312, "an integral JSON number is still seconds")
        XCTAssertEqual(s.artworkURL, cover)
        XCTAssertEqual(bridgeNow(from: s).artworkURL, cover)
    }

    func testStatusWithoutTimesOrArtworkReadsAsBefore() throws {
        let absent = try SourceAppControl(path: "/nonexistent", transport: { _, _ in self.playingReply(extra: "") }).status()
        XCTAssertNil(absent.positionSeconds)
        XCTAssertNil(absent.durationSeconds)
        XCTAssertNil(absent.artworkURL)
        XCTAssertNil(bridgeNow(from: absent).artworkURL)
        // Malformed values are unknown, not a failed reply.
        let bad = playingReply(extra: #","position_s":-3,"duration_s":"long","artwork_url":"""#)
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in bad }).status()
        XCTAssertNil(s.positionSeconds)
        XCTAssertNil(s.durationSeconds)
        XCTAssertNil(s.artworkURL)
        XCTAssertEqual(s.title, "Teardrop")
    }

    /// The poller fills the same fields the Music.app path fills, so the Now
    /// tab's existing progress bar draws SpanDAC's times.
    func testPollerPutsSpanDACTimesOnTheNowModelAndTheBarDrawsThem() {
        let store = NowPlayingStore()
        let p = poller(mode: .source, store: store, reply: {
            self.playingReply(extra: #","position_s":65.9,"duration_s":312.2,"artwork_url":"\#(self.cover)""#)
        })
        p.tick()
        var snap = store.read()
        guard case .active(let np) = snap.outcome else { return XCTFail("expected active, got \(snap.outcome)") }
        XCTAssertEqual(np.position, 65)
        XCTAssertEqual(np.duration, 312)
        XCTAssertEqual(snap.bridge?.artworkURL, cover)

        // Rendered without the URL so the test fetches nothing over the network.
        snap.bridge?.artworkURL = nil
        let out = plain(scene(mode: .source).render(frame: frame, snapshot: snap))
        XCTAssertTrue(out.contains("1:05"), "elapsed time missing")
        XCTAssertTrue(out.contains("5:12"), "duration missing")
        XCTAssertTrue(out.contains("\u{25CF}"), "progress knob missing")
    }

    func testPollerWithoutTimesDrawsNoBar() {
        let store = NowPlayingStore()
        let p = poller(mode: .source, store: store, reply: { self.playingReply(extra: "") })
        p.tick()
        let snap = store.read()
        guard case .active(let np) = snap.outcome else { return XCTFail("expected active, got \(snap.outcome)") }
        XCTAssertEqual(np.duration, 0)
        XCTAssertEqual(np.position, 0)
        XCTAssertNil(snap.bridge?.artworkURL)
        XCTAssertFalse(plain(scene(mode: .source).render(frame: frame, snapshot: snap)).contains("0:00"))
    }
}

/// Spec 6.2 lists `x` as Quiet on the Now tab, but until 2026-09-22 the key
/// only acted inside the "What next?" card, so the documented key did nothing
/// on the screen that documents it.
///
/// **Bridge mode only, deliberately.** Quiet in Music.app mode runs a real
/// `pause` through AppleScript, so a test pressing `x` there would pause the
/// machine's Music.app while the suite ran. The Bridge branch talks to a dead
/// socket and touches nothing. Where the key ROUTES in each mode is already
/// pinned by `ActionRoutingTests`; what is new here is that the key arrives.
final class NowQuietKeyTests: XCTestCase {

    private func scene() -> NowPlayingScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let status = StatusStore()
        return NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               status: status, actions: ActionRunner(status: status),
                               routing: RoutingCoordinator(store: store, surface: .tui,
                                                           makeSource: { SourceAppClient(path: "/nonexistent") }))
    }

    func testBothSpellingsAreConsumedOnTheNowTab() {
        for key in [KeyPress.char("x"), .char("X")] {
            XCTAssertEqual(scene().handle(key), .redraw, "\(key) must run Quiet, not fall through")
        }
    }

    /// The menu keeps its own entry, and `x` there still means that entry.
    func testTheMenuEntryIsUnchanged() {
        XCTAssertEqual(continuationAction(for: .char("x")), .quiet)
        XCTAssertEqual(continuationAction(for: .char("X")), .quiet)
        XCTAssertTrue(continuationOptions(bridge: true).contains(.quiet))
    }

    func testBridgeFooterNowOffersQuiet() {
        XCTAssertEqual(scene().footerHint, "[ ] Seek  x Quiet")
    }

    // MARK: - Quiet on a Bridge that is already quiet

    private func scene(status: StatusStore, reply: @escaping (String, String) throws -> String) -> NowPlayingScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        return NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               status: status, actions: ActionRunner(status: status),
                               routing: RoutingCoordinator(store: store, surface: .tui,
                                                           makeSource: { SourceAppClient(path: "/nonexistent",
                                                                                         transport: reply) }))
    }

    private func settle(_ status: StatusStore, seconds: Double = 2.0) -> StatusToast? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let toast = status.current() { return toast }
            usleep(20_000)
        }
        return nil
    }

    private func reply(playback: String) -> (String, String) throws -> String {
        { _, line in
            if line.contains("slice.pause") {
                // What the real app answers with nothing to pause.
                return #"{"ok":false,"op":"slice.pause","error":{"kind":"bad_request","detail":"did not reach paused within 3s"}}"#
            }
            return #"{"ok":true,"op":"slice.status","status":{"playback":"\#(playback)","contract":3,"authorization":"authorized"}}"#
        }
    }

    /// The defect: `x` on an idle Bridge said "Pause failed." (seen live
    /// 2026-09-22). Nothing was playing, so there was nothing to fail.
    func testQuietOnAnIdleBridgeSaysNothing() {
        let status = StatusStore()
        _ = scene(status: status, reply: reply(playback: "idle")).handle(.char("x"))
        XCTAssertNil(settle(status), "Quiet on a quiet player must not post an error")
    }

    /// Still an error when Bridge says it is playing after the attempt: a pause
    /// that did not take is a real failure, and rule 4's positive evidence holds.
    func testQuietStillReportsAPlayerThatKeepsGoing() {
        let status = StatusStore()
        _ = scene(status: status, reply: reply(playback: "playing")).handle(.char("x"))
        let toast = settle(status)
        XCTAssertEqual(toast?.text, "Couldn't pause SpanDAC.")
        XCTAssertTrue(toast?.isError ?? false)
    }
}

// tools/music/Tests/MusicTests/SpanDACNetworkRoutingTests.swift
//
// A SpanDAC on the network as a selected output (the pairing design, 4.2):
// the same routing as the Mac's own SpanDAC, a client built for THAT device
// only, and no fallback anywhere once it is selected.
import XCTest
@testable import music

final class SpanDACNetworkRoutingTests: XCTestCase {

    private let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
    private let other = "6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91"

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "spandac-routing-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private final class Recorder {
        private let lock = NSLock()
        private var _made: [PlaybackMode] = []
        private var _sent: [(PlaybackMode, String)] = []
        var made: [PlaybackMode] { lock.lock(); defer { lock.unlock() }; return _made }
        var sent: [(PlaybackMode, String)] { lock.lock(); defer { lock.unlock() }; return _sent }
        func make(_ mode: PlaybackMode, reply: String? = nil, error: Error? = nil) -> SourceAppClient {
            lock.lock(); _made.append(mode); lock.unlock()
            return SourceAppClient(path: "/fake", transport: { [self] _, line in
                lock.lock(); _sent.append((mode, line)); lock.unlock()
                if let error { throw error }
                return reply ?? #"{"ok":true,"status":{"playback":"paused","authorization":"authorized","contract":3,"capabilities":[]}}"#
            })
        }
    }

    private func coordinator(_ mode: PlaybackMode, _ recorder: Recorder,
                             failWith error: Error? = nil) -> RoutingCoordinator {
        let store = PlaybackModeStore(path: tempDir() + "/mode.json")
        store.set(mode)
        return RoutingCoordinator(store: store, surface: .tui, makeSourceFor: { recorder.make($0, error: error) })
    }

    // MARK: - The matrix

    /// `.networkSource` routes exactly as `.source`, for every action on both
    /// surfaces: one case added, no new policy (4.2).
    func testTheNetworkModeRoutesExactlyAsTheMacsOwnSpanDAC() {
        for surface in InvocationSurface.allCases {
            for action in MusicTUIAction.allCases {
                XCTAssertEqual(routeAction(action, in: .networkSource(ipad), from: surface),
                               routeAction(action, in: .source, from: surface), "\(action) on \(surface)")
            }
        }
        for action in MusicTUIAction.allCases {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .networkSource(ipad)),
                           cliBridgeRefusal(action, mode: .source), "\(action)")
        }
    }

    // MARK: - Which client

    /// A network selection builds the client for THAT SpanDAC, and a source
    /// action runs on it.
    func testASourceActionRunsOnTheSelectedNetworkSpanDAC() throws {
        let r = Recorder()
        let c = coordinator(.networkSource(ipad), r)
        try c.perform(.next, musicApp: { XCTFail("Music.app ran") },
                      source: { try $0.control.next() }, unaffected: { XCTFail("unaffected ran") })
        XCTAssertEqual(r.made, [.networkSource(ipad)])
        XCTAssertEqual(r.sent.map(\.0), [.networkSource(ipad)])
        XCTAssertEqual(r.sent.first?.1, #"{"op":"slice.next"}"#)
    }

    /// After a switch from one SpanDAC to another, the old one's client is
    /// never handed out again.
    func testASwitchBetweenTwoSpanDACsNeverReusesTheOldClient() throws {
        let r = Recorder()
        let c = coordinator(.networkSource(ipad), r)
        try c.perform(.next, musicApp: {}, source: { try $0.control.next() }, unaffected: {})
        let result = try c.switchMode(to: .networkSource(other), readiness: { .ready },
                                      pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(result, .switched(to: .networkSource(other)))
        try c.perform(.next, musicApp: {}, source: { try $0.control.next() }, unaffected: {})
        XCTAssertEqual(r.sent.map(\.0), [.networkSource(ipad), .networkSource(other)])
    }

    /// The old composition (a factory for the Mac's socket only) cannot reach
    /// a network SpanDAC, and it refuses rather than using the Mac's socket.
    func testACoordinatorWithoutTheNetworkRefusesANetworkSelection() {
        let store = PlaybackModeStore(path: tempDir() + "/mode.json")
        store.set(.networkSource(ipad))
        var localBuilt = 0
        let c = RoutingCoordinator(store: store, surface: .tui, makeSource: {
            localBuilt += 1
            return SourceAppClient(path: "/fake", transport: { _, _ in #"{"ok":true}"# })
        })
        XCTAssertThrowsError(try c.perform(.next, musicApp: {}, source: { try $0.control.next() }, unaffected: {})) {
            XCTAssertEqual($0 as? SourceAppError, .link(.notPaired))
        }
        XCTAssertEqual(localBuilt, 0, "the Mac's own SpanDAC must never stand in for the selected iPad")
    }

    // MARK: - Fail closed (Stage 3 caution)

    /// A selected SpanDAC that cannot be reached returns its error and stops:
    /// no other client is built, Music.app never runs, nothing is retried.
    func testAnUnreachableSelectedSpanDACFailsClosed() {
        for failure in [SpanDACLinkFailure.notFound, .asleep, .refused(-9864), .unsafeCipher, .noAnswer] {
            let r = Recorder()
            let c = coordinator(.networkSource(ipad), r, failWith: SourceAppError.link(failure))
            var musicAppRan = false
            XCTAssertThrowsError(try c.perform(.playPause, musicApp: { musicAppRan = true },
                                               source: { try $0.control.pause() }, unaffected: {})) {
                XCTAssertEqual($0 as? SourceAppError, .link(failure))
            }
            XCTAssertFalse(musicAppRan, "\(failure)")
            XCTAssertEqual(r.made, [.networkSource(ipad)], "\(failure): only the selected SpanDAC is ever built")
            XCTAssertEqual(r.sent.count, 1, "\(failure): sent once, never retried")
        }
    }

    /// Selecting a SpanDAC that is not ready is refused with its own reason,
    /// and the current output stays.
    func testSelectingANetworkSpanDACThatIsNotReadyIsRefusedInItsOwnWords() {
        let r = Recorder()
        let c = coordinator(.musicApp, r)
        XCTAssertThrowsError(try c.switchMode(to: .networkSource(ipad),
                                              readiness: { SourceReadiness.from(SourceAppError.link(.refused(-9864))) },
                                              pauseOutgoing: { _ in XCTFail("paused before readiness"); return true },
                                              dropQueue: { _ in })) {
            XCTAssertEqual(($0 as? ActionError)?.message,
                           "SpanDAC no longer recognises this Mac; pair again. Still using Music.app.")
        }
        XCTAssertEqual(c.mode, .musicApp)
    }

    // MARK: - The factory

    private func pairedStore(with record: SpanDACPairRecord? = nil) -> SpanDACPairedStore {
        let store = SpanDACPairedStore(path: tempDir() + "/spandac/paired.json")
        if let record { try! store.save(record) }
        return store
    }

    private func record(_ id: String) -> SpanDACPairRecord {
        SpanDACPairRecord(sourceID: id, sourceName: "Test iPad", pskID: String(repeating: "ab", count: 16),
                          pairKey: Data(repeating: 7, count: 32), serviceName: id, pairedAt: Date())
    }

    /// With no pair on this Mac, every request fails as not paired, before
    /// any network work.
    func testTheNetworkClientWithNoPairFailsClosedBeforeTouchingTheNetwork() {
        var transports = 0
        let client = SourceAppClient.network(sourceID: ipad, pairs: pairedStore(),
                                             makeTransport: { transports += 1; return SpanDACTLSTransport(record: $0) })
        XCTAssertThrowsError(try client.control.status()) {
            XCTAssertEqual($0 as? SourceAppError, .link(.notPaired))
        }
        XCTAssertEqual(transports, 0)
        XCTAssertEqual(client.readiness(), .unavailable(SpanDACLinkFailure.notPaired.sentence))
    }

    /// With a pair, each request builds the transport for THAT pair, looked
    /// up fresh (so a forget is honoured at the next request).
    func testTheNetworkClientUsesTheSelectedPairAndLooksItUpEachTime() throws {
        let store = pairedStore(with: record(ipad))
        try store.save(record(other))
        var seen: [String] = []
        let client = SourceAppClient.network(sourceID: ipad, pairs: store, makeTransport: {
            seen.append($0.sourceID)
            var t = SpanDACTLSTransport(record: $0)
            t.fixedEndpoint = ("127.0.0.1", 1)   // a closed port: asleep, quickly
            return t
        })
        XCTAssertThrowsError(try client.control.status())
        XCTAssertEqual(seen, [ipad])
        try store.forget(sourceID: ipad)
        XCTAssertThrowsError(try client.control.status()) {
            XCTAssertEqual($0 as? SourceAppError, .link(.notPaired))
        }
        XCTAssertEqual(seen, [ipad], "a forgotten pair builds no transport")
    }

    /// The one factory: the Mac's socket for the Mac's own SpanDAC, the
    /// network link for a network one, never the other way round.
    func testSelectedBuildsTheClientTheModeNames() {
        let network = SourceAppClient.selected(for: .networkSource(ipad), pairs: pairedStore())
        XCTAssertEqual(network.readiness(), .unavailable(SpanDACLinkFailure.notPaired.sentence),
                       "a network selection with no pair must not reach the Mac's socket")
    }

    // MARK: - The Now poller

    /// With a SpanDAC on the network selected, Now reads THAT SpanDAC through
    /// the coordinator, and never builds the Mac's own client.
    func testThePollerReadsTheSelectedNetworkSpanDAC() {
        let r = Recorder()
        let c = coordinator(.networkSource(ipad), r)
        var localBuilt = 0
        let store = NowPlayingStore()
        let poller = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                    appQueue: AppQueueStore(),
                                    queueStore: QueueStore(path: tempDir() + "/q.json"),
                                    routing: c,
                                    makeSourceClient: { localBuilt += 1; return SourceAppClient(path: "/nonexistent") })
        poller.tick()
        XCTAssertEqual(localBuilt, 0)
        XCTAssertEqual(r.sent.map(\.1), [#"{"op":"slice.status"}"#])
        XCTAssertNotNil(store.read().bridge)
    }

    // MARK: - Words

    func testTheCLILockRefusalNamesANetworkSpanDAC() {
        XCTAssertEqual(OutputLock.cliModeChangedMessage(now: .networkSource(ipad)),
                       "Output changed to a SpanDAC on the network while this command ran; nothing was changed.")
        XCTAssertEqual(OutputLock.cliModeChangedMessage(now: .source),
                       "Output changed to Bridge while this command ran; nothing was changed.")
    }
}

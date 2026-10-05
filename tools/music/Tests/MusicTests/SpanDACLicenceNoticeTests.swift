// tools/music/Tests/MusicTests/SpanDACLicenceNoticeTests.swift
//
// SpanDAC's licence on the screens (design section 7; score M3): the first
// notice when serving ends, whom the Now poller asks, and that the Output tab's
// Mac row and the poller read SpanDAC through the coordinator's own client so
// its licence cache hears them.
//
// Every store is an explicit temp path and every client a fixture transport:
// nothing here reaches a socket, a player, the network or ~/.config/music
// (`HOME=` would not isolate it; NSHomeDirectory ignores it).
import XCTest
@testable import music

final class SpanDACLicenceNoticeTests: XCTestCase {

    // MARK: - The notice

    /// Once per flip into not serving: from serving, and from unknown.
    func testNoticeFiresOnAFlipIntoNotServing() {
        XCTAssertEqual(licenceNotice(previous: true, current: false, dataAccepted: true), licenceFallbackNotice)
        XCTAssertEqual(licenceNotice(previous: nil, current: false, dataAccepted: true), licenceFallbackNotice)
    }

    /// Every other pair of values is silent, including the repeat of false.
    func testNoticeIsSilentForEveryOtherPair() {
        let values: [Bool?] = [nil, true, false]
        for previous in values {
            for current in values where !(current == false && previous != false) {
                XCTAssertNil(licenceNotice(previous: previous, current: current, dataAccepted: true),
                             "\(String(describing: previous)) -> \(String(describing: current))")
            }
        }
    }

    /// Without SpanDAC accepted as the music source nothing fell back.
    func testNoticeIsSilentWhenDataWasNeverSpanDAC() {
        XCTAssertNil(licenceNotice(previous: true, current: false, dataAccepted: false))
        XCTAssertNil(licenceNotice(previous: nil, current: false, dataAccepted: false))
    }

    /// Fed a sequence the way the main loop feeds it: serving, lapsed (one
    /// notice), still lapsed (none), serving again, lapsed again (one more).
    func testNoticeFiresOncePerFlipAcrossASequence() {
        var previous: Bool? = nil
        var told = 0
        for current: Bool? in [nil, true, false, false, false, true, false, false] {
            if licenceNotice(previous: previous, current: current, dataAccepted: true) != nil { told += 1 }
            previous = current
        }
        XCTAssertEqual(told, 2)
    }

    /// The wording opens with the Output tab's own line and never names the
    /// player a person is not meant to read about.
    func testNoticeWordingAgreesWithTheOutputTabLine() {
        XCTAssertTrue(licenceFallbackNotice.hasPrefix(spanDACNotLicensedLine("")))
        XCTAssertFalse(licenceFallbackNotice.contains("Music.app"))
        XCTAssertEqual(licenceFallbackNotice,
                       "SpanDAC is installed but not licensed - using the MusicTUI output instead. The Output tab says why.")
    }

    // MARK: - Whom the poller asks

    private let network = PlaybackMode.networkSource("D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F")

    /// With no play-out the target is exactly what Now has always followed.
    func testPollTargetFollowsTheOutputWithoutAPlayOut() {
        XCTAssertEqual(pollTarget(selection: .consistent(data: .spandacMac, output: .source), playOut: nil),
                       .bridge(.source))
        XCTAssertEqual(pollTarget(selection: .consistent(data: .spandacMac, output: network), playOut: nil),
                       .bridge(network))
        XCTAssertEqual(pollTarget(selection: .consistent(data: .spandacMac, output: .musicApp), playOut: nil),
                       .musicApp)
        XCTAssertEqual(pollTarget(selection: .consistent(data: .open, output: .musicApp), playOut: nil),
                       .musicApp)
        XCTAssertEqual(pollTarget(selection: .consistent(data: .open, output: .source), playOut: nil), .stopped)
        XCTAssertEqual(pollTarget(selection: .outputBlocked(stored: .source), playOut: nil), .stopped)
    }

    /// While a queue plays out, Now follows it whatever the selection fell
    /// back to, blocked network output included.
    func testPollTargetFollowsAPlayOutOverEverySelection() {
        let selections: [EffectiveSelection] = [
            .consistent(data: .open, output: .musicApp),
            .consistent(data: .spandacMac, output: .musicApp),
            .consistent(data: .spandacMac, output: .source),
            .outputBlocked(stored: network),
        ]
        for selection in selections {
            XCTAssertEqual(pollTarget(selection: selection, playOut: .source), .bridge(.source))
            XCTAssertEqual(pollTarget(selection: selection, playOut: network), .bridge(network))
        }
    }

    /// A play-out that names MusicTUI's own output is not a SpanDAC to ask.
    func testPollTargetIgnoresAPlayOutThatIsNotASpanDAC() {
        XCTAssertEqual(pollTarget(selection: .consistent(data: .open, output: .musicApp), playOut: .musicApp),
                       .musicApp)
    }

    // MARK: - Fixtures

    private func status(playback: String = "playing", serving: Bool? = nil) -> String {
        var body = #""playback":"\#(playback)","authorization":"authorized","contract":3,"capabilities":[],"#
            + #""queue":{"phase":"complete"}"#
        if let serving {
            body += #","licence":{"serving":\#(serving),"state":"\#(serving ? "licensed" : "none")","text":"Licence text."}"#
        }
        return #"{"ok":true,"op":"slice.status","status":{\#(body)}}"#
    }

    private final class Rig {
        let dir = NSTemporaryDirectory() + "music-licence-notice-\(UUID().uuidString)"
        let modes: PlaybackModeStore
        let data: DataProviderStore
        let cache = SpanDACServingCache()
        private let lock = NSLock()
        private var _sent = 0
        var sent: Int { lock.lock(); defer { lock.unlock() }; return _sent }
        var reply: () -> String = { "" }

        init(output: PlaybackMode, accepted: Bool) {
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
            XCTAssertTrue(modes.set(output))
            data = DataProviderStore(path: (dir as NSString).appendingPathComponent("data.json"))
            if accepted { XCTAssertTrue(data.accept()) }
        }

        deinit { try? FileManager.default.removeItem(atPath: dir) }

        /// The Mac's clients are wrapped with `observingLicence` the way
        /// `RoutingCoordinator.live` wraps them. A scene or poller built over
        /// this and handed no client of its own must read through that.
        func coordinator() -> RoutingCoordinator {
            let fixture: (String, String) throws -> String = { [self] _, _ in
                lock.lock(); _sent += 1; lock.unlock()
                return reply()
            }
            let wrapped = observingLicence(fixture, cache: cache)
            return RoutingCoordinator(store: modes, surface: .tui, dataStore: data,
                                      makeSourceFor: { _ in SourceAppClient(path: "/nonexistent/output", transport: wrapped) },
                                      makeDataClient: { SourceAppClient(path: "/nonexistent/data", transport: wrapped) },
                                      starter: NeverStartsMacSpanDAC(),
                                      licence: cache)
        }
    }

    // MARK: - The Output tab

    private func scene(_ routing: RoutingCoordinator) -> SpeakersScene {
        SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                      status: StatusStore(), actions: ActionRunner(status: StatusStore()),
                      routing: routing, macName: "Studio Mac",
                      fetchSpeakers: { [] },
                      fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                      fetchVisualizer: { _ in false },
                      macSocketExists: { false })
    }

    private func settle(_ s: SpeakersScene) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = s.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []))
            if s.bridgeReadinessForTest != .checking { return }
            usleep(20_000)
        }
    }

    /// The Mac row's readiness is the licence line with SpanDAC's own
    /// sentence, and the tab reached it through the coordinator's client:
    /// the cache learned "not serving" from the tab's own status read.
    func testOutputTabMacRowShowsTheLicenceLineThroughTheCoordinatorsClient() {
        let rig = Rig(output: .musicApp, accepted: false)
        rig.reply = { self.status(playback: "idle", serving: false) }
        let s = scene(rig.coordinator())
        settle(s)
        let line = spanDACNotLicensedLine("Licence text.")
        XCTAssertEqual(s.bridgeReadinessForTest, .unavailable(line))
        XCTAssertEqual(macDataRowDetail(macDataRowState(readiness: s.bridgeReadinessForTest, installed: true,
                                                        starting: false, startOutcome: nil)).text, line)
        XCTAssertEqual(rig.cache.snapshot().serving, false, "the tab's status read never reached the licence cache")
        XCTAssertFalse(line.contains("Music.app"))
    }

    /// A SpanDAC that is not serving reads as the licence line even with no DAC
    /// plugged in: the DAC is no use to a person while it will not play.
    func testNotServingHidesTheDACFromTheRow() {
        let rig = Rig(output: .musicApp, accepted: false)
        rig.reply = {
            #"{"ok":true,"op":"slice.status","status":{"playback":"idle","authorization":"authorized","contract":3,"#
                + #""output":{"dac":"not_connected"},"licence":{"serving":false,"state":"none","text":"Licence text."}}}"#
        }
        let s = scene(rig.coordinator())
        settle(s)
        XCTAssertEqual(macSpanDACRowState(readiness: s.bridgeReadinessForTest, output: nil),
                       .notReady(spanDACNotLicensedLine("Licence text.")))
    }

    // MARK: - The Now poller

    private func poller(_ routing: RoutingCoordinator, store: NowPlayingStore) -> PlaybackPoller {
        PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                       appQueue: AppQueueStore(),
                       queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                       routing: routing)
    }

    /// With SpanDAC the stored output and its queue playing, a status that says
    /// "not serving" ends the selection's claim on SpanDAC, and the poller
    /// still asks SpanDAC for the next tick, reading through the coordinator's
    /// client (it was given none of its own).
    func testPollerFollowsThePlayOutAfterServingEnds() {
        let rig = Rig(output: .source, accepted: true)
        let routing = rig.coordinator()
        let store = NowPlayingStore()
        let poller = poller(routing, store: store)

        rig.reply = { self.status(playback: "playing", serving: true) }
        poller.tick()
        XCTAssertEqual(rig.sent, 1)
        XCTAssertNotNil(store.read().bridge)
        XCTAssertNil(routing.playOutMode)

        rig.reply = { self.status(playback: "playing", serving: false) }
        poller.tick()
        XCTAssertEqual(rig.sent, 2)
        XCTAssertEqual(routing.playOutMode, .source)
        XCTAssertEqual(routing.selection, .consistent(data: .open, output: .musicApp),
                       "the selection has fallen back, so only the play-out can explain what follows")

        poller.tick()
        XCTAssertEqual(rig.sent, 3, "the poller stopped asking SpanDAC while its queue played out")
        XCTAssertNotNil(store.read().bridge)
    }
}

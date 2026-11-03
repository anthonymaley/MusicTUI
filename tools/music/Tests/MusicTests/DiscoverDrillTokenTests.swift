// tools/music/Tests/MusicTests/DiscoverDrillTokenTests.swift
//
// The drill token (catalogue-search score, Revision r2 item 2, step S5a).
// Opening an album or playlist reads its tracks in the background. That read
// belongs to the drill that started it: Back, a change of data source, a
// refresh or a newer drill leaves it behind, and when it lands late it is
// dropped. Its rows never appear, its failure is never posted, and it never
// keeps a newer drill from opening.
//
// Every test drives the real scene over a real `RoutingCoordinator` and the
// SceneDataRig's fake SpanDAC clients (DiscoverDataRouteTests.swift). A read
// is held by arrival order at the fake transport and released by the test.
// No test reaches a real player, Apple's Music app, a socket, the keychain,
// the network or ~/.config/music.
import XCTest
@testable import music

/// Holds the Nth `slice.containerTracks` request (by arrival) until released.
private final class ReadGate {
    private let lock = NSLock()
    private var arrivals = 0
    private var gates: [Int: DispatchSemaphore] = [:]

    func hold(_ ordinal: Int) {
        lock.lock(); gates[ordinal] = DispatchSemaphore(value: 0); lock.unlock()
    }

    func release(_ ordinal: Int) {
        lock.lock(); let gate = gates[ordinal]; lock.unlock()
        gate?.signal()
    }

    /// The rig's `during` hook: runs on the reading thread, outside the rig's lock.
    func arrive() {
        lock.lock(); let ordinal = arrivals; arrivals += 1; let gate = gates[ordinal]; lock.unlock()
        _ = gate?.wait(timeout: .now() + 10)
    }
}

final class DiscoverDrillTokenTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private static let refusal = "That playlist isn't in Apple Music's catalogue."

    override func setUp() {
        super.setUp()
        ExternalCallTripwire.shared.arm()
    }

    override func tearDown() {
        let escaped = ExternalCallTripwire.shared.disarm()
        XCTAssertEqual(escaped.count, 0, "a call escaped the fakes: \(escaped)")
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One rail, two playlists: Alpha (the first row) and Beta (the second).
    private static let rail = """
    {"ok":true,"op":"slice.recommendations","rails":[{"title":"Made For You","items":[
      {"id":"pl.u-alpha","kind":"playlist","name":"Alpha","subtitle":"Curator"},
      {"id":"pl.u-beta","kind":"playlist","name":"Beta","subtitle":"Curator"}]}]}
    """

    private static let alphaIDs = ["101", "102"]
    private static let betaIDs = ["201", "202"]

    private static func tracksReply(_ ids: [String]) -> String {
        let items = ids.map { #"{"id":"\#($0)","kind":"song","name":"Song \#($0)","subtitle":"Artist"}"# }
        return #"{"ok":true,"op":"slice.containerTracks","items":[\#(items.joined(separator: ","))]}"#
    }

    private struct Fixture {
        let rig: SceneDataRig
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let gate: ReadGate
    }

    private func lifecycle(_ log: SceneLifecycleLog) -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }),
            readCountByPersistentID: { _ in 100 },
            confirmReadByPersistentID: { _ in discoverConfirmedToken },
            readContainerTrackIDsByPersistentID: { log.mac?.containerTrackIDs($0) },
            readTracksByPersistentID: { hexes in
                guard let mac = log.mac else { throw Stop.stop }
                return try mac.library.persistentIDReader.tracks(persistentIDs: hexes)
            })
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    /// Accepted SpanDAC data. `alphaRefuses` makes Alpha's read a refusal.
    private func fixture(output: PlaybackMode, alphaRefuses: Bool = false) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: true)
        rig.replies["slice.recommendations"] = Self.rail
        rig.responders["slice.containerTracks"] = { body in
            switch body["id"] as? String {
            case "pl.u-alpha":
                return alphaRefuses
                    ? #"{"ok":false,"op":"slice.containerTracks","error":{"kind":"unresolvable","detail":"\#(Self.refusal)"}}"#
                    : Self.tracksReply(Self.alphaIDs)
            case "pl.u-beta":
                return Self.tracksReply(Self.betaIDs)
            default:
                return #"{"ok":false,"op":"slice.containerTracks","error":{"kind":"bad_request","detail":"unknown"}}"#
            }
        }
        let gate = ReadGate()
        rig.during["slice.containerTracks"] = { gate.arrive() }
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle(SceneLifecycleLog()), routing: routing,
                                  opener: SceneRecordingOpener())
        return Fixture(rig: rig, scene: scene, routing: routing, status: status, actions: actions, gate: gate)
    }

    private func ticks(_ f: Fixture, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertTrue(done(), "timed out", file: file, line: line)
    }

    /// Ticks for a while with nothing to wait for: how a released read is
    /// given its chance to land (it has microseconds of work left).
    private func settle(_ f: Fixture, seconds: TimeInterval = 0.5) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    private func loadRails(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        ticks(f, until: { !f.scene.rails.isEmpty }, file: file, line: line)
    }

    private func readsSent(_ f: Fixture) -> Int { f.rig.sent("slice.containerTracks").count }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    // MARK: - Back, then another album

    /// Alpha's read is held; Back; Beta opens and shows its rows; Alpha's read
    /// lands last. Beta's rows stay, and Enter on them plays Beta, never Alpha.
    func testAnOldReadLandingAfterBackAndANewDrillDoesNotReplaceTheNewRows() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad))
        loadRails(f)
        f.gate.hold(0)

        _ = f.scene.handle(.enter)                      // opens Alpha; its read is held
        ticks(f, until: { self.readsSent(f) == 1 })
        _ = f.scene.handle(.left)                       // Back to the rail
        _ = f.scene.handle(.down)                       // Beta
        _ = f.scene.handle(.enter)                      // opens Beta
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.betaIDs })
        XCTAssertEqual(readsSent(f), 2, "Beta's open was blocked by Alpha's read still in flight")

        f.gate.release(0)                               // Alpha's read lands last
        settle(f)

        XCTAssertEqual(f.scene.trackRows.map(\.id), Self.betaIDs, "Alpha's late rows replaced Beta's")

        // The rows on screen are the only rows a play can take.
        _ = f.scene.handle(.home)
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").last?.body["ids"] as? [String], Self.betaIDs)
        XCTAssertFalse(f.rig.sent("slice.queue").contains { ($0.body["ids"] as? [String])?.first == "101" },
                       "a stale Alpha row was played")
    }

    // MARK: - Back while the read is held

    /// Back during a held read, then it lands: nothing appears, the scene is
    /// still at the rail, and Alpha opens again at once.
    func testBackDuringAHeldReadLeavesTheRailEmptyOfItsRows() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad))
        loadRails(f)
        let railHint = f.scene.footerHint
        f.gate.hold(0)

        _ = f.scene.handle(.enter)
        ticks(f, until: { self.readsSent(f) == 1 })
        _ = f.scene.handle(.left)
        f.gate.release(0)
        settle(f)

        XCTAssertEqual(f.scene.trackRows, [], "the read from a drill left behind put its rows in the scene")
        XCTAssertEqual(f.scene.footerHint, railHint)
        XCTAssertEqual(f.scene.handle(.left), .none, "the scene is not at the rail")

        _ = f.scene.handle(.enter)                      // Alpha again, unheld
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.alphaIDs })
        XCTAssertEqual(readsSent(f), 2)
    }

    /// Back during a held read that refuses: the refusal is not posted.
    func testBackDuringAHeldReadThatFailsPostsNoFailure() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad), alphaRefuses: true)
        loadRails(f)
        f.gate.hold(0)

        _ = f.scene.handle(.enter)
        ticks(f, until: { self.readsSent(f) == 1 })
        _ = f.scene.handle(.left)
        f.gate.release(0)
        settle(f)

        XCTAssertFalse(f.status.current()?.text.contains(Self.refusal) ?? false,
                       "a left-behind read posted its failure: \(f.status.current()?.text ?? "nil")")
        XCTAssertEqual(f.scene.trackRows, [])
    }

    /// The control: a refusal to open the drill on screen is still posted.
    func testARefusalForTheDrillOnScreenIsStillPosted() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad), alphaRefuses: true)
        loadRails(f)

        _ = f.scene.handle(.enter)
        ticks(f, until: { f.status.current()?.text.contains(Self.refusal) ?? false })
    }

    // MARK: - A change of data source during a drill

    /// Stop using SpanDAC data while Alpha's read is held: the read lands into
    /// a reloaded tab and shows nothing. Switching back, Alpha opens at once.
    func testADataSwitchDuringADrillShowsNoStaleRowsAndDoesNotBlockTheNextDrill() throws {
        let f = fixture(output: .musicApp)
        loadRails(f)
        f.gate.hold(0)

        _ = f.scene.handle(.enter)
        ticks(f, until: { self.readsSent(f) == 1 })
        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)                // sees the new data source and reloads
        f.gate.release(0)
        settle(f)

        XCTAssertEqual(f.scene.trackRows, [], "rows read from the source just left were shown")
        XCTAssertFalse(f.scene.trackRows.contains { Self.alphaIDs.contains($0.id) })

        XCTAssertEqual(try f.routing.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        _ = f.scene.tick(snapshot: idle)
        loadRails(f)
        _ = f.scene.handle(.enter)                      // Alpha again, unheld
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.alphaIDs })
        XCTAssertEqual(readsSent(f), 2, "the new drill was blocked by the old read")
    }

    /// Switch away and back while Alpha's read is held, open Beta, then let
    /// Alpha's read land last: Beta's rows stay.
    func testASwitchAndBackDuringADrillThenAnOldReadLandingLastKeepsTheNewRows() throws {
        let f = fixture(output: .musicApp)
        loadRails(f)
        f.gate.hold(0)

        _ = f.scene.handle(.enter)
        ticks(f, until: { self.readsSent(f) == 1 })
        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)
        XCTAssertEqual(try f.routing.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        _ = f.scene.tick(snapshot: idle)
        loadRails(f)

        _ = f.scene.handle(.down)                       // Beta
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.betaIDs })
        f.gate.release(0)
        settle(f)

        XCTAssertEqual(f.scene.trackRows.map(\.id), Self.betaIDs, "Alpha's late rows replaced Beta's")
    }
}

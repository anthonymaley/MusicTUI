// tools/music/Tests/MusicTests/SpanDACQueueJumpRoutingTests.swift
import XCTest
@testable import music

/// Enter on an Up Next row with a SpanDAC output selected, end to end through
/// the Now scene and the routing coordinator: the matrix row, the capability
/// and carrier gates, the epoch and displayed-queue checks, the play-out gate,
/// the visible refusals, and the success path.
///
/// Every SpanDAC is a fixture transport (`LicenceRig`) and the Now scene's
/// AppleScript backend a counting script (`AppleScriptCallCounter`), never
/// osascript: nothing reaches a socket, a player, the keychain or ~/.config/music.
final class SpanDACQueueJumpRoutingTests: XCTestCase {

    private let refusal = "Jumping to a queue row is MusicTUI only in this version."

    // MARK: the matrix

    func testTheMatrixRoutesTheJumpToTheSelectedSpanDACAndNowhereElse() {
        XCTAssertEqual(routeAction(.queueJump, in: .source, from: .tui), .source)
        XCTAssertEqual(routeAction(.queueJump, in: .networkSource(LicenceRig.ipad), from: .tui), .source,
                       "routed; the carrier gate refuses a network output, not the matrix")
        XCTAssertEqual(routeAction(.queueJump, in: .musicApp, from: .tui), .musicApp)
        guard case .refused = routeAction(.queueJump, in: .source, from: .cli) else {
            return XCTFail("no CLI verb reaches the jump, and the CLI clause stays closed")
        }
    }

    /// The jump replaces what is sounding, so a play-out refuses it first.
    func testTheJumpStaysClassifiedAsStartingOrReplacingSound() {
        XCTAssertEqual(MusicTUIAction.queueJump.playOutClass, .startsOrReplacesSound)
    }

    // MARK: the rig

    private func song(_ n: Int) -> MusicRow {
        MusicRow(id: "i\(n)", title: "Song \(n)", artist: "Artist \(n)", album: "Album", kind: .song)
    }

    /// What SpanDAC says for the fixture, and what `slice.queueJump` answers.
    private final class Fixture {
        var capabilities = ["slice.status", "queue.jump"]
        var token: String? = "tok-1"
        var title = "Song 1", row = 1, next = [2, 3, 4]
        /// nil: a success whose status moves to `jumped`.
        var jumpReply: String?
        var jumped = (title: "Song 3", row: 3, next: [4], token: "tok-2")

        func status(title: String, row: Int, next: [Int], token: String?) -> String {
            let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let t = token.map { #","queue_token":"\#($0)""# } ?? ""
            return #"{"playback":"playing","contract":3,"authorization":"authorized","title":"\#(title)","artist":"Artist \#(row)","row":\#(row),"next_rows":\#(next),"capabilities":[\#(caps)],"queue":{"phase":"complete","requested":5,"present":5,"index":\#(row)}\#(t)}"#
        }

        func answer(_ line: String) -> String {
            switch LicenceRig.op(line) {
            case "slice.queueJump":
                if let jumpReply { return jumpReply }
                let s = status(title: jumped.title, row: jumped.row, next: jumped.next, token: jumped.token)
                return #"{"ok":true,"op":"slice.queueJump","status":\#(s),"queue_token":"\#(jumped.token)"}"#
            default:
                return #"{"ok":true,"op":"slice.status","status":\#(status(title: title, row: row, next: next, token: token))}"#
            }
        }
    }

    private struct Harness {
        let rig: LicenceRig, coordinator: RoutingCoordinator, fixture: Fixture
        let counter: AppleScriptCallCounter, status: StatusStore, actions: ActionRunner
        let scene: NowPlayingScene
        var jumps: [String] { rig.sent.map(\.line).filter { LicenceRig.op($0) == "slice.queueJump" } }
    }

    private func harness(output: PlaybackMode = .source, play: Bool = true) -> Harness {
        let rig = LicenceRig(output: output, accepted: true)
        let c = rig.coordinator()
        let fixture = Fixture()
        rig.reply = { _, line in fixture.answer(line) }
        if play { c.recordSpanDACPlay((0..<5).map(song), token: "tok-1") }
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let scene = NowPlayingScene(backend: counter.backend, appQueue: AppQueueStore(), status: status,
                                    actions: actions, routing: c, bridgeCoverExtractor: { _, _ in nil })
        return Harness(rig: rig, coordinator: c, fixture: fixture, counter: counter,
                       status: status, actions: actions, scene: scene)
    }

    /// One poll of the fixture SpanDAC through the real poller, as Now sees it.
    private func poll(_ h: Harness) -> NowPlayingSnapshot {
        let store = NowPlayingStore()
        let p = PlaybackPoller(store: store, backend: h.counter.backend, appQueue: AppQueueStore(),
                               queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                               routing: h.coordinator)
        p.tick()
        return store.read()
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func upNext(_ h: Harness, _ snap: NowPlayingSnapshot) -> String {
        plain(h.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap))
    }

    /// Enter on "Song 2", the second upcoming row (entry index 3 of the list the
    /// play sent, so wire row 2).
    private func pressEnterOnSong2(_ h: Harness, _ snap: NowPlayingSnapshot) {
        h.scene.tick(snapshot: snap)
        _ = h.scene.handle(.down)
        _ = h.scene.handle(.enter)
        h.actions.waitUntilIdle()
    }

    // MARK: the poller records which queue the rows are for

    func testThePollerHandsNowTheTokenOfTheQueueItDrew() {
        let h = harness()
        let snap = poll(h)
        XCTAssertEqual(snap.surrounding.map(\.index), [2, 3, 4, 5], "1-based places in the sent list")
        XCTAssertEqual(snap.spanDACQueueToken, "tok-1")

        // No rows vouched for, no queue token: nothing to jump within.
        let none = harness(play: false)
        XCTAssertNil(poll(none).spanDACQueueToken)
    }

    // MARK: sending

    func testEnterSendsTheDisplayedTokenAndTheZeroBasedRow() {
        let h = harness()
        let snap = poll(h)
        let callsBefore = h.counter.callCount
        pressEnterOnSong2(h, snap)
        XCTAssertEqual(h.jumps.count, 1)
        let sent = try? JSONSerialization.jsonObject(with: Data(h.jumps[0].utf8)) as? [String: Any]
        XCTAssertEqual(sent?["queue_token"] as? String, "tok-1")
        XCTAssertEqual(sent?["row"] as? Int, 2, "Song 2 is entry 3 of 1-based, row 2 of 0-based")
        XCTAssertEqual(h.counter.callCount, callsBefore, "nothing ran against Apple's Music app")
        XCTAssertNil(h.status.current(), "a success posts no refusal")
    }

    // MARK: refusals that send nothing

    private func assertRefusedNothingSent(_ h: Harness, _ text: String, callsBefore: Int,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.status.current()?.text, text, file: file, line: line)
        XCTAssertEqual(h.status.current()?.isError, true, file: file, line: line)
        XCTAssertEqual(h.jumps, [], "no queueJump left the client", file: file, line: line)
        XCTAssertEqual(h.counter.callCount, callsBefore, "Apple's Music app was not reached", file: file, line: line)
    }

    func testWithoutTheCapabilityTheVisibleRefusalStandsAndNothingIsSent() {
        let h = harness()
        h.fixture.capabilities = ["slice.status"]
        let snap = poll(h)
        let before = h.counter.callCount
        pressEnterOnSong2(h, snap)
        assertRefusedNothingSent(h, refusal, callsBefore: before)
    }

    /// A SpanDAC on the network never carries the jump, even one that lists it:
    /// the capability belongs to the Mac's Unix-socket carrier alone.
    func testANetworkOutputRefusesEvenWhenItAdvertisesTheCapability() {
        let h = harness(output: .networkSource(LicenceRig.ipad), play: false)
        // The Mac is serving, so the network output is licensed and routed: it
        // is the carrier gate, not the licence, that has to say no.
        h.rig.says(serving: true)
        h.coordinator.recordSpanDACPlay((0..<5).map(song), token: "tok-1")
        var snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [
            TrackListEntry(index: 2, name: "Song 1", artist: "A", isCurrent: true),
            TrackListEntry(index: 3, name: "Song 2", artist: "A", isCurrent: false)])
        snap.spanDACQueueToken = "tok-1"
        let before = h.counter.callCount
        pressEnterOnSong2(h, snap)
        assertRefusedNothingSent(h, refusal, callsBefore: before)
    }

    func testARowListWithoutATokenIsRefusedNotJumped() {
        let h = harness(play: false)
        var snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [
            TrackListEntry(index: 2, name: "Song 1", artist: "A", isCurrent: true),
            TrackListEntry(index: 3, name: "Song 2", artist: "A", isCurrent: false)])
        snap.spanDACQueueToken = nil
        let before = h.counter.callCount
        pressEnterOnSong2(h, snap)
        assertRefusedNothingSent(h, refusal, callsBefore: before)
    }

    /// The queue shown was replaced (another play recorded) between the draw
    /// and the press: the row means a different list now.
    func testASupersededPlayRefusesAndSendsNothing() {
        let h = harness()
        let snap = poll(h)
        h.scene.tick(snapshot: snap)
        h.coordinator.recordSpanDACPlay((0..<5).map(song), token: "tok-9")
        let before = h.counter.callCount
        _ = h.scene.handle(.down)
        _ = h.scene.handle(.enter)
        h.actions.waitUntilIdle()
        assertRefusedNothingSent(h, sourceChangedNothingPlayed, callsBefore: before)
    }

    /// The output epoch moves between the press and the send (a switch commits
    /// while the action waits its turn): nothing is sent and the Music.app body
    /// never runs on the output that took its place.
    func testAnEpochChangeBetweenPressAndSendRefusesAndRunsNeitherBody() {
        let h = harness()
        let snap = poll(h)
        h.scene.tick(snapshot: snap)
        let gate = DispatchSemaphore(value: 0)
        h.actions.run("Hold") { gate.wait() }
        let before = h.counter.callCount
        _ = h.scene.handle(.down)
        _ = h.scene.handle(.enter)
        XCTAssertNoThrow(try h.coordinator.switchMode(to: .musicApp, readiness: { .ready },
                                                     pauseOutgoing: { _ in true }, dropQueue: { _ in }))
        gate.signal()
        h.actions.waitUntilIdle()
        assertRefusedNothingSent(h, sourceChangedNothingPlayed, callsBefore: before)
    }

    // MARK: SpanDAC's own refusals are shown, and nothing falls back

    func testEverySpanDACRefusalIsShownVisiblyAndNeverReachesAppleMusic() {
        func refusal(_ kind: String, _ detail: String) -> String {
            #"{"ok":false,"op":"slice.queueJump","error":{"kind":"\#(kind)","detail":"\#(detail)"}}"#
        }
        let cases: [(String, String, String)] = [
            ("stale_queue", "The queue changed.", "SpanDAC refused: The queue changed."),
            ("shuffled", "A shuffled queue can't be jumped.", "SpanDAC refused: A shuffled queue can't be jumped."),
            ("row_unbound", "That row isn't in the queue.", "SpanDAC refused: That row isn't in the queue."),
            ("row_ambiguous", "That song is in the queue twice.", "SpanDAC refused: That song is in the queue twice."),
            (spanDACLicenceRefusalKind, "SpanDAC isn't licensed.", "SpanDAC isn't licensed."),
        ]
        for (kind, detail, shown) in cases {
            let h = harness()
            h.fixture.jumpReply = refusal(kind, detail)
            let snap = poll(h)
            let before = h.counter.callCount
            pressEnterOnSong2(h, snap)
            XCTAssertEqual(h.jumps.count, 1, kind)
            XCTAssertEqual(h.status.current()?.text, shown, kind)
            XCTAssertEqual(h.status.current()?.isError, true, kind)
            XCTAssertEqual(h.counter.callCount, before, "\(kind): no fallback to Apple's Music app")
            XCTAssertEqual(h.coordinator.spanDACPlay()?.token, "tok-1", "\(kind): the kept rows are untouched")
        }
    }

    func testAMalformedSuccessIsRefusedAndKeepsTheOldToken() {
        let h = harness()
        h.fixture.jumpReply = #"{"ok":true,"op":"slice.queueJump"}"#
        let snap = poll(h)
        pressEnterOnSong2(h, snap)
        XCTAssertEqual(h.status.current()?.isError, true)
        XCTAssertEqual(h.coordinator.spanDACPlay()?.token, "tok-1")
    }

    // MARK: success

    func testSuccessRebindsTheKeptRowsAndDrawsTheReplysQueue() {
        let h = harness()
        let snap = poll(h)
        pressEnterOnSong2(h, snap)
        XCTAssertNil(h.status.current())
        XCTAssertEqual(h.coordinator.spanDACPlay()?.token, "tok-2", "the kept rows follow the token the reply carried")
        XCTAssertEqual(h.coordinator.spanDACPlay()?.rows.count, 5)

        // The next tick, even over the poll taken before the jump, shows the
        // queue the reply described: the new current row first, then what follows.
        h.scene.tick(snapshot: snap)
        let shown = upNext(h, snap)
        XCTAssertTrue(shown.contains("Song 4 \u{2014} Artist 4"), shown)
        XCTAssertFalse(shown.contains("Song 2 \u{2014} Artist 2"), "the rows before the jump are gone: \(shown)")

        // And the poll that follows, which reads the status echoing tok-2,
        // keeps the list rather than dropping it for a mismatched token.
        h.fixture.title = "Song 3"; h.fixture.row = 3; h.fixture.next = [4]; h.fixture.token = "tok-2"
        let after = poll(h)
        XCTAssertEqual(after.surrounding.map(\.name), ["Song 3", "Song 4"])
        XCTAssertEqual(after.spanDACQueueToken, "tok-2")
    }

    // MARK: MusicTUI output: unchanged

    func testWithMusicTUISelectedTheJumpRunsTheShippedBodyAndSendsNoQueueJump() {
        let h = harness(output: .musicApp, play: false)
        let rows = [TrackListEntry(index: 1, name: "A", artist: "X", isCurrent: true),
                    TrackListEntry(index: 2, name: "B", artist: "Y", isCurrent: false)]
        h.scene.tick(snapshot: NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: rows))
        let before = h.counter.callCount
        _ = h.scene.handle(.down)
        _ = h.scene.handle(.enter)
        h.actions.waitUntilIdle()
        XCTAssertGreaterThan(h.counter.callCount, before, "the shipped AppleScript body ran")
        XCTAssertEqual(h.jumps, [])
    }

    // MARK: the play-out gate

    /// SpanDAC on this Mac stopped serving mid-queue: the jump would replace the
    /// sound, so the gate refuses it before the row moves or anything is sent,
    /// and what Now shows is where it was.
    func testALapsedLicencePlayOutRefusesBeforeTheRowMoves() {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        let fixture = Fixture()
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "playing", phase: "complete")
        rig.reply = { _, line in
            LicenceRig.op(line) == "slice.queueJump" ? fixture.answer(line)
                : LicenceRig.status(playback: "playing", phase: "complete", serving: false)
        }
        XCTAssertEqual(c.playOutMode, .source)
        c.recordSpanDACPlay((0..<5).map(song), token: "tok-1")
        let counter = AppleScriptCallCounter()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let scene = NowPlayingScene(backend: counter.backend, appQueue: AppQueueStore(), status: status,
                                    actions: actions, routing: c, bridgeCoverExtractor: { _, _ in nil })
        var snap = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [
            TrackListEntry(index: 2, name: "Song 1", artist: "Artist 1", isCurrent: true),
            TrackListEntry(index: 3, name: "Song 2", artist: "Artist 2", isCurrent: false)])
        snap.spanDACQueueToken = "tok-1"
        scene.tick(snapshot: snap)
        _ = scene.handle(.down)
        let drawnBefore = plain(scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap))
        let sentBefore = rig.sent.count, serial = c.playSerial
        _ = scene.handle(.enter)
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, macPlayOutRefusal)
        XCTAssertEqual(rig.sent.filter { LicenceRig.op($0.line) == "slice.queueJump" }.count, 0)
        XCTAssertEqual(rig.sent.count, sentBefore, "nothing at all was sent")
        XCTAssertEqual(counter.callCount, 0)
        XCTAssertEqual(c.playSerial, serial)
        XCTAssertEqual(c.spanDACPlay()?.token, "tok-1")
        XCTAssertEqual(plain(scene.render(frame: shellLayout(width: 120, height: 40), snapshot: snap)), drawnBefore,
                       "the row did not move")
        XCTAssertEqual(c.playOutMode, .source)
    }
}

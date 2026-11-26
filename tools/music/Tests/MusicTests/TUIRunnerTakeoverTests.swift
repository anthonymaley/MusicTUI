// tools/music/Tests/MusicTests/TUIRunnerTakeoverTests.swift
//
// Live check 2026-11-25 13:47 (Mac Studio): a `music play --playlist` was playing on the Mac
// DAC route through the detached runner, and opening the TUI over it (1) showed Music's own
// library list as Up Next and (2) made `>` RESTART the song instead of moving to the next.
//
// The cause: the TUI's launch restores the route (`MacRoutePlayer.routeChanged(on: true)`),
// a fence command, and every fence command takes the play lease. The runner's lease was
// the TUI's from then on, so the runner ended `superseded` and, until it did, a client
// asking it found "another owner holds the lease" = "no runner", and fell back to
// Music's own next track, which restarts the song (Music holds one song at a time).
//
// Fakes only: the fence, lease and runner files live in a temp directory; SpanDAC is a
// scripted transport; the queue file is temp; no process, no Music, no socket, no audio,
// never `~/.config/music`.
import ArgumentParser
import XCTest
@testable import music

final class TUIRunnerTakeoverTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "tui-runner-takeover-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: support

    private var files: RunQueueControlFiles { RunQueueControlFiles(directory: dir) }
    private func fence() -> RateFence { RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001)) }

    /// A CLI runner that is up and holds the lease: its record (this test process's pid, which
    /// is alive) and its lease on the same fence the TUI's player uses.
    @discardableResult
    private func liveRunner(owner: String = "runner-X") throws -> FileRunQueueControl {
        _ = try fence().begin(.play, owner: owner)
        let control = FileRunQueueControl(files: files, owner: owner)
        control.register(); control.markReady()
        return control
    }

    /// SpanDAC as a scripted transport that answers every follow with "applied".
    private final class Wire { var ops: [String] = [] }
    private func reporter(_ wire: Wire) -> MacRouteFollowReporter {
        func transport(_ timeout: TimeInterval?) -> (String, String) throws -> String {
            { _, line in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                wire.ops.append(body["op"] as? String ?? "")
                let f = body["fence"] as? Int ?? 0
                return #"{"ok":true,"rate":{"fence":\#(f),"outcome":"quiet"},"follow":{"on":true,"applied":true}}"#
            }
        }
        var c = SourceAppControl(path: "/nonexistent", transport: transport(nil))
        c.rateSender = { transport($0) }
        return MacRouteFollowReporter(control: c, schedule: { $0() })
    }

    /// The TUI's player, as the shell composes it: route on, output MusicTUI, owner "tui".
    private func tuiPlayer(reporter: MacRouteFollowReporter?) -> MacRoutePlayer {
        MacRoutePlayer(
            streamWait: .instant, route: MacDACRouteState(initial: true), outputIsMusicApp: { true },
            fence: fence(), owner: "tui",
            makeMusic: { _ in fatalError("never asked to play") },
            resolvePersistentID: { _, _ in nil },
            makeFollow: { _ in fatalError("never asked to play") },
            post: { _ in }, reporter: reporter)
    }

    /// A `RunQueueSkipClient` as production builds it (the lease read through the real fence),
    /// the runner simulated by its sleep: it takes the request and answers it.
    private func skipClient(_ runner: FileRunQueueControl) -> RunQueueSkipClient {
        let fence = fence()
        var c = RunQueueSkipClient(files: files, leaseStatus: { fence.leaseStatus(owner: $0, timeout: 0.2) })
        var taken: RunQueueSkipRequest?
        c.sleep = { _ in
            if taken == nil { taken = runner.takeSkip() }
            else if let taken { runner.acknowledge(nonce: taken.nonce, outcome: .played) }
        }
        return c
    }

    // MARK: finding 2: `>` restarts the song

    /// The shell's launch, over a live runner: the route is restored. The runner keeps the
    /// lease, and the TUI's `>` (the same `skipThroughRunner` the TUI's `musicTUISkip` calls)
    /// reaches it instead of falling through to Music's own next track.
    func testOpeningTheTUIOverALiveRunnerLeavesTheLeaseWithTheRunnerSoNextReachesIt() throws {
        let runner = try liveRunner()
        let wire = Wire()
        let p = tuiPlayer(reporter: reporter(wire))

        p.routeChanged(on: true)                       // Shell.swift: `if macRouteState.chosen { ... }`

        XCTAssertEqual(fence().leaseStatus(owner: "runner-X"), .ours,
                       "the TUI's route restore took the play lease from the runner")
        var shown = 0
        let handled = try skipThroughRunner(step: 1, json: false, routeIsOn: { true }, client: skipClient(runner),
                                            show: { _ in shown += 1 }, fail: { XCTFail("skip failed: \($0)") })
        XCTAssertTrue(handled, "no runner was found: Music's own next track would run, and it restarts the song")
        XCTAssertEqual(shown, 1)
    }

    func testPreviousReachesTheRunnerToo() throws {
        let runner = try liveRunner()
        tuiPlayer(reporter: reporter(Wire())).routeChanged(on: true)
        let handled = try skipThroughRunner(step: -1, json: false, routeIsOn: { true }, client: skipClient(runner),
                                            show: { _ in }, fail: { XCTFail("back failed: \($0)") })
        XCTAssertTrue(handled)
    }

    /// The guard is not blanket: with no runner (or one whose process is gone) the TUI's
    /// route restore still moves the fence and takes the lease, as it always did.
    func testWithNoLiveRunnerTheRouteRestoreStillTakesTheLease() throws {
        _ = try fence().begin(.play, owner: "old-owner")
        let dead = FileRunQueueControl(files: files, owner: "old-owner", pid: 2_000_000_000)   // no such process
        dead.register(); dead.markReady()
        tuiPlayer(reporter: reporter(Wire())).routeChanged(on: true)
        XCTAssertEqual(fence().leaseStatus(owner: "tui"), .ours)

        // And with no record at all.
        try FileManager.default.removeItem(atPath: files.runnerPath)
        _ = try fence().begin(.play, owner: "old-owner")
        tuiPlayer(reporter: reporter(Wire())).routeChanged(on: true)
        XCTAssertEqual(fence().leaseStatus(owner: "tui"), .ours)
    }

    /// Leaving the route is the person's act and does end a runner (it checks the route).
    func testLeavingTheRouteStillTakesTheLeaseFromARunner() throws {
        try liveRunner()
        tuiPlayer(reporter: reporter(Wire())).routeChanged(on: false)
        XCTAssertEqual(fence().leaseStatus(owner: "tui"), .ours)
    }

    // MARK: finding 1: Up Next

    private func luckyEntries() -> [TrackListEntry] {
        (1359...1363).map { TrackListEntry(index: $0, name: "Library Song \($0)", artist: "Boards of Canada",
                                           isCurrent: $0 == 1361) }
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func nowScreen(player: MacRoutePlayer?, width: Int = 120) -> String {
        let store = AppQueueStore()
        store.macRoute = player
        let status = StatusStore()
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                    status: status, actions: ActionRunner(status: status), routing: rig.coordinator())
        var np = NowPlayingState()
        np.track = "Library Song 1361"; np.artist = "Boards of Canada"; np.album = "Tomorrow's Harvest"
        np.state = "playing"; np.duration = 300; np.position = 26
        // What the poller hands the scene with no app queue: Music's own current context.
        let snap = NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: luckyEntries(),
                                      contextName: "Library")
        _ = scene.tick(snapshot: snap)
        return screenText(scene.render(frame: shellLayout(width: width, height: 40), snapshot: snap),
                          width: width, height: 40).joined(separator: "\n")
    }

    /// With a CLI runner on the queue, `>` moves the RUNNER's queue; Music's own library list is
    /// not that queue, so Up Next does not present it as the one `>` follows.
    func testUpNextOverALiveRunnerDoesNotListMusicsOwnLibraryContext() throws {
        try liveRunner()
        let screen = nowScreen(player: tuiPlayer(reporter: nil))
        XCTAssertFalse(screen.contains("Library Song 1359"), "Music's own library list is shown as Up Next:\n\(screen)")
        XCTAssertFalse(screen.contains("Library Song 1363"), screen)
        XCTAssertTrue(screen.contains("Up Next"), screen)
        XCTAssertTrue(screen.contains("CLI"), "Up Next does not say whose queue > and < follow:\n\(screen)")
    }

    /// Nothing changes where no runner is registered: the list is Music's, as shipped.
    func testUpNextWithNoRunnerIsMusicsListAsShipped() {
        let screen = nowScreen(player: tuiPlayer(reporter: nil))
        XCTAssertTrue(screen.contains("Library Song 1359"), screen)
        XCTAssertFalse(screen.contains("CLI"), screen)
    }

    // MARK: a stale queue.json is not adopted over a runner's queue

    private func staleQueue() -> PersistedQueue {
        let tracks = (1...4).map { TrackListEntry(index: $0, name: "Playlist Song \($0)", artist: "A", isCurrent: false) }
        return PersistedQueue(queue: AppQueue(playlistName: "Top 25 Most Played", tracks: tracks, currentIndex: 2),
                              anchorPersistentID: nil, anchorName: "Playlist Song 2", anchorArtist: "A")
    }

    private func restore(withRunner: Bool) throws -> (adopted: AppQueue?, fileLeft: Bool) {
        if withRunner { try liveRunner() }
        let queueFile = dir + "/queue.json"
        let store = QueueStore(path: queueFile)
        try store.save(staleQueue())
        let appQueue = AppQueueStore()
        appQueue.macRoute = tuiPlayer(reporter: nil)
        var np = NowPlayingState()
        np.track = "Playlist Song 2"; np.artist = "A"; np.state = "playing"; np.duration = 200
        restoreQueueOnLaunch(queueStore: store, appQueue: appQueue, backend: AppleScriptBackend(executable: "/usr/bin/true"),
                             poll: { .active(np) }, anchorID: { nil })
        return (appQueue.read(), FileManager.default.fileExists(atPath: queueFile))
    }

    /// The saved queue is in playlist order, the runner plays shuffled album order: adopting it
    /// would make `>` follow a queue nobody is playing.
    func testALiveRunnersQueueIsNotReplacedByASavedOne() throws {
        let r = try restore(withRunner: true)
        XCTAssertNil(r.adopted, "a saved queue was adopted over a live runner's")
    }

    func testWithNoRunnerTheSavedQueueIsAdoptedAsShipped() throws {
        let r = try restore(withRunner: false)
        XCTAssertEqual(r.adopted?.currentIndex, 2)
        XCTAssertEqual(r.adopted?.playlistName, "Top 25 Most Played")
    }
}

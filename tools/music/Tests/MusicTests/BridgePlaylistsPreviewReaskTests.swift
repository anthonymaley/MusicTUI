import XCTest
@testable import music

/// The Playlists tab's PREVIEW pane (the first 50 songs of the focused rail
/// playlist) used to read once per playlist and never again, so a SpanDAC that
/// answered from an old copy left the pane on it for the rest of the run. A
/// flagged (stale/refreshing) preview is now shown at once and asked for again,
/// by ONE worker, for the playlist the person is resting on.
///
/// Everything here is deterministic: the clock is moved by hand, the re-ask's
/// sleep is injected (and can be held), SpanDAC is a fake that answers PER
/// PLAYLIST and can hold a given read, and a test waits on the worker's own
/// completion seam, never on a duration. Nothing reaches AppleScript, the real
/// SpanDAC socket, the keychain or ~/.config/music.
final class BridgePlaylistsPreviewReaskTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 160, height: 30)

    // MARK: - Fakes

    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    /// The re-ask's sleep: records each wait; `hold()` makes the next one block
    /// until `release()`, so a test can move the world while a worker sleeps.
    private final class ReaskSleep {
        private let lock = NSLock()
        private var taken: [TimeInterval] = []
        private var gate: DispatchSemaphore?
        let entered = DispatchSemaphore(value: 0)
        var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return taken }
        func hold() { lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock() }
        func release() { lock.lock(); let g = gate; gate = nil; lock.unlock(); g?.signal() }
        func sleep(_ seconds: TimeInterval) {
            lock.lock(); taken.append(seconds); let g = gate; lock.unlock()
            if let g { entered.signal(); _ = g.wait(timeout: .now() + 5) }
        }
    }

    /// A SpanDAC that answers the rail and, per playlist id, the preview reads
    /// in arrival order (the last reply repeats when `repeatLast`; otherwise an
    /// unscripted read is a loud failure). A given read of a given playlist can
    /// be held until released.
    private final class PreviewWire {
        private let lock = NSLock()
        private let railIDs: [String]
        private var replies: [String: [String]]
        private var repeatLast: Set<String> = []
        private var counts: [String: Int] = [:]
        private var gates: [String: DispatchSemaphore] = [:]
        init(rail: [String], replies: [String: [String]]) { railIDs = rail; self.replies = replies }

        func repeatingLastReply(of pid: String) { lock.lock(); repeatLast.insert(pid); lock.unlock() }
        func hold(_ pid: String, read n: Int) { lock.lock(); gates["\(pid)#\(n)"] = DispatchSemaphore(value: 0); lock.unlock() }
        func release(_ pid: String, read n: Int) { lock.lock(); let g = gates["\(pid)#\(n)"]; lock.unlock(); g?.signal() }
        func reads(_ pid: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[pid] ?? 0 }
        func reached(_ pid: String, read n: Int) -> Bool { reads(pid) > n }

        func transport(_ path: String, _ line: String) throws -> String {
            let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
            let op = body["op"] as? String ?? ""
            if op == "slice.libraryPlaylists" {
                let rows = railIDs.map { "{\"id\":\"\($0)\",\"title\":\"List \($0)\",\"kind\":\"playlist\"}" }.joined(separator: ",")
                return "{\"ok\":true,\"op\":\"\(op)\",\"generation\":3,\"total\":\(railIDs.count),\"items\":[\(rows)],\"next_cursor\":null}"
            }
            guard op == "slice.libraryPlaylistTracks", let pid = body["id"] as? String else {
                return "{\"ok\":false,\"op\":\"\(op)\",\"error\":{\"kind\":\"bad_request\",\"detail\":\"unscripted \(op)\"}}"
            }
            lock.lock()
            let n = counts[pid, default: 0]
            counts[pid] = n + 1
            let list = replies[pid] ?? []
            let reply: String
            if n < list.count { reply = list[n] }
            else if repeatLast.contains(pid), let last = list.last { reply = last }
            else { reply = "{\"ok\":false,\"op\":\"\(op)\",\"error\":{\"kind\":\"bad_request\",\"detail\":\"unscripted read \(n) of \(pid)\"}}" }
            let gate = gates["\(pid)#\(n)"]
            lock.unlock()
            _ = gate?.wait(timeout: .now() + 5)
            return reply
        }
    }

    private func page(_ titles: [String], total: Int? = nil, flagged: Bool) -> String {
        let items = titles.map { "{\"id\":\"i.\($0)\",\"title\":\"\($0)\",\"artist\":\"Art\",\"kind\":\"song\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":\(total ?? titles.count),
         "stale":\(flagged),"refreshing":\(flagged),"items":[\(items)],"next_cursor":null,"skipped_videos":0}
        """
    }
    private let failure = "{\"ok\":false,\"op\":\"slice.libraryPlaylistTracks\",\"error\":{\"kind\":\"bad_request\",\"detail\":\"boom\"}}"

    /// The production shape of the factory (see `playlistsTestScene`), over this
    /// file's own per-playlist wire.
    private func makeScene(_ wire: PreviewWire, flag: BridgeSelectedFlag = BridgeSelectedFlag(true), clock: Clock,
                           sleep: ReaskSleep = ReaskSleep(), ended: DispatchSemaphore? = nil) -> PlaylistsScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(.source)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) })
        let status = StatusStore()
        let spy = PlaylistAppleScriptSpy()
        let s = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), routing: routing,
                               playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: status, actions: ActionRunner(status: status),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: {
                                   flag.selected
                                       ? BridgeMusicProvider(control: SourceAppControl(
                                           path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                                       : nil
                               },
                               loadMusicAppPlaylists: { spy.loadMusicAppPlaylists() },
                               makeSources: { spy.makeSources($0) },
                               warmUpSleep: sleep.sleep,
                               now: clock.now,
                               screenWidth: { 160 })
        if let ended { s.previewReaskFinishedForTest = { ended.signal() } }
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("List pl0") },
                      "the rail never settled")
        return s
    }

    /// The cursor rests on its row long enough for the preview to be read.
    private func rest(_ s: PlaylistsScene, _ clock: Clock) {
        _ = s.tick(snapshot: idle)
        clock.advance(0.5)
        _ = s.tick(snapshot: idle)
    }

    private func finished(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 3) == .success }

    /// Ticks the scene (which drains the preview landing that starts a worker)
    /// until a worker reports its end.
    private func tickUntilEnded(_ s: PlaylistsScene, _ gate: DispatchSemaphore) -> Bool {
        settleScene(s) { gate.wait(timeout: .now() + 0.001) == .success }
    }

    // MARK: - Tests

    /// (a) A flagged preview is shown at once, then replaced (rows AND count) by the first unflagged read.
    func testAFlaggedPreviewIsShownThenReplacedByTheFreshRead() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [
            page(["Old"], total: 1, flagged: true),
            page(["Old"], total: 1, flagged: false),            // the probe
            page(["New1", "New2", "New3"], total: 3, flagged: false)]])  // the re-walk
        let clock = Clock(), sleep = ReaskSleep(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, sleep: sleep, ended: ended)
        sleep.hold()
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == ["Old"] }, "the flagged preview was not shown at once")
        XCTAssertEqual(s.previewTotalForTest("pl0"), 1)
        XCTAssertTrue(settleScene(s) { sleep.entered.wait(timeout: .now() + 0.001) == .success }, "no re-ask began")
        sleep.release()
        XCTAssertTrue(finished(ended), "the re-ask never ended")
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == ["New1", "New2", "New3"] },
                      "the fresh read never replaced the old preview")
        XCTAssertEqual(s.previewTotalForTest("pl0"), 3, "the count stayed on the old copy's")
        XCTAssertEqual(sleep.all, [LibraryReask.interval])
        XCTAssertEqual(wire.reads("pl0"), 3)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.reads("pl0"), 3, "a fresh preview was asked for again")
    }

    /// (b) An unflagged preview costs nothing extra.
    func testAnUnflaggedPreviewIsNeverReAsked() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [page(["A"], flagged: false)]])
        let clock = Clock(), sleep = ReaskSleep()
        let s = makeScene(wire, clock: clock, sleep: sleep)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == ["A"] })
        for _ in 0..<20 { _ = s.tick(snapshot: idle); clock.advance(1) }
        XCTAssertEqual(wire.reads("pl0"), 1, "an unflagged preview was read again")
        XCTAssertTrue(sleep.all.isEmpty, "a re-ask worker ran for an unflagged preview")
    }

    /// (c) The cursor leaves mid re-ask: the late result is not applied, nothing more is asked
    /// for the old playlist, and coming back resumes the (unspent) re-ask.
    func testALateResultForAPlaylistTheCursorLeftIsDroppedAndReturningResumes() {
        let wire = PreviewWire(rail: ["pl0", "pl1"], replies: [
            "pl0": [page(["Old"], flagged: true),
                    page(["Old"], flagged: false),                 // probe 1
                    page(["Late"], flagged: false),                // re-walk 1: held, then dropped
                    page(["Old"], flagged: false),                 // probe 2, after returning
                    page(["Back1", "Back2"], flagged: false)],     // re-walk 2
            "pl1": [page(["One"], flagged: false)]])
        wire.hold("pl0", read: 2)
        let clock = Clock(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, ended: ended)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { wire.reached("pl0", read: 2) }, "the re-walk never went out")
        _ = s.handle(.down)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl1") == ["One"] })
        wire.release("pl0", read: 2)
        XCTAssertTrue(finished(ended), "the first re-ask never ended")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(s.previewTitlesForTest("pl0"), ["Old"], "a late result for a playlist the cursor left was applied")
        XCTAssertEqual(wire.reads("pl0"), 3, "more was asked for a playlist the cursor had left")
        _ = s.handle(.up)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == ["Back1", "Back2"] },
                      "coming back did not resume the re-ask")
        XCTAssertEqual(wire.reads("pl0"), 5)
        XCTAssertTrue(finished(ended))
    }

    /// (d) A provenance switch outlives the re-ask: its late result is dropped.
    func testALateResultAfterAProvenanceSwitchIsDropped() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [
            page(["Old"], flagged: true), page(["Old"], flagged: false), page(["Late"], flagged: false)]])
        wire.hold("pl0", read: 2)
        let flag = BridgeSelectedFlag(true)
        let clock = Clock(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, flag: flag, clock: clock, ended: ended)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { wire.reached("pl0", read: 2) }, "the re-walk never went out")
        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == nil }, "the provenance reset never cleared the preview")
        wire.release("pl0", read: 2)
        XCTAssertTrue(finished(ended), "the re-ask never ended")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertNil(s.previewTitlesForTest("pl0"), "a SpanDAC re-ask landed after the switch")
        XCTAssertNil(s.previewTotalForTest("pl0"))
        XCTAssertEqual(wire.reads("pl0"), 3)
    }

    /// (e) A spent bound, or a failed probe, while the playlist stays current is not restarted.
    func testASpentBoundDoesNotRestart() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [page(["Old"], flagged: true)]])
        wire.repeatingLastReply(of: "pl0")
        let clock = Clock(), sleep = ReaskSleep(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, sleep: sleep, ended: ended)
        rest(s, clock)
        XCTAssertTrue(tickUntilEnded(s, ended), "the re-ask never ran out")
        let probes = Int(LibraryReask.maxTotalWait / LibraryReask.interval)
        XCTAssertEqual(sleep.all.count, probes)
        XCTAssertEqual(wire.reads("pl0"), 1 + probes)
        for _ in 0..<20 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.reads("pl0"), 1 + probes, "a spent bound was restarted")
        XCTAssertEqual(s.previewTitlesForTest("pl0"), ["Old"])
    }

    func testAFailedProbeDoesNotRestart() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [page(["Old"], flagged: true), failure]])
        let clock = Clock(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, ended: ended)
        rest(s, clock)
        XCTAssertTrue(tickUntilEnded(s, ended), "the re-ask never ended")
        XCTAssertEqual(wire.reads("pl0"), 2)
        for _ in 0..<20 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.reads("pl0"), 2, "a failed re-ask was restarted")
        XCTAssertEqual(s.previewTitlesForTest("pl0"), ["Old"], "a failed re-ask took the old preview off the screen")
    }

    /// (f) One worker: the cursor resting on several stale playlists in turn asks for the one it
    /// is on, and the others stop at their next check.
    func testOnlyOneReAskWorkerRunsAsTheCursorRestsOnSeveralStalePlaylists() {
        let wire = PreviewWire(rail: ["pl0", "pl1", "pl2"], replies: [
            "pl0": [page(["Old0"], flagged: true), page(["Old0"], flagged: false)],
            "pl1": [page(["Old1"], flagged: true), page(["Old1"], flagged: false), page(["New1"], flagged: false)],
            "pl2": [page(["Old2"], flagged: true), page(["Old2"], flagged: false), page(["New2"], flagged: false)]])
        wire.hold("pl0", read: 1)   // pl0's worker sits in its probe
        let clock = Clock(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, ended: ended)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { wire.reached("pl0", read: 1) }, "pl0's probe never went out")
        // Move on and rest on pl1, then pl2, with pl0's worker still in flight.
        _ = s.handle(.down)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl1") == ["Old1"] })
        for _ in 0..<20 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(wire.reads("pl1"), 1, "a second worker asked while the first was still running")
        wire.release("pl0", read: 1)
        XCTAssertTrue(finished(ended), "pl0's worker never ended")
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl1") == ["New1"] }, "pl1 was not re-asked once the first worker ended")
        XCTAssertTrue(finished(ended))
        _ = s.handle(.down)
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl2") == ["New2"] }, "pl2 was not re-asked")
        XCTAssertTrue(finished(ended))
        XCTAssertEqual(wire.reads("pl0"), 2, "pl0 was asked for after the cursor left it")
        XCTAssertEqual(s.previewTitlesForTest("pl0"), ["Old0"])
    }

    /// (g) Leaving the tab (no ticks) stops the asking; coming back resumes it.
    func testLeavingTheTabStopsTheReAskAndComingBackResumesIt() {
        let wire = PreviewWire(rail: ["pl0"], replies: ["pl0": [
            page(["Old"], flagged: true), page(["Old"], flagged: false), page(["New"], flagged: false)]])
        let clock = Clock(), sleep = ReaskSleep(), ended = DispatchSemaphore(value: 0)
        let s = makeScene(wire, clock: clock, sleep: sleep, ended: ended)
        sleep.hold()
        rest(s, clock)
        XCTAssertTrue(settleScene(s) { sleep.entered.wait(timeout: .now() + 0.001) == .success }, "no re-ask began")
        clock.advance(10)   // the tab is left: nothing ticks for longer than the heartbeat window
        sleep.release()
        XCTAssertTrue(finished(ended), "the re-ask never ended")
        XCTAssertEqual(wire.reads("pl0"), 1, "a hidden tab kept asking SpanDAC")
        _ = s.tick(snapshot: idle)   // back on the tab
        XCTAssertTrue(settleScene(s) { s.previewTitlesForTest("pl0") == ["New"] }, "coming back did not resume the re-ask")
        XCTAssertEqual(wire.reads("pl0"), 3)
    }
}

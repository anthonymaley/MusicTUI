import XCTest
@testable import music

/// The Playlists tab on the MusicTUI (AppleScript) data path opens at once and
/// reads its names off the input thread. Before this, `openPlaylistsScene`
/// read the names synchronously inside `ensureScene`, so the shell's input
/// loop sat in `runMusicBlocking` (45 s watchdog) and a failed read was shown
/// as "No playlists found."
///
/// Every read here is a `HeldNamesReader`: it blocks until the test releases
/// it with an answer, so "while the read is held" is a fact the test holds,
/// not a duration it sleeps through. Nothing reaches osascript, Music.app,
/// the SpanDAC socket or ~/.config/music.
final class PlaylistsMusicAppLoadTests: XCTestCase {

    private let frame = shellLayout(width: 138, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let bridgePage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"SpanDAC Playlist","kind":"playlist"}],
     "next_cursor":null}
    """

    /// A names reader that blocks every call until released with an answer.
    final class HeldNamesReader {
        private let lock = NSLock()
        private var calls = 0
        private var answers: [MusicAppPlaylistNamesRead] = []
        private let started = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func read() -> MusicAppPlaylistNamesRead {
            lock.lock(); calls += 1; lock.unlock()
            started.signal()
            gate.wait()
            lock.lock(); defer { lock.unlock() }
            return answers.removeFirst()
        }

        /// Waits (bounded) until a read has begun on some thread.
        func waitStarted(timeout: TimeInterval = 5) -> Bool {
            started.wait(timeout: .now() + timeout) == .success
        }

        /// Lets one held read return `answer`.
        func release(_ answer: MusicAppPlaylistNamesRead) {
            lock.lock(); answers.append(answer); lock.unlock()
            gate.signal()
        }
    }

    private func scene(_ reader: HeldNamesReader, flag: BridgeSelectedFlag = BridgeSelectedFlag(false),
                       wire: BridgeLibraryReadsWire? = nil, status: StatusStore = StatusStore(),
                       width: Int = 138) -> PlaylistsScene {
        let wire = wire ?? BridgeLibraryReadsWire([:])
        return openPlaylistsScene(build: { names, subscription in
            XCTAssertEqual(names, [], "the scene was built with names read on the opening thread")
            XCTAssertEqual(subscription, [])
            return playlistsTestScene(flag: flag, wire: wire, spy: PlaylistAppleScriptSpy(), status: status,
                                      names: names, width: width, loadMusicAppPlaylists: { reader.read() })
        })
    }

    /// Ticks until the scene has taken the landed read (or dropped it).
    private func settleRead(_ s: PlaylistsScene) {
        XCTAssertTrue(settleScene(s) { !s.musicAppNamesReadInFlightForTest }, "the held read never landed")
    }

    // MARK: - Opening never waits on the read

    func testOpeningReturnsBeforeTheReadAndKeysAreHandledWhileItIsHeld() {
        let reader = HeldNamesReader()
        let s = scene(reader)
        XCTAssertEqual(reader.callCount, 0, "opening the tab read the names on the opening thread")

        // The first tick starts the read; it returns while the read is held.
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted(), "the names read never started")
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Loading playlists"))

        // Keys keep working on an empty, loading rail, and none of them indexes it.
        XCTAssertEqual(s.handle(.down), .redraw)
        XCTAssertEqual(s.handle(.enter), .none)
        XCTAssertEqual(s.handle(.right), .none)
        XCTAssertEqual(s.handle(.char("p")), .none)
        XCTAssertEqual(s.handle(.char("s")), .none)
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(reader.callCount, 1, "a second read started while the first was held")
        XCTAssertEqual(s.handle(.escape), .pop, "leaving the tab was not handled while the read was held")

        reader.release(.success(names: ["Chill", "Deep House"], subscription: []))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Deep House") },
                      "the released names never showed")
        XCTAssertEqual(s.railNamesForTest, ["Chill", "Deep House"])
    }

    // MARK: - Distinct outcomes

    func testAFailedReadSaysItFailedAndRRetries() {
        let reader = HeldNamesReader()
        let s = scene(reader)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted())
        reader.release(.failure)
        settleRead(s)

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Couldn't read your playlists - press r to retry"), "no failure state: \(out)")
        XCTAssertFalse(out.contains("No playlists found"), "a failed read was shown as an empty library: \(out)")
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(reader.callCount, 1, "a failed read was retried with nobody asking")

        XCTAssertEqual(s.handle(.char("r")), .redraw)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted(), "r did not read again")
        XCTAssertEqual(reader.callCount, 2)
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Loading playlists"))
        reader.release(.success(names: ["Recovered"], subscription: []))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Recovered") })
    }

    func testASuccessfulReadOfNoPlaylistsShowsTheEmptyState() {
        let reader = HeldNamesReader()
        let s = scene(reader)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted())
        reader.release(.success(names: [], subscription: []))
        settleRead(s)

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("No playlists found."), "no empty state: \(out)")
        XCTAssertFalse(out.contains("Couldn't read"), "an empty library was shown as a failure: \(out)")
        XCTAssertFalse(out.contains("Loading"), "an empty library still said loading: \(out)")
    }

    // MARK: - The landing is fenced

    func testALateResultAfterTheDataSourceMovedIsDroppedAndOnlyOneReadRunsAtATime() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [bridgePage]])
        let flag = BridgeSelectedFlag(false)
        let reader = HeldNamesReader()
        let s = scene(reader, flag: flag, wire: wire)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted())

        // Data moves to SpanDAC while the read is held: the rail follows.
        flag.selected = true
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("SpanDAC Playlist") })

        // ...and straight back again, still with the first read held: no second
        // AppleScript read starts beside it.
        flag.selected = false
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertEqual(reader.callCount, 1, "a second names read ran beside the held one")

        // The held read lands late, under an old epoch: dropped, then read afresh.
        reader.release(.success(names: ["Late Playlist"], subscription: []))
        XCTAssertTrue(settleScene(s) { reader.callCount == 2 }, "the dropped read was never replaced by a fresh one")
        XCTAssertTrue(reader.waitStarted())
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertFalse(s.render(frame: frame, snapshot: idle).contains("Late Playlist"),
                       "a result read before the data source moved was shown")

        reader.release(.success(names: ["Fresh Playlist"], subscription: []))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Fresh Playlist") })
        XCTAssertEqual(s.railNamesForTest, ["Fresh Playlist"])
    }

    func testALateResultWhileSpanDACIsSelectedNeverReachesTheRail() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [bridgePage]])
        let flag = BridgeSelectedFlag(false)
        let reader = HeldNamesReader()
        let s = scene(reader, flag: flag, wire: wire)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted())

        flag.selected = true
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("SpanDAC Playlist") })
        reader.release(.failure)
        settleRead(s)

        XCTAssertEqual(s.railSourceForTest, .bridge)
        XCTAssertEqual(s.railNamesForTest, ["SpanDAC Playlist"])
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Couldn't read your playlists"), "a stale Music.app failure reached a SpanDAC rail: \(out)")
        XCTAssertEqual(reader.callCount, 1, "SpanDAC mode started another AppleScript read")
    }

    func testAResultLandingAfterTheSceneIsGoneIsDropped() {
        let reader = HeldNamesReader()
        // One-zone width: the first tick then starts ONLY the names read. At the
        // default three-zone width it also queues a rail-preview job whose closure
        // upgrades its weak `self` AFTER its (here instant) read and holds the scene
        // strongly for microseconds while it posts; if `s = nil` lands in that window
        // the job's release is the last one, and the scene is still alive when the
        // assertion runs (~2% of runs, 2026-10-25). That job is bounded and harmless,
        // and is not what this test is about.
        var s: PlaylistsScene? = scene(reader, width: 90)
        _ = s?.tick(snapshot: idle)
        XCTAssertTrue(reader.waitStarted())
        weak var gone = s
        s = nil
        XCTAssertNil(gone, "the read thread kept the scene alive")
        reader.release(.success(names: ["Orphan"], subscription: []))
    }
}

import XCTest
@testable import music

/// `r` on a HEALTHY SpanDAC Playlists rail. If SpanDAC lists `library.refresh`
/// it is asked to rebuild (`slice.libraryRefresh`); the reply says `started`,
/// `joined` (both with a ticket) or `deferred`. The rail is read again with its
/// rows and selection kept on screen, and a started/joined rebuild is awaited
/// through `slice.status`'s `library_refresh` fact inside `LibraryReask`'s bound.
/// Every sentence the person is told is pinned here. Fakes only: the wire is
/// `BridgeLibraryReadsWire`, whose `slice.status` replies are consumed in order
/// (the last one repeats): read 0 is the capability probe the footer rides on,
/// read 1 is `r`'s own capability check, read 2 onward are completion checks.
final class BridgePlaylistsRefreshTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private typealias Item = (id: String, title: String)
    private let alpha: Item = (id: "plA", title: "Alpha")
    private let bravo: Item = (id: "plB", title: "Bravo")
    private let friday: Item = (id: "plF", title: "Friday")
    private let gamma: Item = (id: "plG", title: "Gamma")

    private func rail(_ items: [Item], flagged: Bool = false) -> String {
        let rows = items.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"kind\":\"playlist\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":\(items.count),"stale":\(flagged),"refreshing":\(flagged),
         "items":[\(rows)],"next_cursor":null}
        """
    }
    private let noAccess = """
    {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"unauthorized","detail":"no access"}}
    """

    /// A `slice.status` reply. `fact` is the raw `library_refresh` value.
    private func status(advertising: Bool = true, fact: String = "null", libraryInstance: String? = nil) -> String {
        let caps = advertising ? "[\"slice.status\",\"library.refresh\"]" : "[\"slice.status\"]"
        let inst = libraryInstance.map { "\"library_instance\":\"\($0)\"," } ?? ""
        return """
        {"ok":true,"op":"slice.status","status":{"playback":"stopped","capabilities":\(caps),\(inst)"library_refresh":\(fact)}}
        """
    }
    private func fact(_ ticket: Int, _ result: String, instance: String = "inst-1") -> String {
        status(fact: "{\"instance\":\"\(instance)\",\"ticket\":\(ticket),\"result\":\"\(result)\"}")
    }
    private func installed(_ ticket: Int, instance: String = "inst-1") -> String { fact(ticket, "installed", instance: instance) }
    private func failed(_ ticket: Int) -> String { fact(ticket, "failed") }

    private func reply(_ outcome: String, ticket: Int?, instance: String = "inst-1") -> String {
        "{\"ok\":true,\"op\":\"slice.libraryRefresh\",\"outcome\":\"\(outcome)\",\"ticket\":\(ticket.map(String.init) ?? "null"),\"instance\":\"\(instance)\"}"
    }
    private var started7: String { reply("started", ticket: 7) }
    private let refused = """
    {"ok":false,"op":"slice.libraryRefresh","error":{"kind":"unknown_op","detail":"no such op"}}
    """

    /// A `sleep` that holds its FIRST call until the test lets it go, and says when
    /// it is held; every later call returns at once. The plain re-ask's wait.
    private final class FirstSleepGate {
        let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var held = false
        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
        func sleep(_ seconds: TimeInterval) {
            lock.lock(); calls += 1; let first = calls == 1; if first { held = true }; lock.unlock()
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        func open() { release.signal() }
    }

    private func scene(_ wire: BridgeLibraryReadsWire, status store: StatusStore = StatusStore(),
                       sleep: @escaping (TimeInterval) -> Void = { _ in }) -> PlaylistsScene {
        wire.stickyStatus = true
        return playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                  status: store, warmUpSleep: sleep, width: 120)
    }

    /// The scene on its first rail, with the capability probe read and its answer
    /// in hand (the footer shows it), so `r` finds the status reads where the
    /// test scripted them.
    private func settledScene(_ wire: BridgeLibraryReadsWire, status store: StatusStore = StatusStore(),
                              rail names: [String] = ["Alpha", "Bravo"],
                              sleep: @escaping (TimeInterval) -> Void = { _ in }) -> PlaylistsScene {
        let s = scene(wire, status: store, sleep: sleep)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == names }, "the first rail never landed")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.status", at: 0) }, "the capability probe never ran")
        XCTAssertTrue(settleScene(s) { s.footerHint.contains("  r R") }, "the footer never learned the capability")
        return s
    }

    private func text(_ store: StatusStore) -> String? { store.current()?.text }

    private func waitForText(_ store: StatusStore, _ expected: String, _ s: PlaylistsScene, line: UInt = #line) {
        XCTAssertTrue(settleScene(s) { self.text(store) == expected },
                      "the status line said \(text(store) ?? "nothing"), not \(expected)", line: line)
    }

    // MARK: - started, then the completion fact

    func testStartedThenInstalledRefreshesKeepsTheSelectionByIdAndSaysSo() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [started7]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)   // the first re-read, held while the shown rows are checked
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        XCTAssertTrue(s.footerHint.contains("r Refresh"), s.footerHint)
        _ = s.handle(.down)
        XCTAssertEqual(s.railCursorForTest, 1)

        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 1) }, "the re-read never went out")
        XCTAssertEqual(text(store), "Refreshing your playlists\u{2026}")
        // No blank flash: the shown rows and the cursor stand until the fresh list lands.
        XCTAssertEqual(s.railNamesForTest, ["Alpha", "Bravo"])
        XCTAssertEqual(s.railCursorForTest, 1)
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Alpha"))

        wire.release(op: "slice.libraryPlaylists", at: 1)
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] },
                      "the new playlist never appeared: \(s.railNamesForTest)")
        XCTAssertEqual(s.railCursorForTest, 2, "the selection stayed on index 1, which is now Alpha")
        XCTAssertNotEqual(store.current()?.isError, true)
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
        XCTAssertEqual(wire.sent("slice.libraryRefresh").first?.keys.sorted(), ["op"], "the op takes no params")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3, "the install was seen, so the list was read once more after it")
        XCTAssertEqual(wire.sent("slice.status").count, 4, "probe, capability, first check, the check that saw the install")
    }

    func testStartedThenFailedSaysSpanDACCouldNotRefreshAndStillShowsItsList() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([alpha, bravo])],
            "slice.status": [status(), status(), status(), failed(7)],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC couldn't refresh your playlists; showing the list it has.", s)
        XCTAssertEqual(store.current()?.isError, true)
        XCTAssertEqual(s.railNamesForTest, ["Alpha", "Bravo"])
        XCTAssertFalse(s.render(frame: frame, snapshot: idle).contains("press r to retry"), "a failed rebuild is not a failed rail")
    }

    /// An install of an OLDER ticket is not this ask's: it is waited out to the
    /// bound, and the sentence says it is still going rather than claiming a refresh.
    func testStartedThenBoundSpentSaysItIsStillRefreshing() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(6)]])
        wire.script("slice.libraryRefresh", [started7])
        wire.script("slice.libraryPlaylists", Array(repeating: rail([alpha, bravo]), count: 3))
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC is still refreshing; press r again shortly.", s)
        let intervals = Int(LibraryReask.maxTotalWait / LibraryReask.interval)
        // probe, capability, the check before the first read, then one per interval of the bound.
        XCTAssertEqual(wire.sent("slice.status").count, 3 + intervals, "the wait did not run to LibraryReask's bound")
        XCTAssertEqual(s.railNamesForTest, ["Alpha", "Bravo"])
        XCTAssertNotEqual(store.current()?.isError, true)
    }

    func testACancelledRebuildIsSaidLikeAFailedOne() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([alpha, bravo])],
            "slice.status": [status(), status(), status(), fact(7, "cancelled")],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC couldn't refresh your playlists; showing the list it has.", s)
        XCTAssertEqual(store.current()?.isError, true)
    }

    /// A fact from another SpanDAC process is not this ask's, whatever its ticket:
    /// waiting stops, the list is read once more, and the line says why.
    func testAFactFromAnotherInstanceMeansSpanDACRestartedAndStopsTheWait() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(99, instance: "inst-2")],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC restarted; showing its fresh list.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] }, "the list was not read again")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3)
        XCTAssertEqual(wire.sent("slice.status").count, 4, "the wait went on after the restart was seen")
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
    }

    /// `library_instance` is in every status object, so a restart shows while
    /// `library_refresh` is still null: at once, not after the bound.
    func testADifferentLibraryInstanceWhileTheFactIsNullMeansRestartedAtOnce() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(libraryInstance: "inst-1"), status(libraryInstance: "inst-1"),
                             status(libraryInstance: "inst-1"), status(libraryInstance: "inst-2")],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC restarted; showing its fresh list.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(wire.sent("slice.status").count, 4, "the wait went on after the restart was seen")
    }

    /// Without `library_instance` the fact's own instance is the fallback; with it
    /// matching, a null fact is simply not yet.
    func testAMatchingLibraryInstanceWithANullFactIsStillPending() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(libraryInstance: "inst-1"), status(libraryInstance: "inst-1"),
                             status(libraryInstance: "inst-1"), status(libraryInstance: "inst-1"),
                             status(fact: "{\"instance\":\"inst-1\",\"ticket\":7,\"result\":\"installed\"}",
                                    libraryInstance: "inst-1")],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
    }

    // MARK: - a reset revokes a refresh before it starts

    func testAResetBeforeTheWorkerStartsSendsNothingAndSaysNothing() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status()],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        let feed = s.playlistsFeedForTest
        feed.afterClaimForTest = { feed.reset() }   // the provenance switch lands between the claim and the worker
        let before = wire.requestCount
        _ = s.handle(.char("r"))
        XCTAssertTrue(feed.waitForWorkersForTest(timeout: 5), "the refresh worker never ended")
        XCTAssertEqual(wire.requestCount, before, "a revoked refresh still reached the wire")
        XCTAssertNil(text(store), "a revoked refresh still spoke")
    }

    // MARK: - joined is not started

    /// The drain a `joined` ask attached to may have read the library before `r`
    /// was pressed: its ticket is waited out, then the op is sent once more and
    /// that answer followed.
    func testJoinedWaitsForItsTicketThenAsksAgainAndFollowsTheSecondRebuild() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            // probe, capability, check before the first read, T installs (the follow-up goes out), U installs
            "slice.status": [status(), status(), status(), installed(7), installed(9)],
            "slice.libraryRefresh": [reply("joined", ticket: 7), reply("started", ticket: 9)]])
        wire.gate(op: "slice.libraryRefresh", at: 1)   // hold the follow-up
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryRefresh", at: 1) }, "no follow-up ask went out")
        XCTAssertEqual(text(store), "Refreshing your playlists\u{2026}", "T ending is not the refresh the person asked for")
        wire.release(op: "slice.libraryRefresh", at: 1)
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 2)
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3, "the list is read again once U's install is seen, not on T's")
    }

    func testJoinedThenTheFollowUpIsDeferredStopsWithTheDeferredLine() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [reply("joined", ticket: 7), reply("deferred", ticket: nil)]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC can't refresh right now; showing the list it has. Try again in a minute.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 2, "never more than one follow-up")
    }

    /// The follow-up answers `joined` U: that drain began after T ended, so after
    /// the keypress. It is waited on like any started one, with no further ask.
    func testJoinedThenTheFollowUpJoinsAgainWaitsForThatTicketAndTrustsItsInstall() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            // probe, capability, check before the first read, T ends (the follow-up goes out), U not yet, U installs
            "slice.status": [status(), status(), status(), installed(7), installed(7), installed(8)],
            "slice.libraryRefresh": [reply("joined", ticket: 7), reply("joined", ticket: 8), reply("joined", ticket: 9)]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 2, "never more than one follow-up")
        XCTAssertEqual(wire.sent("slice.status").count, 6, "U's install was not what ended the wait")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3, "the final read is the one after U's install")
    }

    func testJoinedThenTheFollowUpIsRefusedSaysSpanDACCouldNotRefresh() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [reply("joined", ticket: 7), refused]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC couldn't refresh your playlists; showing the list it has.", s)
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 2)
    }

    /// A joined ask whose own ticket never ends is waited out to the bound only,
    /// and no follow-up is sent for a drain that never finished.
    func testJoinedWhoseTicketNeverEndsSpendsTheBoundAndSendsNoFollowUp() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(6)],
            "slice.libraryRefresh": [reply("joined", ticket: 7)]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        waitForText(store, "SpanDAC is still refreshing; press r again shortly.", s)
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
    }

    // MARK: - A flagged read hands to the bounded re-ask

    func testAFlaggedReadIsShownThenTheReAskLandsTheDrainAndTheInstallIsSeen() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]),
                                       rail([alpha, bravo, gamma], flagged: true),            // the first re-read
                                       rail([alpha, bravo, gamma], flagged: false),           // the re-ask's probe
                                       rail([friday, alpha, bravo, gamma], flagged: false),   // the re-ask's re-read
                                       rail([friday, alpha, bravo, gamma], flagged: false)],  // the read after the install
            "slice.status": [status(), status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [started7]])
        wire.gate(op: "slice.libraryPlaylists", at: 2)   // hold the probe
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.down)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo", "Gamma"] }, "the flagged list was not shown")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 2) }, "the re-ask never probed")
        XCTAssertEqual(text(store), "Refreshing your playlists\u{2026}", "it must not claim a refresh before the install is seen")
        wire.release(op: "slice.libraryPlaylists", at: 2)
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo", "Gamma"] },
                      "the drain's result never landed: \(s.railNamesForTest)")
        XCTAssertEqual(s.railCursorForTest, 2, "the selection was not kept by id across the re-ask")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 5)
    }

    // MARK: - deferred

    func testDeferredSaysSoReReadsOnceAndDoesNotWait() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status()],
            "slice.libraryRefresh": [reply("deferred", ticket: nil)]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 1) }, "the re-read worker never ended")
        XCTAssertEqual(text(store), "SpanDAC can't refresh right now; showing the list it has. Try again in a minute.")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2, "a deferred refresh read the list more than once")
        XCTAssertEqual(wire.sent("slice.status").count, 2, "a deferred refresh waited on a completion fact")
    }

    // MARK: - not asked

    func testNotAdvertisedSendsNoOpSaysItIsOnlyReadingAgainAndStillReReads() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(advertising: false)]])
        let store = StatusStore()
        let s = scene(wire, status: store)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.status", at: 0) })
        XCTAssertTrue(settleScene(s) { s.footerHint.contains("r Reload") }, s.footerHint)
        XCTAssertFalse(s.footerHint.contains("r Refresh"))
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 1) })
        XCTAssertEqual(text(store), "Reading your playlists from SpanDAC again\u{2026}")
        XCTAssertTrue(wire.sent("slice.libraryRefresh").isEmpty, "the op was sent to a SpanDAC that does not list it")
    }

    func testARefusedOpSaysItIsOnlyReadingAgainAndStillReReads() {
        for refusal in [refused,
                        #"{"ok":false,"op":"slice.libraryRefresh","error":{"kind":"unauthorized","detail":"no access"}}"#,
                        #"{"ok":false,"op":"slice.libraryRefresh","error":{"kind":"unlicensed","detail":"not licensed"}}"#] {
            let wire = BridgeLibraryReadsWire([
                "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
                "slice.status": [status()],
                "slice.libraryRefresh": [refusal]])
            let store = StatusStore()
            let s = settledScene(wire, status: store)
            _ = s.handle(.char("r"))
            XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] }, refusal)
            XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 1) })
            XCTAssertEqual(text(store), "Reading your playlists from SpanDAC again\u{2026}", refusal)
            XCTAssertNotEqual(store.current()?.isError, true)
            XCTAssertEqual(wire.sent("slice.status").count, 2, "a refused op was followed by a wait for a completion fact")
        }
    }

    /// The previous contract's reply shape (no `outcome`) is not a refresh the
    /// client can follow: it is read as the ask not having been made.
    func testAReplyWithoutAnOutcomeIsNotCalledARefresh() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status()],
            "slice.libraryRefresh": [#"{"ok":true,"op":"slice.libraryRefresh","started":true}"#]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 1) })
        XCTAssertEqual(text(store), "Reading your playlists from SpanDAC again\u{2026}")
    }

    // MARK: - the list itself will not read

    func testAFailedReReadSaysSoAndKeepsTheRows() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), noAccess],
            "slice.status": [status()],
            "slice.libraryRefresh": [started7]])
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.down)
        _ = s.handle(.char("r"))
        waitForText(store, "Couldn't read your playlists.", s)
        XCTAssertEqual(store.current()?.isError, true)
        XCTAssertEqual(s.railNamesForTest, ["Alpha", "Bravo"])
        XCTAssertEqual(s.railCursorForTest, 1)
        XCTAssertFalse(s.render(frame: frame, snapshot: idle).contains("press r to retry"))
    }

    // MARK: - one at a time

    func testASecondRWhileTheRefreshIsInFlightStartsNothing() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [started7, started7]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 1) })
        _ = s.handle(.char("r"))
        XCTAssertEqual(text(store), "Already refreshing your playlists\u{2026}", "a repeated r said nothing")
        _ = s.handle(.char("r"))
        wire.release(op: "slice.libraryPlaylists", at: 1)
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 2) }, "the refresh worker never ended")
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3)
    }

    /// The running refresh ends in the gap after a second `r` is told "already
    /// refreshing". Its finished line must stay: it carries the one instruction
    /// for a new playlist, and the second `r` saying so must not cover it.
    func testTheFinishedLineWinsOverAnAlreadyRefreshingThatRacedIt() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(), status(), status(), installed(7)],
            "slice.libraryRefresh": [started7]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)
        let store = StatusStore()
        let s = settledScene(wire, status: store)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 1) })
        let feed = s.playlistsFeedForTest
        feed.afterAlreadyRefreshingForTest = {
            feed.afterAlreadyRefreshingForTest = nil
            wire.release(op: "slice.libraryPlaylists", at: 1)
            XCTAssertTrue(feed.waitForWorkersForTest(timeout: 5), "the refresh worker never ended")
        }
        _ = s.handle(.char("r"))
        XCTAssertEqual(text(store), "Playlists refreshed. New playlists need a song; press r again.",
                       "\"Already refreshing\" covered the finished line")
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
    }

    // MARK: - r during a plain stale re-ask takes over

    /// Opening Playlists on a stale snapshot starts the plain re-ask. `r` then must
    /// not be dropped by its single-flight: it sends the op, and the drain it joins
    /// predates the keypress, so the follow-up is exactly right. The old re-ask
    /// posts nothing once it is taken over.
    func testRDuringAPlainReAskTakesOverAndLandsThroughTheRefreshPath() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo], flagged: true),   // the walk: stale, so a plain re-ask waits
                                       rail([alpha, bravo]),                  // the refresh's first read
                                       rail([friday, alpha, bravo])],         // the read after U's install
            // probe, capability, check before the first read, T ends (the follow-up goes out), U installs
            "slice.status": [status(), status(), status(), installed(7), installed(9)],
            "slice.libraryRefresh": [reply("joined", ticket: 7), reply("started", ticket: 9)]])
        let gate = FirstSleepGate()
        let store = StatusStore()
        let s = settledScene(wire, status: store, sleep: gate.sleep)
        XCTAssertTrue(gate.isHeld, "the plain re-ask was not waiting")
        XCTAssertTrue(wire.sent("slice.libraryRefresh").isEmpty)
        _ = s.handle(.down)

        _ = s.handle(.char("r"))
        waitForText(store, "Playlists refreshed. New playlists need a song; press r again.", s)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(s.railCursorForTest, 2, "the selection was not kept by id")
        gate.open()   // the old re-ask wakes up, and finds it has been taken over
        XCTAssertTrue(s.playlistsFeedForTest.waitForWorkersForTest(timeout: 5), "a worker never ended")
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 2, "the ask, then its one follow-up")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 3, "the old re-ask read after it was taken over")
        XCTAssertEqual(text(store), "Playlists refreshed. New playlists need a song; press r again.", "the old re-ask spoke after the takeover")
        _ = s.tick(snapshot: idle)
        XCTAssertEqual(s.railNamesForTest, ["Friday", "Alpha", "Bravo"], "the old re-ask posted rows after the takeover")
    }

    // MARK: - a failure retry is unchanged

    func testRAfterAFailureRetriesAsBeforeAndSendsNoRefresh() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [noAccess, rail([alpha, bravo])],
            "slice.status": [status()],
            "slice.libraryRefresh": [started7]])
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("press r to retry") })
        XCTAssertFalse(s.footerHint.contains("r Refresh") || s.footerHint.contains("r Reload"), s.footerHint)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        XCTAssertTrue(wire.sent("slice.libraryRefresh").isEmpty, "a failure retry must not also ask SpanDAC to rebuild")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2)
    }
}

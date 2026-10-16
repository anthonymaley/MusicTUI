import XCTest
@testable import music

/// `r` on a HEALTHY SpanDAC Playlists rail refreshes it: SpanDAC is told to
/// rebuild (`slice.libraryRefresh`, only when it lists `library.refresh`), the
/// rail is read again with its rows and selection kept on screen, and the fresh
/// list swaps in by playlist id. Fakes only: the wire is `BridgeLibraryReadsWire`.
final class BridgePlaylistsRefreshTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private typealias Item = (id: String, title: String)
    private let alpha: Item = (id: "plA", title: "Alpha")
    private let bravo: Item = (id: "plB", title: "Bravo")
    private let friday: Item = (id: "plF", title: "Friday")

    private func rail(_ items: [Item], flagged: Bool = false) -> String {
        let rows = items.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"kind\":\"playlist\"}" }.joined(separator: ",")
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":\(items.count),"stale":\(flagged),"refreshing":\(flagged),
         "items":[\(rows)],"next_cursor":null}
        """
    }
    private func status(capabilities: [String]) -> String {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.status\",\"status\":{\"playback\":\"stopped\",\"capabilities\":[\(caps)]}}"
    }
    private let refreshOK = "{\"ok\":true,\"op\":\"slice.libraryRefresh\",\"refreshing\":true}"
    private let refreshUnknown = """
    {"ok":false,"op":"slice.libraryRefresh","error":{"kind":"unknown_op","detail":"no such op"}}
    """

    private func scene(_ wire: BridgeLibraryReadsWire, status store: StatusStore = StatusStore()) -> PlaylistsScene {
        wire.stickyStatus = true
        return playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                  status: store, width: 120)
    }

    /// Ops the refresh is about, in the order they reached the wire.
    private func refreshOps(_ wire: BridgeLibraryReadsWire) -> [String] {
        wire.opsInOrder().filter { $0 == "slice.libraryRefresh" || $0 == "slice.libraryPlaylists" }
    }

    // MARK: - With the capability

    func testRWithTheCapabilitySendsTheRefreshOnceThenReWalksAndKeepsTheSelectionById() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(capabilities: ["library.refresh"])],
            "slice.libraryRefresh": [refreshOK]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)   // the re-walk, held while the old rows are checked
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.down)
        XCTAssertEqual(s.railCursorForTest, 1)

        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 1) }, "the re-walk never went out")
        // No blank flash: the shown rows and the cursor stand until the fresh list lands.
        XCTAssertEqual(s.railNamesForTest, ["Alpha", "Bravo"])
        XCTAssertEqual(s.railCursorForTest, 1)
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains("Alpha"))

        wire.release(op: "slice.libraryPlaylists", at: 1)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] },
                      "the new playlist never appeared: \(s.railNamesForTest)")
        XCTAssertEqual(s.railCursorForTest, 2, "the selection stayed on index 1, which is now Alpha")
        XCTAssertEqual(refreshOps(wire), ["slice.libraryPlaylists", "slice.libraryRefresh", "slice.libraryPlaylists"],
                       "the refresh must go out once, before the re-walk")
        XCTAssertEqual(wire.sent("slice.libraryRefresh").first?.keys.sorted(), ["op"], "the op takes no params")
    }

    // MARK: - Without the capability

    func testRWithoutTheCapabilitySendsNoRefreshButStillReWalks() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(capabilities: ["play.library"])]])
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertTrue(wire.sent("slice.libraryRefresh").isEmpty, "the op was sent to a SpanDAC that does not list it")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2)
    }

    // MARK: - A refusal is not shown

    func testAnUnknownOpFromRefreshIsNotShownAndTheReWalkStillHappens() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(capabilities: ["library.refresh"])],
            "slice.libraryRefresh": [refreshUnknown]])
        let store = StatusStore()
        let s = scene(wire, status: store)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
        XCTAssertNotEqual(store.current()?.isError, true, "a refused refresh was shown as an error")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("no such op"))
        XCTAssertFalse(out.contains("update SpanDAC"))
        XCTAssertFalse(out.contains("press r to retry"))
    }

    func testARefreshThatFailsAtTheTransportIsNotShownEither() {
        // An unscripted `slice.libraryRefresh` answers `bad_request`: any refusal reads the same.
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(capabilities: ["library.refresh"])]])
        let store = StatusStore()
        let s = scene(wire, status: store)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        XCTAssertNotEqual(store.current()?.isError, true)
    }

    // MARK: - One at a time

    func testASecondRWhileTheRefreshIsInFlightStartsNothing() {
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]), rail([friday, alpha, bravo])],
            "slice.status": [status(capabilities: ["library.refresh"])],
            "slice.libraryRefresh": [refreshOK, refreshOK]])
        wire.gate(op: "slice.libraryPlaylists", at: 1)
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 1) })
        _ = s.handle(.char("r"))
        _ = s.handle(.char("r"))
        wire.release(op: "slice.libraryPlaylists", at: 1)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo"] })
        // The refresh worker has ended: a second refresh would have shown itself by now.
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryPlaylists", at: 1) })
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2)
    }

    // MARK: - A flagged reply hands to the re-ask

    func testAFlaggedReWalkIsShownThenTheBoundedReAskLandsTheDrain() {
        let gamma: Item = (id: "plG", title: "Gamma")
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [rail([alpha, bravo]),
                                       rail([alpha, bravo, gamma], flagged: true),               // the refresh re-walk
                                       rail([alpha, bravo, gamma], flagged: false),              // the probe
                                       rail([friday, alpha, bravo, gamma], flagged: false)],     // the re-walk
            "slice.status": [status(capabilities: ["library.refresh"])],
            "slice.libraryRefresh": [refreshOK]])
        wire.gate(op: "slice.libraryPlaylists", at: 2)   // hold the probe
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        _ = s.handle(.down)
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo", "Gamma"] }, "the flagged list was not shown")
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 2) }, "the re-ask never probed")
        wire.release(op: "slice.libraryPlaylists", at: 2)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Friday", "Alpha", "Bravo", "Gamma"] },
                      "the drain's result never landed: \(s.railNamesForTest)")
        XCTAssertEqual(s.railCursorForTest, 2, "the selection was not kept by id across the re-ask")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 4)
        XCTAssertEqual(wire.sent("slice.libraryRefresh").count, 1)
    }

    // MARK: - A failure retry is unchanged

    func testRAfterAFailureRetriesAsBeforeAndSendsNoRefresh() {
        let noAccess = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"unauthorized","detail":"no access"}}
        """
        let wire = BridgeLibraryReadsWire([
            "slice.libraryPlaylists": [noAccess, rail([alpha, bravo])],
            "slice.status": [status(capabilities: ["library.refresh"])],
            "slice.libraryRefresh": [refreshOK]])
        let s = scene(wire)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("press r to retry") })
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Alpha", "Bravo"] })
        XCTAssertTrue(wire.sent("slice.libraryRefresh").isEmpty, "a failure retry must not also ask SpanDAC to rebuild")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2)
    }

    // MARK: - The footer

    func testTheFooterOffersRefreshOnAHealthySpanDACRailOnly() {
        let noAccess = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"unauthorized","detail":"no access"}}
        """
        let healthy = scene(BridgeLibraryReadsWire(["slice.libraryPlaylists": [rail([alpha])]]))
        XCTAssertTrue(settleScene(healthy) { healthy.railNamesForTest == ["Alpha"] })
        XCTAssertTrue(healthy.footerHint.contains("r Refresh"), healthy.footerHint)

        let failed = scene(BridgeLibraryReadsWire(["slice.libraryPlaylists": [noAccess]]))
        XCTAssertTrue(settleScene(failed) { failed.render(frame: frame, snapshot: idle).contains("press r to retry") })
        XCTAssertFalse(failed.footerHint.contains("r Refresh"), failed.footerHint)
    }
}

// tools/music/Tests/MusicTests/SpanDACNowControlsTests.swift
import XCTest
@testable import music

/// SpanDAC on the Now tab: the cover by persistent ID, and the Shuffle / Repeat
/// cells of the existing control grid. Nothing here touches a real Music.app or
/// SpanDAC: the extractor is a fake (or a fake osascript), and the wire is a
/// recording closure.
final class SpanDACNowControlsTests: XCTestCase {

    private let alias = "-596357614188841472"        // SpanDAC's signed decimal, verbatim
    private let hex = "F7B94FE8D72CB600"             // what AppleScript's `persistent ID is` takes

    private func playingReply(extra: String, playback: String = "playing") -> String {
        #"{"ok":true,"op":"slice.status","status":{"playback":"\#(playback)","contract":3,"authorization":"authorized","title":"Teardrop","artist":"Massive Attack"\#(extra),"queue":{"phase":"complete","requested":275,"present":275,"index":0}}}"#
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private let frame = shellLayout(width: 120, height: 40)

    private func snapshot(extra: String = "", playback: String = "playing") throws -> NowPlayingSnapshot {
        let store = NowPlayingStore()
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.source)
        let reply = playingReply(extra: extra, playback: playback)
        let client = { SourceAppClient(path: "/nonexistent", transport: { _, _ in reply }) }
        let p = PlaybackPoller(store: store, backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                               queueStore: QueueStore(path: NSTemporaryDirectory() + "q-\(UUID().uuidString).json"),
                               routing: RoutingCoordinator(store: modeStore, surface: .tui, makeSource: client),
                               makeSourceClient: client)
        p.tick()
        return store.read()
    }

    private func scene(transport: @escaping (String, String) throws -> String = { _, _ in "{}" },
                       status: StatusStore = StatusStore(),
                       extractor: ((String, String) -> String?)? = nil,
                       backend: AppleScriptBackend = AppleScriptBackend(executable: "/usr/bin/true")) -> (NowPlayingScene, ActionRunner) {
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(.source)
        let actions = ActionRunner(status: status)
        let s = NowPlayingScene(backend: backend, appQueue: AppQueueStore(), status: status, actions: actions,
                                routing: RoutingCoordinator(store: modeStore, surface: .tui,
                                                            makeSource: { SourceAppClient(path: "/nonexistent", transport: transport) }),
                                bridgeCoverExtractor: extractor)
        return (s, actions)
    }

    // MARK: - persistent_id on the wire

    func testStatusDecodesPersistentIDVerbatimAndAbsentIsNil() throws {
        let with = try SourceAppControl(path: "/nonexistent", transport: { _, _ in
            self.playingReply(extra: #","persistent_id":"\#(self.alias)""#) }).status()
        XCTAssertEqual(with.persistentID, alias)
        XCTAssertEqual(bridgeNow(from: with).persistentID, alias)

        for extra in ["", #","persistent_id":"""#, #","persistent_id":5"#] {
            let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in self.playingReply(extra: extra) }).status()
            XCTAssertNil(s.persistentID, "\(extra)")
            XCTAssertNil(bridgeNow(from: s).persistentID)
        }
    }

    // MARK: - the art rung

    func testRungPrefersAFetchableURLThenThePersistentID() {
        XCTAssertEqual(bridgeCoverSource(artworkURL: "https://x/y.jpg", persistentID: alias), .remote("https://x/y.jpg"))
        XCTAssertEqual(bridgeCoverSource(artworkURL: nil, persistentID: alias), .library(persistentID: hex))
        XCTAssertEqual(bridgeCoverSource(artworkURL: "musicKit://artwork/transient/abc", persistentID: alias),
                       .library(persistentID: hex), "a non-http URL is ignored")
        XCTAssertEqual(bridgeCoverSource(artworkURL: "musicKit://artwork/transient/abc", persistentID: nil), .none)
        XCTAssertEqual(bridgeCoverSource(artworkURL: nil, persistentID: "F7B94FE8D72CB600"), .none, "the hex form is not what SpanDAC sends")
    }

    func testAPersistentIDThatDoesNotConvertIsAbsent() {
        for bad in ["", "abc", "12x4", "99999999999999999999999", "--5", "1.5"] {
            XCTAssertEqual(bridgeCoverSource(artworkURL: nil, persistentID: bad), .none, bad)
        }
    }

    /// Only a persistent ID, no http URL: the Now tab asks the library, once,
    /// with the HEX AppleScript takes, and not at all when a URL is fetchable.
    func testSceneExtractsByHexOnceAndOnlyWithoutAFetchableURL() throws {
        var calls: [(String, String)] = []
        let lock = NSLock()
        let (s, _) = scene(extractor: { pid, path in lock.lock(); calls.append((pid, path)); lock.unlock(); return nil })

        var snap = try snapshot(extra: #","persistent_id":"\#(alias)","artwork_url":"musicKit://artwork/transient/abc""#)
        XCTAssertEqual(snap.bridge?.persistentID, alias)
        s.tick(snapshot: snap); s.tick(snapshot: snap)
        s.waitForBridgeCover()
        XCTAssertEqual(calls.count, 1, "asked once per song, hit or miss")
        XCTAssertEqual(calls.first?.0, hex)
        XCTAssertTrue(calls.first?.1.hasPrefix("/tmp/music-lib-art-spandac-\(hex)") ?? false, "\(calls)")

        calls = []
        snap.bridge?.persistentID = "-1"
        snap.bridge?.artworkURL = "https://x/y.jpg"
        s.tick(snapshot: snap); s.waitForBridgeCover()
        XCTAssertTrue(calls.isEmpty, "a fetchable URL wins; nothing is extracted")

        snap.bridge?.artworkURL = nil
        snap.bridge?.persistentID = "not-a-number"
        s.tick(snapshot: snap); s.waitForBridgeCover()
        XCTAssertTrue(calls.isEmpty, "an unconvertible ID is absent")
    }

    /// Through the real extraction function with a FAKE interpreter: the script
    /// that reaches "osascript" names the hex, the cover lands, and the scene
    /// reports a repaint.
    func testSceneDrivesLibraryExtractionThroughTheBackendAndRepaints() throws {
        let dir = NSTemporaryDirectory() + "fake-osa-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let record = dir + "/script.txt"
        let fake = dir + "/osascript"
        // $1 is -e, $2 the script. Reports OK without writing any cover.
        try "#!/bin/sh\nprintf '%s' \"$2\" > '\(record)'\necho OK\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let (s, _) = scene(backend: AppleScriptBackend(executable: fake))
        let snap = try snapshot(extra: #","persistent_id":"\#(alias)""#)
        s.tick(snapshot: snap)
        s.waitForBridgeCover()
        let script = try String(contentsOfFile: record, encoding: .utf8)
        XCTAssertTrue(script.contains(#"persistent ID is "\#(hex)""#), script)
        XCTAssertTrue(s.tick(snapshot: snap), "a landed cover must ask for a repaint")
        sweepLibraryArtFiles()
    }

    // MARK: - shuffle and repeat in the existing grid

    private let both = #","shuffle":true,"repeat":"all","capabilities":["slice.status","slice.shuffle","slice.repeat"]"#

    func testStatusDecodesShuffleRepeatAndCapabilitiesAndRejectsMalformed() throws {
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in self.playingReply(extra: self.both) }).status()
        XCTAssertEqual(s.shuffle, true)
        XCTAssertEqual(s.repeatMode, "all")
        XCTAssertTrue(s.offersShuffle && s.offersRepeat)
        let b = bridgeNow(from: s)
        XCTAssertEqual(b.shuffle, true); XCTAssertEqual(b.repeatMode, "all")
        XCTAssertTrue(b.offersShuffle && b.offersRepeat)

        // An older build sends none of it; a malformed value is unknown, not a failure.
        for extra in ["", #","shuffle":1,"repeat":"loop","capabilities":"slice.shuffle""#] {
            let o = try SourceAppControl(path: "/nonexistent", transport: { _, _ in self.playingReply(extra: extra) }).status()
            XCTAssertNil(o.shuffle, extra); XCTAssertNil(o.repeatMode, extra)
            XCTAssertFalse(o.offersShuffle || o.offersRepeat, extra)
        }
        let one = try SourceAppControl(path: "/nonexistent", transport: { _, _ in
            self.playingReply(extra: #","capabilities":["slice.repeat"]"#) }).status()
        XCTAssertTrue(one.offersRepeat); XCTAssertFalse(one.offersShuffle)
    }

    func testTheOpsGoOutAsSpecified() throws {
        var lines: [[String: Any]] = []
        let c = SourceAppControl(path: "/nonexistent", transport: { _, line in
            lines.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
            return #"{"ok":true,"op":"x"}"#
        })
        try c.setShuffle(true); try c.setShuffle(false)
        for m in [RepeatMode.off, .one, .all] { try c.setRepeat(m) }
        XCTAssertEqual(lines.map { $0["op"] as? String },
                       ["slice.shuffle", "slice.shuffle", "slice.repeat", "slice.repeat", "slice.repeat"])
        XCTAssertEqual(lines.prefix(2).map { $0["on"] as? Bool }, [true, false])
        XCTAssertEqual(lines.suffix(3).map { $0["mode"] as? String }, ["off", "one", "all"])
    }

    func testGridModelOnSpanDAC() {
        XCTAssertEqual((0..<4).map { ControlGrid.spanDACEnabled(row: $0, offersShuffle: true, offersRepeat: true) },
                       [true, false, true, false])
        XCTAssertFalse(ControlGrid.spanDACEnabled(row: 0, offersShuffle: false, offersRepeat: true))
        XCTAssertEqual(ControlGrid.spanDACActiveColumn(row: 0, shuffle: true, repeatMode: nil), 0)
        XCTAssertEqual(ControlGrid.spanDACActiveColumn(row: 0, shuffle: false, repeatMode: nil), 1)
        XCTAssertNil(ControlGrid.spanDACActiveColumn(row: 0, shuffle: nil, repeatMode: nil))
        XCTAssertEqual(["off", "all", "one"].map { ControlGrid.spanDACActiveColumn(row: 2, shuffle: nil, repeatMode: $0) }, [0, 1, 2])
        XCTAssertNil(ControlGrid.spanDACActiveColumn(row: 1, shuffle: true, repeatMode: "all"))
        XCTAssertNil(ControlGrid.spanDACActiveColumn(row: 3, shuffle: true, repeatMode: "all"))
        XCTAssertEqual(ControlGrid.spanDACStep(from: 0, by: 1, offersShuffle: true, offersRepeat: true), 2, "skips Order")
        XCTAssertEqual(ControlGrid.spanDACStep(from: 2, by: 1, offersShuffle: true, offersRepeat: true), 2, "Genius is off")
        XCTAssertEqual(ControlGrid.spanDACStep(from: 2, by: -1, offersShuffle: true, offersRepeat: true), 0)
        XCTAssertEqual(ControlGrid.spanDACStep(from: 0, by: 1, offersShuffle: true, offersRepeat: false), 0)
    }

    func testGridShowsSpanDACsStateAndDimsOrderAndGenius() throws {
        let (s, _) = scene()
        let raw = s.render(frame: frame, snapshot: try snapshot(extra: both))
        let text = plain(raw)
        for label in ["Shuffle", "Order", "Repeat", "Genius"] { XCTAssertTrue(text.contains(label), label) }
        XCTAssertTrue(text.contains("[On]"), text)
        XCTAssertTrue(text.contains("[All]"), text)
        XCTAssertFalse(text.contains("[Off]") || text.contains("[One]"), text)
        XCTAssertFalse(text.contains("aren't available on SpanDAC"), text)
        // Order and Genius cells are dim and struck through, with no active cell.
        for cell in ["Songs", "Shuffle now"] {
            XCTAssertTrue(raw.contains("\(ANSICode.dim)\u{1B}[9m \(cell) "), cell)
            XCTAssertFalse(text.contains("[\(cell)]"))
        }
        XCTAssertTrue(s.footerHint.contains("Controls"), s.footerHint)

        let off = plain(scene().0.render(frame: frame, snapshot: try snapshot(
            extra: #","shuffle":false,"repeat":"one","capabilities":["slice.shuffle","slice.repeat"]"#)))
        XCTAssertTrue(off.contains("[Off]") && off.contains("[One]"), off)
    }

    /// An older SpanDAC lists neither op: today's sentence, no grid, nothing sent.
    func testAnOlderSpanDACKeepsTheSentenceAndSendsNothing() throws {
        var lines: [String] = []
        let status = StatusStore()
        let (s, actions) = scene(transport: { _, line in lines.append(line); return "{}" }, status: status)
        let snap = try snapshot()
        s.tick(snapshot: snap)
        let text = plain(s.render(frame: frame, snapshot: snap))
        XCTAssertTrue(text.contains("Shuffle and repeat aren't available on SpanDAC."), text)
        XCTAssertFalse(text.contains("Genius"), text)
        XCTAssertEqual(s.footerHint, "[ ] Seek  x Quiet")
        XCTAssertEqual(s.handle(.left), .none)
        for k in [KeyPress.char("s"), .char("r"), .enter] { _ = s.handle(k) }
        actions.waitUntilIdle()
        XCTAssertTrue(lines.isEmpty, "\(lines)")
        XCTAssertEqual(status.current()?.text, "Shuffle and repeat aren't available on SpanDAC.")
    }

    func testPressingTheCellsSendsTheOpsAndMovesTheCellAtOnce() throws {
        var lines: [[String: Any]] = []
        let lock = NSLock()
        let transport: (String, String) throws -> String = { _, line in
            lock.lock(); defer { lock.unlock() }
            lines.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
            return #"{"ok":true,"op":"x"}"#
        }
        let (s, actions) = scene(transport: transport)
        let snap = try snapshot(extra: both)       // shuffle on, repeat all
        s.tick(snapshot: snap)
        _ = s.render(frame: frame, snapshot: snap)

        func press(_ key: KeyPress) { _ = s.handle(key); actions.waitUntilIdle() }
        press(.left)                                // focus the grid: lands on Shuffle
        XCTAssertTrue(s.footerHint.contains("Row"), s.footerHint)
        press(.enter)                               // shuffle on -> off
        XCTAssertTrue(plain(s.render(frame: frame, snapshot: snap)).contains("[Off]"), "the cell moves before the next poll")
        press(.down)                                // skips Order: Repeat
        press(.enter)                               // all -> one
        press(.down)                                // Genius is disabled: stays
        press(.enter)                               // one -> off
        XCTAssertEqual(lines.map { $0["op"] as? String }, ["slice.shuffle", "slice.repeat", "slice.repeat"])
        XCTAssertEqual(lines[0]["on"] as? Bool, false)
        XCTAssertEqual(lines[1]["mode"] as? String, "one")
        XCTAssertEqual(lines[2]["mode"] as? String, "off")

        lines = []
        press(.char("s")); press(.char("r"))        // the keys do the same
        XCTAssertEqual(lines.map { $0["op"] as? String }, ["slice.shuffle", "slice.repeat"])
        XCTAssertEqual(lines[0]["on"] as? Bool, true, "the override remembers the last press, not the stale status")
    }

    func testOrderAndGeniusAreRefusedInWordsAndNeverReachMusicApp() throws {
        var lines: [String] = []
        let status = StatusStore()
        let (s, actions) = scene(transport: { _, line in lines.append(line); return "{}" }, status: status)
        let snap = try snapshot(extra: both)
        s.tick(snapshot: snap); _ = s.render(frame: frame, snapshot: snap)
        _ = s.handle(.char("m")); actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, "Order isn't available on SpanDAC.")
        XCTAssertTrue(lines.isEmpty)
    }

    func testAFailedPressPutsTheCellBack() throws {
        struct Boom: Error {}
        let (s, actions) = scene(transport: { _, _ in throw Boom() })
        let snap = try snapshot(extra: both)
        s.tick(snapshot: snap); _ = s.render(frame: frame, snapshot: snap)
        _ = s.handle(.char("s")); actions.waitUntilIdle()
        XCTAssertTrue(plain(s.render(frame: frame, snapshot: snap)).contains("[On]"))
    }

    func testTheTUIAndTheCLIBothServeShuffleAndRepeatOnSpanDAC() {
        for a in [MusicTUIAction.persistentShuffleMode, .persistentRepeatMode] {
            XCTAssertEqual(routeAction(a, in: .source, from: .tui), .source, "\(a)")
            XCTAssertEqual(routeAction(a, in: .source, from: .cli), .source, "\(a)")
        }
    }
}

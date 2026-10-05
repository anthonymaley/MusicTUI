// tools/music/Tests/MusicTests/SpanDACNowControlsTests.swift
import XCTest
@testable import music

/// SpanDAC on the Now tab: the cover by persistent ID, and the visible control
/// row. Nothing here touches a real Music.app or SpanDAC: the extractor is a
/// fake (or a fake osascript), and the wire is a recording closure.
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

    // MARK: - the control row

    func testControlRowRendersOnSpanDACWithKeysAndReflectsState() throws {
        let playing = plain(scene().0.render(frame: frame, snapshot: try snapshot(extra: #","position_s":65,"duration_s":312"#)))
        for text in ["Prev <", "Pause Space", "Next \u{25B6}\u{25B6} >", "-30s [", "+30s ]"] {
            XCTAssertTrue(playing.contains(text), "\(text)\n\(playing)")
        }
        let paused = plain(scene().0.render(frame: frame, snapshot: try snapshot(playback: "paused")))
        XCTAssertTrue(paused.contains("Play Space"))
        XCTAssertFalse(paused.contains("Pause Space"))
        // Without a duration there is no bar, and the controls are still there.
        XCTAssertTrue(paused.contains("Prev <"))
    }

    func testControlRowIsNotInTheFooterUntilDrawnAndFooterNamesIt() throws {
        let (s, _) = scene()
        XCTAssertEqual(s.footerHint, "[ ] Seek  x Quiet")
        _ = s.render(frame: frame, snapshot: try snapshot())
        XCTAssertEqual(s.footerHint, "\u{2190}\u{2192} Control  Enter Press  [ ] Seek  x Quiet")
    }

    func testEveryCellMapsToTheKeyAlreadyOnTheFooter() {
        for t in SpanDACTransport.allCases {
            if let g = t.global { XCTAssertEqual(resolveGlobalKey(t.key), g, "\(t)") }
        }
        XCTAssertEqual(SpanDACTransport.previous.global, .prev)
        XCTAssertEqual(SpanDACTransport.playPause.global, .playPause)
        XCTAssertEqual(SpanDACTransport.next.global, .next)
        XCTAssertEqual(SpanDACTransport.seekBack.seekOffset, -30)
        XCTAssertEqual(SpanDACTransport.seekForward.seekOffset, 30)
        XCTAssertEqual(SpanDACTransport.allCases.map(\.keyLabel), ["<", "Space", ">", "[", "]"])
    }

    /// Arrow-select + Enter reaches the wire with the same ops the keys send.
    func testArrowsAndEnterSendTheSameOpsAsTheKeys() throws {
        var lines: [String] = []
        let lock = NSLock()
        let transport: (String, String) throws -> String = { _, line in
            lock.lock(); lines.append(line); lock.unlock()
            if line.contains("slice.status") { return self.playingReply(extra: "") }
            return #"{"ok":true,"op":"x"}"#
        }
        let (s, actions) = scene(transport: transport)
        let snap = try snapshot()
        s.tick(snapshot: snap)
        _ = s.render(frame: frame, snapshot: snap)

        func press(_ key: KeyPress) -> SceneAction { let a = s.handle(key); actions.waitUntilIdle(); return a }
        XCTAssertEqual(press(.enter), .redraw)                                   // Prev
        _ = press(.right); XCTAssertEqual(press(.enter), .redraw)                // Play/pause (playing -> pause)
        _ = press(.right); XCTAssertEqual(press(.enter), .redraw)                // Next
        _ = press(.right); XCTAssertEqual(press(.enter), .redraw)                // -30s
        _ = press(.right); XCTAssertEqual(press(.enter), .redraw)                // +30s
        _ = press(.right); XCTAssertEqual(press(.enter), .redraw)                // wraps to Prev

        let ops = lines.compactMap { line -> String? in
            guard let r = line.range(of: #""op":"slice\.[a-z]+""#, options: .regularExpression) else { return nil }
            return String(line[r]).replacingOccurrences(of: #""op":""#, with: "").replacingOccurrences(of: "\"", with: "")
        }
        XCTAssertEqual(ops, ["slice.previous", "slice.status", "slice.pause", "slice.next",
                             "slice.seek", "slice.seek", "slice.previous"])
        let seeks = lines.filter { $0.contains("slice.seek") }
        XCTAssertTrue(seeks[0].contains("-30"), seeks[0])
        XCTAssertTrue(seeks[1].contains("30") && !seeks[1].contains("-30"), seeks[1])

        // The footer's own seek keys send the identical request.
        lines = []
        _ = press(.char("[")); _ = press(.char("]"))
        func offsets(_ ls: [String]) -> [Double] {
            ls.filter { $0.contains("slice.seek") }.compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["offset"] as? Double
            }
        }
        XCTAssertEqual(offsets(lines), [-30, 30])
        XCTAssertEqual(offsets(Array(seeks.prefix(2))), [-30, 30])
    }

    func testArrowsDoNothingBeforeTheRowIsDrawn() {
        let (s, _) = scene()
        XCTAssertEqual(s.handle(.left), .none)
        XCTAssertEqual(s.handle(.enter), .none)
    }
}

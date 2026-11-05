// tools/music/Tests/MusicTests/DJBoxSceneTests.swift
//
// The DJ box on the Now tab, driven through the real scene over a real
// `RoutingCoordinator` and the SceneDataRig's fake SpanDAC clients, with a fake
// reader (the Apple model is never asked), a fake AppleScript runner for the
// MusicTUI-data library read, a fake SpanDAC genre source, a hand-off spy and a
// recording queue player. No test reaches a real player, a socket, osascript,
// the keychain, the network or ~/.config/music (the external-call tripwire is
// armed for every test).
//
// What these pin: the box is reached by moving down past the last row of the
// control grid or of Up Next, takes raw input (Space included) and asks off the
// input loop; a newer prompt wins and a stale answer (an error too) never
// lands; Enter on the request plays it the moment the answer arrives, with no
// card and no second Enter, once; a source, output or play change between
// Enter and the play stops it and says so; an artist mix is SpanDAC data on a
// SpanDAC output only and refuses every other combination before any read or
// add; the box says what played and empties.
import XCTest
@testable import music

/// A reader whose answers are scripted by prompt and can be held until released.
final class DJFakeReader: DJReader, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: DJReading] = [:]
    private var gates: [String: DispatchSemaphore] = [:]
    private var _asked: [String] = []

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    func answer(_ prompt: String, with reading: DJReading) {
        lock.lock(); answers[prompt] = reading; lock.unlock()
    }

    func hold(_ prompt: String) {
        lock.lock(); gates[prompt] = DispatchSemaphore(value: 0); lock.unlock()
    }

    func release(_ prompt: String) {
        lock.lock(); let gate = gates[prompt]; lock.unlock()
        gate?.signal()
    }

    private func begin(_ prompt: String) -> DispatchSemaphore? {
        lock.lock(); defer { lock.unlock() }
        _asked.append(prompt)
        return gates[prompt]
    }

    private func answer(for prompt: String) -> DJReading {
        lock.lock(); defer { lock.unlock() }
        return answers[prompt] ?? .card(.unsupported)
    }

    func read(_ prompt: String) async -> DJReading {
        if let gate = begin(prompt) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { _ = gate.wait(timeout: .now() + 10); done.resume() }
            }
        }
        return answer(for: prompt)
    }
}

/// A scripted SpanDAC genre source.
final class DJFakeGenreSource: DJSpanDACGenreSource, @unchecked Sendable {
    private let lock = NSLock()
    var result: Result<DJSpanDACGenrePick, Error>
    var recheckError: Error?
    /// When set, `recheck` signals `recheckStarted` and waits here (at most 5 s) before answering.
    var recheckGate: DispatchSemaphore?
    let recheckStarted = DispatchSemaphore(value: 0)
    private var _asked: [(genre: String, days: Int)] = []
    private var _rechecks = 0
    var asked: [(genre: String, days: Int)] { lock.lock(); defer { lock.unlock() }; return _asked }
    var rechecks: Int { lock.lock(); defer { lock.unlock() }; return _rechecks }

    init(_ result: Result<DJSpanDACGenrePick, Error>) { self.result = result }

    func genreUnheard(genre: String, days: Int) throws -> DJSpanDACGenrePick {
        lock.lock(); _asked.append((genre, days)); let r = result; lock.unlock()
        return try r.get()
    }

    func recheck(_ pick: DJSpanDACGenrePick) throws {
        lock.lock(); _rechecks += 1; let e = recheckError; let gate = recheckGate; lock.unlock()
        if let gate { recheckStarted.signal(); _ = gate.wait(timeout: .now() + 5) }
        if let e { throw e }
    }
}

/// Records every hand-off; succeeds.
private final class DJHandoffSpy: MusicTUIHandoff {
    private let lock = NSLock()
    private var _calls: [[MusicRow]] = []
    var calls: [[MusicRow]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                     title: String) throws -> HandoffPlayReport {
        lock.lock(); _calls.append(rows); lock.unlock()
        return HandoffPlayReport()
    }
}

/// Counts what the MusicTUI-data genre play does, with the real queue store.
private final class DJPlayLog {
    private let lock = NSLock()
    private var _queues: [AppQueue] = []
    var queues: [AppQueue] { lock.lock(); defer { lock.unlock() }; return _queues }
    func record(_ q: AppQueue) { lock.lock(); _queues.append(q); lock.unlock() }
}

final class DJNowBoxTests: XCTestCase {

    private let fs = "\u{1F}", rs = "\u{1E}"
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let frame = shellLayout(width: 120, height: 40)

    /// What every tick and render sees: a track playing, SpanDAC answering, no
    /// Up Next rows and no grid (so the box is the first thing ↓ reaches). A
    /// Bridge snapshot, so a tick starts no Music.app read of its own.
    private let snap: NowPlayingSnapshot = {
        var np = NowPlayingState()
        np.track = "Teardrop"; np.artist = "Massive Attack"; np.state = "playing"
        var s = NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])
        s.bridge = BridgeNow(link: .answering, playback: "playing", title: "Teardrop", artist: "Massive Attack",
                             queue: .none, index: nil)
        return s
    }()

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

    private static let statusWithArtists = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":["search.artist","slice.artistAlbums"]}}"#
    private static let statusWithoutArtists = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":[]}}"#

    private static func searchReply(_ records: String) -> String {
        #"{"ok":true,"op":"slice.search","records":\#(records)}"#
    }

    private static func albumsReply(_ ids: [String], more: Bool = false) -> String {
        let records = ids.map { #"{"kind":"album","id":"\#($0)","title":"Title \#($0)","subtitle":"A"}"# }
        return #"{"ok":true,"op":"slice.artistAlbums","records":[\#(records.joined(separator: ","))],"more":\#(more)}"#
    }

    /// `ids` available songs, each with a length; `unavailable` ids with a null length.
    private static func tracksReply(_ ids: [String], unavailable: Set<String> = []) -> String {
        let items = ids.map { id -> String in
            let length = unavailable.contains(id) ? "null" : "180000"
            return #"{"id":"\#(id)","kind":"song","name":"Track \#(id)","subtitle":"A","duration_ms":\#(length)}"#
        }
        return #"{"ok":true,"op":"slice.containerTracks","items":[\#(items.joined(separator: ","))]}"#
    }

    private static func ids(_ prefix: String, _ n: Int) -> [String] { (1...n).map { "\(prefix)\($0)" } }

    /// Radiohead: three albums of 20 songs; album two repeats album one's first
    /// song and holds three songs with no length. 60 listed, 1 repeated, so 59
    /// distinct, 3 unavailable, 56 playable.
    private static let radioheadAlbum1 = ids("a", 20)
    private static let radioheadAlbum2 = ["a1"] + ids("b", 19)
    private static let radioheadAlbum3 = ids("c", 20)
    private static let radioheadUnavailable: Set<String> = ["b2", "b3", "b4"]

    private struct Fixture {
        let rig: SceneDataRig
        let scene: NowPlayingScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let reader: DJFakeReader
        let handoff: DJHandoffSpy
        let store: AppQueueStore
        let plays: DJPlayLog
        let scripts: ScriptCalls
    }

    private final class ScriptCalls {
        private let lock = NSLock()
        private var _count = 0
        var reply: () throws -> String = { throw AppleScriptBackend.ScriptError.executionFailed("no script wired") }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func run() throws -> String { lock.lock(); _count += 1; lock.unlock(); return try reply() }
    }

    private func fixture(output: PlaybackMode, accepted: Bool = true, artists: Bool = true,
                         genreSource: DJSpanDACGenreSource? = nil) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: accepted)
        rig.replies["slice.status"] = artists ? Self.statusWithArtists : Self.statusWithoutArtists
        rig.responders["slice.search"] = { body in
            switch body["term"] as? String {
            case "Radiohead":
                return Self.searchReply(#"[{"kind":"artist","id":"art1","title":"Radiohead"},{"kind":"artist","id":"art2","title":"Radiohead Tribute"}]"#)
            case "Nirvana":
                return Self.searchReply(#"[{"kind":"artist","id":"n1","title":"Nirvana"},{"kind":"artist","id":"n2","title":"Nirvana"}]"#)
            case "Beatles":
                return Self.searchReply(#"[{"kind":"artist","id":"b1","title":"The Beatles"}]"#)
            case "Rad":
                return Self.searchReply(#"[{"kind":"artist","id":"r1","title":"Radio Dept"},{"kind":"artist","id":"r2","title":"Radio Head Fan"}]"#)
            case "Many":
                return Self.searchReply("[" + ["One", "Two", "Three", "Four", "Five"].enumerated().map {
                    #"{"kind":"artist","id":"m\#($0.offset + 1)","title":"Many \#($0.element)"}"#
                }.joined(separator: ",") + "]")
            case "Nobody":
                return Self.searchReply("[]")
            case "Broken":
                return #"{"ok":false,"op":"slice.search","error":{"kind":"unavailable","detail":"Apple Music isn't answering."}}"#
            default:
                return Self.searchReply("[]")
            }
        }
        rig.responders["slice.artistAlbums"] = { body in
            switch body["id"] as? String {
            case "art1": return Self.albumsReply(["alb1", "alb2", "alb3"])
            case "n1":   return Self.albumsReply(["na"])
            case "n2":   return Self.albumsReply(["nb"])
            case "b1":   return Self.albumsReply(["alb1"], more: true)
            case "r1":   return Self.albumsReply(["alb1"])
            case "m3":   return Self.albumsReply(["na"])
            default:     return Self.albumsReply([])
            }
        }
        rig.responders["slice.containerTracks"] = { body in
            switch body["id"] as? String {
            case "alb1": return Self.tracksReply(Self.radioheadAlbum1)
            case "alb2": return Self.tracksReply(Self.radioheadAlbum2, unavailable: Self.radioheadUnavailable)
            case "alb3": return Self.tracksReply(Self.radioheadAlbum3)
            case "na":   return Self.tracksReply(["na1", "na2"])
            case "nb":   return Self.tracksReply(["nb1", "nb2", "nb3"])
            case "bad":  return #"{"ok":false,"op":"slice.containerTracks","error":{"kind":"unavailable","detail":"nope"}}"#
            default:     return Self.tracksReply([])
            }
        }
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let reader = DJFakeReader()
        let handoff = DJHandoffSpy()
        let store = AppQueueStore()
        let plays = DJPlayLog()
        let scripts = ScriptCalls()
        var seams = DJSeams()
        seams.reader = reader
        seams.runScript = { _, _ in try scripts.run() }
        seams.spandacGenre = { _ in genreSource ?? DJFakeGenreSource(.failure(DJGenreSourceError.needsNewerSpanDAC)) }
        seams.appQueue = store
        seams.playFirst = { plays.record($0); return true }
        seams.handoff = handoff
        seams.shuffler = DJReverseShuffle()
        seams.now = { self.fixedNow }
        let scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: store,
                                    status: status, actions: actions, routing: routing, dj: seams)
        return Fixture(rig: rig, scene: scene, routing: routing, status: status, actions: actions,
                       reader: reader, handoff: handoff, store: store, plays: plays, scripts: scripts)
    }

    private func ticks(_ f: Fixture, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline {
            _ = f.scene.tick(snapshot: snap)
            usleep(2_000)
        }
        XCTAssertTrue(done(), "timed out", file: file, line: line)
    }

    private func settle(_ f: Fixture, seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = f.scene.tick(snapshot: snap)
            usleep(2_000)
        }
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func screen(_ f: Fixture) -> String { plain(f.scene.render(frame: frame, snapshot: snap)) }

    /// ↓ into the box, as a person does: the first frame is drawn, then the key.
    private func focus(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        if !f.scene.boxFocused {
            _ = f.scene.render(frame: frame, snapshot: snap)
            _ = f.scene.handle(.down)
        }
        XCTAssertTrue(f.scene.boxFocused, "↓ did not reach the box", file: file, line: line)
    }

    private func type(_ f: Fixture, _ text: String) {
        for c in text { _ = f.scene.handle(c == " " ? .space : .char(c)) }
    }

    private func stage(_ f: Fixture) -> DJBoxModel.Stage { f.scene.djModel.stage }

    private func playingLine(_ f: Fixture) -> String? {
        if case .playing(let line) = stage(f) { return line }
        return nil
    }

    private func message(_ f: Fixture) -> String? {
        if case .message(let text) = stage(f) { return text }
        return nil
    }

    private func isPick(_ f: Fixture) -> Bool {
        if case .pick = stage(f) { return true }
        return false
    }

    /// Focus the box, type the prompt, Enter. That is all a person does.
    private func ask(_ f: Fixture, _ prompt: String) {
        focus(f)
        type(f, prompt)
        _ = f.scene.handle(.enter)
    }

    /// Ask, and wait until the box has an answer on screen: it is playing,
    /// showing a message, or showing the artist picker.
    private func askAndWait(_ f: Fixture, _ prompt: String, file: StaticString = #filePath, line: UInt = #line) {
        ask(f, prompt)
        ticks(f, until: { self.playingLine(f) != nil || self.message(f) != nil || self.isPick(f) },
              file: file, line: line)
    }

    /// Ask, wait for the play to be dispatched, and let the action queue run it.
    private func askAndPlay(_ f: Fixture, _ prompt: String, file: StaticString = #filePath, line: UInt = #line) {
        askAndWait(f, prompt, file: file, line: line)
        drain(f.actions)
    }

    private func assertNothingPlayed(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "a queue was sent", file: file, line: line)
        XCTAssertEqual(f.plays.queues.count, 0, "the queue player ran", file: file, line: line)
        XCTAssertEqual(f.handoff.calls.count, 0, "a hand-off ran", file: file, line: line)
        XCTAssertNil(f.store.read(), "the app queue was set", file: file, line: line)
        let libraryOps = f.rig.sent.map(\.op).filter {
            $0.hasPrefix("library.") && $0 != "library.genreUnheard" && $0 != "library.resolveIDs"
        }
        XCTAssertEqual(libraryOps, [], "a SpanDAC library op was sent", file: file, line: line)
    }

    private func artistMixReading(_ artist: String = "Radiohead") -> DJReading {
        .card(DJCard(kind: .artistMix, artist: artist, genre: nil))
    }

    private func genreReading(_ genre: String = "Jazz") -> DJReading {
        .card(DJCard(kind: .genreUnheard, artist: nil, genre: genre))
    }

    private func switchToMusicTUIOutput(_ f: Fixture) throws {
        _ = try f.routing.switchMode(to: .musicApp, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
    }

    /// Some other chosen-music play is admitted by the coordinator.
    private func admitAnotherPlay(_ f: Fixture, origin: PlayOrigin = .spandacLibrary) throws {
        try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: origin,
                              musicApp: { _ in }, source: { _ in }, unaffected: {})
    }

    // MARK: - Reaching the box, leaving it

    // (↓ from the Music.app control grid and from Up Next: `NowBoxFocusTests`, below.)

    func testDownWithNothingToBrowseGoesStraightToTheBox() {
        let f = fixture(output: .source)
        _ = f.scene.render(frame: frame, snapshot: snap)
        XCTAssertEqual(f.scene.handle(.down), .redraw)
        XCTAssertTrue(f.scene.boxFocused)
    }

    func testNothingPlayingStillHasTheBox() {
        let f = fixture(output: .source)
        let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        let out = plain(f.scene.render(frame: frame, snapshot: idle))
        XCTAssertTrue(out.contains(DJBoxModel.placeholder), "no box on the empty state")
        _ = f.scene.handle(.down)
        XCTAssertTrue(f.scene.boxFocused)
    }

    func testDownBeforeTheFirstFrameFocusesNothing() {
        let f = fixture(output: .source)
        _ = f.scene.handle(.down)
        XCTAssertFalse(f.scene.boxFocused, "the box took focus before it had been drawn")
    }

    func testUpAndEscBothLeaveTheBoxAndBothKeepTheTypedText() {
        for leave in [KeyPress.up, KeyPress.escape] {
            let f = fixture(output: .source)
            focus(f)
            type(f, "half a thought")
            XCTAssertEqual(f.scene.handle(leave), .redraw)
            XCTAssertFalse(f.scene.boxFocused, "\(leave)")
            XCTAssertFalse(f.scene.capturesAllInput)
            XCTAssertEqual(f.scene.djModel.text, "half a thought")
            XCTAssertTrue(screen(f).contains("half a thought"))
        }
    }

    func testTheBoxIsNotOfferedWhereThereIsNoRoom() {
        let f = fixture(output: .source)
        let tiny = shellLayout(width: 120, height: 12)
        let out = plain(f.scene.render(frame: tiny, snapshot: snap))
        XCTAssertFalse(out.contains(DJBoxModel.placeholder))
        _ = f.scene.handle(.down)
        XCTAssertFalse(f.scene.boxFocused)
    }

    func testTheBoxIsLeftWhenTheFrameShrinksUnderIt() {
        let f = fixture(output: .source)
        focus(f)
        _ = f.scene.render(frame: shellLayout(width: 120, height: 12), snapshot: snap)
        XCTAssertFalse(f.scene.boxFocused, "a focused box that is no longer drawn kept the keyboard")
        XCTAssertFalse(f.scene.capturesAllInput)
    }

    // MARK: - The box on screen

    func testTheBoxShowsMakeARequestWhileUnfocusedAndClearsItWhenFocused() {
        let f = fixture(output: .source)
        let before = screen(f)
        XCTAssertTrue(before.contains("Make a request"), "the placeholder is not drawn")
        XCTAssertTrue(before.contains("\u{256D}") && before.contains("\u{2570}"), "the box has no border")

        focus(f)
        let focused = screen(f)
        XCTAssertFalse(focused.contains("Make a request"), "the placeholder stayed while focused")
        XCTAssertTrue(focused.contains(DJBoxModel.caret), "no cursor while focused")

        _ = f.scene.handle(.escape)
        XCTAssertTrue(screen(f).contains("Make a request"), "the placeholder did not come back")
    }

    func testTheBoxIsAsWideAsTheContentAndSitsBelowTheRest() {
        let f = fixture(output: .source)
        let out = f.scene.render(frame: frame, snapshot: snap)
        let rule = plain(out).split(separator: "\u{256D}").last.map { String($0) } ?? ""
        let bars = rule.prefix(while: { $0 == "\u{2500}" }).count
        XCTAssertEqual(bars, frame.width - 4 - 2, "the box is not the content's width")
        // Its top border is at the bottom of the body, under everything else.
        let boxRow: Int? = out.range(of: "\u{256D}").flatMap { range in
            let head = String(out[out.startIndex..<range.lowerBound])
            let moves = try? NSRegularExpression(pattern: "\u{1B}\\[(\\d+);\\d+H")
            let last = moves?.matches(in: head, range: NSRange(head.startIndex..., in: head)).last
            return last.flatMap { Range($0.range(at: 1), in: head) }.flatMap { Int(head[$0]) }
        }
        XCTAssertEqual(boxRow, frame.bodyY + frame.bodyHeight - 4, "the box is not at the bottom of the body")
    }

    func testTheFooterSaysHowToUseTheBox() {
        let f = fixture(output: .source)
        focus(f)
        XCTAssertTrue(f.scene.footerHint.contains("Enter"), f.scene.footerHint)
        XCTAssertTrue(f.scene.footerHint.contains("Esc"), f.scene.footerHint)
    }

    // MARK: - Raw keys

    func testWhileFocusedEveryPrintableKeyTypesSpaceIncludedAndNowsShortcutsDoNotFire() {
        let f = fixture(output: .source)
        focus(f)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .scene,
                       "Space would still go to play/pause")
        for key in ["q", "z", "s", "x", "n", "l", "[", "]", "<", ">", "+", "-", "4", "p", "r", "m", "g"] {
            XCTAssertEqual(shellRoute(for: .char(Character(key)), sceneCapturing: f.scene.capturesAllInput), .scene, key)
        }
        type(f, "q z s x n l [ ] < > + - 4 p r m g")
        XCTAssertEqual(f.scene.djModel.text, "q z s x n l [ ] < > + - 4 p r m g")
        XCTAssertEqual(f.scene.handle(.char("q")), .redraw, "q quit the app from the box")
        XCTAssertEqual(f.rig.sent.count, 0, "a shortcut reached SpanDAC")
        XCTAssertNil(f.status.current(), "a shortcut posted a status")
        drain(f.actions)
        XCTAssertEqual(f.rig.sent.count, 0)
    }

    func testNotFocusedSpaceIsStillPlayPauseAndTheBoxCapturesNothing() {
        let f = fixture(output: .source)
        _ = f.scene.render(frame: frame, snapshot: snap)
        XCTAssertFalse(f.scene.capturesAllInput)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .globals)
        XCTAssertEqual(resolveGlobalKey(.space), .playPause)
        XCTAssertEqual(f.scene.djModel.text, "")
    }

    func testBackspaceEditsAndTheCursorMovesNoWhere() {
        let f = fixture(output: .source)
        focus(f)
        type(f, "jazzz")
        _ = f.scene.handle(.char("\u{7F}"))
        XCTAssertEqual(f.scene.djModel.text, "jazz")
        XCTAssertEqual(f.scene.handle(.left), .none, "← left the box or moved a Now cursor")
        XCTAssertEqual(f.scene.handle(.right), .none)
        XCTAssertTrue(f.scene.boxFocused)
        XCTAssertEqual(f.scene.djModel.text, "jazz")
    }

    // MARK: - Asking: off the input loop, one reader call

    func testEnterAsksTheReaderOnceOffTheInputLoop() {
        let f = fixture(output: .source)
        f.reader.answer("some jazz", with: .card(.unsupported))
        f.reader.hold("some jazz")
        ask(f, "some jazz")
        XCTAssertEqual(stage(f), .reading, "Enter waited for the reader")
        XCTAssertTrue(f.scene.capturesAllInput)
        f.reader.release("some jazz")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(f.reader.asked, ["some jazz"])
    }

    func testABlankPromptAsksNothing() {
        let f = fixture(output: .source)
        ask(f, "   ")
        settle(f, seconds: 0.1)
        XCTAssertEqual(f.reader.asked, [])
        XCTAssertEqual(stage(f), .typing)
    }

    // MARK: - What the reader cannot do: shown as the line, nothing plays

    func testAnUnsupportedPromptSaysWhatTheDJCanDoAndPlaysNothing() {
        let f = fixture(output: .source)
        f.reader.answer("music like tribe called quest", with: .card(.unsupported))
        askAndWait(f, "music like tribe called quest")
        XCTAssertEqual(message(f), djUnsupportedRequest)
        XCTAssertEqual(djUnsupportedRequest, "The DJ can do artist mixes and genres you haven't heard lately for now.")
        XCTAssertTrue(screen(f).contains(djUnsupportedRequest), "the refusal is not on screen")
        drain(f.actions)
        assertNothingPlayed(f)
        XCTAssertEqual(f.rig.sent("slice.search").count, 0)
    }

    func testEveryUnavailableStateShowsItsOwnPlainMessageAndPlaysNothing() {
        var seen = Set<String>()
        for reason in DJUnavailable.allCases {
            let f = fixture(output: .source)
            f.reader.answer("x", with: .unavailable(reason))
            askAndWait(f, "x")
            XCTAssertEqual(message(f), reason.message, "\(reason)")
            seen.insert(reason.message)
            drain(f.actions)
            assertNothingPlayed(f)
        }
        XCTAssertEqual(seen.count, DJUnavailable.allCases.count, "two states shared one message")
    }

    func testAReaderThatDoesNotAnswerInTimeShowsTheTimeoutSentenceAndLeavesTheSpinner() {
        let f = fixture(output: .source)
        var seams = f.scene.dj
        seams.readerTimeout = 0.1
        f.scene.dj = seams
        f.reader.hold("slow one")
        ask(f, "slow one")
        XCTAssertEqual(stage(f), .reading)
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(message(f), "The DJ took too long to answer. Try again.")
        XCTAssertNotEqual(f.scene.djModel.statusLine, "Asking the DJ\u{2026}")
        XCTAssertEqual(djReaderTimedOutLine, "The DJ took too long to answer. Try again.")
        f.reader.release("slow one")
    }

    func testTheDefaultReaderTimeoutIsTwentySeconds() {
        XCTAssertEqual(DJSeams().readerTimeout, 20)
    }

    func testALateAnswerAfterTheTimeoutNeverLandsOrPlays() {
        let f = fixture(output: .source)
        var seams = f.scene.dj
        seams.readerTimeout = 0.1
        f.scene.dj = seams
        f.reader.answer("late jazz", with: genreReading("Jazz"))
        f.reader.hold("late jazz")
        ask(f, "late jazz")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(message(f), djReaderTimedOutLine)
        f.reader.release("late jazz")
        settle(f, seconds: 0.4)
        drain(f.actions)
        XCTAssertEqual(message(f), djReaderTimedOutLine, "a late card replaced the timeout sentence")
        XCTAssertNil(playingLine(f), "a late answer played")
        assertNothingPlayed(f)
    }

    func testAFailedReadShowsItsOwnMessage() {
        let f = fixture(output: .source)
        f.reader.answer("x", with: .failed("the model errored"))
        askAndWait(f, "x")
        XCTAssertEqual(message(f), "The DJ couldn't read that: the model errored")
        assertNothingPlayed(f)
    }

    // MARK: - Newer prompt wins; stale answers never land

    func testAnOlderPromptsAnswerArrivingLastNeverReplacesTheNewerNorPlays() {
        let f = fixture(output: .source)
        f.reader.answer("first", with: artistMixReading())
        f.reader.hold("first")
        f.reader.answer("second", with: .card(.unsupported))
        ask(f, "first")
        ticks(f, until: { f.reader.asked == ["first"] })
        for _ in 0..<5 { _ = f.scene.handle(.char("\u{7F}")) }
        type(f, "second")
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.message(f) == djUnsupportedRequest })

        f.reader.release("first")
        settle(f)
        drain(f.actions)
        XCTAssertEqual(message(f), djUnsupportedRequest, "the older prompt's answer replaced the newer")
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "a stale request went on to read the catalogue")
        assertNothingPlayed(f)
    }

    func testAnOlderPromptsErrorArrivingLastNeverReplacesTheNewer() {
        let f = fixture(output: .source)
        f.reader.answer("first", with: .failed("stale boom"))
        f.reader.hold("first")
        f.reader.answer("second", with: .card(.unsupported))
        ask(f, "first")
        ticks(f, until: { f.reader.asked == ["first"] })
        for _ in 0..<5 { _ = f.scene.handle(.char("\u{7F}")) }
        type(f, "second")
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.message(f) == djUnsupportedRequest })

        f.reader.release("first")
        settle(f)
        XCTAssertEqual(message(f), djUnsupportedRequest, "a stale error replaced the newer answer")
    }

    /// The old box's "closed box" fences, for a box that no longer closes: leaving Now
    /// with a request out abandons it, and its answer never shows under the next request.
    func testAnAbandonedRequestsLateAnswerNeverShowsUnderTheNextRequest() {
        let f = fixture(output: .source)
        f.reader.answer("first", with: .failed("old request"))
        f.reader.hold("first")
        ask(f, "first")
        ticks(f, until: { f.reader.asked == ["first"] })
        f.scene.becameActive()                                   // the person came back from another tab
        XCTAssertEqual(message(f), NowPlayingScene.djLeftNow)
        for _ in 0..<5 { _ = f.scene.handle(.char("\u{7F}")) }

        f.reader.answer("second", with: .card(.unsupported))
        f.reader.hold("second")
        ask(f, "second")
        ticks(f, until: { f.reader.asked == ["first", "second"] })
        f.reader.release("first")
        settle(f)
        XCTAssertEqual(stage(f), .reading, "the abandoned request's answer landed in the next one")
        f.reader.release("second")
        ticks(f, until: { self.message(f) == djUnsupportedRequest })
    }

    func testAnAbandonedRequestsAnswerNeverPlaysAndNeverReadsTheCatalogue() {
        let f = fixture(output: .source)
        f.reader.answer("x", with: artistMixReading())
        f.reader.hold("x")
        ask(f, "x")
        ticks(f, until: { f.reader.asked == ["x"] })
        f.scene.becameActive()
        f.reader.release("x")
        settle(f)
        drain(f.actions)
        XCTAssertEqual(message(f), NowPlayingScene.djLeftNow)
        XCTAssertEqual(f.rig.sent("slice.search").count, 0)
        assertNothingPlayed(f)
    }

    func testComingBackToNowWithNothingOutLeavesTheBoxAlone() {
        let f = fixture(output: .source)
        focus(f)
        type(f, "jazz")
        f.scene.becameActive()
        XCTAssertEqual(f.scene.djModel.text, "jazz")
        XCTAssertEqual(stage(f), .typing)
    }

    func testLeavingTheBoxWithARequestOutDoesNotStopItsAnswerFromPlaying() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        f.reader.hold("mix")
        ask(f, "mix")
        ticks(f, until: { f.reader.asked == ["mix"] })
        _ = f.scene.handle(.escape)
        XCTAssertFalse(f.scene.boxFocused)
        f.reader.release("mix")
        ticks(f, until: { self.playingLine(f) != nil })
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
    }

    // MARK: - Artist mix: plays straight away

    func testAnArtistMixPlaysStraightAwayWithNoSecondKeyAndTheLineSaysTheExactScope() throws {
        let f = fixture(output: .source)
        f.reader.answer("a radiohead mix", with: artistMixReading())
        askAndPlay(f, "a radiohead mix")                       // the one Enter, and nothing after it

        XCTAssertEqual(playingLine(f), "Radiohead \u{00B7} 50 songs from 3 albums (3 unavailable skipped)")
        XCTAssertEqual(f.scene.djModel.statusLine,
                       "Playing: Radiohead \u{00B7} 50 songs from 3 albums (3 unavailable skipped)")
        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1, "one Enter must be one queue")
        let ids = try XCTUnwrap(queues.first?.body["ids"] as? [String])
        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(Set(ids).count, 50)
        let playable = Set(Self.radioheadAlbum1 + Self.radioheadAlbum2 + Self.radioheadAlbum3)
            .subtracting(Self.radioheadUnavailable)
        XCTAssertTrue(Set(ids).isSubset(of: playable), "an unavailable song is in the mix")
        XCTAssertNotEqual(queues.first?.tag, "mac-data", "the queue went to the data client, not the output")

        // Reads came from SpanDAC on this Mac.
        XCTAssertEqual(f.rig.sent("slice.search").map(\.tag), ["mac-data"])
        XCTAssertEqual(f.rig.sent("slice.search").first?.body["term"] as? String, "Radiohead")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["id"] as? String, "art1")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["limit"] as? Int, 25)
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 3, "the albums were read again")
        XCTAssertEqual(f.plays.queues.count, 0)
        XCTAssertEqual(f.handoff.calls.count, 0)
    }

    func testTheBoxSaysWhatPlayedAndEmptiesForTheNextRequest() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        askAndPlay(f, "mix")
        XCTAssertEqual(f.scene.djModel.text, "", "the box did not empty")
        XCTAssertEqual(f.scene.djModel.statusLine,
                       "Playing: Radiohead \u{00B7} 50 songs from 3 albums (3 unavailable skipped)")
        let shown = screen(f)
        XCTAssertTrue(shown.contains("Playing: Radiohead \u{00B7} 50 songs from 3 albums"), "the line is not on screen")
        XCTAssertTrue(f.scene.boxFocused, "the box lost focus after a play")

        // The next request starts from an empty box and a typed key clears the line.
        type(f, "j")
        XCTAssertEqual(f.scene.djModel.text, "j")
        XCTAssertEqual(stage(f), .typing)
        XCTAssertNil(f.scene.djModel.statusLine)
    }

    func testASecondEnterOnTheEmptiedBoxPlaysNothingMore() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        askAndPlay(f, "mix")
        XCTAssertEqual(f.scene.handle(.enter), .none, "an Enter on the emptied box did something")
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 3, "a second Enter read the albums again")
        XCTAssertEqual(f.reader.asked, ["mix"])
    }

    /// SpanDAC's own refusal of the queue reaches him as it is said, in the status and in the box.
    func testSpanDACsRefusalOfTheQueueSurfacesAsItIsAndTheBoxStopsSayingPlaying() {
        let f = fixture(output: .source)
        f.rig.responders["slice.queue"] = { _ in
            #"{"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in SpanDAC; 101 were requested."}}"#
        }
        f.reader.answer("mix", with: artistMixReading())
        askAndPlay(f, "mix")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        XCTAssertTrue(f.status.current()?.text.contains("A queue holds at most 100 songs") ?? false,
                      f.status.current()?.text ?? "no status")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertTrue(message(f)?.contains("A queue holds at most 100 songs") ?? false, "\(stage(f))")
        XCTAssertNil(playingLine(f), "the box kept saying Playing over a refused queue")
    }

    func testTheLineSaysFirst25AlbumsWhenTheArtistHasMore() {
        let f = fixture(output: .source)
        f.reader.answer("beatles", with: artistMixReading("Beatles"))
        askAndPlay(f, "beatles")
        XCTAssertTrue(playingLine(f)?.contains("first 25 albums") ?? false, playingLine(f) ?? "not playing")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["id"] as? String, "b1",
                       "The Beatles is the one exact match for Beatles")
    }

    // MARK: - Artist mix: choosing the artist, then playing

    func testTwoArtistsOfOneNameShowAPickerInsideTheBoxAndChoosingPlaysStraightAway() throws {
        let f = fixture(output: .source)
        f.reader.answer("nirvana mix", with: artistMixReading("Nirvana"))
        ask(f, "nirvana mix")
        ticks(f, until: { self.isPick(f) })
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0, "an artist was chosen for him")
        let shown = screen(f)
        XCTAssertTrue(shown.contains("Which Nirvana?"), shown)
        XCTAssertTrue(shown.contains("\u{25B8} Nirvana"), "the picker rows are not in the box")
        drain(f.actions)
        assertNothingPlayed(f)

        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)                                  // the choice is the only key after the ask
        ticks(f, until: { self.playingLine(f) != nil })
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.search").count, 1, "the chosen artist was resolved by name again")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").map { $0.body["id"] as? String ?? "" }, ["n2"])
        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1)
        XCTAssertEqual(Set(queues.first?.body["ids"] as? [String] ?? []), ["nb1", "nb2", "nb3"])
    }

    func testUpAndDownMoveThePickerAndOnlyEscLeavesTheBoxFromIt() {
        let f = fixture(output: .source)
        f.reader.answer("nirvana mix", with: artistMixReading("Nirvana"))
        ask(f, "nirvana mix")
        ticks(f, until: { self.isPick(f) })
        _ = f.scene.handle(.down)
        XCTAssertEqual(f.scene.handle(.up), .redraw)
        XCTAssertTrue(f.scene.boxFocused, "↑ left the box instead of moving the picker")
        XCTAssertEqual(f.scene.handle(.up), .none)
        XCTAssertTrue(f.scene.boxFocused, "↑ at the top of the picker left the box")
        XCTAssertEqual(f.scene.handle(.escape), .redraw)
        XCTAssertFalse(f.scene.boxFocused)
    }

    func testNoExactMatchOffersTheNearestArtistsAndChoosingPlays() {
        let f = fixture(output: .source)
        f.reader.answer("rad", with: artistMixReading("Rad"))
        ask(f, "rad")
        ticks(f, until: { if case .pick(let p) = self.stage(f) { return p.hits.count == 2 } else { return false } })
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.playingLine(f) != nil })
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").map { $0.body["id"] as? String ?? "" }, ["r1"])
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
    }

    func testEditingWhileThePickerShowsDropsItAndNothingPlays() {
        let f = fixture(output: .source)
        f.reader.answer("nirvana mix", with: artistMixReading("Nirvana"))
        ask(f, "nirvana mix")
        ticks(f, until: { self.isPick(f) })
        type(f, "!")
        XCTAssertEqual(stage(f), .typing)
        _ = f.scene.handle(.enter)                 // asks "nirvana mix!" again, never plays
        ticks(f, until: { f.reader.asked.count == 2 })
        drain(f.actions)
        assertNothingPlayed(f)
    }

    func testNoArtistFoundSaysSoAndPlaysNothing() {
        let f = fixture(output: .source)
        f.reader.answer("nobody", with: artistMixReading("Nobody"))
        askAndWait(f, "nobody")
        XCTAssertEqual(message(f), "No artist found for Nobody.")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0)
        drain(f.actions)
        assertNothingPlayed(f)
    }

    func testAnOlderSpanDACWithoutArtistSearchSaysSo() {
        let f = fixture(output: .source, artists: false)
        f.reader.answer("radiohead", with: artistMixReading())
        askAndWait(f, "radiohead")
        XCTAssertEqual(message(f), CatalogueSearchResults.artistsNeedNewerSpanDAC)
        assertNothingPlayed(f)
    }

    func testAFailedSearchShowsTheReasonAndPlaysNothing() {
        let f = fixture(output: .source)
        f.reader.answer("broken", with: artistMixReading("Broken"))
        askAndWait(f, "broken")
        XCTAssertTrue(message(f)?.contains("Apple Music isn't answering") ?? false, message(f) ?? "no message")
        assertNothingPlayed(f)
    }

    func testAFailedAlbumReadFailsTheWholeMixAndPlaysNothing() {
        let f = fixture(output: .source)
        f.rig.responders["slice.artistAlbums"] = { _ in Self.albumsReply(["alb1", "bad", "alb3"]) }
        f.reader.answer("radiohead", with: artistMixReading())
        askAndWait(f, "radiohead")
        XCTAssertNil(playingLine(f), "a partial mix played")
        XCTAssertTrue(message(f)?.contains("Title bad") ?? false, message(f) ?? "no message")
        drain(f.actions)
        assertNothingPlayed(f)
    }

    func testAnArtistWithNoPlayableSongsPlaysNothing() {
        let f = fixture(output: .source)
        f.rig.responders["slice.artistAlbums"] = { _ in Self.albumsReply(["empty"]) }
        f.reader.answer("radiohead", with: artistMixReading())
        askAndWait(f, "radiohead")
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), "No playable songs found for Radiohead.")
        assertNothingPlayed(f)
    }

    // MARK: - Artist mix: every other combination refuses before any read, add or play

    private func assertArtistMixRefusedBeforeAnything(_ f: Fixture, expected: String,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        f.reader.answer("mix", with: artistMixReading())
        askAndWait(f, "mix", file: file, line: line)
        XCTAssertEqual(message(f), expected, file: file, line: line)
        XCTAssertNil(playingLine(f), file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "the catalogue was read", file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0, file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 0, file: file, line: line)
        drain(f.actions)
        assertNothingPlayed(f, file: file, line: line)
        XCTAssertEqual(f.rig.outputBuilt, [], "an output client was built", file: file, line: line)
    }

    func testSpanDACDataOnTheMusicTUIOutputRefusesAnArtistMix() {
        let f = fixture(output: .musicApp)
        assertArtistMixRefusedBeforeAnything(f, expected: djArtistMixSpanDACOnly)
    }

    func testMusicTUIDataOnTheMusicTUIOutputRefusesAnArtistMix() {
        let f = fixture(output: .musicApp, accepted: false)
        settle(f, seconds: 0.1)
        assertArtistMixRefusedBeforeAnything(f, expected: djArtistMixNeedsSpanDACData)
    }

    func testMusicTUIDataWithAStoredSpanDACOutputRefusesAnArtistMix() {
        let f = fixture(output: .source, accepted: false)
        settle(f, seconds: 0.1)
        assertArtistMixRefusedBeforeAnything(f, expected: djArtistMixNeedsSpanDACData)
    }

    /// The coordinator itself: the DJ artist-mix origin never reaches the
    /// MusicTUI body (whatever its path), admits no play, and plays on a
    /// SpanDAC output.
    func testTheCoordinatorRefusesTheDJArtistMixOriginOnTheMusicTUIOutputBeforeAnyBody() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        var paths: [MusicTUIPlayPath] = []
        let serial = routing.playSerial
        XCTAssertThrowsError(try routing.perform(.discoverTrackPlay, expecting: routing.stamp, origin: .djArtistMix,
                                                 musicApp: { paths.append($0) },
                                                 source: { _ in XCTFail("source ran") }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, djArtistMixSpanDACOnly)
        }
        XCTAssertEqual(paths, [], "the MusicTUI body ran for a DJ artist mix")
        XCTAssertEqual(routing.playSerial, serial, "a refused DJ artist mix was admitted")

        let open = SceneDataRig(output: .musicApp, accepted: false).coordinator()
        XCTAssertThrowsError(try open.perform(.discoverTrackPlay, expecting: open.stamp, origin: .djArtistMix,
                                              musicApp: { _ in XCTFail("MusicTUI body ran on open data") },
                                              source: { _ in XCTFail("source ran") }, unaffected: {}))

        let blocked = SceneDataRig(output: .source, accepted: false).coordinator()
        XCTAssertThrowsError(try blocked.perform(.discoverTrackPlay, expecting: blocked.stamp, origin: .djArtistMix,
                                                 musicApp: { _ in XCTFail("MusicTUI body ran while blocked") },
                                                 source: { _ in XCTFail("source ran while blocked") }, unaffected: {}))

        let spandac = SceneDataRig(output: .source, accepted: true).coordinator()
        var sourced = 0
        try spandac.perform(.discoverTrackPlay, expecting: spandac.stamp, origin: .djArtistMix,
                            musicApp: { _ in XCTFail("MusicTUI body ran") },
                            source: { _ in sourced += 1 }, unaffected: {})
        XCTAssertEqual(sourced, 1)
    }

    // MARK: - A source, output or play change between Enter and the play stops it

    func testAnOutputChangeBeforeTheAnswerStopsItAndSaysSo() throws {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        f.reader.hold("mix")
        ask(f, "mix")
        ticks(f, until: { f.reader.asked == ["mix"] })
        try switchToMusicTUIOutput(f)
        f.reader.release("mix")
        settle(f)
        drain(f.actions)
        XCTAssertNil(playingLine(f), "an answer from before the switch played")
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNothingPlayed(f)
    }

    func testAnOutputChangeAfterTheAnswerIsInTheSlotButBeforeATickStopsItAndSaysSo() throws {
        let f = fixture(output: .source)
        let written = DispatchSemaphore(value: 0)
        f.scene.inboxWritten = { if $0 == "dj" { written.signal() } }
        f.reader.answer("mix", with: artistMixReading())
        ask(f, "mix")
        var waits = 0
        // The mix answers in two parts (progress, then the plan): wait for the plan's.
        while written.wait(timeout: .now() + 5) == .success, waits < 1 { waits += 1 }
        try switchToMusicTUIOutput(f)
        _ = f.scene.tick(snapshot: snap)
        drain(f.actions)
        XCTAssertNil(playingLine(f), "the answer played after an output change")
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNothingPlayed(f)
    }

    func testADataSourceChangeBeforeTheAnswerStopsItWithASentenceAndNothingPlays() throws {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        f.reader.hold("mix")
        ask(f, "mix")
        ticks(f, until: { f.reader.asked == ["mix"] })
        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        f.reader.release("mix")
        settle(f)
        drain(f.actions)
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testAnotherPlayAdmittedBetweenEnterAndTheAnswerStopsIt() throws {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        f.reader.hold("mix")
        ask(f, "mix")
        ticks(f, until: { f.reader.asked == ["mix"] })
        try admitAnotherPlay(f)
        f.reader.release("mix")
        settle(f)
        drain(f.actions)
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testAnOutputChangeWhileThePickerShowsDropsItAtTheNextTick() throws {
        let f = fixture(output: .source)
        f.reader.answer("nirvana mix", with: artistMixReading("Nirvana"))
        ask(f, "nirvana mix")
        ticks(f, until: { self.isPick(f) })
        try switchToMusicTUIOutput(f)
        _ = f.scene.tick(snapshot: snap)
        XCTAssertFalse(isPick(f), "the picker survived an output change")
        XCTAssertEqual(message(f), djChangedLine)
        _ = f.scene.handle(.enter)             // a message: Enter asks again, it never plays
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    /// The window the card used to leave to the person is now the action queue's:
    /// the play is dispatched, another play is admitted before it runs, and the
    /// coordinator's serial check at admission stops it.
    func testAnArtistMixWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothing() throws {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        try askBehindAHold(f, "mix") { try self.admitAnotherPlay(f) }
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "the artist mix queued after another play was admitted")
        XCTAssertEqual(f.status.current()?.text, anotherPlayAdmittedNothingPlayed)
        ticks(f, until: { self.message(f) == anotherPlayAdmittedNothingPlayed })
    }

    /// A held action ahead of the DJ's: the request is asked, its play is queued
    /// behind the hold, `admit` lets a different play in meanwhile, then the hold is released.
    private func askBehindAHold(_ f: Fixture, _ prompt: String, admit: () throws -> Void) throws {
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, prompt)
        ticks(f, until: { self.playingLine(f) != nil })       // the play is dispatched, behind the hold
        try admit()
        hold.signal()
        drain(f.actions)
    }

    // MARK: - Genre on MusicTUI's own data

    private func pid(_ n: Int) -> String { String(format: "%016X", n) }

    /// One library read in the bulk-column shape. Song n: genre per `genre(n)`,
    /// played per `played(n)` (a token: "N" never, an epoch, "U" unreadable).
    private func libraryText(count: Int, genre: (Int) -> String, played: (Int) -> String) -> String {
        let ids = (1...max(1, count)).map(pid)
        func col(_ f: (Int) -> String) -> String { (1...max(1, count)).map(f).joined(separator: rs) }
        if count == 0 { return ["", "", "", "", "", ""].joined(separator: fs) }
        return [ids.joined(separator: rs), col { "Song \($0)" }, col { _ in "Artist" }, col { _ in "Album" },
                col(genre), col(played)].joined(separator: fs)
    }

    private func daysAgoToken(_ days: Int) -> String {
        String(Int(fixedNow.timeIntervalSince1970) - days * 86_400)
    }

    private func openFixture(library: String? = nil) -> Fixture {
        let f = fixture(output: .musicApp, accepted: false)
        if let library { f.scripts.reply = { library } }
        return f
    }

    func testGenreOnMusicTUIDataPlaysTheFrozenQueueStraightAwayAndOnce() throws {
        // 120 jazz songs, played 100...219 days ago (all eligible); song n played (99 + n) days ago,
        // so song 120 is the oldest. 30 rock songs never played (must not match).
        let text = libraryText(count: 150,
                               genre: { $0 <= 120 ? "Vocal Jazz" : "Rock" },
                               played: { $0 <= 120 ? self.daysAgoToken(99 + $0) : "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("some jazz", with: genreReading("jazz"))
        askAndPlay(f, "some jazz")

        XCTAssertEqual(playingLine(f), "jazz you haven't played in 90 days \u{00B7} 50 songs")
        XCTAssertEqual(f.scripts.count, 1, "the library was read more than once")
        XCTAssertEqual(f.rig.sent.count, 0, "a SpanDAC client was used for MusicTUI's own data")
        XCTAssertEqual(f.scene.handle(.enter), .none)
        drain(f.actions)

        XCTAssertEqual(f.plays.queues.count, 1, "one Enter must be one queue")
        let queue = try XCTUnwrap(f.plays.queues.first)
        XCTAssertEqual(queue.playlistName, persistentIDQueueSource)
        let played = queue.tracks.map { persistentIDOfQueueEntry($0.index) }
        // The 50 oldest are songs 71...120, oldest (120) first; the test shuffler reverses that order.
        XCTAssertEqual(played, (71...120).map(pid))
        XCTAssertEqual(f.store.read(), queue)
        XCTAssertEqual(f.scripts.count, 1, "a second Enter read the library again")
    }

    func testGenreNeverPlayedAndRecentlyPlayedAreHandledAndTheCountIsExact() {
        let text = libraryText(count: 10,
                               genre: { _ in "Jazz" },
                               played: { n in n <= 3 ? "N" : (n <= 6 ? self.daysAgoToken(91) : self.daysAgoToken(89)) })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertEqual(playingLine(f), "Jazz you haven't played in 90 days \u{00B7} 6 songs")
        XCTAssertEqual(f.plays.queues.first?.tracks.count, 6)
    }

    func testAnEmptyResultPlaysNothing() {
        let text = libraryText(count: 5, genre: { _ in "Rock" }, played: { _ in "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
        _ = f.scene.handle(.enter)       // asks again, never plays
        drain(f.actions)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testAnEmptyLibraryPlaysNothing() {
        let f = openFixture(library: libraryText(count: 0, genre: { _ in "" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testFiftyAndFewerThanFiftyAreBothExact() {
        let fifty = openFixture(library: libraryText(count: 50, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(fifty, seconds: 0.1)
        fifty.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(fifty, "jazz")
        XCTAssertEqual(playingLine(fifty), "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        let one = openFixture(library: libraryText(count: 1, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(one, seconds: 0.1)
        one.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(one, "jazz")
        XCTAssertEqual(playingLine(one), "Jazz you haven't played in 90 days \u{00B7} 1 song")
    }

    func testAnUnreadableDateIsSkippedAndSaid() {
        let text = libraryText(count: 4, genre: { _ in "Jazz" }, played: { $0 == 1 ? "U" : "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertEqual(playingLine(f),
                       "Jazz you haven't played in 90 days \u{00B7} 3 songs (1 with an unreadable date skipped)")
    }

    func testMisalignedColumnsFailTheWholeReadAndPlayNothing() {
        let skewed = [pid(1) + rs + pid(2), "N", "A", "B", "Jazz", "N"].joined(separator: fs)
        let f = openFixture(library: skewed)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), djLibraryMisaligned)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testATimedOutReadRefuses() {
        let f = openFixture()
        f.scripts.reply = { throw AppleScriptBackend.ScriptError.timeout("script") }
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), djLibraryReadTimedOut)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testAFailedPlayStartClearsTheQueueAndSaysSoInTheStatusAndTheBox() {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        var seams = f.scene.dj
        seams.playFirst = { _ in false }
        f.scene.dj = seams
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertNil(f.store.read(), "a queue that never started was left for the poller")
        XCTAssertTrue(f.status.current()?.isError ?? false, "\(String(describing: f.status.current()))")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertNil(playingLine(f), "the box kept saying Playing over a play that did not start")
    }

    func testMusicTUIDataWithASpanDACOutputRefusesBeforeReadingAnything() {
        let f = fixture(output: .source, accepted: false)
        f.scripts.reply = { XCTFail("the library was read"); return "" }
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertNil(playingLine(f))
        XCTAssertEqual(message(f), finishSwitchingToSpanDAC)
        XCTAssertEqual(f.scripts.count, 0)
        XCTAssertEqual(f.plays.queues.count, 0)
        XCTAssertEqual(f.rig.sent.count, 0)
    }

    func testAnotherPlayBetweenEnterAndTheGenreAnswerStopsIt() throws {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        f.reader.hold("jazz")
        ask(f, "jazz")
        ticks(f, until: { f.reader.asked == ["jazz"] })
        try admitAnotherPlay(f, origin: .openData(resultNumber: nil))
        f.reader.release("jazz")
        settle(f)
        drain(f.actions)
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    // MARK: - Genre on SpanDAC data

    private func aliasRows(_ n: Int, withAlias: (Int) -> Bool = { _ in true }) -> [MusicRow] {
        (1...n).map { i in
            MusicRow(id: "lib\(i)", title: "Song \(i)", artist: "A", album: "B", kind: .song,
                     alias: withAlias(i) ? String(i) : nil)
        }
    }

    private func spandacPick(_ rows: [MusicRow], total: Int? = nil) -> DJSpanDACGenrePick {
        DJSpanDACGenrePick(rows: rows, total: total ?? rows.count, instance: "inst", generation: 7)
    }

    func testGenreOnSpanDACDataAndOutputQueuesTheFrozenLibraryIDsStraightAwayAndOnce() {
        let rows = aliasRows(50)
        let source = DJFakeGenreSource(.success(spandacPick(rows, total: 312)))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")

        XCTAssertEqual(playingLine(f), "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        XCTAssertEqual(source.asked.map(\.genre), ["Jazz"])
        XCTAssertEqual(source.asked.map(\.days), [90])
        XCTAssertEqual(f.scripts.count, 0, "AppleScript was read for SpanDAC data")
        XCTAssertEqual(f.scene.handle(.enter), .none)
        drain(f.actions)

        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1)
        // The server's 50 are shuffled client side (the test shuffler reverses them).
        XCTAssertEqual(queues.first?.body["library_ids"] as? [String], rows.map(\.id).reversed().map { $0 })
        XCTAssertNotEqual(queues.first?.tag, "mac-data")
        XCTAssertEqual(source.rechecks, 1, "the library was not re-checked before playing")
        XCTAssertEqual(f.handoff.calls.count, 0)
    }

    /// 50 rows, the second and the fifth both "Autumn Leaves".
    private func autumnRows() -> [MusicRow] {
        (1...50).map { i in
            MusicRow(id: "lib\(i)", title: (i == 2 || i == 5) ? "Autumn Leaves" : "Song \(i)", artist: "A",
                     album: "B", kind: .song, alias: String(i))
        }
    }

    func testGenreOnSpanDACOutputKeepsTheOldestOfARepeatedTitleAndSaysSo() throws {
        let source = DJFakeGenreSource(.success(spandacPick(autumnRows(), total: 312)))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")

        XCTAssertEqual(playingLine(f), "Jazz you haven't played in 90 days \u{00B7} 49 songs (1 repeated title skipped)")
        let sent = try XCTUnwrap(f.rig.sent("slice.queue").first?.body["library_ids"] as? [String])
        XCTAssertEqual(sent.count, 49)
        XCTAssertFalse(sent.contains("lib5"), "the later Autumn Leaves must not be queued")
        XCTAssertTrue(sent.contains("lib2"), "the first (oldest) Autumn Leaves is the one kept")
        XCTAssertEqual(source.rechecks, 1)
    }

    func testGenreOnSpanDACOutputKeepsTitlesThatDifferOnlyInCase() {
        var rows = autumnRows()
        rows[4] = MusicRow(id: "lib5", title: "autumn leaves", artist: "A", album: "B", kind: .song, alias: "5")
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertEqual(playingLine(f), "Jazz you haven't played in 90 days \u{00B7} 50 songs")
    }

    /// The MusicTUI output plays through a hand-off, not SpanDAC's queue preflight:
    /// the refusal does not exist there, so the pick is left exactly as read.
    func testGenreOnSpanDACDataAndTheMusicTUIOutputKeepsRepeatedTitles() {
        let source = DJFakeGenreSource(.success(spandacPick(autumnRows())))
        let f = fixture(output: .musicApp, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertEqual(playingLine(f), "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        XCTAssertEqual(f.handoff.calls.first?.count, 50)
    }

    func testGenreOnSpanDACDataAndTheMusicTUIOutputHandsOffVerifiedAliasesStraightAway() {
        let rows = aliasRows(5)
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .musicApp, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertNotNil(playingLine(f), "\(stage(f))")
        XCTAssertEqual(f.handoff.calls.count, 1, "one Enter must be one hand-off")
        XCTAssertEqual(f.handoff.calls.first?.map(\.id), rows.map(\.id).reversed().map { $0 })
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        XCTAssertEqual(f.plays.queues.count, 0, "the open-data queue player was used for SpanDAC rows")
        assertNothingPlayedExceptTheHandoff(f)
    }

    private func assertNothingPlayedExceptTheHandoff(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, file: file, line: line)
        XCTAssertNil(f.store.read(), file: file, line: line)
    }

    func testAnySongWithoutAnAliasFailsTheWholePickOnTheMusicTUIOutput() {
        let rows = aliasRows(5, withAlias: { $0 != 3 })
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .musicApp, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertNil(playingLine(f), "a pick with an unaliased song played")
        XCTAssertEqual(message(f), djGenreNeedsAliases)
        XCTAssertEqual(f.handoff.calls.count, 0)
    }

    func testASpanDACOutputNeedsNoAliasToQueueByLibraryID() {
        let rows = aliasRows(3, withAlias: { _ in false })
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertNotNil(playingLine(f), "\(stage(f))")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
    }

    func testALibraryThatChangedBeforeThePlayStopsItAndPlaysNothing() {
        let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
        source.recheckError = DJGenreSourceError.libraryChanged
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndPlay(f, "jazz")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        XCTAssertEqual(f.status.current()?.text, DJGenreSourceError.libraryChanged.message)
        ticks(f, until: { self.message(f) == DJGenreSourceError.libraryChanged.message })
    }

    func testAnEmptySpanDACGenreResultPlaysNothing() {
        let source = DJFakeGenreSource(.success(spandacPick([], total: 0)))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
        assertNothingPlayed(f)
    }

    func testAnOlderSpanDACSaysItNeedsANewerOneAndPlaysNothing() {
        let f = fixture(output: .source)       // the stub source
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertEqual(message(f), djNeedsNewerSpanDAC)
        assertNothingPlayed(f)
    }

    func testASpanDACGenreFailureIsSaidInItsOwnWords() {
        let source = DJFakeGenreSource(.failure(DJGenreSourceError.failed("SpanDAC is warming")))
        let f = fixture(output: .source, genreSource: source)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askAndWait(f, "jazz")
        XCTAssertTrue(message(f)?.contains("SpanDAC is warming") ?? false, message(f) ?? "no message")
        assertNothingPlayed(f)
    }

    // MARK: - The play serial is checked at admission, with both epochs

    /// The coordinator's own admission: the expected serial is judged with the
    /// epochs, before any body, and a refusal admits nothing.
    func testTheCoordinatorRefusesAStaleExpectedPlaySerialBeforeAnyBodyAndAdmitsNothing() throws {
        let routing = SceneDataRig(output: .source, accepted: true).coordinator()
        let before = routing.playSerial
        var ran = 0
        try routing.perform(.libraryPlay, expecting: routing.stamp, expectingPlaySerial: before,
                            origin: .spandacLibrary, musicApp: { _ in ran += 1 }, source: { _ in ran += 1 },
                            unaffected: {})
        XCTAssertEqual(ran, 1, "a current serial did not run")
        XCTAssertEqual(routing.playSerial, before + 1)

        XCTAssertThrowsError(try routing.perform(.libraryPlay, expecting: routing.stamp, expectingPlaySerial: before,
                                                 origin: .spandacLibrary, musicApp: { _ in ran += 1 },
                                                 source: { _ in ran += 1 }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, anotherPlayAdmittedNothingPlayed)
        }
        XCTAssertEqual(ran, 1, "a stale serial still ran a body")
        XCTAssertEqual(routing.playSerial, before + 1, "a refused play moved the serial")

        // No serial given: nothing to keep honest, as before.
        try routing.perform(.libraryPlay, expecting: routing.stamp, expectingPlaySerial: nil,
                            origin: .spandacLibrary, musicApp: { _ in ran += 1 }, source: { _ in ran += 1 },
                            unaffected: {})
        XCTAssertEqual(ran, 2)
    }

    /// The last word on a dispatched DJ play is asked inside the boundary: a claim
    /// that refuses runs no body and leaves the serial alone; a claim that
    /// succeeds is admitted, and a revoke after it undoes nothing.
    func testTheCoordinatorsClaimRefusesBeforeAnyBodyAndLeavesTheSerialAlone() throws {
        let routing = SceneDataRig(output: .source, accepted: true).coordinator()
        let before = routing.playSerial
        var ran = 0
        let token = DJPlayToken()
        XCTAssertTrue(token.revoke())
        XCTAssertThrowsError(try routing.perform(.libraryPlay, expecting: routing.stamp, expectingPlaySerial: before,
                                                 origin: .spandacLibrary, claim: { try token.claim() },
                                                 musicApp: { _ in ran += 1 }, source: { _ in ran += 1 },
                                                 unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, djLeftNowLine)
        }
        XCTAssertEqual(ran, 0, "a revoked play still ran a body")
        XCTAssertEqual(routing.playSerial, before, "a revoked play moved the serial")

        let live = DJPlayToken()
        try routing.perform(.libraryPlay, expecting: routing.stamp, expectingPlaySerial: before,
                            origin: .spandacLibrary, claim: { try live.claim() },
                            musicApp: { _ in ran += 1 }, source: { _ in ran += 1 }, unaffected: {})
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(routing.playSerial, before + 1)
        XCTAssertFalse(live.revoke(), "a claimed play was revoked after admission")
    }

    func testAnOpenDataGenreWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothing() throws {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        try askBehindAHold(f, "jazz") { try self.admitAnotherPlay(f, origin: .openData(resultNumber: nil)) }
        XCTAssertEqual(f.plays.queues.count, 0, "the genre queue played after another play was admitted")
        XCTAssertNil(f.store.read(), "the genre queue was set after another play was admitted")
    }

    func testASpanDACGenreWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothingOnEitherOutput() throws {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let f = fixture(output: output, genreSource: source)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            try askBehindAHold(f, "jazz") { try self.admitAnotherPlay(f) }
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after another play was admitted")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after another play was admitted")
        }
    }

    func testAPlayAdmittedWhileTheRecheckIsHeldStopsTheSpanDACGenre() throws {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let gate = DispatchSemaphore(value: 0)
            let f = fixture(output: output, genreSource: source)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            source.recheckGate = gate
            ask(f, "jazz")                                       // asked; the play is dispatched at the answer
            ticks(f, until: { self.playingLine(f) != nil })
            XCTAssertEqual(source.recheckStarted.wait(timeout: .now() + 5), .success, "the recheck never started")
            try admitAnotherPlay(f)
            gate.signal()
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after another play was admitted")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after another play was admitted")
        }
    }

    // MARK: - Editing a pending prompt invalidates the request that is out

    func testEditingAPendingPromptReleasesItsRequestAndTheNextEnterAsksTheNewText() {
        let f = fixture(output: .source)
        f.reader.answer("old", with: artistMixReading())
        f.reader.hold("old")
        ask(f, "old")
        ticks(f, until: { f.reader.asked == ["old"] })
        type(f, "x")
        XCTAssertEqual(stage(f), .typing, "the edit left the old request waiting")
        f.reader.release("old")
        settle(f)
        drain(f.actions)
        XCTAssertEqual(stage(f), .typing, "the old answer landed after the edit")
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "the edited-away request went on to read the catalogue")
        assertNothingPlayed(f)

        f.reader.answer("oldx", with: .card(.unsupported))
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.message(f) == djUnsupportedRequest })
        XCTAssertEqual(f.reader.asked, ["old", "oldx"])
    }

    func testAnEditedAwayRequestsLateFailureNeverLands() {
        let f = fixture(output: .source)
        f.reader.answer("old", with: .failed("stale boom"))
        f.reader.hold("old")
        ask(f, "old")
        ticks(f, until: { f.reader.asked == ["old"] })
        _ = f.scene.handle(.char("\u{7F}"))
        f.reader.release("old")
        settle(f)
        XCTAssertEqual(stage(f), .typing)
        XCTAssertNil(message(f), "the old request's failure landed after the edit")
    }

    // MARK: - A job's progress belongs to the session and request it began under

    /// Parks the first artist-mix job just before it reports progress.
    private func parkFirstProgress(_ f: Fixture) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var seams = f.scene.dj
        seams.beforeProgress = {
            lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        f.scene.dj = seams
        return (entered, release)
    }

    func testAnOldJobsProgressNeverLandsUnderTheNextRequestsSameNumberedID() {
        let f = fixture(output: .source)
        let park = parkFirstProgress(f)
        f.reader.answer("old mix", with: artistMixReading())
        ask(f, "old mix")
        XCTAssertEqual(park.entered.wait(timeout: .now() + 5), .success, "the job never reached its progress")
        f.scene.becameActive()                                   // abandoned: the session moves on
        for _ in 0..<7 { _ = f.scene.handle(.char("\u{7F}")) }
        f.reader.hold("new")
        f.reader.answer("new", with: .card(.unsupported))
        ask(f, "new")
        ticks(f, until: { f.reader.asked.contains("new") })

        park.release.signal()                                   // the old job reports "Looking up Radiohead"
        settle(f, seconds: 0.4)
        XCTAssertEqual(stage(f), .reading, "the old job's progress landed on the new request: \(stage(f))")

        f.reader.release("new")
        ticks(f, until: { self.message(f) == djUnsupportedRequest })
        drain(f.actions)
        assertNothingPlayed(f)
    }

    func testAnOldJobsProgressNeverReplacesTheNewAnswerAlreadyInTheSlot() {
        let f = fixture(output: .source)
        let park = parkFirstProgress(f)
        let written = DispatchSemaphore(value: 0)
        f.reader.answer("old mix", with: artistMixReading())
        ask(f, "old mix")
        XCTAssertEqual(park.entered.wait(timeout: .now() + 5), .success)
        f.scene.becameActive()
        for _ in 0..<7 { _ = f.scene.handle(.char("\u{7F}")) }
        f.reader.answer("new", with: .card(.unsupported))
        f.scene.inboxWritten = { if $0 == "dj" { written.signal() } }
        ask(f, "new")                                           // answers at once: the slot holds it, untouched by a tick
        XCTAssertEqual(written.wait(timeout: .now() + 5), .success, "the new answer never reached the slot")

        park.release.signal()
        usleep(300_000)                                         // the old job's progress arrives; no tick yet
        settle(f, seconds: 0.3)
        XCTAssertEqual(message(f), djUnsupportedRequest,
                       "the old job's progress replaced the new answer: \(stage(f))")
    }

    // MARK: - Enter checks the very songs the plan will play, not only the stamp

    private final class ResolveAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int?
        private var _generation = 7
        var count: Int? { get { lock.lock(); defer { lock.unlock() }; return _count }
                          set { lock.lock(); _count = newValue; lock.unlock() } }
        var generation: Int { get { lock.lock(); defer { lock.unlock() }; return _generation }
                              set { lock.lock(); _generation = newValue; lock.unlock() } }
    }

    /// The real SpanDAC genre client over the rig's fake SpanDAC: five songs, each with an alias,
    /// read under instance "inst" and generation 7; `library.resolveIDs` answers per `answer`
    /// (all five resolved when `count` is nil).
    private func realClientFixture(output: PlaybackMode, answer: ResolveAnswer) -> Fixture {
        let f = fixture(output: output)
        f.rig.replies["slice.status"] = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":["search.artist","slice.artistAlbums","library.genreUnheard","library.resolveIDs"]}}"#
        let songs = (1...5).map {
            #"{"id":"lib\#($0)","alias":"\#($0)","title":"Song \#($0)","artist":"A","album":"B","last_played":null}"#
        }.joined(separator: ",")
        f.rig.responders["library.genreUnheard"] = { _ in
            #"{"ok":true,"op":"library.genreUnheard","songs":[\#(songs)],"total":5,"generation":7,"instance":"inst"}"#
        }
        f.rig.responders["library.resolveIDs"] = { body in
            let sent = (body["ids"] as? [String])?.count ?? 0
            return #"{"ok":true,"op":"library.resolveIDs","count":\#(answer.count ?? sent),"generation":\#(answer.generation),"instance":"inst"}"#
        }
        var seams = f.scene.dj
        seams.spandacGenre = { DJSpanDACGenreClient(client: $0) }
        f.scene.dj = seams
        return f
    }

    func testAChosenSongGoneFromTheLibraryStopsTheGenreOnEitherOutputWithTheStampUnchanged() {
        for output in [PlaybackMode.source, .musicApp] {
            let answer = ResolveAnswer()
            let f = realClientFixture(output: output, answer: answer)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            answer.count = 4                                    // one of the five chosen is gone
            askAndPlay(f, "jazz")
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued with a chosen song gone")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off with a chosen song gone")
            XCTAssertEqual(f.status.current()?.text, djSpanDACLibraryChanged, "\(output)")
            let asked = f.rig.sent("library.resolveIDs")
            XCTAssertEqual(asked.count, 1, "\(output)")
            XCTAssertEqual(Set(asked.first?.body["ids"] as? [String] ?? []), Set((1...5).map { "lib\($0)" }), "\(output)")
        }
    }

    func testAChangedGenerationStopsTheGenreEvenWhenEveryChosenSongStillResolves() {
        for output in [PlaybackMode.source, .musicApp] {
            let answer = ResolveAnswer()
            let f = realClientFixture(output: output, answer: answer)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            answer.generation = 8
            askAndPlay(f, "jazz")
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output)")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output)")
            XCTAssertEqual(f.status.current()?.text, djSpanDACLibraryChanged, "\(output)")
        }
    }

    func testWhenEveryChosenSongStillResolvesTheGenrePlaysAfterTheCheckOnEitherOutput() {
        for output in [PlaybackMode.source, .musicApp] {
            let answer = ResolveAnswer()
            let f = realClientFixture(output: output, answer: answer)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askAndPlay(f, "jazz")
            let ops = f.rig.sent.map(\.op)
            XCTAssertEqual(ops.filter { $0 == "library.resolveIDs" }.count, 1, "\(output)")
            XCTAssertEqual(ops.filter { $0 == "library.genreUnheard" }.count, 1, "\(output): the library was scanned again")
            if output == .source {
                let check = ops.firstIndex(of: "library.resolveIDs"), queue = ops.firstIndex(of: "slice.queue")
                XCTAssertNotNil(check); XCTAssertNotNil(queue)
                if let check, let queue { XCTAssertLessThan(check, queue, "the queue went out before the check") }
                XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
            } else {
                XCTAssertEqual(f.handoff.calls.count, 1)
            }
        }
    }

    // MARK: - Leaving Now revokes a play that was dispatched but not yet admitted
    //
    // The play is queued on the action queue the moment its answer arrives. A tab
    // switch before the queue reaches it (or, for a SpanDAC genre, before its
    // library recheck returns) must stop it. A play already admitted is not
    // undone: the sound has started and leaving Now does not stop it.

    private func leaveNow(_ f: Fixture) { f.scene.resignedActive() }

    func testLeavingNowWhileTheArtistMixActionIsHeldPlaysNothing() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "mix")
        ticks(f, until: { self.playingLine(f) != nil })          // dispatched, behind the hold
        leaveNow(f)
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "the artist mix queued after the person left Now")
        f.scene.becameActive()
        XCTAssertEqual(message(f), NowPlayingScene.djLeftNow, "the box still says Playing")
    }

    func testLeavingNowWhileAnOpenDataGenreActionIsHeldPlaysNothing() {
        let text = libraryText(count: 60, genre: { _ in "Jazz" }, played: { self.daysAgoToken(99 + $0) })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "jazz")
        ticks(f, until: { self.playingLine(f) != nil })
        leaveNow(f)
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.plays.queues.count, 0, "the queue player ran after the person left Now")
        XCTAssertNil(f.store.read(), "the app queue was set after the person left Now")
    }

    func testLeavingNowWhileASpanDACGenreActionIsHeldPlaysNothingOnEitherOutput() {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let f = fixture(output: output, genreSource: source)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            let hold = DispatchSemaphore(value: 0)
            f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
            ask(f, "jazz")
            ticks(f, until: { self.playingLine(f) != nil })
            leaveNow(f)
            hold.signal()
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after the person left Now")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after the person left Now")
        }
    }

    func testLeavingNowWhileTheSpanDACRecheckIsHeldPlaysNothingOnEitherOutput() {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let gate = DispatchSemaphore(value: 0)
            let f = fixture(output: output, genreSource: source)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            source.recheckGate = gate
            ask(f, "jazz")
            ticks(f, until: { self.playingLine(f) != nil })
            XCTAssertEqual(source.recheckStarted.wait(timeout: .now() + 5), .success, "the recheck never started")
            leaveNow(f)
            gate.signal()
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after the person left Now")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after the person left Now")
        }
    }

    func testAPlayAlreadyAdmittedIsNotUndoneByLeavingNow() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        askAndPlay(f, "mix")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        let line = playingLine(f)
        XCTAssertNotNil(line)
        leaveNow(f)
        f.scene.becameActive()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        XCTAssertEqual(playingLine(f), line, "leaving Now rewrote a play that had already started")
    }

    func testReturningToNowAfterARevokedPlayAskingAgainPlaysNormally() {
        let f = fixture(output: .source)
        f.reader.answer("mix", with: artistMixReading())
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "mix")
        ticks(f, until: { self.playingLine(f) != nil })
        leaveNow(f)
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        f.scene.becameActive()
        for _ in 0..<5 { _ = f.scene.handle(.char("\u{7F}")) }
        askAndPlay(f, "mix")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1, "a normal play after returning to Now did not play")
    }

    func testLeavingNowWithNothingDispatchedChangesNothing() {
        let f = fixture(output: .source)
        focus(f)
        type(f, "jazz")
        leaveNow(f)
        f.scene.becameActive()
        XCTAssertEqual(f.scene.djModel.text, "jazz")
        XCTAssertEqual(stage(f), .typing)
    }

    // MARK: - Revocation is synchronous with the departure
    //
    // The shell changes `router.active` in the key handler and used to tell the
    // scene on its NEXT loop pass; a held action released in between could claim
    // and play on the other tab. The router now announces the departure itself,
    // in the same call that changes the active scene. These tests release the
    // held work right after the transition and before any tick.

    private func routed(_ f: Fixture) -> Router {
        let router = Router(root: .nowPlaying)
        connectDepartures(of: router) { $0 == .nowPlaying ? f.scene : nil }
        return router
    }

    func testARouterSwitchRevokesAHeldActionBeforeTheNextTick() {
        let f = fixture(output: .source)
        let router = routed(f)
        f.reader.answer("mix", with: artistMixReading())
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "mix")
        ticks(f, until: { self.playingLine(f) != nil })
        router.switchTo(.library)                                // no tick, no resignedActive call by hand
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "the play started on the other tab")
    }

    func testARouterPushRevokesAHeldActionAndPopDoesNotRevokeAgain() {
        let f = fixture(output: .source)
        let router = routed(f)
        f.reader.answer("mix", with: artistMixReading())
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "mix")
        ticks(f, until: { self.playingLine(f) != nil })
        router.push(.discover)
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "the play started on the pushed tab")
        router.pop()
        f.scene.becameActive()
        XCTAssertEqual(message(f), NowPlayingScene.djLeftNow)
    }

    func testARouterSwitchRevokesAHeldRecheckBeforeTheNextTick() {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let gate = DispatchSemaphore(value: 0)
            let f = fixture(output: output, genreSource: source)
            let router = routed(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            source.recheckGate = gate
            ask(f, "jazz")
            ticks(f, until: { self.playingLine(f) != nil })
            XCTAssertEqual(source.recheckStarted.wait(timeout: .now() + 5), .success, "the recheck never started")
            router.switchTo(.playlists)
            gate.signal()
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued on the other tab")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off on the other tab")
        }
    }

    func testASwitchAfterTheClaimLeavesTheAdmittedPlayAlone() {
        let f = fixture(output: .source)
        let router = routed(f)
        f.reader.answer("mix", with: artistMixReading())
        askAndPlay(f, "mix")                                     // claimed and played
        router.switchTo(.library)
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        f.scene.becameActive()
        XCTAssertNotNil(playingLine(f), "leaving after admission rewrote the box")
    }

    func testSwitchingToTheSceneAlreadyActiveRevokesNothing() {
        let f = fixture(output: .source)
        let router = routed(f)
        f.reader.answer("mix", with: artistMixReading())
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        ask(f, "mix")
        ticks(f, until: { self.playingLine(f) != nil })
        router.switchTo(.nowPlaying)                             // the same scene: not a departure
        router.pop()                                             // a pop at the root: not either
        hold.signal()
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1, "a non-departure revoked the play")
    }

    func testTheRouterAnnouncesEachRealDepartureExactlyOnce() {
        let router = Router(root: .nowPlaying)
        var left: [SceneID] = []
        router.onDeparture = { left.append($0) }
        router.switchTo(.nowPlaying)
        router.pop()
        XCTAssertEqual(left, [])
        router.switchTo(.library)
        XCTAssertEqual(left, [.nowPlaying])
        router.push(.discover)
        XCTAssertEqual(left, [.nowPlaying, .library])
        router.push(.discover)                                   // already on it
        XCTAssertEqual(left, [.nowPlaying, .library])
        router.pop()                                             // discover -> discover (stack of two)
        XCTAssertEqual(left, [.nowPlaying, .library])
        router.pop()                                             // discover -> library
        XCTAssertEqual(left, [.nowPlaying, .library, .discover])
    }

    // MARK: - The artist picker never hides its own box

    /// A frame whose body is exactly `rows` tall.
    private func frame(bodyRows rows: Int) -> ShellFrame? {
        (6...60).lazy.map { shellLayout(width: 120, height: $0) }.first { $0.bodyHeight == rows }
    }

    private func boxTopRow(_ out: String) -> Int? {
        guard let range = out.range(of: "\u{256D}") else { return nil }
        let head = String(out[out.startIndex..<range.lowerBound])
        let moves = try? NSRegularExpression(pattern: "\u{1B}\\[(\\d+);\\d+H")
        let last = moves?.matches(in: head, range: NSRange(head.startIndex..., in: head)).last
        return last.flatMap { Range($0.range(at: 1), in: head) }.flatMap { Int(head[$0]) }
    }

    /// Focus the box on `small`, ask for the 5-artist picker, and wait for it.
    private func fivePicker(_ f: Fixture, on small: ShellFrame) {
        f.reader.answer("many mix", with: artistMixReading("Many"))
        _ = f.scene.render(frame: small, snapshot: snap)
        _ = f.scene.handle(.down)
        XCTAssertTrue(f.scene.boxFocused, "↓ did not reach the box at body \(small.bodyHeight)")
        type(f, "many mix")
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.isPick(f) })
    }

    func testAFiveChoicePickerKeepsItsBoxAndFocusOnSmallBodies() throws {
        for rows in 10...14 {
            let small = try XCTUnwrap(frame(bodyRows: rows), "no frame with a \(rows)-row body")
            let f = fixture(output: .source)
            fivePicker(f, on: small)
            let out = f.scene.render(frame: small, snapshot: snap)
            let text = plain(out)
            XCTAssertTrue(f.scene.boxFocused, "body \(rows): the picker took focus away")
            XCTAssertTrue(f.scene.capturesAllInput, "body \(rows): the box stopped capturing input")
            XCTAssertTrue(text.contains("\u{256D}") && text.contains("\u{2570}"), "body \(rows): the box was hidden")
            XCTAssertTrue(text.contains("\u{25B8} Many One"), "body \(rows): the selected row is not visible\n\(text)")
            let top = try XCTUnwrap(boxTopRow(out), "body \(rows): no box top border")
            XCTAssertGreaterThanOrEqual(top - small.bodyY, 6, "body \(rows): the box ate the screen above it")
        }
    }

    func testTheSelectedPickerRowStaysVisibleWhileArrowingAndEnterSelectsIt() throws {
        let names = ["One", "Two", "Three", "Four", "Five"]
        for rows in 10...14 {
            let small = try XCTUnwrap(frame(bodyRows: rows))
            let f = fixture(output: .source)
            fivePicker(f, on: small)
            for (i, name) in names.enumerated() {
                if i > 0 { _ = f.scene.handle(.down) }
                let text = plain(f.scene.render(frame: small, snapshot: snap))
                XCTAssertTrue(f.scene.boxFocused, "body \(rows): focus dropped at choice \(i + 1)")
                XCTAssertTrue(text.contains("\u{25B8} Many \(name)"),
                              "body \(rows): choice \(i + 1) is selected but not visible\n\(text)")
            }
            for i in stride(from: names.count - 2, through: 0, by: -1) {
                _ = f.scene.handle(.up)
                let text = plain(f.scene.render(frame: small, snapshot: snap))
                XCTAssertTrue(text.contains("\u{25B8} Many \(names[i])"), "body \(rows): going up lost choice \(i + 1)")
            }
            XCTAssertTrue(f.scene.boxFocused)
        }
    }

    func testEnterOnAClippedPickerChoosesTheSelectedArtist() throws {
        let small = try XCTUnwrap(frame(bodyRows: 10))
        let f = fixture(output: .source)
        fivePicker(f, on: small)
        _ = f.scene.handle(.down); _ = f.scene.handle(.down)
        _ = f.scene.render(frame: small, snapshot: snap)
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.playingLine(f) != nil || self.message(f) != nil })
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").map { $0.body["id"] as? String ?? "" }, ["m3"])
    }

    func testResizingWhilePickerShowsKeepsTheBoxFocusAndSelection() throws {
        let small = try XCTUnwrap(frame(bodyRows: 10))
        let f = fixture(output: .source)
        fivePicker(f, on: small)
        _ = f.scene.handle(.down); _ = f.scene.handle(.down)
        for size in [frame, small, try XCTUnwrap(self.frame(bodyRows: 12)), frame, small] {
            let text = plain(f.scene.render(frame: size, snapshot: snap))
            XCTAssertTrue(f.scene.boxFocused, "focus dropped at body \(size.bodyHeight)")
            XCTAssertTrue(text.contains("\u{25B8} Many Three"), "selection lost at body \(size.bodyHeight)\n\(text)")
        }
        // Under the minimum the box goes, as it always has.
        _ = f.scene.render(frame: shellLayout(width: 120, height: 12), snapshot: snap)
        XCTAssertFalse(f.scene.boxFocused)
    }
}

/// ↓ into the box from the Music.app control grid and from Up Next, and ↑ / Esc
/// back; and Discover's `d`, which opens nothing now. Not under the external-call
/// tripwire: a Music.app-shaped Now tick starts its modes read, which the
/// harmless backend (`/usr/bin/true`) swallows. Nothing here asks the DJ anything.
final class NowBoxFocusTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 40)

    private func musicAppSnapshot(rows: Int) -> NowPlayingSnapshot {
        var np = NowPlayingState()
        np.track = "Song 1"; np.artist = "Artist"; np.state = "playing"
        let entries = (0..<rows).map {
            TrackListEntry(index: $0 + 1, name: "Song \($0 + 1)", artist: "Artist", isCurrent: $0 == 0)
        }
        return NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: entries)
    }

    /// A Now scene on the MusicTUI output with a real grid and Up Next, ticked
    /// and drawn once so its rows and its room for the box are in.
    private func gridScene(rows: Int) -> (NowPlayingScene, NowPlayingSnapshot) {
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let status = StatusStore()
        let scene = NowPlayingScene(backend: AppleScriptBackend(executable: "/usr/bin/true"), appQueue: AppQueueStore(),
                                    status: status, actions: ActionRunner(status: status), routing: rig.coordinator())
        let s = musicAppSnapshot(rows: rows)
        _ = scene.tick(snapshot: s)
        _ = scene.render(frame: frame, snapshot: s)
        return (scene, s)
    }

    func testDownPastTheLastRowOfUpNextFocusesTheBoxAndUpReturnsToUpNext() {
        let (scene, s) = gridScene(rows: 3)
        XCTAssertFalse(scene.boxFocused)
        XCTAssertEqual(scene.handle(.down), .redraw)                 // row 1 -> 2
        XCTAssertEqual(scene.handle(.down), .redraw)                 // row 2 -> 3
        XCTAssertFalse(scene.boxFocused, "the box took focus before the last row")
        XCTAssertEqual(scene.handle(.down), .redraw)                 // past the last row
        XCTAssertTrue(scene.boxFocused)
        XCTAssertTrue(scene.capturesAllInput)

        XCTAssertEqual(scene.handle(.up), .redraw)
        XCTAssertFalse(scene.boxFocused)
        XCTAssertFalse(scene.capturesAllInput)
        _ = scene.render(frame: frame, snapshot: s)
        // Back in Up Next, not the grid: ↑ moves the Up Next cursor off the last row,
        // and ↓ then returns to it without reaching the box.
        XCTAssertEqual(scene.handle(.up), .redraw)
        XCTAssertEqual(scene.handle(.down), .redraw)
        XCTAssertFalse(scene.boxFocused, "focus did not come back to Up Next")
        XCTAssertEqual(scene.handle(.down), .redraw)
        XCTAssertTrue(scene.boxFocused)
    }

    func testDownPastTheLastRowOfTheControlGridFocusesTheBoxAndEscReturnsToTheGrid() {
        let (scene, s) = gridScene(rows: 3)
        XCTAssertEqual(scene.handle(.left), .redraw)                  // focus the grid
        for _ in 0..<(ControlGrid.rowCount - 1) {
            XCTAssertEqual(scene.handle(.down), .redraw)
            XCTAssertFalse(scene.boxFocused, "the box took focus before the grid's last row")
        }
        XCTAssertEqual(scene.handle(.down), .redraw)
        XCTAssertTrue(scene.boxFocused)

        XCTAssertEqual(scene.handle(.escape), .redraw)
        XCTAssertFalse(scene.boxFocused)
        _ = scene.render(frame: frame, snapshot: s)
        // The grid has focus again, on its last row: ↑ then ↓ stays in the grid, and one more ↓ is the box.
        XCTAssertEqual(scene.handle(.up), .redraw)
        XCTAssertEqual(scene.handle(.down), .redraw)
        XCTAssertFalse(scene.boxFocused)
        XCTAssertEqual(scene.handle(.down), .redraw)
        XCTAssertTrue(scene.boxFocused, "focus did not come back to the grid")
    }

    func testUpFromTheBoxReturnsToTheGridWhenTheGridSentYouThere() {
        let (scene, _) = gridScene(rows: 3)
        _ = scene.handle(.left)
        for _ in 0..<ControlGrid.rowCount { _ = scene.handle(.down) }
        XCTAssertTrue(scene.boxFocused)
        XCTAssertEqual(scene.handle(.up), .redraw)
        XCTAssertFalse(scene.boxFocused)
        // Grid-focused: Enter would cycle a row; the footer says the grid has focus.
        XCTAssertTrue(scene.footerHint.contains("Row"), scene.footerHint)
    }

    func testTheGridsMiddleRowsNeverFocusTheBox() {
        let (scene, _) = gridScene(rows: 3)
        _ = scene.handle(.left)
        for _ in 0..<(ControlGrid.rowCount - 1) {
            XCTAssertFalse(scene.boxFocused)
            _ = scene.handle(.down)
        }
        XCTAssertFalse(scene.boxFocused)
    }

    func testTheUpNextCursorStaysWhereItWasWhileTheBoxHasFocus() {
        let (scene, _) = gridScene(rows: 3)
        for _ in 0..<3 { _ = scene.handle(.down) }
        XCTAssertTrue(scene.boxFocused)
        for key in ["a", "b"] { _ = scene.handle(.char(Character(key))) }
        _ = scene.handle(.up)
        XCTAssertFalse(scene.boxFocused)
        XCTAssertEqual(scene.handle(.down), .redraw, "the cursor was not on the last row after the box")
        XCTAssertTrue(scene.boxFocused)
    }

    // MARK: - Discover's `d`

    private func lifecycle() -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let log = SceneLifecycleLog()
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }),
            readCountByPersistentID: { _ in 100 },
            confirmReadByPersistentID: { _ in discoverConfirmedToken },
            readContainerTrackIDsByPersistentID: { _ in nil },
            readTracksByPersistentID: { _ in throw Stop.stop })
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    func testDOnDiscoverNoLongerOpensAnythingAndItsFooterNoLongerOffersARequest() {
        let rig = SceneDataRig(output: .source, accepted: true)
        let status = StatusStore()
        let scene = DiscoverScene(feed: nil, status: status, actions: ActionRunner(status: status), api: nil,
                                  lifecycle: lifecycle(), routing: rig.coordinator(), opener: SceneRecordingOpener())
        let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        let deadline = Date().addingTimeInterval(5)
        while scene.rails.isEmpty && Date() < deadline { _ = scene.tick(snapshot: idle); usleep(2_000) }
        XCTAssertFalse(scene.rails.isEmpty)

        let level = scene.currentLevel
        let footer = scene.footerHint
        XCTAssertEqual(scene.handle(.char("d")), .none, "d did something on Discover")
        XCTAssertEqual(scene.currentLevel, level)
        XCTAssertFalse(scene.capturesAllInput, "d captured the keyboard")
        XCTAssertEqual(scene.footerHint, footer)
        XCTAssertFalse(footer.lowercased().contains("request"), footer)
        let out = scene.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Make a request"))
        XCTAssertFalse(out.contains("Apple Music DJ"))
        // A letter typed after it is not text anywhere.
        XCTAssertEqual(scene.handle(.char("x")), .none)
    }

    func testDiscoversSearchStillOpensOnSlashAndCapturesKeys() {
        let rig = SceneDataRig(output: .source, accepted: true)
        let status = StatusStore()
        let scene = DiscoverScene(feed: nil, status: status, actions: ActionRunner(status: status), api: nil,
                                  lifecycle: lifecycle(), routing: rig.coordinator(), opener: SceneRecordingOpener())
        let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
        let deadline = Date().addingTimeInterval(5)
        while scene.rails.isEmpty && Date() < deadline { _ = scene.tick(snapshot: idle); usleep(2_000) }
        _ = scene.handle(.char("/"))
        XCTAssertEqual(scene.currentLevel, .search)
        for c in "d" { _ = scene.handle(.char(c)) }
        XCTAssertEqual(scene.searchPane?.model.text, "d")
    }
}

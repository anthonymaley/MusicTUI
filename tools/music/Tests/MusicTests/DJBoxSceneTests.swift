// tools/music/Tests/MusicTests/DJBoxSceneTests.swift
//
// The DJ box on Discover (`d`), driven through the real scene over a real
// `RoutingCoordinator` and the SceneDataRig's fake SpanDAC clients, with a fake
// reader (the Apple model is never asked), a fake AppleScript runner for the
// MusicTUI-data library read, a fake SpanDAC genre source, a hand-off spy and a
// recording queue player. No test reaches a real player, a socket, osascript,
// the keychain, the network or ~/.config/music (the external-call tripwire is
// armed for every test).
//
// What these pin: the box takes raw input and asks off the input loop; a newer
// prompt wins and a stale answer (an error too) never lands; Esc closes and a
// reopened box never shows the old one's answer; the card shows the exact scope
// and freezes the queue; nothing plays before Enter and Enter plays exactly
// once; a source or output change between card and Enter drops the card and
// says so; an artist mix is SpanDAC data on a SpanDAC output only and refuses
// every other combination before any read, add or lifecycle call.
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

final class DJBoxSceneTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let fs = "\u{1F}", rs = "\u{1E}"
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

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
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let log: SceneLifecycleLog
        let mac: FakeSpanDACMac
        let lib: FakeAppleLibrary
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
        let log = SceneLifecycleLog()
        let lib = FakeAppleLibrary()
        let mac = FakeSpanDACMac(library: lib)
        log.mac = mac
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle(log), routing: routing,
                                  opener: SceneRecordingOpener())
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        scene.libraryOps = mac.client

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
        scene.dj = seams
        return Fixture(rig: rig, scene: scene, routing: routing, status: status, actions: actions, log: log,
                       mac: mac, lib: lib, reader: reader, handoff: handoff, store: store, plays: plays,
                       scripts: scripts)
    }

    private func ticks(_ f: Fixture, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertTrue(done(), "timed out", file: file, line: line)
    }

    private func settle(_ f: Fixture, seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    private func loadRails(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        ticks(f, until: { !f.scene.rails.isEmpty }, file: file, line: line)
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    private func type(_ f: Fixture, _ text: String) {
        for c in text { _ = f.scene.handle(c == " " ? .space : .char(c)) }
    }

    private func stage(_ f: Fixture) -> DJBoxModel.Stage? { f.scene.djModel?.stage }

    private var isDJ: (Fixture) -> Bool { { if case .dj = $0.scene.currentLevel { return true }; return false } }

    private func plan(_ f: Fixture) -> DJPlan? {
        if case .card(let plan)? = stage(f) { return plan }
        return nil
    }

    private func message(_ f: Fixture) -> String? {
        if case .message(let text)? = stage(f) { return text }
        return nil
    }

    /// `d`, the prompt, Enter.
    private func ask(_ f: Fixture, _ prompt: String) {
        if f.scene.djModel == nil { _ = f.scene.handle(.char("d")) }
        type(f, prompt)
        _ = f.scene.handle(.enter)
    }

    /// Ask and wait for the answer to be on screen as a card.
    private func askForCard(_ f: Fixture, _ prompt: String, file: StaticString = #filePath, line: UInt = #line) {
        ask(f, prompt)
        ticks(f, until: { self.plan(f) != nil || self.message(f) != nil }, file: file, line: line)
    }

    private func assertNoLibraryOrPlay(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.mac.allOps, [], "a SpanDAC library op was sent", file: file, line: line)
        XCTAssertEqual(f.lib.events, [], "Music.app's library was touched", file: file, line: line)
        XCTAssertEqual(f.log.created, [], "the lifecycle created a container", file: file, line: line)
        XCTAssertEqual(f.log.played, [], "the lifecycle played", file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "a queue was sent", file: file, line: line)
    }

    private func artistMixReading(_ artist: String = "Radiohead") -> DJReading {
        .card(DJCard(kind: .artistMix, artist: artist, genre: nil))
    }

    private func genreReading(_ genre: String = "Jazz") -> DJReading {
        .card(DJCard(kind: .genreUnheard, artist: nil, genre: genre))
    }

    // MARK: - `d` and the box

    func testDOpensTheBoxAndItCapturesEveryKeyUntilEscCloses() {
        let f = fixture(output: .source)
        loadRails(f)
        XCTAssertFalse(f.scene.capturesAllInput)

        XCTAssertEqual(f.scene.handle(.char("d")), .redraw)
        XCTAssertTrue(isDJ(f), "\(f.scene.currentLevel)")
        XCTAssertTrue(f.scene.capturesAllInput)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .scene)
        type(f, "p r q j k / d")
        XCTAssertEqual(f.scene.djModel?.text, "p r q j k / d")
        let out = f.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains(DJBoxModel.boxPrefix), "the box is not drawn")

        XCTAssertEqual(f.scene.handle(.escape), .redraw)
        XCTAssertFalse(isDJ(f))
        XCTAssertFalse(f.scene.capturesAllInput)
        XCTAssertNil(f.scene.djModel)
        XCTAssertEqual(f.scene.currentLevel, .root)
    }

    func testDDoesNothingInsideAnotherBoxOrTheSearch() {
        let f = fixture(output: .source)
        loadRails(f)
        _ = f.scene.handle(.char("/"))
        type(f, "d")
        XCTAssertNil(f.scene.djModel, "d opened the DJ inside the search box")
        XCTAssertEqual(f.scene.searchPane?.model.text, "d")
    }

    func testTheFooterSaysHowToUseTheBox() {
        let f = fixture(output: .source)
        loadRails(f)
        _ = f.scene.handle(.char("d"))
        XCTAssertTrue(f.scene.footerHint.contains("Esc"), f.scene.footerHint)
    }

    // MARK: - Asking: off the input loop, one reader call

    func testEnterAsksTheReaderOnceOffTheInputLoop() {
        let f = fixture(output: .source)
        loadRails(f)
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
        loadRails(f)
        ask(f, "   ")
        settle(f, seconds: 0.1)
        XCTAssertEqual(f.reader.asked, [])
        XCTAssertEqual(stage(f), .typing)
    }

    // MARK: - What the reader cannot do

    func testAnUnsupportedPromptSaysWhatTheDJCanDoAndPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("music like tribe called quest", with: .card(.unsupported))
        askForCard(f, "music like tribe called quest")
        XCTAssertEqual(message(f), djUnsupportedRequest)
        XCTAssertEqual(djUnsupportedRequest, "The DJ can do artist mixes and genres you haven't heard lately for now.")
        assertNoLibraryOrPlay(f)
        XCTAssertEqual(f.rig.sent("slice.search").count, 0)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testEveryUnavailableStateShowsItsOwnPlainMessageAndPlaysNothing() {
        var seen = Set<String>()
        for reason in DJUnavailable.allCases {
            let f = fixture(output: .source)
            loadRails(f)
            f.reader.answer("x", with: .unavailable(reason))
            askForCard(f, "x")
            XCTAssertEqual(message(f), reason.message, "\(reason)")
            seen.insert(reason.message)
            assertNoLibraryOrPlay(f)
            XCTAssertEqual(f.plays.queues.count, 0)
        }
        XCTAssertEqual(seen.count, DJUnavailable.allCases.count, "two states shared one message")
    }

    func testAReaderThatDoesNotAnswerInTimeShowsTheTimeoutSentenceAndLeavesTheSpinner() {
        let f = fixture(output: .source)
        loadRails(f)
        var seams = f.scene.dj
        seams.readerTimeout = 0.1
        f.scene.dj = seams
        f.reader.hold("slow one")
        ask(f, "slow one")
        XCTAssertEqual(stage(f), .reading)
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(message(f), "The DJ took too long to answer. Try again.")
        XCTAssertNotEqual(f.scene.djModel?.statusLine, "Asking the DJ\u{2026}")
        XCTAssertEqual(djReaderTimedOutLine, "The DJ took too long to answer. Try again.")
        f.reader.release("slow one")
    }

    func testTheDefaultReaderTimeoutIsTwentySeconds() {
        XCTAssertEqual(DJSeams().readerTimeout, 20)
    }

    func testALateAnswerAfterTheTimeoutNeverLands() {
        let f = fixture(output: .source)
        loadRails(f)
        var seams = f.scene.dj
        seams.readerTimeout = 0.1
        f.scene.dj = seams
        f.reader.answer("late jazz", with: genreReading("Jazz"))
        f.reader.hold("late jazz")
        ask(f, "late jazz")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(message(f), djReaderTimedOutLine)
        // The reader finally answers with a real card.
        f.reader.release("late jazz")
        settle(f, seconds: 0.4)
        XCTAssertEqual(message(f), djReaderTimedOutLine, "a late card replaced the timeout sentence")
        XCTAssertNil(plan(f), "a late answer produced a card")
        assertNoLibraryOrPlay(f)
    }

    func testAFailedReadShowsItsOwnMessage() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("x", with: .failed("the model errored"))
        askForCard(f, "x")
        XCTAssertEqual(message(f), "The DJ couldn't read that: the model errored")
        assertNoLibraryOrPlay(f)
    }

    // MARK: - Newer prompt wins; stale answers never land

    func testAnOlderPromptsAnswerArrivingLastNeverReplacesTheNewer() {
        let f = fixture(output: .source)
        loadRails(f)
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
        XCTAssertEqual(message(f), djUnsupportedRequest, "the older prompt's answer replaced the newer")
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "a stale request went on to read the catalogue")
    }

    func testAnOlderPromptsErrorArrivingLastNeverReplacesTheNewer() {
        let f = fixture(output: .source)
        loadRails(f)
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

    func testAClosedBoxsLateAnswerNeverShowsUnderTheNextBox() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("first", with: .failed("old box"))
        f.reader.hold("first")
        ask(f, "first")
        ticks(f, until: { f.reader.asked == ["first"] })
        _ = f.scene.handle(.escape)
        XCTAssertNil(f.scene.djModel)

        f.reader.answer("second", with: .card(.unsupported))
        f.reader.hold("second")
        ask(f, "second")
        ticks(f, until: { f.reader.asked == ["first", "second"] })
        f.reader.release("first")
        settle(f)
        XCTAssertEqual(stage(f), .reading, "the closed box's answer landed in the new box")
        f.reader.release("second")
        ticks(f, until: { self.message(f) != nil })
        XCTAssertEqual(message(f), djUnsupportedRequest)
    }

    func testAClosedBoxsAnswerAfterEscNeverReopensIt() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("x", with: artistMixReading())
        f.reader.hold("x")
        ask(f, "x")
        ticks(f, until: { f.reader.asked == ["x"] })
        _ = f.scene.handle(.escape)
        f.reader.release("x")
        settle(f)
        XCTAssertNil(f.scene.djModel)
        XCTAssertFalse(isDJ(f))
        XCTAssertEqual(f.rig.sent("slice.search").count, 0)
        XCTAssertFalse(f.scene.capturesAllInput)
    }

    // MARK: - Artist mix: the card

    func testAnArtistMixCardShowsKindArtistAndTheExactScopeAndPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("a radiohead mix", with: artistMixReading())
        askForCard(f, "a radiohead mix")

        let card = plan(f)
        XCTAssertNotNil(card, "\(String(describing: stage(f)))")
        XCTAssertEqual(card?.line, "Radiohead \u{00B7} 50 songs from 3 albums (3 unavailable skipped)")
        guard case .artistMix(let mix)? = card?.payload else { return XCTFail("\(String(describing: card))") }
        XCTAssertEqual(mix.ids.count, 50)
        XCTAssertEqual(Set(mix.ids).count, 50)
        let playable = Set(Self.radioheadAlbum1 + Self.radioheadAlbum2 + Self.radioheadAlbum3)
            .subtracting(Self.radioheadUnavailable)
        XCTAssertTrue(Set(mix.ids).isSubset(of: playable), "an unavailable song is in the mix")
        XCTAssertEqual(mix.unavailable, 3)

        // Reads came from SpanDAC on this Mac; nothing was queued or added.
        XCTAssertEqual(f.rig.sent("slice.search").map(\.tag), ["mac-data"])
        XCTAssertEqual(f.rig.sent("slice.search").first?.body["term"] as? String, "Radiohead")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["id"] as? String, "art1")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["limit"] as? Int, 25)
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 3)
        assertNoLibraryOrPlay(f)
        let out = f.scene.render(frame: shellLayout(width: 140, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains("Radiohead"), "the card is not drawn")
    }

    func testEnterPlaysExactlyTheFrozenIDsOnceAndASecondEnterPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        guard case .artistMix(let mix)? = plan(f)?.payload else { return XCTFail() }

        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        drain(f.actions)
        XCTAssertEqual(f.scene.handle(.enter), .none, "a second Enter did something")
        drain(f.actions)

        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1, "one Enter must be one queue")
        XCTAssertEqual(queues.first?.body["ids"] as? [String], mix.ids)
        XCTAssertNotEqual(queues.first?.tag, "mac-data", "the queue went to the data client, not the output")
        XCTAssertEqual(f.mac.allOps, [])
        XCTAssertEqual(f.lib.events, [])
        XCTAssertEqual(f.log.created, [])
        XCTAssertEqual(f.log.played, [])
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 3, "Enter read the albums again")
    }

    /// SpanDAC's own refusal of the queue reaches him as it is said; nothing else is added.
    func testSpanDACsRefusalOfTheQueueSurfacesAsItIs() {
        let f = fixture(output: .source)
        loadRails(f)
        f.rig.responders["slice.queue"] = { _ in
            #"{"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"A queue holds at most 100 songs in SpanDAC; 101 were requested."}}"#
        }
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 1)
        XCTAssertTrue(f.status.current()?.text.contains("A queue holds at most 100 songs") ?? false,
                      f.status.current()?.text ?? "no status")
        XCTAssertEqual(f.mac.allOps, [])
        XCTAssertEqual(f.lib.events, [])
    }

    func testEscDropsTheCardAndNothingEverPlays() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        _ = f.scene.handle(.escape)
        XCTAssertNil(f.scene.djModel)
        _ = f.scene.handle(.enter)       // a Discover Enter now, not the card's
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testEditingThePromptAfterTheCardNeverPlaysTheOldCard() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        type(f, "!")
        XCTAssertEqual(stage(f), .typing)
        _ = f.scene.handle(.enter)       // asks again; does not play
        ticks(f, until: { f.reader.asked == ["mix", "mix!"] })
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testTheCardSaysFirst25AlbumsWhenTheArtistHasMore() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("beatles", with: artistMixReading("Beatles"))
        askForCard(f, "beatles")
        XCTAssertTrue(plan(f)?.line.contains("first 25 albums") ?? false, plan(f)?.line ?? "no card")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").first?.body["id"] as? String, "b1",
                       "The Beatles is the one exact match for Beatles")
    }

    // MARK: - Artist mix: choosing the artist

    func testTwoArtistsOfOneNameOfferAPickerAndTheChosenCatalogueIDIsKept() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("nirvana mix", with: artistMixReading("Nirvana"))
        ask(f, "nirvana mix")
        ticks(f, until: { if case .pick? = self.stage(f) { return true } else { return false } })
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0, "an artist was chosen for him")
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.plan(f) != nil })

        XCTAssertEqual(f.rig.sent("slice.search").count, 1, "the chosen artist was resolved by name again")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").map { $0.body["id"] as? String ?? "" }, ["n2"])
        guard case .artistMix(let mix)? = plan(f)?.payload else { return XCTFail() }
        XCTAssertEqual(Set(mix.ids), ["nb1", "nb2", "nb3"])
        XCTAssertEqual(mix.artistID, "n2")
        assertNoLibraryOrPlay(f)
    }

    func testNoExactMatchOffersTheNearestArtistsToPick() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("rad", with: artistMixReading("Rad"))
        ask(f, "rad")
        ticks(f, until: { if case .pick(let p)? = self.stage(f) { return p.hits.count == 2 } else { return false } })
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.plan(f) != nil })
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").map { $0.body["id"] as? String ?? "" }, ["r1"])
    }

    func testNoArtistFoundSaysSoAndPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("nobody", with: artistMixReading("Nobody"))
        askForCard(f, "nobody")
        XCTAssertEqual(message(f), "No artist found for Nobody.")
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0)
        assertNoLibraryOrPlay(f)
    }

    func testAnOlderSpanDACWithoutArtistSearchSaysSo() {
        let f = fixture(output: .source, artists: false)
        loadRails(f)
        f.reader.answer("radiohead", with: artistMixReading())
        askForCard(f, "radiohead")
        XCTAssertEqual(message(f), CatalogueSearchResults.artistsNeedNewerSpanDAC)
        assertNoLibraryOrPlay(f)
    }

    func testAFailedSearchShowsTheReasonAndPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("broken", with: artistMixReading("Broken"))
        askForCard(f, "broken")
        XCTAssertTrue(message(f)?.contains("Apple Music isn't answering") ?? false, message(f) ?? "no message")
        assertNoLibraryOrPlay(f)
    }

    func testAFailedAlbumReadFailsTheWholeMixAndPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.rig.responders["slice.artistAlbums"] = { _ in Self.albumsReply(["alb1", "bad", "alb3"]) }
        f.reader.answer("radiohead", with: artistMixReading())
        askForCard(f, "radiohead")
        XCTAssertNil(plan(f), "a partial mix was offered")
        XCTAssertTrue(message(f)?.contains("Title bad") ?? false, message(f) ?? "no message")
        assertNoLibraryOrPlay(f)
    }

    func testAnArtistWithNoPlayableSongsPlaysNothing() {
        let f = fixture(output: .source)
        loadRails(f)
        f.rig.responders["slice.artistAlbums"] = { _ in Self.albumsReply(["empty"]) }
        f.reader.answer("radiohead", with: artistMixReading())
        askForCard(f, "radiohead")
        XCTAssertNil(plan(f))
        XCTAssertEqual(message(f), "No playable songs found for Radiohead.")
    }

    // MARK: - Artist mix: every other combination refuses before any read, add or lifecycle call

    private func assertArtistMixRefusedBeforeAnything(_ f: Fixture, expected: String,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix", file: file, line: line)
        XCTAssertEqual(message(f), expected, file: file, line: line)
        XCTAssertNil(plan(f), file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "the catalogue was read", file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.artistAlbums").count, 0, file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 0, file: file, line: line)
        assertNoLibraryOrPlay(f, file: file, line: line)
        XCTAssertEqual(f.rig.outputBuilt, [], "an output client was built", file: file, line: line)
    }

    func testSpanDACDataOnTheMusicTUIOutputRefusesAnArtistMix() {
        let f = fixture(output: .musicApp)
        loadRails(f)
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

    // MARK: - A source or output change between the card and Enter

    func testAnOutputChangeAfterTheCardDropsItAndSaysSoOnTheNextTick() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        _ = try f.routing.switchMode(to: .musicApp, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)
        XCTAssertNil(plan(f), "the card survived an output change")
        XCTAssertEqual(message(f), djChangedLine)
        _ = f.scene.handle(.enter)       // a message: Enter asks again, it does not play
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    func testAnOutputChangeAfterTheCardDropsItAtEnterEvenBeforeATick() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        _ = try f.routing.switchMode(to: .musicApp, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    func testADataSourceChangeAfterTheCardClosesTheBoxWithASentence() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)
        XCTAssertNil(f.scene.djModel, "the box survived a change of data source")
        XCTAssertFalse(isDJ(f))
        XCTAssertFalse(f.scene.capturesAllInput)
        XCTAssertEqual(f.status.current()?.text, DiscoverScene.djDataSourceChanged)
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testAnotherPlayBetweenTheCardAndEnterDropsTheCard() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        // Some other chosen-music play is admitted meanwhile.
        try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .spandacLibrary,
                              musicApp: { _ in }, source: { _ in }, unaffected: {})
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(message(f), djChangedLine)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    func testAnAnswerFromBeforeAnOutputSwitchNeverLandsAsACard() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        f.reader.hold("mix")
        ask(f, "mix")
        ticks(f, until: { f.reader.asked == ["mix"] })
        _ = try f.routing.switchMode(to: .musicApp, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        f.reader.release("mix")
        settle(f)
        XCTAssertNil(plan(f), "an answer from before the switch landed as a card")
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
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

    func testGenreOnMusicTUIDataShowsTheCardThenPlaysTheFrozenQueueOnce() throws {
        // 120 jazz songs, played 100...219 days ago (all eligible); song n played (99 + n) days ago,
        // so song 120 is the oldest. 30 rock songs never played (must not match).
        let text = libraryText(count: 150,
                               genre: { $0 <= 120 ? "Vocal Jazz" : "Rock" },
                               played: { $0 <= 120 ? self.daysAgoToken(99 + $0) : "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("some jazz", with: genreReading("jazz"))
        askForCard(f, "some jazz")

        let card = try XCTUnwrap(plan(f), "\(String(describing: stage(f)))")
        XCTAssertEqual(card.line, "jazz you haven't played in 90 days \u{00B7} 50 songs")
        XCTAssertEqual(f.scripts.count, 1, "the library was read more than once")
        XCTAssertEqual(f.plays.queues.count, 0, "it played before Enter")
        XCTAssertNil(f.store.read(), "the queue was set before Enter")
        XCTAssertEqual(f.rig.sent.count, 0, "a SpanDAC client was used for MusicTUI's own data")

        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        drain(f.actions)
        XCTAssertEqual(f.scene.handle(.enter), .none)
        drain(f.actions)

        XCTAssertEqual(f.plays.queues.count, 1, "one Enter must be one queue")
        let queue = try XCTUnwrap(f.plays.queues.first)
        XCTAssertEqual(queue.playlistName, persistentIDQueueSource)
        let played = queue.tracks.map { persistentIDOfQueueEntry($0.index) }
        // The 50 oldest are songs 71...120, oldest (120) first; the test shuffler reverses that order.
        XCTAssertEqual(played, (71...120).map(pid))
        XCTAssertEqual(f.store.read(), queue)
        XCTAssertEqual(f.scripts.count, 1, "Enter read the library again")
    }

    func testGenreNeverPlayedAndRecentlyPlayedAreHandledAndTheCountIsExact() {
        let text = libraryText(count: 10,
                               genre: { _ in "Jazz" },
                               played: { n in n <= 3 ? "N" : (n <= 6 ? self.daysAgoToken(91) : self.daysAgoToken(89)) })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertEqual(plan(f)?.line, "Jazz you haven't played in 90 days \u{00B7} 6 songs")
    }

    func testAnEmptyResultOffersNoCard() {
        let text = libraryText(count: 5, genre: { _ in "Rock" }, played: { _ in "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNil(plan(f))
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
        _ = f.scene.handle(.enter)       // asks again, never plays
        drain(f.actions)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testAnEmptyLibraryOffersNoCard() {
        let f = openFixture(library: libraryText(count: 0, genre: { _ in "" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
    }

    func testFiftyAndFewerThanFiftyAreBothExact() {
        let fifty = openFixture(library: libraryText(count: 50, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(fifty, seconds: 0.1)
        fifty.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(fifty, "jazz")
        XCTAssertEqual(plan(fifty)?.line, "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        let one = openFixture(library: libraryText(count: 1, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(one, seconds: 0.1)
        one.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(one, "jazz")
        XCTAssertEqual(plan(one)?.line, "Jazz you haven't played in 90 days \u{00B7} 1 song")
    }

    func testAnUnreadableDateIsSkippedAndSaid() {
        let text = libraryText(count: 4, genre: { _ in "Jazz" }, played: { $0 == 1 ? "U" : "N" })
        let f = openFixture(library: text)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertEqual(plan(f)?.line,
                       "Jazz you haven't played in 90 days \u{00B7} 3 songs (1 with an unreadable date skipped)")
    }

    func testMisalignedColumnsFailTheWholeReadAndPlayNothing() {
        let skewed = [pid(1) + rs + pid(2), "N", "A", "B", "Jazz", "N"].joined(separator: fs)
        let f = openFixture(library: skewed)
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNil(plan(f))
        XCTAssertEqual(message(f), djLibraryMisaligned)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testATimedOutReadRefuses() {
        let f = openFixture()
        f.scripts.reply = { throw AppleScriptBackend.ScriptError.timeout("script") }
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNil(plan(f))
        XCTAssertEqual(message(f), djLibraryReadTimedOut)
        XCTAssertEqual(f.plays.queues.count, 0)
    }

    func testAFailedPlayStartClearsTheQueueAndSaysSo() throws {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        var seams = f.scene.dj
        seams.playFirst = { _ in false }
        f.scene.dj = seams
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertNil(f.store.read(), "a queue that never started was left for the poller")
        XCTAssertTrue(f.status.current()?.isError ?? false, "\(String(describing: f.status.current()))")
    }

    func testMusicTUIDataWithASpanDACOutputRefusesBeforeReadingAnything() {
        let f = fixture(output: .source, accepted: false)
        f.scripts.reply = { XCTFail("the library was read"); return "" }
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNil(plan(f))
        XCTAssertEqual(message(f), finishSwitchingToSpanDAC)
        XCTAssertEqual(f.scripts.count, 0)
        XCTAssertEqual(f.plays.queues.count, 0)
        XCTAssertEqual(f.rig.sent.count, 0)
    }

    func testAnotherPlayBetweenTheGenreCardAndEnterDropsTheCard() throws {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNotNil(plan(f))
        try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .openData(resultNumber: nil),
                              musicApp: { _ in }, source: { _ in }, unaffected: {})
        _ = f.scene.handle(.enter)
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

    func testGenreOnSpanDACDataAndOutputQueuesTheFrozenLibraryIDsOnce() throws {
        let rows = aliasRows(50)
        let source = DJFakeGenreSource(.success(spandacPick(rows, total: 312)))
        let f = fixture(output: .source, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")

        let card = try XCTUnwrap(plan(f), "\(String(describing: stage(f)))")
        XCTAssertEqual(card.line, "Jazz you haven't played in 90 days \u{00B7} 50 songs")
        XCTAssertEqual(source.asked.map(\.genre), ["Jazz"])
        XCTAssertEqual(source.asked.map(\.days), [90])
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "it played before Enter")
        XCTAssertEqual(f.scripts.count, 0, "AppleScript was read for SpanDAC data")

        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        drain(f.actions)
        XCTAssertEqual(f.scene.handle(.enter), .none)
        drain(f.actions)

        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1)
        // The server's 50 are shuffled client side (the test shuffler reverses them).
        XCTAssertEqual(queues.first?.body["library_ids"] as? [String], rows.map(\.id).reversed().map { $0 })
        XCTAssertNotEqual(queues.first?.tag, "mac-data")
        XCTAssertEqual(source.rechecks, 1, "the library was not re-checked at Enter")
        XCTAssertEqual(f.handoff.calls.count, 0)
        XCTAssertEqual(f.log.created, [])
    }

    func testGenreOnSpanDACDataAndTheMusicTUIOutputHandsOffVerifiedAliasesOnly() throws {
        let rows = aliasRows(5)
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .musicApp, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNotNil(plan(f), "\(String(describing: stage(f)))")
        XCTAssertEqual(f.handoff.calls.count, 0)

        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(f.handoff.calls.count, 1, "one Enter must be one hand-off")
        XCTAssertEqual(f.handoff.calls.first?.map(\.id), rows.map(\.id).reversed().map { $0 })
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        XCTAssertEqual(f.plays.queues.count, 0, "the open-data queue player was used for SpanDAC rows")
        assertNoLibraryOrPlay(f)
    }

    func testAnySongWithoutAnAliasFailsTheWholePickOnTheMusicTUIOutput() {
        let rows = aliasRows(5, withAlias: { $0 != 3 })
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .musicApp, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNil(plan(f), "a pick with an unaliased song was offered")
        XCTAssertEqual(message(f), djGenreNeedsAliases)
        XCTAssertEqual(f.handoff.calls.count, 0)
    }

    func testASpanDACOutputNeedsNoAliasToQueueByLibraryID() {
        let rows = aliasRows(3, withAlias: { _ in false })
        let source = DJFakeGenreSource(.success(spandacPick(rows)))
        let f = fixture(output: .source, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNotNil(plan(f), "\(String(describing: stage(f)))")
    }

    func testALibraryThatChangedBeforeEnterDropsTheCardAndPlaysNothing() {
        let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
        source.recheckError = DJGenreSourceError.libraryChanged
        let f = fixture(output: .source, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        _ = f.scene.handle(.enter)
        drain(f.actions)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        XCTAssertEqual(f.status.current()?.text, DJGenreSourceError.libraryChanged.message)
    }

    func testAnEmptySpanDACGenreResultOffersNoCard() {
        let source = DJFakeGenreSource(.success(spandacPick([], total: 0)))
        let f = fixture(output: .source, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertEqual(message(f), "No Jazz songs you haven't played in 90 days.")
    }

    func testAnOlderSpanDACSaysItNeedsANewerOneAndPlaysNothing() {
        let f = fixture(output: .source)       // the stub source
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertEqual(message(f), djNeedsNewerSpanDAC)
        assertNoLibraryOrPlay(f)
    }

    func testASpanDACGenreFailureIsSaidInItsOwnWords() {
        let source = DJFakeGenreSource(.failure(DJGenreSourceError.failed("SpanDAC is warming")))
        let f = fixture(output: .source, genreSource: source)
        loadRails(f)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertTrue(message(f)?.contains("SpanDAC is warming") ?? false, message(f) ?? "no message")
    }

    // MARK: - Codex branch review r1

    /// A held action ahead of the DJ's: Enter queues the DJ play behind it, `admit`
    /// lets a different play in meanwhile, then the hold is released.
    private func enterBehindAHold(_ f: Fixture, admit: () throws -> Void) throws {
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        try admit()
        hold.signal()
        drain(f.actions)
    }

    // Finding 2: the play serial is checked at admission, with both epochs.

    func testAnArtistMixWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothing() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("mix", with: artistMixReading())
        askForCard(f, "mix")
        XCTAssertNotNil(plan(f))
        try enterBehindAHold(f) {
            try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .spandacLibrary,
                                  musicApp: { _ in }, source: { _ in }, unaffected: {})
        }
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "the artist mix queued after another play was admitted")
        XCTAssertEqual(f.status.current()?.text, anotherPlayAdmittedNothingPlayed)
    }

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
        try routing.perform(.libraryPlay, expecting: routing.stamp, origin: .spandacLibrary,
                            musicApp: { _ in ran += 1 }, source: { _ in ran += 1 }, unaffected: {})
        XCTAssertEqual(ran, 2)
    }

    func testAnOpenDataGenreWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothing() throws {
        let f = openFixture(library: libraryText(count: 3, genre: { _ in "Jazz" }, played: { _ in "N" }))
        settle(f, seconds: 0.1)
        f.reader.answer("jazz", with: genreReading("Jazz"))
        askForCard(f, "jazz")
        XCTAssertNotNil(plan(f))
        try enterBehindAHold(f) {
            try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .openData(resultNumber: nil),
                                  musicApp: { _ in }, source: { _ in }, unaffected: {})
        }
        XCTAssertEqual(f.plays.queues.count, 0, "the genre queue played after another play was admitted")
        XCTAssertNil(f.store.read(), "the genre queue was set after another play was admitted")
    }

    func testASpanDACGenreWhoseActionWaitedWhileAnotherPlayWasAdmittedPlaysNothingOnEitherOutput() throws {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let f = fixture(output: output, genreSource: source)
            loadRails(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askForCard(f, "jazz")
            XCTAssertNotNil(plan(f), "\(output)")
            try enterBehindAHold(f) {
                try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .spandacLibrary,
                                      musicApp: { _ in }, source: { _ in }, unaffected: {})
            }
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after another play was admitted")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after another play was admitted")
        }
    }

    func testAPlayAdmittedWhileTheRecheckIsHeldStopsTheSpanDACGenre() throws {
        for output in [PlaybackMode.source, .musicApp] {
            let source = DJFakeGenreSource(.success(spandacPick(aliasRows(5))))
            let gate = DispatchSemaphore(value: 0)
            let f = fixture(output: output, genreSource: source)
            loadRails(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askForCard(f, "jazz")
            XCTAssertNotNil(plan(f), "\(output)")
            source.recheckGate = gate
            XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
            XCTAssertEqual(source.recheckStarted.wait(timeout: .now() + 5), .success, "the recheck never started")
            try f.routing.perform(.libraryPlay, expecting: f.routing.stamp, origin: .spandacLibrary,
                                  musicApp: { _ in }, source: { _ in }, unaffected: {})
            gate.signal()
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output): queued after another play was admitted")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output): handed off after another play was admitted")
        }
    }

    // Finding 3: `d` over a loading Discover album does not lose the album read.

    private func playlistTracksFixture() -> Fixture {
        let f = fixture(output: .source)
        let base = f.rig.responders["slice.containerTracks"]
        f.rig.responders["slice.containerTracks"] = { body in
            if body["id"] as? String == "pl.u-abc" { return Self.tracksReply(["901", "902"]) }
            return base?(body) ?? ""
        }
        return f
    }

    private func isTracks(_ f: Fixture, _ id: String) -> Bool {
        if case .tracks(let item) = f.scene.currentLevel { return item.id == id }
        return false
    }

    func testDOverALoadingAlbumKeepsItsReadAndEscShowsTheRows() {
        let f = playlistTracksFixture()
        let held = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var first = true
        f.rig.during["slice.containerTracks"] = {
            lock.lock(); let hold = first; first = false; lock.unlock()
            if hold { _ = held.wait(timeout: .now() + 5) }
        }
        loadRails(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)                      // the album's read is held
        ticks(f, until: { f.rig.sent("slice.containerTracks").count == 1 })

        _ = f.scene.handle(.char("d"))
        XCTAssertTrue(isDJ(f))
        held.signal()                                   // the read finishes under the box
        settle(f, seconds: 0.2)
        _ = f.scene.handle(.escape)

        XCTAssertTrue(isTracks(f, "pl.u-abc"), "\(f.scene.currentLevel)")
        ticks(f, until: { f.scene.trackRows.map(\.id) == ["901", "902"] })
        XCTAssertEqual(f.scene.shownCursorIndex, 0)
    }

    func testDOverAnAlreadyLoadedAlbumLeavesItsRowsAndCursorAlone() {
        let f = playlistTracksFixture()
        loadRails(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.scene.trackRows.map(\.id) == ["901", "902"] })
        _ = f.scene.handle(.down)
        XCTAssertEqual(f.scene.shownCursorIndex, 1)
        let reads = f.rig.sent("slice.containerTracks").count

        _ = f.scene.handle(.char("d"))
        settle(f, seconds: 0.1)
        _ = f.scene.handle(.escape)

        XCTAssertTrue(isTracks(f, "pl.u-abc"))
        XCTAssertEqual(f.scene.trackRows.map(\.id), ["901", "902"], "the loaded rows were lost")
        XCTAssertEqual(f.scene.shownCursorIndex, 1, "the cursor moved")
        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, reads, "a loaded album was read again")
    }

    func testAnAlbumLoadingUnderTheBoxWhenTheDataSourceChangesIsLeftBehindWithTheBox() throws {
        let f = playlistTracksFixture()
        let held = DispatchSemaphore(value: 0)
        f.rig.during["slice.containerTracks"] = { _ = held.wait(timeout: .now() + 5) }
        loadRails(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.rig.sent("slice.containerTracks").count == 1 })
        _ = f.scene.handle(.char("d"))
        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)
        held.signal()
        settle(f, seconds: 0.2)

        XCTAssertNil(f.scene.djModel)
        XCTAssertEqual(f.status.current()?.text, DiscoverScene.djDataSourceChanged)
        XCTAssertEqual(f.scene.currentLevel, .root, "the old source's album is still on screen")
        XCTAssertEqual(f.scene.trackRows, [])
        _ = f.scene.handle(.char("d"))
        _ = f.scene.handle(.escape)
        XCTAssertEqual(f.scene.currentLevel, .root, "closing a later box brought the old album back")
        XCTAssertEqual(f.scene.trackRows, [])
    }

    // Finding 4: editing a pending prompt invalidates the request that is out.

    func testEditingAPendingPromptReleasesItsRequestAndTheNextEnterAsksTheNewText() {
        let f = fixture(output: .source)
        loadRails(f)
        f.reader.answer("old", with: artistMixReading())
        f.reader.hold("old")
        ask(f, "old")
        ticks(f, until: { f.reader.asked == ["old"] })
        type(f, "x")
        XCTAssertEqual(stage(f), .typing, "the edit left the old request waiting")
        f.reader.release("old")
        settle(f)
        XCTAssertEqual(stage(f), .typing, "the old answer landed after the edit")
        XCTAssertEqual(f.rig.sent("slice.search").count, 0, "the edited-away request went on to read the catalogue")
        XCTAssertNil(plan(f))

        f.reader.answer("oldx", with: .card(.unsupported))
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.message(f) == djUnsupportedRequest })
        XCTAssertEqual(f.reader.asked, ["old", "oldx"])
    }

    func testAnEditedAwayRequestsLateFailureNeverLands() {
        let f = fixture(output: .source)
        loadRails(f)
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

    // Finding 5: a job's progress belongs to the session and request it began under.

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

    func testAnOldJobsProgressNeverLandsUnderTheNextBoxsSameNumberedRequest() {
        let f = fixture(output: .source)
        loadRails(f)
        let park = parkFirstProgress(f)
        f.reader.answer("old mix", with: artistMixReading())
        ask(f, "old mix")                                       // box 1, request 1
        XCTAssertEqual(park.entered.wait(timeout: .now() + 5), .success, "the job never reached its progress")
        _ = f.scene.handle(.escape)                             // closed ...
        f.reader.hold("new")
        f.reader.answer("new", with: .card(.unsupported))
        ask(f, "new")                                           // ... reopened: box 2, request 1
        ticks(f, until: { f.reader.asked.contains("new") })

        park.release.signal()                                   // the old job reports "Looking up Radiohead"
        settle(f, seconds: 0.4)
        XCTAssertEqual(stage(f), .reading, "the old job's progress landed on the new box: \(String(describing: stage(f)))")

        f.reader.release("new")
        ticks(f, until: { self.message(f) == djUnsupportedRequest })
    }

    func testAnOldJobsProgressNeverReplacesTheNewAnswerAlreadyInTheSlot() {
        let f = fixture(output: .source)
        loadRails(f)
        let park = parkFirstProgress(f)
        let written = DispatchSemaphore(value: 0)
        f.reader.answer("old mix", with: artistMixReading())
        ask(f, "old mix")
        XCTAssertEqual(park.entered.wait(timeout: .now() + 5), .success)
        _ = f.scene.handle(.escape)
        f.reader.answer("new", with: .card(.unsupported))
        f.scene.inboxWritten = { if $0 == "dj" { written.signal() } }
        ask(f, "new")                                           // answers at once: the slot holds it, untouched by a tick
        XCTAssertEqual(written.wait(timeout: .now() + 5), .success, "the new answer never reached the slot")

        park.release.signal()
        usleep(300_000)                                         // the old job's progress arrives; no tick yet
        settle(f, seconds: 0.3)
        XCTAssertEqual(message(f), djUnsupportedRequest,
                       "the old job's progress replaced the new answer: \(String(describing: stage(f)))")
    }

    // Finding 1: Enter checks the very songs the card will play, not only the stamp.

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
            loadRails(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askForCard(f, "jazz")
            XCTAssertNotNil(plan(f), "\(output): \(String(describing: stage(f)))")
            answer.count = 4                                    // one of the five chosen is gone
            XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
            drain(f.actions)
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
            loadRails(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askForCard(f, "jazz")
            answer.generation = 8
            _ = f.scene.handle(.enter)
            drain(f.actions)
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0, "\(output)")
            XCTAssertEqual(f.handoff.calls.count, 0, "\(output)")
            XCTAssertEqual(f.status.current()?.text, djSpanDACLibraryChanged, "\(output)")
        }
    }

    func testWhenEveryChosenSongStillResolvesTheGenrePlaysAfterTheCheckOnEitherOutput() {
        for output in [PlaybackMode.source, .musicApp] {
            let answer = ResolveAnswer()
            let f = realClientFixture(output: output, answer: answer)
            loadRails(f)
            f.reader.answer("jazz", with: genreReading("Jazz"))
            askForCard(f, "jazz")
            _ = f.scene.handle(.enter)
            drain(f.actions)
            let ops = f.rig.sent.map(\.op)
            XCTAssertEqual(ops.filter { $0 == "library.resolveIDs" }.count, 1, "\(output)")
            XCTAssertEqual(ops.filter { $0 == "library.genreUnheard" }.count, 1, "\(output): Enter scanned the library again")
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
}

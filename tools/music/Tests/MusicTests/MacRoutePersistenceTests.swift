// tools/music/Tests/MusicTests/MacRoutePersistenceTests.swift
//
// P8 (2026-11-15): the Mac DAC route choice survives a restart, the Mac row's
// highlight follows it, and the route is left by the plain MusicTUI row, a
// speaker toggle, or a network SpanDAC. Temp stores and stub clients only: no
// audio, no AppleScript (the backend is /usr/bin/true), no socket, and never
// `~/.config/music`.
import XCTest
@testable import music

final class MacRoutePersistenceTests: XCTestCase {
    private var dir: String!
    private let speaker: [[String: Any]] = [["name": "Kitchen", "selected": false, "volume": 30, "kind": "speaker"]]

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "macroute-p8-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private var store: MacRouteStore { MacRouteStore(path: dir + "/mac-route.json") }

    /// With no speakers the list shows the plain MusicTUI row; with one it shows the speaker.
    private func scene(speakers: Int = 1, macReply: @escaping () throws -> String = { outputTabReadyReply }) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: FakeSpanDACOutputs(),
                                   speakers: speakers == 0 ? [] : speaker, macReply: macReply)
        settleOutputTab(s, speakers: speakers)
        return s
    }

    private func press(_ s: SpeakersScene, on row: OutputTabRow) {
        let done = DispatchSemaphore(value: 0)
        s.selectModeFinishedForTest = { done.signal() }
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: row) else { return XCTFail("no \(row) row") }
        for _ in 0..<i { _ = s.handle(.down) }
        _ = s.handle(.enter)
        // A row that selects a mode signals; one that does not has no signal to wait for.
        _ = done.wait(timeout: .now() + 0.5)
    }

    private func tickUntil(_ s: SpeakersScene, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !done() { _ = s.tick(snapshot: outputTabSnapshot()); usleep(10_000) }
    }

    private func macRow(_ s: SpeakersScene) -> String {
        let text = screenText(s.render(frame: shellLayout(width: 110, height: 30), snapshot: outputTabSnapshot()),
                              width: 110, height: 30)
        return text.first { $0.contains("Studio Mac") } ?? ""
    }

    func testTheRoutePersistsAcrossANewSceneAndTheMacRowHighlightFollowsIt() {
        let a = scene()
        XCTAssertFalse(a.macDACRouteOn)
        XCTAssertTrue(macRow(a).contains("\u{25CB}"), macRow(a))
        press(a, on: .spandacMac)
        XCTAssertTrue(a.macDACRouteOn)
        XCTAssertTrue(store.isOn)

        let b = scene()   // a restart: new scene, same stores
        XCTAssertTrue(b.macDACRouteOn)
        XCTAssertTrue(b.macRateFollowWanted)
        XCTAssertTrue(macRow(b).contains("\u{25CF}"), macRow(b))
    }

    func testTheMusicTUIRowLeavesTheRouteAndPersistsIt() {
        store.set(true)
        let s = scene(speakers: 0)
        var off = 0
        s.onMacRouteOff = { off += 1 }
        XCTAssertTrue(s.macDACRouteOn)
        press(s, on: .musicApp)
        XCTAssertFalse(s.macDACRouteOn)
        XCTAssertFalse(s.macRateFollowWanted)
        XCTAssertEqual(off, 1)
        XCTAssertFalse(store.isOn)
        XCTAssertEqual(s.routingForTest.mode, .musicApp)
        XCTAssertFalse(scene(speakers: 0).macDACRouteOn, "stays off after a restart")
    }

    func testAMusicTUIRowPressOffTheRouteIsStillANoOp() {
        let s = scene(speakers: 0)
        var off = 0
        s.onMacRouteOff = { off += 1 }
        press(s, on: .musicApp)
        XCTAssertEqual(off, 0)
        XCTAssertFalse(store.isOn)
    }

    func testASpeakerToggleLeavesTheRoute() {
        store.set(true)
        let s = scene()
        var off = 0
        s.onMacRouteOff = { off += 1 }
        press(s, on: .speaker(0))
        XCTAssertFalse(s.macDACRouteOn)
        XCTAssertEqual(off, 1)
        XCTAssertFalse(store.isOn)
    }

    func testASpeakerToggleOffTheRouteTouchesNothing() {
        let s = scene()
        var off = 0
        s.onMacRouteOff = { off += 1 }
        press(s, on: .speaker(0))
        XCTAssertEqual(off, 0)
        XCTAssertFalse(store.isOn)
    }

    func testADACAbsentAtLaunchKeepsTheChoiceAndHoldsTheFollowUntilItIsBack() {
        store.set(true)
        let state = MacDACRouteState(initial: store.isOn)
        XCTAssertTrue(state.isOn)
        var reports: [Bool] = []
        let s = scene(macReply: { outputTabNoDACReply })
        s.onMacDACAbsent = { reports.append($0); state.setDACAbsent($0) }
        // The reply with no DAC was already drained during settle; drive one more.
        s.deliverMacStatusForTest(readiness: .ready, output: SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil))
        tickUntil(s) { reports.last == true }
        XCTAssertTrue(s.macDACRouteOn, "the choice is kept")
        XCTAssertTrue(store.isOn)
        XCTAssertEqual(reports.last, true)
        XCTAssertTrue(state.chosen)
        XCTAssertFalse(state.isOn, "no rate follow while the DAC is absent")

        s.deliverMacStatusForTest(readiness: .ready, output: SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000))
        tickUntil(s) { reports.last == false }
        XCTAssertEqual(reports.last, false)
        XCTAssertTrue(state.isOn, "follow resumes when the DAC is back")
    }

    func testTheStoreReadsEveryFailureAsNotChosenAndOffRemovesTheFile() throws {
        XCTAssertFalse(store.isOn)
        try "not json".write(toFile: dir + "/mac-route.json", atomically: true, encoding: .utf8)
        XCTAssertFalse(store.isOn)
        store.set(true)
        XCTAssertTrue(store.isOn)
        store.set(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/mac-route.json"))
        // Beside mode.json: a temp mode store gives a temp route file.
        XCTAssertEqual(MacRouteStore(beside: PlaybackModeStore(path: dir + "/mode.json")).isOn, false)
    }

    func testRouteStateRestoresItsInitialChoiceAndOffPlaysAreUntouched() {
        XCTAssertFalse(MacDACRouteState().isOn)
        let on = MacDACRouteState(initial: true)
        XCTAssertTrue(on.isOn)
        on.set(false)
        on.setDACAbsent(true)
        XCTAssertFalse(on.isOn)
        on.setDACAbsent(false)
        XCTAssertFalse(on.isOn, "a route that was turned off stays off when the DAC returns")
    }
}

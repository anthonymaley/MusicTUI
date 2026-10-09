// tools/music/Tests/MusicTests/SpeakerVolumeRoutingTests.swift
//
// The Output tab's per-speaker volume arrows obey the routing contract at TWO
// points, and these tests keep them apart: the keypress asks the coordinator
// before the bar moves (`refusal(for:)`), and the queued write runs inside the
// coordinator's `perform` (which decides again when the action runs). A held
// action queue lets a test change the routing between the two.
//
// The coordinator is a `LicenceRig` (fixture transports, temp stores); the
// AppleScript backend is a recording stand-in for osascript. Nothing here
// reaches the real osascript, a player, a socket, the keychain or
// ~/.config/music.
import XCTest
@testable import music

final class SpeakerVolumeRoutingTests: XCTestCase {

    private let volumeSentence = "Volume is MusicTUI only; SpanDAC plays at the Mac's output level."
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "speaker-volume-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: Rigs

    /// Appends each script (`$2`, after `-e`) to a file; exits 0.
    private func recordingBackend() throws -> (AppleScriptBackend, scripts: () -> [String]) {
        let fake = dir + "/osascript"
        let record = dir + "/scripts.txt"
        try "#!/bin/sh\nprintf '%s\\n--END--\\n' \"$2\" >> '\(record)'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return (AppleScriptBackend(executable: fake), {
            ((try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n--END--\n").filter { !$0.isEmpty }
        })
    }

    /// SpanDAC on this Mac stored, data accepted, not serving: the MusicTUI
    /// output, volume allowed.
    private func macNotServing() -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        rig.reply = { _, _ in LicenceRig.status(playback: "idle", serving: false) }
        rig.says(serving: false, playback: "idle")
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.effectiveOutput, .musicApp)
        return (rig, c)
    }

    /// The same Mac stored, whose queue was playing when serving ended: the
    /// selection names MusicTUI, so ONLY the play-out gate refuses volume.
    private func macPlayingOut() -> (LicenceRig, RoutingCoordinator) {
        let rig = LicenceRig(output: .source, accepted: true)
        let c = rig.coordinator()
        rig.says(serving: true, playback: "playing", phase: "complete")
        rig.says(serving: false, playback: "playing", phase: "complete")
        rig.reply = { _, _ in LicenceRig.status(playback: "playing", phase: "complete", serving: false) }
        XCTAssertEqual(c.playOutMode, .source)
        XCTAssertEqual(c.selection, .consistent(data: .open, output: .musicApp))
        return (rig, c)
    }

    private let kitchen: [[String: Any]] = [["name": "Kitchen", "selected": true, "volume": 50]]

    private func scene(_ c: RoutingCoordinator, status: StatusStore, actions: ActionRunner,
                       backend: AppleScriptBackend) -> SpeakersScene {
        let s = SpeakersScene(backend: backend, status: status, actions: actions, routing: c,
                              confirmMusicAppPaused: musicAppPauseTripwire, macName: "Studio Mac",
                              fetchSpeakers: { self.kitchen },
                              fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                              fetchVisualizer: { _ in false },
                              macSocketExists: { false })
        let snap = outputTabSnapshot()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, s.speakerRowsForTest.count != 1 {
            _ = s.tick(snapshot: snap)
            usleep(10_000)
        }
        XCTAssertEqual(s.speakerRowsForTest.count, 1, "the speaker row never loaded")
        // Onto the Kitchen row: the first row whose footer is a speaker's.
        _ = s.handle(.home)
        for _ in 0..<8 where !s.footerHint.contains("Enter Toggle") && !s.footerHint.contains("Enter Use MusicTUI   ") {
            _ = s.handle(.down)
        }
        return s
    }

    /// Holds the action queue until the returned closure is called.
    private func hold(_ actions: ActionRunner) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        actions.enqueueQuiet { gate.wait() }
        return { gate.signal() }
    }

    private func volume(_ s: SpeakersScene) -> Int? { s.speakerRowsForTest.first { $0.name == "Kitchen" }?.volume }

    // MARK: - B2: the write is inside the coordinator's perform

    /// Allowed at the keypress, refused by the time the queue runs: the bar
    /// moved (it was allowed), but the write is refused by `perform` and
    /// nothing reaches Apple's Music app. Reverting `setVolume` to a direct
    /// AppleScript write fails this one.
    func testARoutingFlipBetweenKeypressAndWriteStopsTheWrite() throws {
        let (rig, c) = macNotServing()
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(c, status: status, actions: actions, backend: backend)
        XCTAssertTrue(s.footerHint.contains("Volume"), "allowed to begin with: \(s.footerHint)")
        let release = hold(actions)
        _ = s.handle(.right)
        rig.says(serving: true, playback: "idle")        // SpanDAC serves: it is the output now
        XCTAssertEqual(c.effectiveOutput, .source)
        release()
        actions.waitUntilIdle()
        XCTAssertEqual(scripts(), [], "the refused write never reached the Music app")
        XCTAssertEqual(status.current()?.text, volumeSentence)
        XCTAssertEqual(status.current()?.isError, true)
    }

    // MARK: - B1: a refusal at the keypress is shown even if routing relaxes

    /// Refused at the keypress by a Mac play-out, and the play-out ends (its queue
    /// finishes, the licence still lapsed) before
    /// the queue runs: the person still sees the refusal. (Re-deciding in the
    /// queue would route to MusicTUI and run an empty body: a keypress that
    /// vanished with no toast.)
    func testARefusalAtTheKeypressStillToastsWhenThePlayOutEndsBeforeTheQueueRuns() throws {
        let (rig, c) = macPlayingOut()
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(c, status: status, actions: actions, backend: backend)
        let release = hold(actions)
        _ = s.handle(.right)
        // The play-out's queue ends while the Mac is still not serving: a status
        // from the play-out output showing idle, read through the gate by an
        // action that follows the play-out (here, the global Next).
        rig.reply = { _, _ in LicenceRig.status(playback: "idle", serving: false) }
        try c.perform(.next, expecting: nil, origin: nil,
                      musicApp: { _ in XCTFail("Next follows the play-out") },
                      source: { client in _ = try client.control.status() },
                      unaffected: { XCTFail("Next follows the play-out") })
        XCTAssertNil(c.playOutMode)
        XCTAssertEqual(c.effectiveOutput, .musicApp, "MusicTUI is the output again: volume would now be allowed")
        XCTAssertNil(c.refusal(for: .volume))
        release()
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s), 50, "the bar never moved")
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(status.current()?.text, volumeSentence, "the refusal the keypress was given")
        XCTAssertEqual(status.current()?.isError, true)
    }

    // MARK: - The play-out gate is in the preflight and the footer

    /// During a Mac play-out the selection names MusicTUI, so the matrix alone
    /// would allow volume: only the coordinator's play-out check refuses. A
    /// `refusal(for:)` that forgot that check fails here.
    func testSpeakerRowDuringAMacPlayOutOffersNoVolumeAndRefusesTheArrows() throws {
        let (_, c) = macPlayingOut()
        XCTAssertEqual(c.refusal(for: .volume), volumeSentence)
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(c, status: status, actions: actions, backend: backend)
        XCTAssertFalse(s.footerHint.contains("Volume"), s.footerHint)
        for key in [KeyPress.right, .left] {
            _ = s.handle(key)
            actions.waitUntilIdle()
            XCTAssertEqual(volume(s), 50)
            XCTAssertEqual(scripts(), [])
            XCTAssertEqual(status.current()?.text, volumeSentence)
        }
    }
}

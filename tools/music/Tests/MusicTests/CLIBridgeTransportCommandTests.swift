// tools/music/Tests/MusicTests/CLIBridgeTransportCommandTests.swift
//
// Slice 3 score, S6: `now` and the transport verbs executed through their real
// command paths (`run<Verb>(…, env:, musicApp:)`), in both modes, with counting
// fakes. The Bridge wire is scripted and records every request together with
// whether the output lock was held when it arrived; the store, lock and cache
// are temp; the external-call tripwire is armed throughout, so "0 AppleScript
// or REST calls" is a count. Nothing sleeps.
import ArgumentParser
import XCTest
@testable import music

final class CLIBridgeTransportCommandTests: XCTestCase {

    private typealias S = OutputLockTestSupport

    // MARK: harness

    /// Every request Bridge received, with the lock's state at that moment.
    private final class Seen {
        private let lock = NSLock()
        private var entries: [(op: String, locked: Bool)] = []
        func add(_ op: String, _ locked: Bool) { lock.lock(); entries.append((op, locked)); lock.unlock() }
        var ops: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.op) }
        func locked(_ op: String) -> [Bool] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.op == op }.map(\.locked)
        }
    }

    private struct Harness {
        let env: CLIBridgeEnv
        let io: CLIBridgeTestIO
        let wire: BridgeLibraryReadsWire
        let seen: Seen
        var lockPath: String { env.routing.outputLock!.path }
    }

    /// A CLI-surface env (production's surface) on a scripted wire whose
    /// transport also records whether the output lock was held per request.
    private func harness(_ mode: PlaybackMode, _ replies: [String: [String]] = [:]) -> Harness {
        let dir = NSTemporaryDirectory() + "music-test-s6-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PlaybackModeStore(path: dir + "/mode.json")
        precondition(store.set(mode))
        precondition(isUnderTemporaryDirectory(store.lockPath))
        let wire = BridgeLibraryReadsWire(replies)
        let seen = Seen()
        let lockPath = store.lockPath
        let routing = RoutingCoordinator(
            store: store, surface: .cli,
            makeSource: {
                SourceAppClient(path: "/nonexistent/s6-test.sock", transport: { path, line in
                    let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
                    seen.add(body["op"] as? String ?? "", !S.isFree(lockPath))
                    return try wire.transport(path, line)
                })
            },
            outputLock: OutputLock(path: lockPath))
        let io = CLIBridgeTestIO()
        let env = CLIBridgeEnv(routing: routing, modeStore: store, cache: ResultCache(directory: dir + "/cache"),
                               out: io.writeOut, err: io.writeErr, sleep: io.sleep)
        return Harness(env: env, io: io, wire: wire, seen: seen)
    }

    private func status(_ playback: String, title: String? = nil, artist: String? = nil,
                        queue: String? = nil) -> String {
        var fields = [#""playback":"\#(playback)""#, #""authorization":"authorized""#,
                      #""contract":\#(sourceContractVersion)"#]
        if let title { fields.append(#""title":"\#(title)""#) }
        if let artist { fields.append(#""artist":"\#(artist)""#) }
        if let queue { fields.append(#""queue":\#(queue)"#) }
        return #"{"ok":true,"status":{"# + fields.joined(separator: ",") + "}}"
    }

    private let ready = CLIBridgeReplies.status()
    private let ok = CLIBridgeReplies.ok

    private func json(_ line: String?) -> [String: Any]? {
        guard let line else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// Counts calls to a Music.app body and whether the lock was held then.
    private final class Body {
        var runs = 0
        var heldDuringRun: [Bool] = []
        let lockPath: String
        init(_ lockPath: String) { self.lockPath = lockPath }
        func run() { runs += 1; heldDuringRun.append(!S.isFree(lockPath)) }
    }

    // MARK: now, Bridge

    func testNowOnBridgePrintsTheBridgeNowText() throws {
        let playing = status("playing", title: "Teardrop", artist: "Massive Attack")
        let h = harness(.source, ["slice.status": [ready, playing]])
        let body = Body(h.lockPath)
        let (_, calls) = try withTripwire { try runNow(json: false, env: h.env, musicApp: { _ in body.run() }) }
        XCTAssertEqual(h.io.out, bridgeNowLines(SourceAppControl(path: "/nonexistent", transport: { _, _ in playing }).statusForTest()))
        XCTAssertEqual(h.io.out.first, "Teardrop \u{2014} Massive Attack [Bridge]")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.status"], "readiness, then the one read")
        XCTAssertEqual(h.seen.locked("slice.status"), [false, false], "a read takes no lock")
        XCTAssertEqual(body.runs, 0)
        XCTAssertEqual(calls, [])
    }

    func testNowOnBridgeAsJSONIsOneDocumentWithNoMusicAppKeys() throws {
        let h = harness(.source, ["slice.status": [ready, status("loading", queue: #"{"phase":"building","requested":40,"present":3}"#)]])
        let (_, calls) = try withTripwire { try runNow(json: true, env: h.env, musicApp: { _ in XCTFail("Music.app ran") }) }
        XCTAssertEqual(h.io.out.count, 1, "one JSON document")
        let doc = try XCTUnwrap(json(h.io.out.first))
        XCTAssertEqual(doc["output"] as? String, "bridge")
        XCTAssertEqual(doc["state"] as? String, "loading")
        XCTAssertEqual((doc["queue"] as? [String: Any])?["phase"] as? String, "building")
        for forbidden in ["album", "duration", "position", "speakers", "live", "track"] {
            XCTAssertNil(doc[forbidden], forbidden)
        }
        XCTAssertEqual(calls, [])
    }

    func testNowOnBridgeWithAnUnreadableStatusFailsInItsOwnWords() {
        for asJSON in [false, true] {
            let h = harness(.source, ["slice.status": [ready, #"{"ok":true,"status":{}}"#]])
            XCTAssertThrowsError(try runNow(json: asJSON, env: h.env, musicApp: { _ in XCTFail() })) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
            let message = SourceAppError.unreadable.message
            if asJSON {
                XCTAssertEqual(json(h.io.out.first)?["error"] as? String, message)
                XCTAssertEqual(json(h.io.out.first)?["ok"] as? Bool, false)
            } else {
                XCTAssertEqual(h.io.out, [message])
            }
        }
    }

    // MARK: now, Music.app

    func testNowOnMusicAppRunsTheShippedBodyOnceWithoutTheLock() throws {
        let h = harness(.musicApp)
        let body = Body(h.lockPath)
        var sawJSON: Bool?
        let (_, calls) = try withTripwire {
            try runNow(json: true, env: h.env, musicApp: { j in sawJSON = j; body.run() })
        }
        XCTAssertEqual(body.runs, 1)
        XCTAssertEqual(body.heldDuringRun, [false], "now is a read: no lock")
        XCTAssertEqual(sawJSON, true)
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, [])
    }

    /// The production Music.app body is the shipped read: its first external
    /// effect is one AppleScript call (stopped by the tripwire, reported by the
    /// shipped error path), and Bridge hears nothing.
    func testNowOnMusicAppProductionBodyIsTheShippedAppleScriptRead() {
        let h = harness(.musicApp)
        var calls: [ExternalCall] = []
        let printed = captureStdout {
            calls = try withTripwire { try runNow(json: true, env: h.env) }.calls
        }
        XCTAssertNil(printed.error)
        XCTAssertEqual(printed.output, #"{"error": "could not read now playing"}"# + "\n")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(h.wire.requestCount, 0)
    }

    // MARK: pause, Bridge (D5: confirmBridgeNotPlaying under the lock)

    private func pause(after replies: [String], pauseReply: String? = nil) -> (Harness, Error?) {
        let h = harness(.source, ["slice.status": [ready] + replies, "slice.pause": [pauseReply ?? ok]])
        var thrown: Error?
        do { _ = try withTripwire { try runPause(env: h.env, musicApp: { XCTFail("Music.app ran") }) } }
        catch { thrown = error }
        return (h, thrown)
    }

    func testPauseOnBridgeConfirmsPausedUnderTheLock() {
        let (h, error) = pause(after: [status("paused")])
        XCTAssertNil(error)
        XCTAssertEqual(h.io.out, ["Paused."])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.pause", "slice.status"])
        XCTAssertEqual(h.seen.locked("slice.pause"), [true])
        XCTAssertEqual(h.seen.locked("slice.status"), [false, true], "the confirming read is under the lock")
        XCTAssertTrue(S.isFree(h.lockPath))
    }

    func testPauseOnBridgeWithNothingPlayingSaysSoAndSucceeds() {
        for state in ["stopped", "idle"] {
            // An idle Bridge refuses slice.pause; that refusal is not a verdict.
            let (h, error) = pause(after: [status(state)],
                                   pauseReply: CLIBridgeReplies.refused("did not reach paused within 3s"))
            XCTAssertNil(error, state)
            XCTAssertEqual(h.io.out, ["Nothing playing on Bridge."], state)
            XCTAssertEqual(h.wire.sent("slice.pause").count, 1)
        }
    }

    func testPauseOnBridgeStillPlayingFails() {
        let (h, error) = pause(after: [status("playing", title: "Teardrop")])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Bridge is still playing."])
        XCTAssertEqual(h.wire.sent("slice.pause").count, 1)
    }

    /// A status that cannot be read fails in its own words, and a `warming`
    /// answer to the CONFIRMING read never re-sends the pause: only a warming
    /// refusal of the mutation itself is retried.
    func testPauseOnBridgeWithAnUnreadableStatusFailsAndIsNotResent() {
        for (reply, message) in [(#"{"ok":true,"status":{}}"#, SourceAppError.unreadable.message),
                                 (CLIBridgeReplies.warming(retryAfter: 1),
                                  SourceAppError.warming("Bridge is reading your library", retryAfter: 1).message)] {
            let (h, error) = pause(after: [reply])
            XCTAssertEqual(error as? ExitCode, .failure)
            XCTAssertEqual(h.io.out, [message])
            XCTAssertEqual(h.wire.sent("slice.pause").count, 1, "the pause was not re-sent")
            XCTAssertEqual(h.io.sleeps, [])
        }
    }

    /// The CLI's three-way pause outcome is `confirmBridgeNotPlaying`'s verdict,
    /// split: the same states count as "not playing".
    func testThePauseOutcomeAgreesWithConfirmBridgeNotPlaying() throws {
        for state in ["playing", "paused", "stopped", "idle", "loading", "something-new"] {
            let reply = status(state)
            let control = SourceAppControl(path: "/nonexistent", transport: { _, line in
                line.contains("slice.status") ? reply : CLIBridgeReplies.ok
            })
            XCTAssertEqual(try confirmBridgeNotPlaying(control),
                           BridgePauseOutcome(playback: state) != .stillPlaying, state)
        }
    }

    // MARK: skip and back, Bridge

    private func assertStep(_ op: String, run: (Bool, CLIBridgeEnv) throws -> Void) throws {
        for asJSON in [false, true] {
            let after = status("playing", title: "Unfinished Sympathy", artist: "Massive Attack")
            let h = harness(.source, ["slice.status": [ready, after], op: [ok]])
            let (_, calls) = try withTripwire { try run(asJSON, h.env) }
            XCTAssertEqual(h.seen.ops, ["slice.status", op, "slice.status"])
            XCTAssertEqual(h.seen.locked(op), [true], "\(op) is sent under the lock")
            XCTAssertEqual(h.seen.locked("slice.status"), [false, false], "the observation is outside it")
            let expected = SourceAppControl(path: "/nonexistent", transport: { _, _ in after }).statusForTest()
            if asJSON {
                XCTAssertEqual(h.io.out.count, 1)
                XCTAssertEqual(h.io.out.first, OutputFormat(mode: .json).render(bridgeNowJSON(expected)))
            } else {
                XCTAssertEqual(h.io.out, bridgeNowLines(expected))
            }
            XCTAssertEqual(calls, [])
            XCTAssertTrue(S.isFree(h.lockPath))
        }
    }

    func testSkipOnBridgeSendsNextThenShowsNow() throws {
        try assertStep("slice.next") { j, env in try runSkip(json: j, env: env, musicApp: { _ in XCTFail() }) }
    }

    func testBackOnBridgeSendsPreviousThenShowsNow() throws {
        try assertStep("slice.previous") { j, env in try runBack(json: j, env: env, musicApp: { _ in XCTFail() }) }
    }

    /// D5: the mutation's reply decides success. A status read that fails after
    /// it is reported, exit 0, and the mutation is never re-sent.
    func testSkipOnBridgeWhoseStatusReadFailsSucceedsAndIsNotResent() throws {
        for asJSON in [false, true] {
            let h = harness(.source, ["slice.status": [ready, CLIBridgeReplies.warming(retryAfter: 1)],
                                      "slice.next": [ok]])
            XCTAssertNoThrow(try runSkip(json: asJSON, env: h.env, musicApp: { _ in XCTFail() }))
            let message = SourceAppError.warming("Bridge is reading your library", retryAfter: 1).message
            XCTAssertEqual(h.wire.sent("slice.next").count, 1)
            XCTAssertEqual(h.io.sleeps, [])
            if asJSON {
                XCTAssertEqual(h.io.out.count, 1)
                let doc = try XCTUnwrap(json(h.io.out.first))
                XCTAssertEqual(doc["output"] as? String, "bridge")
                XCTAssertEqual(doc["status_error"] as? String, message)
                XCTAssertEqual(h.io.err, [])
            } else {
                XCTAssertEqual(h.io.out, [])
                XCTAssertEqual(h.io.err, ["Bridge accepted the request, but its status couldn't be read: \(message)"])
            }
        }
    }

    func testABridgeRefusalOfNextIsPrintedVerbatim() {
        for asJSON in [false, true] {
            let h = harness(.source, ["slice.status": [ready], "slice.next": [CLIBridgeReplies.refused("Nothing is queued")]])
            XCTAssertThrowsError(try runSkip(json: asJSON, env: h.env, musicApp: { _ in XCTFail() })) {
                XCTAssertEqual($0 as? ExitCode, .failure)
            }
            let message = SourceAppError.refused("Nothing is queued").message
            if asJSON {
                XCTAssertEqual(json(h.io.out.first)?["error"] as? String, message)
            } else {
                XCTAssertEqual(h.io.out, [message])
            }
            XCTAssertEqual(h.seen.ops, ["slice.status", "slice.next"], "no status read after a refused mutation")
        }
    }

    // MARK: stop, Bridge

    func testStopOnBridge() throws {
        let h = harness(.source, ["slice.status": [ready], "slice.stop": [ok]])
        let (_, calls) = try withTripwire { try runStop(env: h.env, musicApp: { XCTFail() }) }
        XCTAssertEqual(h.io.out, ["Stopped."])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.stop"])
        XCTAssertEqual(h.seen.locked("slice.stop"), [true])
        XCTAssertEqual(calls, [])
    }

    // MARK: seek, Bridge

    func testSeekOnBridgeAbsoluteAndRelative() throws {
        let cases: [(String, String, String, [String: Any])] = [
            ("1:30", "Seeked to 1:30 on Bridge.", "position", ["position": 90]),
            ("90", "Seeked to 1:30 on Bridge.", "position", ["position": 90]),
            ("+30", "Seeked +30s on Bridge.", "offset", ["offset": 30]),
            ("-15", "Seeked -15s on Bridge.", "offset", ["offset": -15]),
        ]
        for (arg, text, key, requested) in cases {
            for asJSON in [false, true] {
                let h = harness(.source, ["slice.status": [ready], "slice.seek": [ok]])
                let (_, calls) = try withTripwire {
                    try runSeek(position: arg, json: asJSON, env: h.env, musicApp: { _, _ in XCTFail() })
                }
                XCTAssertEqual(h.seen.ops, ["slice.status", "slice.seek"], arg)
                XCTAssertEqual(h.seen.locked("slice.seek"), [true])
                let sent = h.wire.sent("slice.seek").first
                XCTAssertEqual((sent?[key] as? NSNumber)?.intValue, requested[key] as? Int, arg)
                if asJSON {
                    XCTAssertEqual(h.io.out.count, 1)
                    let doc = try XCTUnwrap(json(h.io.out.first))
                    XCTAssertEqual(doc["ok"] as? Bool, true)
                    XCTAssertEqual(doc["output"] as? String, "bridge")
                    XCTAssertEqual((doc["requested"] as? [String: Any])?[key] as? Int, requested[key] as? Int)
                    XCTAssertNil(doc["position"], "no observed position")
                } else {
                    XCTAssertEqual(h.io.out, [text], arg)
                }
                XCTAssertEqual(calls, [])
            }
        }
        // The exact JSON document, for one case.
        let h = harness(.source, ["slice.status": [ready], "slice.seek": [ok]])
        try runSeek(position: "90", json: true, env: h.env, musicApp: { _, _ in XCTFail() })
        XCTAssertEqual(h.io.out, [#"{"ok":true,"output":"bridge","requested":{"position":90}}"#])
    }

    func testSeekOnBridgeWithABadPositionSendsNoSeek() {
        let h = harness(.source, ["slice.status": [ready]])
        XCTAssertThrowsError(try runSeek(position: "banana", json: false, env: h.env, musicApp: { _, _ in XCTFail() })) {
            XCTAssertEqual($0 as? ExitCode, .failure)
        }
        XCTAssertEqual(h.io.out, ["Position must be +N / -N, seconds, or m:ss (e.g. +30, 90, 1:30)."])
        XCTAssertEqual(h.wire.sent("slice.seek").count, 0)
    }

    // MARK: the five transport verbs, Music.app

    private func musicAppTransport() -> [(String, (CLIBridgeEnv, @escaping () -> Void) throws -> Void)] {
        [
            ("pause", { env, b in try runPause(env: env, musicApp: { b() }) }),
            ("skip", { env, b in try runSkip(json: false, env: env, musicApp: { _ in b() }) }),
            ("back", { env, b in try runBack(json: true, env: env, musicApp: { _ in b() }) }),
            ("stop", { env, b in try runStop(env: env, musicApp: { b() }) }),
            ("seek", { env, b in try runSeek(position: "+30", json: false, env: env, musicApp: { _, _ in b() }) }),
        ]
    }

    func testTransportOnMusicAppRunsTheShippedBodyOnceUnderTheLock() throws {
        for (name, run) in musicAppTransport() {
            let h = harness(.musicApp)
            let body = Body(h.lockPath)
            let (_, calls) = try withTripwire { try run(h.env) { body.run() } }
            XCTAssertEqual(body.runs, 1, name)
            XCTAssertEqual(body.heldDuringRun, [true], "\(name)'s Music.app body runs inside the lock")
            XCTAssertEqual(h.wire.requestCount, 0, name)
            XCTAssertEqual(calls, [], name)
            XCTAssertEqual(h.io.out, [], name)
            XCTAssertTrue(S.isFree(h.lockPath), name)
        }
    }

    /// The production Music.app bodies are the shipped ones: each one's first
    /// external effect is its shipped AppleScript, and Bridge hears nothing.
    func testTransportOnMusicAppProductionBodiesSendTheShippedAppleScript() {
        let expected: [(String, (CLIBridgeEnv) throws -> Void, String)] = [
            ("pause", { try runPause(env: $0) }, "pause"),
            ("skip", { try runSkip(json: false, env: $0) }, "next track"),
            ("back", { try runBack(json: false, env: $0) }, "previous track"),
            ("stop", { try runStop(env: $0) }, "stop"),
            ("seek", { try runSeek(position: "+30", json: false, env: $0) }, "set player position to (player position + 30)"),
        ]
        for (name, run, script) in expected {
            let h = harness(.musicApp)
            var calls: [ExternalCall] = []
            var thrown: Error?
            ExternalCallTripwire.shared.arm()
            do { try run(h.env) } catch { thrown = error }
            calls = ExternalCallTripwire.shared.disarm()
            XCTAssertTrue(thrown is ExternalCallBlocked, "\(name): \(String(describing: thrown))")
            XCTAssertEqual(calls.count, 1, name)
            guard case .appleScript(let text)? = calls.first else { XCTFail(name); continue }
            XCTAssertTrue(text.contains(script), "\(name) sent: \(text)")
            XCTAssertEqual(h.wire.requestCount, 0, name)
            XCTAssertEqual(h.io.out, [], name)
            XCTAssertTrue(S.isFree(h.lockPath), name)
        }
    }

    /// A bad seek position in Music.app mode is the shipped ValidationError,
    /// untouched by the dispatcher.
    func testSeekOnMusicAppKeepsTheShippedValidationError() {
        let h = harness(.musicApp)
        XCTAssertThrowsError(try withTripwire { try runSeek(position: "banana", json: false, env: h.env) }) {
            XCTAssertEqual(($0 as? ValidationError)?.message, seekPositionUsage,
                           "the Bridge branch's sentence is the shipped one")
        }
        XCTAssertEqual(h.io.out, [])
    }

    // MARK: shuffle, repeat, radio play, playlist temp

    private func refusedVerbs() -> [(String, MusicTUIAction, (CLIBridgeEnv, Bool, @escaping () -> Void) throws -> Void)] {
        [
            ("shuffle", .persistentShuffleMode,
             { env, j, b in try runShuffle(state: "on", json: j, env: env, musicApp: { _, _ in b() }) }),
            ("repeat", .persistentRepeatMode,
             { env, _, b in try runRepeat(mode: "all", env: env, musicApp: { _ in b() }) }),
            ("radio play", .radioStationPlay,
             { env, _, b in try runRadioPlay(query: ["BBC", "Radio", "6"], env: env, musicApp: { _ in b() }) }),
            ("playlist temp", .playlistTemp,
             { env, _, b in try runPlaylistTemp(items: ["Teardrop", "Massive Attack"], env: env, musicApp: { _ in b() }) }),
        ]
    }

    func testRefusedVerbsRefuseOnBridgeBeforeAnyRequest() throws {
        for (name, action, run) in refusedVerbs() {
            let h = harness(.source, ["slice.status": [ready]])
            var ran = 0
            let (_, calls) = try withTripwire { () throws -> Void in
                XCTAssertThrowsError(try run(h.env, false, { ran += 1 })) {
                    XCTAssertEqual($0 as? ExitCode, .failure, name)
                }
            }
            XCTAssertEqual(h.io.out, [cliBridgeNotServedReason(action)], name)
            XCTAssertEqual(ran, 0, name)
            XCTAssertEqual(h.wire.requestCount, 0, "\(name) sent a Bridge request")
            XCTAssertEqual(calls, [], name)
            XCTAssertTrue(S.isFree(h.lockPath), name)
        }
        // shuffle --json: one refusal document.
        let h = harness(.source)
        XCTAssertThrowsError(try runShuffle(state: nil, json: true, env: h.env, musicApp: { _, _ in XCTFail() }))
        XCTAssertEqual(h.io.out, [cliFailureText(cliBridgeNotServedReason(.persistentShuffleMode), json: true)])
    }

    func testRefusedVerbsTakeTheLockInMusicAppMode() throws {
        for (name, _, run) in refusedVerbs() {
            let h = harness(.musicApp)
            let body = Body(h.lockPath)
            let (_, calls) = try withTripwire { try run(h.env, false, { body.run() }) }
            XCTAssertEqual(body.runs, 1, name)
            XCTAssertEqual(body.heldDuringRun, [true], "\(name)'s Music.app body runs inside the lock")
            XCTAssertEqual(h.wire.requestCount, 0, name)
            XCTAssertEqual(calls, [], name)
            XCTAssertTrue(S.isFree(h.lockPath), name)
        }
    }

    /// The Music.app bodies carry their arguments through unchanged.
    func testRefusedVerbsPassTheirArgumentsToTheMusicAppBody() throws {
        let h = harness(.musicApp)
        var got: [String] = []
        try runShuffle(state: "off", json: true, env: h.env, musicApp: { s, j in got.append("\(s ?? "-") \(j)") })
        try runRepeat(mode: "one", env: h.env, musicApp: { got.append($0) })
        try runRadioPlay(query: ["a", "b"], env: h.env, musicApp: { got.append($0.joined(separator: "+")) })
        try runPlaylistTemp(items: ["t", "a"], env: h.env, musicApp: { got.append($0.joined(separator: "+")) })
        try runSeek(position: "1:00", json: true, env: h.env, musicApp: { p, j in got.append("\(p) \(j)") })
        XCTAssertEqual(got, ["off true", "one", "a+b", "t+a", "1:00 true"])
    }

    /// The production bodies that reach AppleScript first do so inside the
    /// dispatcher; `radio play` is not run here (its shipped body opens a URL).
    func testShuffleRepeatAndTempProductionBodiesSendTheShippedAppleScript() {
        let expected: [(String, (CLIBridgeEnv) throws -> Void, String)] = [
            ("shuffle", { try runShuffle(state: "on", json: false, env: $0) }, "set shuffle enabled to true"),
            ("repeat", { try runRepeat(mode: "all", env: $0) }, "set song repeat to all"),
            ("playlist temp", { try runPlaylistTemp(items: ["Teardrop", "Massive Attack"], env: $0) }, "make new playlist"),
        ]
        for (name, run, script) in expected {
            let h = harness(.musicApp)
            ExternalCallTripwire.shared.arm()
            var thrown: Error?
            do { try run(h.env) } catch { thrown = error }
            let calls = ExternalCallTripwire.shared.disarm()
            XCTAssertTrue(thrown is ExternalCallBlocked, "\(name): \(String(describing: thrown))")
            XCTAssertEqual(calls.count, 1, name)
            guard case .appleScript(let text)? = calls.first else { XCTFail(name); continue }
            XCTAssertTrue(text.contains(script), "\(name) sent: \(text)")
            XCTAssertEqual(h.wire.requestCount, 0)
        }
    }

    // MARK: structure

    func testTransportSourceNamesNoMusicAppOrRESTBackend() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands/CLIBridgeTransport.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["AppleScriptBackend", "runMusic", "osascript", "RESTAPIBackend", "AuthManager", "exclusively"] {
            XCTAssertFalse(text.contains(forbidden), "CLIBridgeTransport.swift names \(forbidden)")
        }
    }
}

private extension SourceAppControl {
    /// Parse one scripted status reply the way the command does.
    func statusForTest() -> SourceStatus { (try? status())! }
}

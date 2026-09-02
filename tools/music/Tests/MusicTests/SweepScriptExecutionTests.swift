import XCTest
@testable import music

/// §20.7: the WHOLE sweep script is verified by RUNNING it, not by reading it.
///
/// Four rounds of pins failed here, each drawing a boundary and leaving the
/// far side asserted rather than measured. Presence pins missed swapped branch
/// bodies. Ordering pins missed a dead `else` with the append hoisted out, and
/// missed the token sequence hoisted into an `if false` decoy. A harness over
/// the CAPTURE LOOP alone then missed three more: appending `keepName` to
/// `eligibleNames` after the loop, deleting `keepName` outright after the loop,
/// and deriving `keepName` wrongly in the preamble — each of which deletes the
/// container the user is listening to, with the whole suite green.
///
/// The user-facing invariant is "the active container is never deleted", and it
/// spans the preamble, the capture loop AND the delete phase. So this runs the
/// entire generated script against a synthetic library and asserts on both the
/// returned outcome and WHICH PLAYLISTS SURVIVE.
///
/// Fidelity limit, stated rather than glossed: six application operations are
/// replaced by handlers over a synthetic list — the player-state read, the
/// current-playlist read, the playlist collection, the per-item name access,
/// the per-name count and the per-name delete. Everything else, every branch
/// and every outcome, runs verbatim. All six substitutions are ASSERTED to
/// have applied, because a harness that silently fails to transform reports a
/// pass it never measured.
final class SweepScriptExecutionTests: XCTestCase {

    struct Outcome {
        let result: String
        let surviving: [String]
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run a generated sweep script against a synthetic library.
    func run(_ script0: String,
             library: [String],
             context: String?,
             state: String = "playing",
             mutate: ((String) -> String)? = nil,
             file: StaticString = #filePath, line: UInt = #line) -> Outcome? {
        var script = script0
        if let mutate {
            let before = script
            script = mutate(script)
            XCTAssertNotEqual(script, before,
                              "mutation did not apply — a self-check that mutates nothing proves nothing",
                              file: file, line: line)
        }

        // Replace every application operation with a handler over the synthetic
        // library. Substitutions are applied where present (the uncounted
        // variant has no count expression), and the POST-CONDITION below is the
        // real guard: if any application term survives, the harness is stale and
        // must fail rather than quietly measure something else.
        let subs: [(String, String)] = [
            ("player state as text", "my stateRead()"),
            ("name of current playlist", "my ctxRead()"),
            ("repeat with pp in (every user playlist)", "repeat with pp in libNames"),
            ("set nm to name of pp", "set nm to (pp as text)"),
            ("count of (every user playlist whose name is nm)", "(my countOf(nm as text))"),
            ("delete (every user playlist whose name is nm)", "my deleteAll(nm as text)"),
            ("count of (every user playlist whose name is keepName)", "(my countOf(keepName))"),
            ("delete (every user playlist whose name is keepName)", "my deleteAll(keepName)"),
        ]
        var applied = 0
        for (from, to) in subs where script.contains(from) {
            script = script.replacingOccurrences(of: from, with: to)
            applied += 1
        }
        XCTAssertGreaterThanOrEqual(applied, 5, "too few substitutions applied — harness is stale",
                                    file: file, line: line)
        for residue in ["every user playlist", "name of current playlist", "player state", "name of pp"] {
            XCTAssertFalse(script.contains(residue),
                           "application term survived substitution: \(residue)", file: file, line: line)
        }

        let libLiteral = "{" + library.map { "\"\(esc($0))\"" }.joined(separator: ", ") + "}"
        let harness = """
        global libNames, ctxValue, ctxThrows, stateValue
        on stateRead()
            global stateValue
            return stateValue
        end stateRead
        on ctxRead()
            global ctxValue, ctxThrows
            if ctxThrows then error "unreadable" number -1728
            return ctxValue
        end ctxRead
        on countOf(n)
            global libNames
            set c to 0
            repeat with x in libNames
                if (x as text) is n then set c to c + 1
            end repeat
            return c
        end countOf
        on deleteAll(n)
            global libNames
            set out to {}
            repeat with x in libNames
                if (x as text) is not n then set end of out to (x as text)
            end repeat
            set libNames to out
        end deleteAll
        set libNames to \(libLiteral)
        set ctxValue to "\(esc(context ?? ""))"
        set ctxThrows to \(context == nil ? "true" : "false")
        set stateValue to "\(esc(state))"
        on runScript()
            global libNames
        \(script)
        end runScript
        set outcome to my runScript()
        set AppleScript's text item delimiters to "|"
        return (outcome as text) & "##" & (libNames as text)
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", harness]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch {
            XCTFail("osascript failed to launch: \(error)", file: file, line: line); return nil
        }
        // Watchdog: this repo already pays for hung osascript elsewhere, so a
        // hang here must fail the test rather than hang CI indefinitely.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0 else {
            XCTFail("osascript exit \(p.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "")",
                    file: file, line: line)
            return nil
        }
        let raw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.components(separatedBy: "##")
        let survivors = (parts.count > 1 && !parts[1].isEmpty) ? parts[1].components(separatedBy: "|") : []
        return Outcome(result: parts.first ?? "", surviving: survivors)
    }

    // Production scripts, not reconstructions: a reconstruction drifts silently
    // when the production prefix set changes.
    private var cleanup: String { playlistCleanupScript() }
    private var staleSweep: String { albumStaleSweepScript() }

    private var playing: String { "\(albumPlaylistPrefix)NOW-PLAYING" }
    private var orphan: String { "\(albumPlaylistPrefix)ORPHAN-1" }
    private let unrelated = "Road Trip Mix"

    // MARK: - the invariant: the active container is never deleted

    func testCleanupNeverDeletesTheActiveContainer() {
        guard let r = run(cleanup, library: [playing, orphan, unrelated], context: playing) else { return }
        XCTAssertTrue(r.surviving.contains(playing), "the container being played must survive cleanup")
        XCTAssertTrue(r.surviving.contains(unrelated), "unrelated playlists must survive")
        XCTAssertFalse(r.surviving.contains(orphan), "the stale orphan must be collected")
        XCTAssertEqual(r.result, "1", "exactly one object measured as removed")
    }

    func testStaleSweepNeverDeletesTheActiveContainer() {
        guard let r = run(staleSweep, library: [playing, orphan, unrelated], context: playing) else { return }
        XCTAssertTrue(r.surviving.contains(playing),
                      "the automatic sweep must never delete the container it is about to play from")
        XCTAssertTrue(r.surviving.contains(unrelated))
        XCTAssertFalse(r.surviving.contains(orphan))
    }

    func testActiveContainerSurvivesWhenItIsTheOnlyMatch() {
        guard let r = run(cleanup, library: [playing, unrelated], context: playing) else { return }
        XCTAssertEqual(r.result, "spared", "a lone protected match reports spared")
        XCTAssertEqual(r.surviving.sorted(), [playing, unrelated].sorted(), "nothing deleted")
    }

    // MARK: - outcome classification, executed

    func testNothingExistedReportsNone() {
        guard let r = run(cleanup, library: [unrelated], context: nil, state: "stopped") else { return }
        XCTAssertEqual(r.result, "none")
        XCTAssertEqual(r.surviving, [unrelated])
    }

    func testRemovedReportsTheMeasuredCount() {
        guard let r = run(cleanup, library: [orphan, orphan, unrelated], context: nil, state: "stopped") else { return }
        XCTAssertEqual(r.result, "2", "both objects sharing the captured name are measured as removed")
        XCTAssertEqual(r.surviving, [unrelated])
    }

    func testUnreadableContextWhileActiveDefersAndDeletesNothing() {
        guard let r = run(cleanup, library: [playing, orphan], context: nil, state: "playing") else { return }
        XCTAssertEqual(r.result, "deferred")
        XCTAssertEqual(r.surviving.sorted(), [playing, orphan].sorted(), "a deferral deletes nothing")
    }

    func testUnrecognisedStateDefersAndDeletesNothing() {
        guard let r = run(cleanup, library: [orphan], context: nil, state: "teleporting") else { return }
        XCTAssertEqual(r.result, "deferred")
        XCTAssertEqual(r.surviving, [orphan])
    }

    func testPausedContainerIsSpared() {
        guard let r = run(cleanup, library: [playing, orphan], context: playing, state: "paused") else { return }
        XCTAssertTrue(r.surviving.contains(playing), "a PAUSED container is spared, not collected")
        XCTAssertFalse(r.surviving.contains(orphan))
    }

    // MARK: - self-checks: the shapes that survived every earlier pin

    /// Appending keepName to the snapshot AFTER the capture loop.
    func testHarnessCatchesPostLoopCaptureOfKeepName() {
        guard let r = run(cleanup, library: [playing, orphan], context: playing, mutate: {
            $0.replacingOccurrences(
                of: "if (count of eligibleNames) is 0 then",
                with: """
                if keepName is not "" then
                    if (eligibleNames does not contain keepName) then set end of eligibleNames to keepName
                end if
                if (count of eligibleNames) is 0 then
                """)
        }) else { return }
        XCTAssertFalse(r.surviving.contains(playing),
                       "harness self-check: this mutation MUST delete the active container")
    }

    /// Deleting keepName outright after the capture loop.
    func testHarnessCatchesPostLoopDeleteOfKeepName() {
        guard let r = run(cleanup, library: [playing, orphan], context: playing, mutate: {
            $0.replacingOccurrences(
                of: "if (count of eligibleNames) is 0 then",
                with: """
                try
                    delete (every user playlist whose name is keepName)
                end try
                if (count of eligibleNames) is 0 then
                """)
        }) else { return }
        XCTAssertFalse(r.surviving.contains(playing),
                       "harness self-check: this mutation MUST delete the active container")
    }

    /// Deriving keepName wrongly in the PREAMBLE, outside the capture loop.
    func testHarnessCatchesWrongKeepNameDerivation() {
        guard let r = run(cleanup, library: [playing, orphan], context: playing, mutate: {
            $0.replacingOccurrences(of: "set keepName to name of current playlist",
                                    with: "set keepName to (name of current playlist) & \" \"")
        }) else { return }
        XCTAssertFalse(r.surviving.contains(playing),
                       "harness self-check: a wrongly derived keepName MUST delete the active container")
    }
}

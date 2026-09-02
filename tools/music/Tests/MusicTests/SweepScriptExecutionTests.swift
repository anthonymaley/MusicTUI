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
    /// How the synthetic delete behaves. `.all` models the optimistic case the
    /// generator's doc explicitly refuses to ASSUME; the others make the
    /// measured-after branches (`partial:`, race-to-zero) reachable.
    enum DeleteMode: String { case all, none, firstOnly }

    func run(_ script0: String,
             library: [String],
             context: String?,
             state: String = "playing",
             deleteMode: DeleteMode = .all,
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
            // The stale sweep's deferReturn is a BARE `return`, so assigning its
            // result errors (-2753) and its two defer guards were structurally
            // unmeasurable. Giving the same immediate return a value preserves
            // control flow exactly and makes the deferral observable.
            ("if not recognised then return\n", "if not recognised then return \"deferred\"\n"),
            ("if not contextReadable then return\n", "if not contextReadable then return \"deferred\"\n"),
        ]
        var applied = 0
        for (from, to) in subs where script.contains(from) {
            script = script.replacingOccurrences(of: from, with: to)
            applied += 1
        }
        XCTAssertGreaterThanOrEqual(applied, 5, "too few substitutions applied — harness is stale",
                                    file: file, line: line)

        // WHITELIST, not blacklist. Denying a list of known spellings misses a
        // one-word drift: `user playlists whose name is ...` (plural, no
        // `every`) slipped every previous check and reached the real library
        // with the suite green. Assert instead that NO application vocabulary
        // survives, with word boundaries so `playerStateText` is not a match.
        for pattern in ["\\btell\\b", "\\bapplication\\b", "\\bplaylists?\\b",
                        "\\btracks?\\b", "\\bplayer\\b"] {
            if let r = script.range(of: pattern, options: .regularExpression) {
                XCTFail("application vocabulary survived substitution: \(script[r])",
                        file: file, line: line)
                return nil
            }
        }

        let libLiteral = "{" + library.map { "\"\(esc($0))\"" }.joined(separator: ", ") + "}"
        let harness = """
        global libNames, ctxValue, ctxThrows, stateValue, deleteMode
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
            global libNames, deleteMode
            if deleteMode is "none" then return
            set out to {}
            set skipped to false
            repeat with x in libNames
                if (x as text) is n then
                    if deleteMode is "firstOnly" and skipped then
                        set end of out to (x as text)
                    else
                        set skipped to true
                    end if
                else
                    set end of out to (x as text)
                end if
            end repeat
            set libNames to out
        end deleteAll
        set libNames to \(libLiteral)
        set ctxValue to "\(esc(context ?? ""))"
        set ctxThrows to \(context == nil ? "true" : "false")
        set stateValue to "\(esc(state))"
        set deleteMode to "\(deleteMode.rawValue)"
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
        // Drain stderr on a background queue: draining both to EOF in sequence
        // deadlocks if the child ever fills the stderr buffer while the parent
        // blocks on stdout.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        _ = errDone.wait(timeout: .now() + 5)
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

    // MARK: - §20.8: the uncounted variant's deferral paths, now executable

    /// The stale sweep runs UNCOMMANDED at the start of every bounded album
    /// play, so its defer guards matter more than cleanup's. They were
    /// structurally unmeasurable until the bare `return` was given a value.
    func testStaleSweepDefersOnUnrecognisedStateAndDeletesNothing() {
        guard let r = run(staleSweep, library: [playing, orphan], context: nil, state: "teleporting") else { return }
        XCTAssertEqual(r.result, "deferred")
        XCTAssertEqual(r.surviving.sorted(), [playing, orphan].sorted(), "a deferral deletes nothing")
    }

    func testStaleSweepDefersOnUnreadableContextAndDeletesNothing() {
        guard let r = run(staleSweep, library: [playing, orphan], context: nil, state: "playing") else { return }
        XCTAssertEqual(r.result, "deferred")
        XCTAssertEqual(r.surviving.sorted(), [playing, orphan].sorted(), "a deferral deletes nothing")
    }

    // MARK: - §20.8: prefix narrowness, measured rather than asserted

    /// Cleanup collects both owned prefixes; the automatic stale sweep collects
    /// only its own and must leave a `__temp__` container alone.
    func testTempPrefixIsCollectedByCleanupButNotByTheStaleSweep() {
        let temp = "__temp__ORPHAN"
        guard let c = run(cleanup, library: [temp, orphan, unrelated], context: nil, state: "stopped") else { return }
        XCTAssertFalse(c.surviving.contains(temp), "cleanup collects __temp__")
        XCTAssertFalse(c.surviving.contains(orphan))
        XCTAssertTrue(c.surviving.contains(unrelated))

        guard let sweep = run(staleSweep, library: [temp, orphan, unrelated], context: nil, state: "stopped") else { return }
        XCTAssertTrue(sweep.surviving.contains(temp), "the stale sweep must NOT touch __temp__")
        XCTAssertFalse(sweep.surviving.contains(orphan))
        XCTAssertTrue(sweep.surviving.contains(unrelated))
    }

    // MARK: - §20.8: the measure-after branches, reachable at last

    /// Every delete fails: nothing removed, everything still there. The
    /// outcome must be an explicit partial failure carrying both counts, not
    /// a success and not a claim about playback.
    func testTotalDeleteFailureReportsPartialWithZeroRemoved() {
        guard let r = run(cleanup, library: [orphan, unrelated], context: nil,
                          state: "stopped", deleteMode: .none) else { return }
        XCTAssertEqual(r.result, "partial:0:1")
        XCTAssertTrue(r.surviving.contains(orphan), "nothing was actually removed")
        XCTAssertEqual(parsePlaylistCleanupResult(r.result),
                       .partiallyRemoved(removed: 0, remaining: 1))
        let msg = playlistCleanupMessage(parsePlaylistCleanupResult(r.result))
        XCTAssertTrue(msg.contains("0") && msg.contains("1"), "both measured counts are stated")
        XCTAssertFalse(msg.lowercased().contains("playing"), "no playback claim")
    }

    /// One of two objects sharing a captured name is removed. This is the
    /// branch §20.6 exists for: a pre-delete count would have reported 2.
    func testPartialDeletionReportsMeasuredRemovedAndRemaining() {
        guard let r = run(cleanup, library: [orphan, orphan, unrelated], context: nil,
                          state: "stopped", deleteMode: .firstOnly) else { return }
        XCTAssertEqual(r.result, "partial:1:1",
                       "measured: one object gone, one still present — never the pre-delete count of 2")
        XCTAssertEqual(r.surviving.sorted(), [orphan, unrelated].sorted())
    }
}

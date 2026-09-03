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

    /// `.alwaysZero` models the RACE TO ZERO: the snapshot is non-empty but the
    /// objects are already gone by the time the counts are taken, because a
    /// watcher won the race. That arm reports "none" when nothing was
    /// protected, and "spared" when a container genuinely was (§20.9).
    /// `.fails` models a count read that THROWS, which must report "unknown"
    /// rather than claiming nothing existed.
    enum CountMode: String { case real, alwaysZero, fails }

    func run(_ script0: String,
             library: [String],
             context: String?,
             state: String = "playing",
             deleteMode: DeleteMode = .all,
             countMode: CountMode = .real,
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
        // The ESSENTIAL substitution is the collection source: without it the
        // script would read the real library. Everything else varies by script
        // (the legacy queue sweep reads no player state at all, so an arbitrary
        // "at least N applied" floor was wrong rather than protective). The
        // real staleness guard is the post-condition below.
        XCTAssertTrue(script.contains("repeat with pp in libNames"),
                      "collection substitution did not apply — the script would read the real library",
                      file: file, line: line)
        XCTAssertGreaterThan(applied, 0, "no substitutions applied — harness is stale",
                             file: file, line: line)

        // A REAL whitelist. The previous check denied five known spellings,
        // which is the same KIND of check the round before it failed on: a
        // denylist is only as complete as the drift you imagined. `do shell
        // script`, raw chevron codes (`«class cUsP»`), `every song` and
        // `sound volume` all slipped it, and one of them executed a side
        // effect. So: strip string literals, tokenise, and require EVERY
        // identifier to be one the substituted script is known to contain.
        // Unknown token means fail — a new application term cannot be
        // unlisted, because nothing is listed as bad in the first place.
        let permitted: Set<String> = [
            "afterCount", "and", "as", "beforeCount", "contain", "contextReadable",
            "count", "countFailed", "countOf", "ctxRead", "deleteAll", "does",
            "eligibleNames", "error", "on",
            "else", "end", "false", "if", "in", "is", "keepName", "libNames",
            "my", "nm", "not", "of", "or", "playerStateText", "pp",
            "protectedMatch", "protectedNames", "recognised", "removedCount", "repeat", "return",
            "set", "starts", "stateRead", "text", "then", "to", "true", "try", "with",
        ]
        // `"[^"]*"` pairs quotes POSITIONALLY, so a single escaped quote inside
        // a literal inverts which regions are treated as code — verified to let
        // injected code past the whitelist entirely. This form consumes escape
        // pairs, and the post-condition below is the real guard: if any quote
        // survives, stripping desynchronised and the token scan is meaningless.
        let literalsStripped = script.replacingOccurrences(
            of: "\"(\\\\.|[^\"\\\\])*\"", with: " ", options: .regularExpression)
        guard !literalsStripped.contains("\"") else {
            XCTFail("literal stripping desynchronised — token scan cannot be trusted",
                    file: file, line: line)
            return nil
        }
        var seen = Set<String>()
        literalsStripped.enumerateSubstrings(in: literalsStripped.startIndex...,
                                             options: [.byWords]) { w, _, _, _ in
            if let w, w.first?.isLetter == true || w.first == "_" { seen.insert(w) }
        }
        let unexpected = seen.subtracting(permitted).sorted()
        guard unexpected.isEmpty else {
            XCTFail("""
                unexpected identifier(s) survived substitution: \(unexpected)
                Either an application term reached the harness, or the generator \
                gained a legitimate new token — in which case add it to `permitted` \
                deliberately, after checking it is not an application term.
                """, file: file, line: line)
            return nil
        }

        // The Discover sweep returns nothing at all — it is fire-and-forget at
        // TUI launch and exit — so assigning its result would error (-2753).
        // Giving it a terminal value changes no control flow: there is no
        // earlier `return` to preempt.
        if !script.contains("return ") {
            script += "\nreturn \"swept\""
        }

        let libLiteral = "{" + library.map { "\"\(esc($0))\"" }.joined(separator: ", ") + "}"
        let harness = """
        global libNames, ctxValue, ctxThrows, stateValue, deleteMode, countMode
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
            global libNames, countMode
            if countMode is "alwaysZero" then return 0
            if countMode is "fails" then error "count unavailable" number -1728
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
        set countMode to "\(countMode.rawValue)"
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
        // Two distinct hazards, both avoided. Read BEFORE waiting, or a child
        // whose output exceeds the pipe buffer blocks on write while we block
        // on exit (the rule `AppleScriptBackend.run` documents). AND drain
        // stderr concurrently rather than after stdout, or a child that fills
        // the stderr buffer blocks while we are still draining stdout —
        // a case sequential draining does not cover.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // Unconditional: the child has exited, so stderr is at EOF and the
        // drain terminates. A timeout here would let the main thread read
        // `errData` while the background write was still in flight.
        errDone.wait()
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
                of: "set beforeCount to 0",
                with: """
                if keepName is not "" then
                    if (eligibleNames does not contain keepName) then set end of eligibleNames to keepName
                end if
                set beforeCount to 0
                """)
        }) else { return }
        XCTAssertFalse(r.surviving.contains(playing),
                       "harness self-check: this mutation MUST delete the active container")
    }

    /// Deleting keepName outright after the capture loop.
    func testHarnessCatchesPostLoopDeleteOfKeepName() {
        guard let r = run(cleanup, library: [playing, orphan], context: playing, mutate: {
            $0.replacingOccurrences(
                of: "set beforeCount to 0",
                with: """
                try
                    delete (every user playlist whose name is keepName)
                end try
                set beforeCount to 0
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

    /// RACE TO ZERO, executed at last. The snapshot is non-empty but the
    /// objects are already gone when the counts are taken — a watcher won the
    /// race. Nothing was removed BY THIS INVOCATION, so the honest report is
    /// "none". Reporting "spared" here would claim playback that is not
    /// happening, which is the §20.3 misreport this series began with.
    func testRaceToZeroReportsNoneWhenNothingWasProtected() {
        // deleteMode .all so the synthetic library is CONSISTENT with the
        // modelled race: the objects really are gone when the counts are taken.
        guard let r = run(cleanup, library: [orphan, unrelated], context: nil,
                          state: "stopped", deleteMode: .all, countMode: .alwaysZero) else { return }
        XCTAssertEqual(r.result, "none", "nothing protected, nothing measured removed")
        XCTAssertNotEqual(r.result, "spared", "never invent a spare that did not happen")
    }

    /// §20.9: the same race, but a container IS playing and WAS spared.
    /// Reporting "none" here printed "No temp playlists to clean up." while an
    /// `__album__` container was audibly playing. The race rule is right that
    /// a spare must not be invented; it was wrong to suppress a real one.
    func testRaceToZeroStillReportsSparedWhenAContainerWasProtected() {
        guard let r = run(cleanup, library: [playing, orphan, unrelated], context: playing,
                          state: "playing", deleteMode: .all, countMode: .alwaysZero) else { return }
        XCTAssertEqual(r.result, "spared",
                       "a container was playing and spared — saying 'none' denies it exists")
        XCTAssertNotEqual(playlistCleanupMessage(parsePlaylistCleanupResult(r.result)),
                          "No temp playlists to clean up.")
        XCTAssertTrue(r.surviving.contains(playing), "and it is still there")
    }

    /// §20.9: the counts are accumulated inside `try`. A library-side read
    /// failure on every name previously yielded 0 and 0 and was reported as
    /// "none" — claiming nothing existed on the strength of a read that never
    /// happened.
    func testCountFailureReportsUnknownNotNothing() {
        guard let r = run(cleanup, library: [orphan, unrelated], context: nil,
                          state: "stopped", deleteMode: .none, countMode: .fails) else { return }
        XCTAssertEqual(r.result, "unknown")
        XCTAssertEqual(parsePlaylistCleanupResult(r.result), .unreadable)
        let msg = playlistCleanupMessage(.unreadable)
        XCTAssertTrue(msg.contains("unknown"), "the user is told the count is unknown")
        XCTAssertNotEqual(msg, "No temp playlists to clean up.")
        XCTAssertTrue(r.surviving.contains(orphan), "and nothing was actually removed")
    }

    /// §20.10: an unmeasured count OUTRANKS a spare it already knows about.
    ///
    /// Found by the independent reviewer, and reproduced before fixing: with
    /// the guard moved below the zero-removal branch the whole suite stayed
    /// green, because no test combined a protected container WITH a failing
    /// count. `testCountFailureReportsUnknownNotNothing` has nothing
    /// protected; `testRaceToZeroStillReportsSparedWhenAContainerWasProtected`
    /// never fails a count.
    ///
    /// Note what is deliberately NOT asserted: that the orphan survived. The
    /// delete pass runs BETWEEN the two failed counts, so what happened to the
    /// other captured names is precisely the thing that is unknown — and
    /// "spared" would have claimed "Nothing was deleted", which is exactly the
    /// unjustified claim this precedence exists to avoid.
    func testCountFailureOutranksAKnownSpare() {
        guard let r = run(cleanup, library: [playing, orphan, unrelated], context: playing,
                          state: "playing", deleteMode: .all, countMode: .fails) else { return }
        XCTAssertEqual(r.result, "unknown",
                       "an unmeasured removal count outranks a spare it already knows about")
        XCTAssertNotEqual(r.result, "spared",
                          "spared asserts 'Nothing was deleted', which the failed counts cannot support")
        XCTAssertTrue(r.surviving.contains(playing),
                      "the protected container is still spared in fact, whatever is reported")
        XCTAssertTrue(r.surviving.contains(unrelated), "unrelated playlists are never touched")
    }

    // MARK: - §20.11: the Discover sweep, the last carrier of the §20 defect

    private var discover: String { discoverSweepScript() }
    /// The queue sweep's script is inline in `sweepQueuePlaylists`, so the
    /// harness needs the same text. Pinned identical by a test below.
    private var queueSweepScriptForTest: String { legacyQueueSweepScript() }
    private var discoverA: String { "\(discoverPlaylistPrefix)ONE" }
    private var discoverB: String { "\(discoverPlaylistPrefix)TWO" }

    /// The defect this closes: `delete pp` while enumerating the collection it
    /// mutated collected roughly HALF the matches per run (measured live:
    /// four containers, one run, two removed). All four must go in ONE pass.
    func testDiscoverSweepCollectsEveryMatchInOnePass() {
        let four = (1...4).map { "\(discoverPlaylistPrefix)STALE-\($0)" }
        guard let r = run(discover, library: four + [unrelated], context: nil,
                          state: "stopped") else { return }
        XCTAssertEqual(r.surviving, [unrelated],
                       "one pass must collect all four, not roughly half")
    }

    /// The sparing rule is preserved: active playback keeps its container.
    func testDiscoverSweepSparesTheActiveContainer() {
        guard let r = run(discover, library: [discoverA, discoverB, unrelated],
                          context: discoverA, state: "playing") else { return }
        XCTAssertTrue(r.surviving.contains(discoverA), "the playing container is spared")
        XCTAssertFalse(r.surviving.contains(discoverB), "the stale one is collected")
        XCTAssertTrue(r.surviving.contains(unrelated))
    }

    /// The DELIBERATE difference from the album cleanup: a PAUSED Discover
    /// container IS collected, because `current playlist` outlives a pause and
    /// sparing on it leaked one row per paused play.
    func testDiscoverSweepCollectsAPausedContainerUnlikeAlbumCleanup() {
        guard let r = run(discover, library: [discoverA, unrelated],
                          context: discoverA, state: "paused") else { return }
        XCTAssertFalse(r.surviving.contains(discoverA),
                       "paused releases the container in the Discover lifecycle")

        // Same inputs through the album cleanup, which spares paused. The two
        // rules are genuinely different and both are now executed.
        guard let a = run(cleanup, library: [playing, unrelated],
                          context: playing, state: "paused") else { return }
        XCTAssertTrue(a.surviving.contains(playing),
                      "the album cleanup spares a paused container")
    }

    /// It sweeps its own prefix only — never album containers, never user rows.
    func testDiscoverSweepTouchesOnlyItsOwnPrefix() {
        guard let r = run(discover, library: [discoverA, orphan, "__temp__X", unrelated],
                          context: nil, state: "stopped") else { return }
        XCTAssertFalse(r.surviving.contains(discoverA))
        XCTAssertTrue(r.surviving.contains(orphan), "album containers are not its business")
        XCTAssertTrue(r.surviving.contains("__temp__X"), "nor are manual temp containers")
        XCTAssertTrue(r.surviving.contains(unrelated))
    }

    /// §20.12: an ACTIVE state whose context cannot be read must DELETE NOTHING.
    ///
    /// The reviewer supplied this case and it failed before the fix: state
    /// `playing`, unreadable context, and BOTH Discover containers were
    /// deleted — including the one being listened to. The state read falls back
    /// to `playing` and so fails toward sparing, but the identity to spare WITH
    /// was read in a bare `try`; when it threw, `keepName` stayed empty and
    /// every container looked stale. §20.11's commit claimed the active
    /// container invariant while the harness could demonstrate its negation.
    func testDiscoverSweepDefersWhenActiveButContextUnreadable() {
        guard let r = run(discover, library: [discoverA, discoverB, unrelated],
                          context: nil, state: "playing") else { return }
        XCTAssertTrue(r.surviving.contains(discoverA),
                      "an unreadable context while active must spare, not sweep")
        XCTAssertTrue(r.surviving.contains(discoverB))
        XCTAssertEqual(r.surviving.count, 3, "nothing at all is deleted")
    }

    /// The deliberate paused rule is NOT affected by that deferral: paused is
    /// sweepable, so it never needs a readable context and still collects.
    func testDiscoverSweepStillCollectsWhenPausedWithUnreadableContext() {
        guard let r = run(discover, library: [discoverA, unrelated],
                          context: nil, state: "paused") else { return }
        XCTAssertFalse(r.surviving.contains(discoverA),
                       "paused releases the container regardless of context readability")
    }

    /// §20.12: the legacy `__queue__` sweep was the OTHER surviving carrier of
    /// the §20 defect — §20.11 called Discover "the last carrier" and was wrong.
    /// No current source path creates these, but a library holding several
    /// legacy orphans collected roughly half of them per launch.
    func testQueueSweepCollectsEveryLegacyOrphanInOnePass() {
        let four = (1...4).map { "__queue__ LEGACY-\($0)" }
        guard let r = run(queueSweepScriptForTest, library: four + [unrelated],
                          context: nil, state: "stopped") else { return }
        XCTAssertEqual(r.surviving, [unrelated],
                       "all four legacy orphans go in one pass, not roughly half")
    }
    // MARK: - Protected names (Discover lifecycle design §6.3)

    /// The exit sweep carries the names of this session's unconfirmed
    /// transactions as protected. A protected name survives even in a state
    /// that would otherwise release it, with no current playlist at all.
    func testProtectedNameSurvivesWhenStoppedWithNoContext() {
        guard let r = run(discoverSweepScript(protectedNames: [discoverA]),
                          library: [discoverA, discoverB, unrelated],
                          context: nil, state: "stopped") else { return }
        XCTAssertTrue(r.surviving.contains(discoverA), "protected survives")
        XCTAssertFalse(r.surviving.contains(discoverB), "an unprotected sibling is still collected")
        XCTAssertTrue(r.surviving.contains(unrelated))
    }

    /// Paused releases the current playlist in this lifecycle (the deliberate
    /// rule), but protection is orthogonal to that rule: a protected name
    /// survives while its unprotected sibling with the same prefix goes, in
    /// the same run.
    func testProtectedNameSurvivesWhenPausedWhileSiblingIsCollected() {
        guard let r = run(discoverSweepScript(protectedNames: [discoverA]),
                          library: [discoverA, discoverB, unrelated],
                          context: unrelated, state: "paused") else { return }
        XCTAssertTrue(r.surviving.contains(discoverA))
        XCTAssertFalse(r.surviving.contains(discoverB))
        XCTAssertEqual(r.surviving.count, 2)
    }

    /// Names carry user-controlled titles. A quote and a backslash must round
    /// trip through the preamble literal and still match the library entry.
    func testProtectedNameWithQuoteAndBackslashSurvives() {
        let awkward = "\(discoverPlaylistPrefix)He said \"hi\" \\ twice"
        guard let r = run(discoverSweepScript(protectedNames: [awkward]),
                          library: [awkward, discoverB, unrelated],
                          context: nil, state: "stopped") else { return }
        XCTAssertTrue(r.surviving.contains(awkward), "escaped name must still match: \(r.surviving)")
        XCTAssertFalse(r.surviving.contains(discoverB))
    }

    /// The clause is load-bearing: strip it from the emitted text and the
    /// protected name is deleted. A pin that cannot fail proves nothing.
    func testHarnessCatchesRemovalOfTheProtectedClause() {
        guard let r = run(discoverSweepScript(protectedNames: [discoverA]),
                          library: [discoverA, discoverB, unrelated],
                          context: nil, state: "stopped",
                          mutate: { $0.replacingOccurrences(of: " and (protectedNames does not contain nm)", with: "") })
        else { return }
        XCTAssertFalse(r.surviving.contains(discoverA),
                       "with the clause removed the protected name must be deleted, or the clause was never what protected it")
    }

    /// The empty list is TODAY'S script through the harness: same outcome,
    /// same survivors, for the case the existing tests already pin.
    func testEmptyProtectedListBehavesExactlyAsBefore() {
        guard let r = run(discoverSweepScript(protectedNames: []),
                          library: [discoverA, discoverB, unrelated],
                          context: discoverA, state: "playing") else { return }
        XCTAssertEqual(Set(r.surviving), [discoverA, unrelated])
    }
}

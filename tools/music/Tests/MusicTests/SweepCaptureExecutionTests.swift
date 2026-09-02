import XCTest
@testable import music

/// §20.7: the capture decision is verified by RUNNING it, not by reading it.
///
/// Three rounds of text pins failed here. Presence pins missed a swapped pair
/// of branch bodies; ordering pins missed a dead `else` branch with the append
/// hoisted below `end if`, and missed the whole token sequence being hoisted
/// into an `if false then ... end if` decoy so `range(of:)` anchored on code
/// that never runs. A text pin cannot see conditionality or reachability —
/// which is the same reason four whole-branch reviews read the original §20
/// mutate-while-enumerating defect and did not see it.
///
/// So this executes the generator's own capture loop under `osascript` over a
/// SYNTHETIC name list and asserts on the resulting `eligibleNames`.
///
/// Fidelity limit, stated rather than glossed: two substitutions are made, the
/// collection source (`every user playlist` -> a literal list) and the name
/// access (`name of pp` -> `pp`), because the alternative is mutating the
/// user's real library. Every branch of the capture decision itself runs
/// verbatim. Both substitutions are ASSERTED to have applied, because a
/// harness that silently fails to transform reports a pass it never measured.
final class SweepCaptureExecutionTests: XCTestCase {

    private struct CaptureOutcome {
        let eligible: [String]
        let protectedMatch: Bool?
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Extract the capture region from the generated script and run it.
    private func runCapture(counted: Bool,
                            names: [String],
                            keepName: String,
                            prefixes: [String]? = nil,
                            mutate: ((String) -> String)? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> CaptureOutcome? {
        // Default to each variant's PRODUCTION prefix set: cleanup sweeps both
        // owned prefixes, the automatic stale sweep only its own.
        let px = prefixes ?? (counted ? ["__temp__", "__album__ "] : ["__album__ "])
        var script = albumSweepGuardedScript(prefixes: px,
                                             deferReturn: "return \"deferred\"",
                                             countDeleted: counted)
        if let mutate {
            let before = script
            script = mutate(script)
            XCTAssertNotEqual(script, before,
                              "mutation did not apply — a self-check that mutates nothing proves nothing",
                              file: file, line: line)
        }

        guard let start = script.range(of: "set eligibleNames to {}")?.lowerBound,
              let end = script.range(of: "end repeat", range: start..<script.endIndex)?.upperBound else {
            XCTFail("could not locate the capture region", file: file, line: line); return nil
        }
        var region = String(script[start..<end])

        let listLiteral = "{" + names.map { "\"\(esc($0))\"" }.joined(separator: ", ") + "}"
        let beforeCollection = region
        region = region.replacingOccurrences(of: "repeat with pp in (every user playlist)",
                                             with: "repeat with pp in \(listLiteral)")
        XCTAssertNotEqual(region, beforeCollection,
                          "collection substitution did not apply — result would be meaningless",
                          file: file, line: line)
        let beforeName = region
        region = region.replacingOccurrences(of: "set nm to name of pp", with: "set nm to (pp as text)")
        XCTAssertNotEqual(region, beforeName,
                          "name substitution did not apply — result would be meaningless",
                          file: file, line: line)

        let tail = counted
            ? "return (eligibleNames as text) & \"#\" & (protectedMatch as text)"
            : "return (eligibleNames as text)"
        let harness = """
        set AppleScript's text item delimiters to "|"
        set keepName to "\(esc(keepName))"
        \(region)
        \(tail)
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", harness]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { XCTFail("osascript failed to launch: \(error)", file: file, line: line); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            XCTFail("osascript exit \(p.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "")",
                    file: file, line: line)
            return nil
        }
        let raw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.components(separatedBy: "#")
        let listPart = parts.first ?? ""
        let eligible = listPart.isEmpty ? [] : listPart.components(separatedBy: "|")
        let prot: Bool? = counted ? (parts.count > 1 ? parts[1] == "true" : nil) : nil
        return CaptureOutcome(eligible: eligible, protectedMatch: prot)
    }

    private let playing = "__album__ NOW-PLAYING"
    private let orphan1 = "__album__ ORPHAN-1"
    private let orphan2 = "__temp__ ORPHAN-2"
    private let unrelated = "My Road Trip Mix"

    // MARK: - the capture truth table, EXECUTED

    func testCountedCaptureNeverCapturesTheActiveContainer() {
        guard let r = runCapture(counted: true,
                                 names: [playing, orphan1, orphan2, unrelated],
                                 keepName: playing) else { return }
        XCTAssertFalse(r.eligible.contains(playing),
                       "the container the user is listening to must NEVER be captured")
        XCTAssertEqual(r.eligible.sorted(), [orphan1, orphan2].sorted(),
                       "exactly the stale owned containers are captured")
        XCTAssertEqual(r.protectedMatch, true, "the active container sets protectedMatch")
    }

    func testUncountedCaptureNeverCapturesTheActiveContainer() {
        guard let r = runCapture(counted: false,
                                 names: [playing, orphan1, orphan2, unrelated],
                                 keepName: playing) else { return }
        XCTAssertFalse(r.eligible.contains(playing),
                       "the auto stale-sweep must NEVER capture the container it is about to play from")
        XCTAssertEqual(r.eligible.sorted(), [orphan1].sorted(),
                       "the stale sweep captures only its own prefix, and never the active one")
    }

    func testUnrelatedPlaylistsAreNeverCaptured() {
        for counted in [true, false] {
            guard let r = runCapture(counted: counted, names: [unrelated, "Library"], keepName: "") else { return }
            XCTAssertEqual(r.eligible, [], "counted=\(counted): non-owned names are never captured")
        }
    }

    func testDuplicateNamesAreCapturedOnce() {
        for counted in [true, false] {
            guard let r = runCapture(counted: counted,
                                     names: [orphan1, orphan1, orphan1], keepName: "") else { return }
            XCTAssertEqual(r.eligible, [orphan1], "counted=\(counted): deduplicated")
        }
    }

    func testProtectedMatchIsFalseWhenNothingActiveMatches() {
        guard let r = runCapture(counted: true, names: [orphan1], keepName: "Some Other Playlist") else { return }
        XCTAssertEqual(r.protectedMatch, false)
        XCTAssertEqual(r.eligible, [orphan1])
    }

    // MARK: - the harness must actually catch the mutations text pins missed

    /// Swapped branch bodies: every token present, still in order.
    func testHarnessCatchesSwappedBranchBodies() {
        guard let r = runCapture(counted: true, names: [playing, orphan1], keepName: playing, mutate: {
            $0.replacingOccurrences(of: "set protectedMatch to true", with: "@@SWAP@@")
              .replacingOccurrences(of: "set end of eligibleNames to nm", with: "set protectedMatch to true")
              .replacingOccurrences(of: "@@SWAP@@", with: "set end of eligibleNames to nm")
        }) else { return }
        XCTAssertTrue(r.eligible.contains(playing),
                      "harness self-check: the swapped mutation MUST capture the active container")
    }

    /// Reachability: neutering the keepName test leaves every token present and
    /// in order, and is invisible to any text pin.
    func testHarnessCatchesNeuteredKeepNameTest() {
        guard let r = runCapture(counted: true, names: [playing, orphan1], keepName: playing, mutate: {
            $0.replacingOccurrences(of: "if (nm is keepName) then", with: "if false then")
        }) else { return }
        XCTAssertTrue(r.eligible.contains(playing),
                      "harness self-check: a neutered keepName test MUST capture the active container")
    }
}

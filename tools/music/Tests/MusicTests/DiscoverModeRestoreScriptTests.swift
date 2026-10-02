import XCTest
@testable import music

/// The one guarded restore's script (amendment 2.3, with Codex 69.2: explicit
/// `currentID is "<HEX>"` comparisons, never a list membership test). The
/// script is never run here: `walk` is a small reader of exactly the line
/// forms `discoverModeRestoreScript` emits, and fails the test on any line it
/// does not know. It is a model of AppleScript, not AppleScript.
final class DiscoverModeRestoreScriptTests: XCTestCase {
    private let hexA = "00000000000000AA"
    private let hexB = "00000000000000BB"
    private let hexC = "00000000000000CC"
    private let foreign = "00000000000000EE"

    private func request(shuffle: Bool? = true, songRepeat: RepeatMode? = .all,
                         ours: DiscoverOurCopies, unlessHeChanged: Bool = true) -> DiscoverModeRestoreRequest {
        DiscoverModeRestoreRequest(shuffle: shuffle, songRepeat: songRepeat, ours: ours,
                                   unlessHeChanged: unlessHeChanged)
    }

    private func lines(_ script: String) -> [String] {
        script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: The walker

    /// Music.app as the script sees it. A nil field is a read that fails.
    private struct World {
        var shuffle: String? = "false"
        var songRepeat: String? = "off"
        var state: String? = "stopped"
        var current: String?
        var shuffleSetWorks = true
        var repeatSetWorks = true
        var readBackWorks = true
    }

    private func walk(_ script: String, _ start: World,
                      file: StaticString = #filePath, line: UInt = #line) -> (answer: String?, sets: [String]) {
        var world = start
        var sets: [String] = []
        var vars: [String: String] = [:]

        func quoted(_ text: String) -> String? {
            guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
            return String(text.dropFirst().dropLast())
        }
        /// `.some(nil)` = the read fails.
        func value(_ expression: String, into name: String) -> String?? {
            if let literal = quoted(expression) { return literal }
            let afterSets = name.hasSuffix("After")
            switch expression {
            case "(shuffle enabled as text)": return .some(afterSets && !world.readBackWorks ? nil : world.shuffle)
            case "(song repeat as text)": return .some(afterSets && !world.readBackWorks ? nil : world.songRepeat)
            case "(player state as text)": return .some(world.state)
            case "(persistent ID of current playlist) as text": return .some(world.current)
            default: return nil
            }
        }
        func term(_ text: String) -> Bool? {
            if text.hasPrefix("("), text.hasSuffix(")") {
                var any = false
                for one in text.dropFirst().dropLast().components(separatedBy: " or ") {
                    guard let yes = term(one) else { return nil }
                    any = any || yes
                }
                return any
            }
            if let r = text.range(of: " is not "), let v = vars[String(text[..<r.lowerBound])],
               let literal = quoted(String(text[r.upperBound...])) { return v != literal }
            if let r = text.range(of: " is "), let v = vars[String(text[..<r.lowerBound])],
               let literal = quoted(String(text[r.upperBound...])) { return v == literal }
            return nil
        }
        func holds(_ condition: String) -> Bool? {
            var all = true
            for one in condition.components(separatedBy: " and ") {
                guard let yes = term(one) else { return nil }
                all = all && yes
            }
            return all
        }
        func expression(_ text: String) -> String? {
            var out = ""
            for part in text.components(separatedBy: " & ") {
                if let literal = quoted(part) { out += literal } else if let v = vars[part] { out += v } else { return nil }
            }
            return out
        }
        /// One simple statement. `failed` = it raised (a failed read or set).
        func statement(_ text: String) -> (answer: String?, failed: Bool)? {
            for on in ["true", "false"] where text == "set shuffle enabled to \(on)" {
                sets.append("shuffle:\(on)")
                guard world.shuffleSetWorks else { return (nil, true) }
                world.shuffle = on
                return (nil, false)
            }
            for mode in RepeatMode.allCases where text == "set song repeat to \(mode.rawValue)" {
                sets.append("repeat:\(mode.rawValue)")
                guard world.repeatSetWorks else { return (nil, true) }
                world.songRepeat = mode.rawValue
                return (nil, false)
            }
            if text.hasPrefix("return "), let answer = expression(String(text.dropFirst(7))) { return (answer, false) }
            if text.hasPrefix("set "), let r = text.range(of: " to ") {
                let name = String(text[text.index(text.startIndex, offsetBy: 4)..<r.lowerBound])
                guard let got = value(String(text[r.upperBound...]), into: name) else { return nil }
                guard let read = got else { return (nil, true) }
                vars[name] = read
                return (nil, false)
            }
            return nil
        }

        var inTry = false
        var skipping = false
        for text in lines(script) {
            if text == "try" { inTry = true; skipping = false; continue }
            if text == "end try" { inTry = false; skipping = false; continue }
            if skipping { continue }
            var body = text
            if text.hasPrefix("if "), let r = text.range(of: " then ") {
                guard let yes = holds(String(text[text.index(text.startIndex, offsetBy: 3)..<r.lowerBound])) else {
                    XCTFail("unknown condition: \(text)", file: file, line: line); return (nil, sets)
                }
                if !yes { continue }
                body = String(text[r.upperBound...])
            }
            guard let done = statement(body) else {
                XCTFail("unknown line: \(text)", file: file, line: line); return (nil, sets)
            }
            if done.failed {
                guard inTry else { XCTFail("a read or set failed outside a try: \(text)", file: file, line: line); return (nil, sets) }
                skipping = true
                continue
            }
            if let answer = done.answer { return (answer, sets) }
        }
        XCTFail("the script ended without an answer", file: file, line: line)
        return (nil, sets)
    }

    /// The same world as the shared contract sees it.
    private func contract(_ request: DiscoverModeRestoreRequest, _ world: World) -> DiscoverModeRestoreAnswer {
        var modes: (shuffle: Bool, songRepeat: RepeatMode)?
        if let s = world.shuffle, let r = world.songRepeat.flatMap(RepeatMode.init(rawValue:)) {
            modes = (s == "true", r)
        }
        let player: DiscoverCopyPlayerRead? = world.state == nil && world.current == nil
            ? nil : DiscoverCopyPlayerRead(state: world.state ?? "", playlistID: world.current, trackID: nil)
        var model = world
        return dfhModeRestoreContract(request, modes: modes, player: player) { s, r in
            if let s, model.shuffleSetWorks { model.shuffle = "\(s)" }
            if let r, model.repeatSetWorks { model.songRepeat = r.rawValue }
            guard model.readBackWorks, let shuffle = model.shuffle,
                  let mode = model.songRepeat.flatMap(RepeatMode.init(rawValue:)) else { return nil }
            return (shuffle == "true", mode)
        }
    }

    // MARK: Structure

    func testTheScriptLooksAtThePlayerLastAndHoldsBeforeAnySet() throws {
        for ours in [DiscoverOurCopies.known([hexA, hexB]), .known([]), .unknowable] {
            for unless in [true, false] {
                let text = lines(discoverModeRestoreScript(request(ours: ours, unlessHeChanged: unless)))
                let modeReads = text.indices.filter { text[$0].contains("shuffle enabled as text")
                    || text[$0].contains("song repeat as text") }
                let playerReads = text.indices.filter { text[$0].contains("player state as text")
                    || text[$0].contains("current playlist") }
                let firstSet = try XCTUnwrap(text.firstIndex { $0.hasPrefix("set shuffle enabled to")
                    || $0.hasPrefix("set song repeat to") })
                let decisions = text.indices.filter { index in
                    ["held|", "unreadable", "changed", "back"].contains { text[index].contains("return \"\($0)") }
                }
                XCTAssertTrue(playerReads.allSatisfy { $0 > modeReads[1] }, "the player is read after the modes")
                XCTAssertTrue(modeReads.filter { $0 < firstSet }.count == 2, "only the two first reads before the sets")
                let held = try XCTUnwrap(text.lastIndex { $0.contains("return \"held|") })
                XCTAssertTrue(playerReads.allSatisfy { $0 < held }, "the player is read last before the hold")
                XCTAssertTrue(decisions.allSatisfy { $0 < firstSet }, "every no-set answer comes before the first set")
                XCTAssertFalse(text[..<firstSet].contains { $0.hasPrefix("set shuffle enabled to")
                    || $0.hasPrefix("set song repeat to") })
            }
        }
    }

    func testTheUnknowableScriptHoldsWheneverNotStoppedAndReadsNoPlaylist() {
        let script = discoverModeRestoreScript(request(ours: .unknowable))
        XCTAssertFalse(script.contains("current playlist"))
        XCTAssertFalse(script.contains("currentID"))
        XCTAssertTrue(lines(script).contains("if stateText is not \"stopped\" then return \"held|\""))
        for state in ["playing", "paused", "fast forwarding", nil] as [String?] {
            let walked = walk(script, World(state: state, current: hexA))
            XCTAssertEqual(walked.answer, "held|", "\(String(describing: state))")
            XCTAssertEqual(walked.sets, [])
        }
        XCTAssertEqual(walk(script, World(state: "stopped")).answer, "set|true,all")
    }

    func testAMalformedIDNeverReachesTheScriptText() {
        let hostile = "0000\"; delete pl --"
        for ours in [DiscoverOurCopies.known([hostile]), .known([hexA, hostile]), .known(["00000000000000aa"])] {
            let script = discoverModeRestoreScript(request(ours: ours))
            XCTAssertEqual(script, discoverModeRestoreScript(request(ours: .unknowable)), "\(ours)")
            XCTAssertFalse(script.contains("delete"))
            XCTAssertFalse(script.contains(hexA), "a list with any malformed member compares nothing")
        }
    }

    func testAnOrdinaryRecordsScriptChecksHisChangeAndAPendingOnesDoesNot() {
        let ordinary = lines(discoverModeRestoreScript(request(ours: .known([hexA]), unlessHeChanged: true)))
        let pending = lines(discoverModeRestoreScript(request(ours: .known([hexA]), unlessHeChanged: false)))
        let changed = ["if shuffleNow is not \"false\" then return \"changed\"",
                       "if repeatNow is not \"off\" then return \"changed\""]
        XCTAssertEqual(ordinary.filter { $0.contains("changed") }, changed)
        XCTAssertEqual(pending.filter { $0.contains("changed") }, [])
    }

    func testTheScriptSetsOnlyWhatIsRecordedAndNamesNoPlaylist() {
        let shuffleOnly = discoverModeRestoreScript(request(shuffle: false, songRepeat: nil, ours: .known([hexA])))
        XCTAssertTrue(shuffleOnly.contains("set shuffle enabled to false"))
        XCTAssertFalse(shuffleOnly.contains("set song repeat"))
        XCTAssertTrue(lines(shuffleOnly).contains("if shuffleNow is \"false\" then return \"back\""))
        let repeatOnly = discoverModeRestoreScript(request(shuffle: nil, songRepeat: .one, ours: .known([hexA])))
        XCTAssertFalse(repeatOnly.contains("set shuffle enabled"))
        XCTAssertTrue(lines(repeatOnly).contains("if repeatNow is \"one\" then return \"back\""))
        for script in [shuffleOnly, repeatOnly, discoverModeRestoreScript(request(ours: .unknowable))] {
            for verb in ["delete", "play ", "pause", "stop\n", "next track", "name of", "whose", "playpause"] {
                XCTAssertFalse(script.contains(verb), "the restore commands no player and reads no name: \(verb)")
            }
            XCTAssertFalse(lines(script).contains { $0 == "play" || $0 == "stop" || $0 == "pause" })
        }
    }

    // MARK: Codex 69.2: explicit comparisons, pinned

    func testTheHeldComparisonIsOneExplicitTermPerHexAndNeverAListTest() {
        let common = "if stateText is not \"stopped\" and currentID is \"\" then return \"held|\""
        let cases: [([String], String?)] = [
            ([], nil),
            ([hexA], "if stateText is not \"stopped\" and (currentID is \"\(hexA)\") then return \"held|\" & currentID"),
            ([hexA, hexB, hexC],
             "if stateText is not \"stopped\" and (currentID is \"\(hexA)\" or currentID is \"\(hexB)\" "
                + "or currentID is \"\(hexC)\") then return \"held|\" & currentID"),
        ]
        for (hexes, compare) in cases {
            let script = discoverModeRestoreScript(request(ours: .known(hexes)))
            let text = lines(script)
            XCTAssertTrue(text.contains(common), "\(hexes.count) hexes")
            let comparisons = text.filter { $0.contains("(currentID is") }
            XCTAssertEqual(comparisons, compare.map { [$0] } ?? [], "\(hexes.count) hexes")
            XCTAssertFalse(script.contains("contains"))
            XCTAssertFalse(script.contains("{"))
            XCTAssertFalse(script.contains("}"))
            XCTAssertFalse(script.contains(" in {"))
        }
    }

    func testTheTwoHexOrdinaryScriptIsExactlyThisText() {
        let script = discoverModeRestoreScript(request(shuffle: true, songRepeat: .all, ours: .known([hexA, hexB])))
        XCTAssertEqual(script, """
        set shuffleNow to ""
        try
            set shuffleNow to (shuffle enabled as text)
        end try
        set repeatNow to ""
        try
            set repeatNow to (song repeat as text)
        end try
        if shuffleNow is "" then return "unreadable"
        if repeatNow is "" then return "unreadable"
        set stateText to "playing"
        try
            set stateText to (player state as text)
        end try
        set currentID to ""
        try
            set currentID to (persistent ID of current playlist) as text
        end try
        if currentID is "missing value" then set currentID to ""
        if stateText is not "stopped" and currentID is "" then return "held|"
        if stateText is not "stopped" and (currentID is "00000000000000AA" or currentID is "00000000000000BB") then return "held|" & currentID
        if shuffleNow is not "false" then return "changed"
        if repeatNow is not "off" then return "changed"
        if shuffleNow is "true" and repeatNow is "all" then return "back"
        try
            set shuffle enabled to true
        end try
        try
            set song repeat to all
        end try
        set shuffleAfter to ""
        try
            set shuffleAfter to (shuffle enabled as text)
        end try
        set repeatAfter to ""
        try
            set repeatAfter to (song repeat as text)
        end try
        return "set|" & shuffleAfter & "," & repeatAfter
        """)
    }

    /// Through the script-runner fake: the runner walks the very text it is handed.
    func testTheGeneratedComparisonsHoldThroughTheScriptRunnerFake() {
        func attempt(_ ours: DiscoverOurCopies, _ world: World) -> (DiscoverModeRestoreAnswer, [String]) {
            var scripts: [String] = []
            let runner: ScriptRunner = { [self] script in
                scripts.append(script)
                return walk(script, world).answer
            }
            let req = request(ours: ours)
            let answer = discoverModeRestore(run: runner, req)
            XCTAssertEqual(scripts, [discoverModeRestoreScript(req)], "one script, the generated text")
            return (answer, scripts)
        }
        let three = DiscoverOurCopies.known([hexA, hexB, hexC])
        for hex in [hexA, hexB, hexC] {
            for state in ["playing", "paused", nil] as [String?] {
                XCTAssertEqual(attempt(three, World(state: state, current: hex)).0, .held(current: hex))
            }
        }
        XCTAssertEqual(attempt(three, World(state: "playing", current: foreign)).0,
                       .set(shuffle: true, songRepeat: .all))
        XCTAssertEqual(attempt(.known([hexA]), World(state: "playing", current: hexA)).0, .held(current: hexA))
        // No hex to compare: an unreadable current playlist still holds whenever not stopped.
        for state in ["playing", "paused", nil] as [String?] {
            for current in [nil, "missing value"] as [String?] {
                XCTAssertEqual(attempt(.known([]), World(state: state, current: current)).0, .held(current: nil))
            }
        }
        XCTAssertEqual(attempt(.known([]), World(state: "playing", current: foreign)).0,
                       .set(shuffle: true, songRepeat: .all))
        XCTAssertEqual(attempt(.known([]), World(state: "stopped", current: nil)).0,
                       .set(shuffle: true, songRepeat: .all))
    }

    // MARK: The walked script and the shared contract agree

    func testTheWalkedScriptAnswersEveryCaseOfTheContract() {
        let modeWorlds: [(String?, String?)] = [
            ("false", "off"), ("true", "all"), ("false", "all"), ("true", "one"), (nil, "off"), ("false", nil),
        ]
        let players: [(String?, String?)] = [
            (nil, nil), ("stopped", nil), ("stopped", hexA), ("playing", hexA), ("paused", hexA), ("playing", hexB),
            ("playing", foreign), ("playing", nil), ("playing", "missing value"), (nil, hexA), ("paused", foreign),
        ]
        let ourses: [DiscoverOurCopies] = [.known([]), .known([hexA]), .known([hexA, hexB]), .unknowable,
                                           .known(["bad"])]
        let effects: [(Bool, Bool, Bool)] = [(true, true, true), (false, true, true), (true, false, true),
                                             (true, true, false)]
        var cases = 0
        for (shuffle, songRepeat) in modeWorlds {
            for (state, current) in players {
                for ours in ourses {
                    for (shuffleWorks, repeatWorks, readBack) in effects {
                        for wantShuffle in [nil, true, false] as [Bool?] {
                            for wantRepeat in [nil, RepeatMode.off, .all, .one] as [RepeatMode?] {
                                guard wantShuffle != nil || wantRepeat != nil else { continue }
                                for unless in [true, false] {
                                    let req = request(shuffle: wantShuffle, songRepeat: wantRepeat, ours: ours,
                                                      unlessHeChanged: unless)
                                    let world = World(shuffle: shuffle, songRepeat: songRepeat, state: state,
                                                      current: current, shuffleSetWorks: shuffleWorks,
                                                      repeatSetWorks: repeatWorks, readBackWorks: readBack)
                                    let walked = parseDiscoverModeRestoreAnswer(
                                        walk(discoverModeRestoreScript(req), world).answer, request: req)
                                    let expected = contract(req, world)
                                    cases += 1
                                    if walked != expected {
                                        XCTFail("\(req) \(world): walked \(walked), contract \(expected)")
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 10_000)
    }

    // MARK: Parsing and the live seam

    func testTheAnswersParse() {
        let ordinary = request(ours: .known([hexA, hexB]), unlessHeChanged: true)
        let pending = request(ours: .known([hexA, hexB]), unlessHeChanged: false)
        func parse(_ output: String?, _ req: DiscoverModeRestoreRequest) -> DiscoverModeRestoreAnswer {
            discoverModeRestore(run: { _ in output }, req)
        }
        XCTAssertEqual(parse("held|\(hexA)", ordinary), .held(current: hexA))
        XCTAssertEqual(parse("held|\(hexB.lowercased())\n", ordinary), .held(current: hexB))
        XCTAssertEqual(parse("held|", ordinary), .held(current: nil))
        XCTAssertEqual(parse("held|\(foreign)", ordinary), .held(current: nil), "not one of ours")
        XCTAssertEqual(parse("held|junk", ordinary), .held(current: nil))
        XCTAssertEqual(parse("held|\(hexA)", request(ours: .unknowable)), .held(current: nil))
        XCTAssertEqual(parse("unreadable", ordinary), .modesUnreadable)
        XCTAssertEqual(parse("changed", ordinary), .changed)
        XCTAssertEqual(parse("changed", pending), .unknown, "a pending record was never asked")
        XCTAssertEqual(parse(" back \n", ordinary), .back)
        XCTAssertEqual(parse("set|true,all", ordinary), .set(shuffle: true, songRepeat: .all))
        XCTAssertEqual(parse("set|false,off\n", ordinary), .set(shuffle: false, songRepeat: .off))
        XCTAssertEqual(parse("set|,", ordinary), .set(shuffle: nil, songRepeat: nil))
        XCTAssertEqual(parse("set|maybe,sometimes", ordinary), .set(shuffle: nil, songRepeat: nil))
        for junk in [nil, "", "held", "set|true", "set|true,all,one", "set", "garbage", "BACK"] as [String?] {
            XCTAssertEqual(parse(junk, ordinary), .unknown, "\(String(describing: junk))")
        }
    }

    func testTheLiveSeamRunsOneScriptPerAttempt() {
        var scripts: [String] = []
        let seams = DiscoverModeGuard.Seams.live(backend: AppleScriptBackend(), run: { scripts.append($0); return "back" })
        let req = request(ours: .known([hexA]))
        XCTAssertEqual(seams.restore(req), .back)
        XCTAssertEqual(scripts, [discoverModeRestoreScript(req)])
    }

    func testOurCopiesAreEveryWellFormedHexInEveryStateAndOneMalformedMakesThemUnknowable() {
        func entry(_ txn: String, _ state: DiscoverCopyState, _ hex: String?) -> DiscoverCopyEntry {
            DiscoverCopyEntry(txn: txn, playlistID: "pl.x", title: "P", state: state, hex: hex, copiesRead: 0,
                              watching: false, copySeen: false, toldAtLaunch: false, priorShuffle: nil,
                              priorRepeat: nil, createdAt: 1, updatedAt: 1)
        }
        let entries = [entry("1", .closed, hexB), entry("2", .intent, nil), entry("3", .uncertain, hexA),
                       entry("4", .preexisting, hexB), entry("5", .listening, hexC)]
        XCTAssertEqual(discoverOurCopies(entries), .known([hexA, hexB, hexC]))
        XCTAssertEqual(discoverOurCopies([]), .known([]))
        XCTAssertEqual(discoverOurCopies(entries + [entry("6", .closed, "00000000000000cc")]), .unknowable)
        XCTAssertEqual(discoverOurCopies(entries + [entry("7", .closed, "")]), .unknowable)
    }
}

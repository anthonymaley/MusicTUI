import XCTest
@testable import music

/// The AppleScript text behind `AppleScriptDiscoverCopyPlayer` (score step
/// C3). The scripts are WRITTEN here and pinned as text; none is run, by
/// osascript or otherwise: every call goes through a recording script-runner
/// fake that answers what a test scripts.
final class DiscoverCopyScriptTests: XCTestCase {

    private let hex = "AAAAAAAAAAAAAAAA"
    private let trackA = "00000000000000A1"
    private let trackB = "00000000000000B2"
    private let fs = "\u{1F}"
    private let rs = "\u{1E}"

    /// Records every script it is handed and answers the scripted output.
    private final class Runner {
        var answer: String?
        private(set) var scripts: [String] = []
        init(_ answer: String? = nil) { self.answer = answer }
        var run: ScriptRunner { { [self] script in scripts.append(script); return answer } }
    }

    private func player(_ runner: Runner) -> AppleScriptDiscoverCopyPlayer {
        AppleScriptDiscoverCopyPlayer(run: runner.run)
    }

    private func lines(_ script: String) -> [String] {
        script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var allScripts: [String] {
        [discoverCopyTrackCountScript(hex: hex), discoverCopyReadScript(hex: hex, k: 3),
         discoverCopyPlayCopyScript(hex: hex), discoverCopyTransportScript("pause"),
         discoverCopyTransportScript("next track"), discoverCopyTransportScript("play"),
         discoverCopyTransportScript("stop"), discoverCopyStopIfCurrentScript(hex: hex),
         discoverCopyFirstPlayScript(hex: hex, track: trackA),
         discoverCopyLandingScript(hex: hex, expected: trackB, previous: trackA, settling: false),
         discoverCopyLandingScript(hex: hex, expected: trackA, previous: trackA, settling: true),
         discoverCopyConfirmScript(hex: hex, track: trackA)]
    }

    // MARK: - How the copy is addressed (CH1)

    func testEveryScriptThatAddressesTheCopyUsesTheLoopPreamble() {
        let preamble = discoverCopyLookupPreamble(hex: hex)
        XCTAssertTrue(preamble.contains("repeat with p in playlists"))
        for script in [discoverCopyTrackCountScript(hex: hex), discoverCopyReadScript(hex: hex, k: 3),
                       discoverCopyPlayCopyScript(hex: hex)] {
            XCTAssertTrue(script.contains(preamble), script)
        }
    }

    func testNoScriptNamesUserPlaylistAWhoseClauseOrATellBlock() {
        for script in allScripts {
            XCTAssertFalse(script.contains("user playlist"), script)
            XCTAssertFalse(script.contains("whose"), script)
            XCTAssertFalse(script.contains("tell application"), script)
            XCTAssertFalse(script.contains("delay"), "no script waits: \(script)")
        }
    }

    func testPlayCopyPlaysThePlaylistItFoundAndNeverATrackOfIt() {
        let script = lines(discoverCopyPlayCopyScript(hex: hex))
        XCTAssertTrue(script.contains("play pl"))
        XCTAssertTrue(script.contains("if pl is missing value then error \"the copy is missing\""))
        XCTAssertFalse(script.contains { $0.hasPrefix("play track") })
        XCTAssertLessThan(script.firstIndex(of: "end repeat")!, script.firstIndex(of: "play pl")!)
    }

    func testAMissingCopyCountsZero() {
        let script = lines(discoverCopyTrackCountScript(hex: hex))
        XCTAssertTrue(script.contains("if pl is missing value then return \"0\""))
        XCTAssertEqual(script.last, "return (count of tracks of pl) as text")
    }

    // MARK: - stopIfCurrent (CH13)

    func testStopIfCurrentStopsOnlyInsideTheCurrentPlaylistComparison() {
        let script = lines(discoverCopyStopIfCurrentScript(hex: hex))
        let opening = "if persistent ID of current playlist is \"\(hex)\" then"
        guard let start = script.firstIndex(of: opening),
              let end = script.firstIndex(of: "end if") else { return XCTFail("no guarded block") }
        let stops = script.indices.filter { script[$0] == "stop" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(stops.allSatisfy { $0 > start && $0 < end })
        XCTAssertEqual(script.filter { $0.hasPrefix("if ") }.count, 1, "one condition, and it is the playlist's")
    }

    func testStopIfCurrentReportsWhetherTheScriptRan() {
        for (answer, expected) in [("stopped", true), ("left\n", true), ("notyet", false), ("", false)] {
            XCTAssertEqual(player(Runner(answer)).stopIfCurrent(hex: hex), expected, answer)
        }
        XCTAssertFalse(player(Runner(nil)).stopIfCurrent(hex: hex))
    }

    // MARK: - The polls compare INSIDE the script

    func testEveryPollReadsStatePlaylistAndTrackEachInsideATry() {
        for script in [discoverCopyFirstPlayScript(hex: hex, track: trackA),
                       discoverCopyLandingScript(hex: hex, expected: trackB, previous: trackA, settling: false),
                       discoverCopyConfirmScript(hex: hex, track: trackA)] {
            let body = lines(script)
            for read in ["set stateText to player state as text",
                         "set ctxID to persistent ID of current playlist",
                         "set trackID to persistent ID of current track"] {
                guard let at = body.firstIndex(of: read) else { XCTFail("missing: \(read)"); continue }
                XCTAssertEqual(body[at - 1], "try")
                XCTAssertEqual(body[at + 1], "end try")
            }
        }
    }

    func testFirstPlayLandsOnlyPlayingInOurCopyOnTheTrack() {
        let script = lines(discoverCopyFirstPlayScript(hex: hex, track: trackA))
        XCTAssertTrue(script.contains("if stateText is \"\(nowPlayingReadyState)\" and ctxID is \"\(hex)\" then"))
        XCTAssertTrue(script.contains("if trackID is \"\(trackA)\" then return \"landed\""))
        XCTAssertTrue(script.contains("if trackID is not \"\" then return \"wrongtrack\""))
        XCTAssertEqual(script.last, "return \"notyet\"")
    }

    func testLandingChecksPlaylistThenStateThenTheExactTrack() {
        let script = lines(discoverCopyLandingScript(hex: hex, expected: trackB, previous: trackA, settling: false))
        let order = ["if ctxID is not \"\" and ctxID is not \"\(hex)\" then return \"foreign\"",
                     "if stateText is \"\" then return \"notyet\"",
                     "if stateText is not \"paused\" then return \"wrongstate\"",
                     "if ctxID is \"\" then return \"notyet\"",
                     "if trackID is \"\" then return \"notyet\"",
                     "if trackID is \"\(trackB)\" then return \"landed\"",
                     "if trackID is \"\(trackA)\" then return \"notyet\"",
                     "return \"wrongtrack\""]
        let positions = order.map { script.firstIndex(of: $0) }
        XCTAssertFalse(positions.contains(nil), "\(script)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertEqual(script.last, "return \"wrongtrack\"")
    }

    func testASettlingLandingTreatsNotPausedAsNotYet() {
        let script = lines(discoverCopyLandingScript(hex: hex, expected: trackA, previous: trackA, settling: true))
        XCTAssertTrue(script.contains("if stateText is not \"paused\" then return \"notyet\""))
        XCTAssertFalse(script.contains { $0.contains("wrongstate") })
    }

    func testConfirmNeedsOurCopyTheTrackPlayingAndAReadablePosition() {
        let script = lines(discoverCopyConfirmScript(hex: hex, track: trackA))
        let order = ["if ctxID is not \"\" and ctxID is not \"\(hex)\" then return \"foreign\"",
                     "if ctxID is \"\" then return \"notyet\"",
                     "if trackID is \"\" then return \"notyet\"",
                     "if trackID is not \"\(trackA)\" then return \"wrongtrack\"",
                     "if stateText is not \"\(nowPlayingReadyState)\" then return \"notyet\"",
                     "set positionText to (round (player position * 1000) rounding as taught in school) as text",
                     "if positionText is \"\" then return \"notyet\"",
                     "return \"ontrack:\" & positionText"]
        let positions = order.map { script.firstIndex(of: $0) }
        XCTAssertFalse(positions.contains(nil), "\(script)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
    }

    // MARK: - What the player makes of the answers

    func testPollAnswersParseAndAnythingElseIsNotYet() {
        let cases: [(String?, DiscoverCopyPoll)] = [
            ("landed", .landed), ("landed\n", .landed), ("foreign", .foreign), ("wrongstate", .wrongState),
            ("wrongtrack", .wrongTrack), ("notyet", .notYet), ("", .notYet), ("LANDED", .notYet),
            ("landed?", .notYet), (nil, .notYet)]
        for (answer, expected) in cases {
            let runner = Runner(answer)
            XCTAssertEqual(player(runner).firstPlay(hex: hex, track: trackA), expected, "\(answer ?? "nil")")
            XCTAssertEqual(player(runner).landing(hex: hex, expected: trackB, previous: trackA, settling: false),
                           expected, "\(answer ?? "nil")")
            XCTAssertEqual(runner.scripts, [discoverCopyFirstPlayScript(hex: hex, track: trackA),
                                            discoverCopyLandingScript(hex: hex, expected: trackB,
                                                                      previous: trackA, settling: false)])
        }
    }

    func testConfirmAnswersParseAndAnythingElseIsNotYet() {
        let cases: [(String?, DiscoverCopyConfirm)] = [
            ("ontrack:0", .onTrack(positionMS: 0)), ("ontrack:1234\n", .onTrack(positionMS: 1234)),
            ("ontrack:", .notYet), ("ontrack:1,5", .notYet), ("ontrack:-3", .notYet), ("ontrack:1.5E+3", .notYet),
            ("foreign", .foreign), ("wrongtrack", .wrongTrack), ("notyet", .notYet), ("landed", .notYet),
            (nil, .notYet)]
        for (answer, expected) in cases {
            XCTAssertEqual(player(Runner(answer)).confirm(hex: hex, track: trackA), expected, "\(answer ?? "nil")")
        }
    }

    func testCommandsSucceedOnlyOnTheOKToken() {
        for (answer, expected) in [("ok", true), ("ok\n", true), ("", false), ("notyet", false)] {
            let p = player(Runner(answer))
            XCTAssertEqual(p.playCopy(hex: hex), expected)
            XCTAssertEqual(p.pause(), expected)
            XCTAssertEqual(p.nextTrack(), expected)
            XCTAssertEqual(p.play(), expected)
            XCTAssertEqual(p.stop(), expected)
        }
        let failed = player(Runner(nil))
        XCTAssertFalse(failed.playCopy(hex: hex))
        XCTAssertFalse(failed.pause())
        XCTAssertFalse(failed.nextTrack())
        XCTAssertFalse(failed.play())
        XCTAssertFalse(failed.stop())
    }

    func testEachTransportCommandIsExactlyItsOwnVerb() {
        let runner = Runner("ok")
        let p = player(runner)
        _ = p.pause(); _ = p.nextTrack(); _ = p.play(); _ = p.stop()
        XCTAssertEqual(runner.scripts.map { lines($0) },
                       [["pause", "return \"ok\""], ["next track", "return \"ok\""],
                        ["play", "return \"ok\""], ["stop", "return \"ok\""]])
    }

    func testTrackCountParsesAnIntegerAndNothingElse() {
        XCTAssertEqual(player(Runner("12\n")).trackCount(hex: hex), 12)
        XCTAssertEqual(player(Runner("0")).trackCount(hex: hex), 0)
        XCTAssertNil(player(Runner("")).trackCount(hex: hex))
        XCTAssertNil(player(Runner("twelve")).trackCount(hex: hex))
        XCTAssertNil(player(Runner("-1")).trackCount(hex: hex))
        XCTAssertNil(player(Runner(nil)).trackCount(hex: hex))
    }

    /// An ID that is not sixteen `0-9A-F` never reaches a script.
    func testAMalformedIDRunsNoScriptAndGivesTheFailingAnswer() {
        for bad in ["", "abc", "AAAAAAAAAAAAAAAa", "A\" then\nstop\n--AAAAA", "AAAAAAAAAAAAAAAAA"] {
            let runner = Runner("ok")
            let p = player(runner)
            XCTAssertNil(p.trackCount(hex: bad))
            XCTAssertNil(p.read(hex: bad, k: 1))
            XCTAssertFalse(p.playCopy(hex: bad))
            XCTAssertFalse(p.stopIfCurrent(hex: bad))
            XCTAssertEqual(p.firstPlay(hex: bad, track: trackA), .notYet)
            XCTAssertEqual(p.firstPlay(hex: hex, track: bad), .notYet)
            XCTAssertEqual(p.landing(hex: bad, expected: trackA, previous: trackA, settling: false), .notYet)
            XCTAssertEqual(p.landing(hex: hex, expected: bad, previous: trackA, settling: false), .notYet)
            XCTAssertEqual(p.landing(hex: hex, expected: trackA, previous: bad, settling: false), .notYet)
            XCTAssertEqual(p.confirm(hex: bad, track: trackA), .notYet)
            XCTAssertEqual(p.confirm(hex: hex, track: bad), .notYet)
            XCTAssertTrue(runner.scripts.isEmpty, bad)
        }
        let runner = Runner("ok")
        XCTAssertNil(player(runner).read(hex: hex, k: 0))
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    // MARK: - S7's read

    func testTheReadScriptJoinsIDsBy31AndFieldsBy30WithAWholeMillisecondLength() {
        let script = lines(discoverCopyReadScript(hex: hex, k: 7))
        XCTAssertTrue(script.contains("set fs to (ASCII character 31)"))
        XCTAssertTrue(script.contains("set rs to (ASCII character 30)"))
        XCTAssertTrue(script.contains("set t to track 7 of pl"))
        let length = "set lengthText to (round ((duration of t) * 1000) rounding as taught in school) as text"
        guard let at = script.firstIndex(of: length) else { return XCTFail("no length line") }
        XCTAssertEqual(script[at - 1], "try")
        XCTAssertEqual(script[at + 1], "end try")
        XCTAssertEqual(script.last, "return idText & rs & (name of t) & rs & (artist of t) & rs & lengthText")
        let runner = Runner(nil)
        XCTAssertNil(player(runner).read(hex: hex, k: 7))
        XCTAssertEqual(runner.scripts, [discoverCopyReadScript(hex: hex, k: 7)])
    }

    func testParseRoundTripsTitlesWithQuotesCommasAndNewlines() {
        let title = "He said \"hi\", twice\nand 'again'"
        let artist = "Earth, Wind & Fire\n\"Live\""
        let output = [trackA, trackB].joined(separator: fs) + rs + title + rs + artist + rs + "215333"
        let expected = DiscoverCopyRead(ids: [trackA, trackB],
                                        trackK: DiscoverCopyTrack(title: title, artist: artist, durationMS: 215_333))
        XCTAssertEqual(parseDiscoverCopyRead(output), expected)
        XCTAssertEqual(parseDiscoverCopyRead(output + "\n"), expected, "osascript's trailing newline")
        XCTAssertEqual(player(Runner(output + "\n")).read(hex: hex, k: 2), expected)
    }

    func testAnEmptyLengthFieldIsNoLength() {
        let output = trackA + rs + "Song" + rs + "Artist" + rs
        XCTAssertEqual(parseDiscoverCopyRead(output)?.trackK.durationMS, nil)
        XCTAssertNotNil(parseDiscoverCopyRead(output))
        XCTAssertNil(parseDiscoverCopyRead(output + "\n")?.trackK.durationMS)
        for unreadable in ["2.15E+5", "215,333", "abc"] {
            XCTAssertNil(parseDiscoverCopyRead(output + unreadable)?.trackK.durationMS, unreadable)
        }
    }

    func testAReadWithTheWrongNumberOfFieldsIsUnreadable() {
        XCTAssertNil(parseDiscoverCopyRead(""))
        XCTAssertNil(parseDiscoverCopyRead(trackA + rs + "Song" + rs + "Artist"))
        XCTAssertNil(parseDiscoverCopyRead(trackA + rs + "So" + rs + "ng" + rs + "Artist" + rs + "1000"))
        XCTAssertEqual(parseDiscoverCopyRead(rs + "Song" + rs + "Artist" + rs + "1000")?.ids, [])
    }
}

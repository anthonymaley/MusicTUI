import XCTest
@testable import music

/// The Discover container sweep, as a pure decision plus a pinned script.
///
/// These tests pin the RULE and the generated script text. They cannot prove
/// what Music does when a read fails — the guard that actually runs is
/// AppleScript, so only live verification covers behaviour. What they do buy is
/// that the Swift predicate and the emitted script can never disagree, which is
/// the twin-drift shape this repo has already paid for twice.
final class DiscoverSweepTests: XCTestCase {
    // MARK: - The spare rule

    /// Music's `player state` has five values (sdef, read 2026-08-31):
    /// stopped, playing, paused, fast forwarding, rewinding. Only the two idle
    /// ones release the container.
    func testActivePlaybackSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "playing"))
    }

    func testPausedAndStoppedReleaseTheCurrentPlaylist() {
        XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: "paused"))
        XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: "stopped"))
    }

    /// A scrub is active playback. The filed fix shape ("spare only while
    /// playing") would have deleted the container out from under it.
    func testScrubbingSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "fast forwarding"))
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "rewinding"))
    }

    /// Read error. Sparing is the cheap side of the asymmetry: a spared
    /// container costs one leftover row the next sweep collects, a wrongly
    /// swept one reverts live playback to the library.
    func testAnUnreadableStateSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: nil))
    }

    /// Any value Apple adds later lands on the spare side by construction.
    func testAnUnknownStateSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "buffering"))
    }

    // MARK: - Script / predicate agreement

    /// The live guard is the generated AppleScript, so the two must key on one
    /// set of literals. This is the `nowPlayingReadyState` shape.
    func testScriptKeysOnTheSameStatesAsThePredicate() {
        let script = discoverSweepScript()
        for state in sweepablePlayerStates {
            XCTAssertTrue(script.contains("\"\(state)\""),
                          "script must test the sweepable state \(state)")
            XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: state))
        }
    }

    /// The fallback used when `player state` cannot be read must itself be a
    /// state the predicate spares, or an unreadable state would sweep.
    func testTheUnreadableFallbackIsASparedState() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: unreadablePlayerStateFallback))
        XCTAssertTrue(discoverSweepScript().contains("\"\(unreadablePlayerStateFallback)\""))
    }

    func testScriptSweepsTheDiscoverPrefix() {
        XCTAssertTrue(discoverSweepScript().contains(discoverPlaylistPrefix))
    }

    /// The containers-only invariant, from DiscoverPlay.swift's module doc: this
    /// script enumerates playlists and can never reach a library row. Pinned
    /// here so it is enforced rather than merely documented.
    func testScriptCanNeverReachALibraryRow() {
        let script = discoverSweepScript()
        XCTAssertFalse(script.contains("track"), "sweep must never name a track")
        XCTAssertFalse(script.contains("song"), "sweep must never name a song")
    }
    // MARK: - Protected names (Discover lifecycle design §3.5)

    /// Today's script, verbatim. The design says an EMPTY protected list must
    /// emit exactly this — no `set protectedNames` line, no empty-list
    /// variable, no extra clause — because a syntactically equivalent form is
    /// a different script to the execution harness and to Music. A change to
    /// this fixture is a deliberate change to the sweep, never a side effect.
    private let scriptBeforeProtectedNames = """
        set keepName to ""
        set contextReadable to true
        set playerStateText to "playing"
        try
            set playerStateText to player state as text
        end try
        if playerStateText is not "paused" and playerStateText is not "stopped" then
            set contextReadable to false
            try
                set keepName to name of current playlist
                set contextReadable to true
            end try
        end if
        if not contextReadable then return
        set eligibleNames to {}
        repeat with pp in (every user playlist)
            try
                set nm to name of pp
                if (nm starts with "__discover__ ") and (nm is not keepName) and (eligibleNames does not contain nm) then
                    set end of eligibleNames to nm
                end if
            end try
        end repeat
        repeat with nm in eligibleNames
            try
                delete (every user playlist whose name is nm)
            end try
        end repeat
        """

    func testEmptyProtectedListEmitsTodaysScriptByteForByte() {
        XCTAssertEqual(discoverSweepScript(protectedNames: []), scriptBeforeProtectedNames)
        XCTAssertEqual(discoverSweepScript(), scriptBeforeProtectedNames,
                       "the default must be the empty list, so every existing caller is unchanged")
        XCTAssertFalse(discoverSweepScript().contains("protectedNames"))
    }

    /// A non-empty list is baked into the preamble, escaped, and joins the
    /// capture condition. The names carry user-controlled titles, so the
    /// escaping is the same function every other generated script uses.
    func testProtectedNamesAreEscapedAndJoinTheCaptureCondition() {
        let quoted = "\(discoverPlaylistPrefix)A — He said \"hi\""
        let slashed = "\(discoverPlaylistPrefix)B — back\\slash"
        let script = discoverSweepScript(protectedNames: [quoted, slashed])
        let expectedList = "set protectedNames to {\"\(escapeAppleScriptString(quoted))\", \"\(escapeAppleScriptString(slashed))\"}"
        XCTAssertTrue(script.contains(expectedList), "preamble must carry the escaped list:\n\(script)")
        XCTAssertTrue(script.contains(" and (protectedNames does not contain nm)"),
                      "capture condition must exclude protected names")
        // The clause is INSIDE the capture condition, not a separate statement.
        let captureLine = script.split(separator: "\n").first { $0.contains("starts with") }.map(String.init) ?? ""
        XCTAssertTrue(captureLine.contains("(protectedNames does not contain nm)"),
                      "the protected clause belongs on the capture line: \(captureLine)")
    }

    // MARK: - The pure twin of the capture condition

    /// `discoverCaptureDecision` mirrors the capture condition ONLY: prefix,
    /// not the kept name, not protected. The preamble's state and
    /// unreadable-context deferral are deliberately NOT twinned here; the
    /// whole-script execution tests remain the authority for those.
    func testCaptureDecisionRequiresThePrefix() {
        XCTAssertFalse(discoverCaptureDecision(name: "Road Trip Mix", keepName: "", protected: []))
        XCTAssertTrue(discoverCaptureDecision(name: "\(discoverPlaylistPrefix)X", keepName: "", protected: []))
    }

    func testCaptureDecisionSparesTheKeptName() {
        let n = "\(discoverPlaylistPrefix)X"
        XCTAssertFalse(discoverCaptureDecision(name: n, keepName: n, protected: []))
    }

    func testCaptureDecisionSparesProtectedNames() {
        let n = "\(discoverPlaylistPrefix)X"
        XCTAssertFalse(discoverCaptureDecision(name: n, keepName: "", protected: [n]))
        XCTAssertTrue(discoverCaptureDecision(name: n, keepName: "", protected: ["\(discoverPlaylistPrefix)Y"]))
    }

    /// The script and the decision key on the SAME prefix and the SAME
    /// protected list in the same escaped form. This is the twin-drift pin.
    func testScriptAndDecisionKeyOnTheSamePrefixAndList() {
        let names = ["\(discoverPlaylistPrefix)P \"1\"", "\(discoverPlaylistPrefix)P\\2"]
        let script = discoverSweepScript(protectedNames: names)
        XCTAssertTrue(script.contains("starts with \"\(discoverPlaylistPrefix)\""))
        for n in names {
            XCTAssertTrue(script.contains("\"\(escapeAppleScriptString(n))\""),
                          "each protected name appears escaped in the script")
            XCTAssertFalse(discoverCaptureDecision(name: n, keepName: "", protected: names))
        }
    }
}

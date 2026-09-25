import ArgumentParser
import XCTest
@testable import music

/// DoD 13 and ruling 12.14 at the call sites. `ActionRoutingTests` proves the
/// matrix refuses; these prove the CLI asks it, first, from every verb that can
/// change playback or would read Music.app's current track.
final class CLIBridgeGateTests: XCTestCase {

    // MARK: - The decision

    /// Slice 3 D7: the playback verbs Bridge does not serve from the CLI yet
    /// refuse in their not-served words. (Part 2, P6: the Apple Music song link
    /// left this list; it is dispatched, so the gate fails closed on it below.)
    func testUnservedPlaybackVerbsRefuseWithTheirD7WordsOnBridge() {
        XCTAssertEqual(cliBridgeRefusal(.cliPlayCatalogSong, mode: .source), cliGateOnDispatchedAction)
        let verbs: [MusicTUIAction] = [.cliPlayQuery, .persistentShuffleMode,
                                       .persistentRepeatMode, .radioStationPlay, .playlistTemp]
        for action in verbs {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source), cliBridgeNotServedReason(action), "\(action)")
        }
        XCTAssertEqual(cliBridgeRefusal(.cliPlayQuery, mode: .source),
                       "Bridge output is selected, and music play <words> isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app.")
    }

    /// A dispatched verb is not gated. If one ever were, "go ahead as it
    /// ships" would run Music.app with Bridge selected: a silent fallback. The
    /// gate fails closed instead.
    func testTheGateFailsClosedOnADispatchedAction() {
        for action in cliDispatchedOnBridge {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source), cliGateOnDispatchedAction, "\(action)")
            XCTAssertNil(cliBridgeRefusal(action, mode: .musicApp), "\(action)")
        }
    }

    /// One failure formatter for the gate and the dispatcher (S6 unified S5's copy).
    func testRefuseInBridgePrintsTheSharedFailureText() {
        let why = cliBridgeNotServedReason(.playlistTemp)
        let text = captureStdout { try refuseInBridge(.playlistTemp, json: false, mode: .source) }
        XCTAssertEqual(text.output, cliFailureText(why, json: false) + "\n")
        // Parsed, not compared as bytes: JSONSerialization does not order the
        // keys of two equal dictionaries the same way every time.
        let json = captureStdout { try refuseInBridge(.playlistTemp, json: true, mode: .source) }
        let printed = try? JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
        XCTAssertEqual(printed?["ok"] as? Bool, false)
        XCTAssertEqual(printed?["error"] as? String, why)
        XCTAssertEqual(printed?.count, 2)
        XCTAssertEqual(cliFailureText("x", json: false), "x")
        let doc = try? JSONSerialization.jsonObject(with: Data(cliFailureText("x", json: true).utf8)) as? [String: Any]
        XCTAssertEqual(doc?["ok"] as? Bool, false)
        XCTAssertEqual(doc?["error"] as? String, "x")
    }

    func testCurrentTrackVerbsRefuseWithTheirOwnReasonOnBridge() {
        let verbs: [MusicTUIAction] = [.loveTrack, .removeCurrentTrackFromPlaylist, .addCurrentTrackToPlaylist,
                                       .similarToCurrentTrack, .suggestFromCurrentTrack, .newReleasesLikeCurrentTrack]
        for action in verbs {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source), currentTrackIsStaleInBridge, "\(action)")
        }
    }

    /// The other half of 12.14: a verb that names its target explicitly, or only
    /// reads, runs as it ships.
    func testExplicitAndReadOnlyVariantsGoAheadOnBridge() {
        for action in [MusicTUIAction.similar, .suggest, .newReleases, .addToLibrary] {
            XCTAssertNil(cliBridgeRefusal(action, mode: .source), "\(action)")
        }
    }

    /// Binding rule 1: Music.app selected, nothing refuses.
    func testNothingRefusesWithMusicAppSelected() {
        for action in MusicTUIAction.allCases where action.surfaces.contains(.cli) {
            XCTAssertNil(cliBridgeRefusal(action, mode: .musicApp), "\(action)")
        }
    }

    func testRefuseInBridgeExitsNonZeroOnlyOnBridge() {
        XCTAssertThrowsError(try refuseInBridge(.cliPlayQuery, mode: .source)) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
        XCTAssertNoThrow(try refuseInBridge(.cliPlayQuery, mode: .musicApp))
    }

    // MARK: - Which action, when flags decide

    func testSelectorsFollowTheCommandsOwnBranches() {
        XCTAssertEqual(similarAction(query: []), .similarToCurrentTrack)
        XCTAssertEqual(similarAction(query: ["Teardrop"]), .similar)
        XCTAssertEqual(suggestAction(from: nil), .suggestFromCurrentTrack)
        XCTAssertEqual(suggestAction(from: "Top 25 Most Played"), .suggest)
        XCTAssertEqual(newReleasesAction(artist: nil, likeCurrent: true), .newReleasesLikeCurrentTrack)
        XCTAssertEqual(newReleasesAction(artist: "Air", likeCurrent: true), .newReleases, "--artist wins")
        XCTAssertEqual(newReleasesAction(artist: nil, likeCurrent: false), .newReleases)
        XCTAssertEqual(addAction(query: [], id: nil, to: ["Mix"]), .addCurrentTrackToPlaylist)
        XCTAssertEqual(addAction(query: ["Teardrop"], id: nil, to: ["Mix"]), .addToLibrary)
        XCTAssertEqual(addAction(query: [], id: "123", to: ["Mix"]), .addToLibrary)
        XCTAssertEqual(addAction(query: ["3"], id: nil, to: []), .addToLibrary)
    }

    // MARK: - The call sites

    /// Every gated verb asks FIRST: the first statement of its `run()` is the
    /// gate, so no AppleScript, `open music://` or current-track read can come
    /// before a refusal. Read from the source, because a verb that forgets the
    /// call compiles and passes every test above.
    func testEveryGatedVerbAsksBeforeDoingAnything() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands")
        let gated: [(file: String, command: String)] = [
            ("DiscoveryCommands.swift", "Similar"), ("DiscoveryCommands.swift", "Suggest"),
            ("DiscoveryCommands.swift", "NewReleases"), ("LoveCommands.swift", "Love"),
            ("LoveCommands.swift", "Unlove"), ("RemoveCommand.swift", "Remove"),
            ("AddCommand.swift", "Add"),
        ]
        for (file, command) in gated {
            let source = try String(contentsOf: commands.appendingPathComponent(file), encoding: .utf8)
            guard let firstLine = firstLineOfRun(command, in: source)
            else { return XCTFail("\(command) not found in \(file)") }
            XCTAssertTrue(firstLine.contains("try refuseInBridge("),
                          "\(command).run() must ask the Bridge gate first; it starts with: \(firstLine)")
        }
    }

    /// Slice 3 S6 and S7: the dispatching verbs. `run()` starts with `try run<Verb>(`
    /// (`Now` keeps its TTY check first, then calls it), and `run<Verb>`'s
    /// first statement is `try cliDispatch(`, so no AppleScript, `open` or
    /// Bridge request can precede the route.
    func testEveryDispatchingVerbDispatchesBeforeDoingAnything() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands")
        let dispatching: [(file: String, command: String, verb: String)] = [
            ("PlaybackCommands.swift", "Pause", "runPause"), ("PlaybackCommands.swift", "Skip", "runSkip"),
            ("PlaybackCommands.swift", "Back", "runBack"), ("PlaybackCommands.swift", "Stop", "runStop"),
            ("PlaybackCommands.swift", "Seek", "runSeek"), ("PlaybackCommands.swift", "Shuffle", "runShuffle"),
            ("PlaybackCommands.swift", "Repeat_", "runRepeat"), ("RadioCommands.swift", "RadioPlay", "runRadioPlay"),
            ("PlaylistCommands.swift", "PlaylistTemp", "runPlaylistTemp"),
            // S7: `music play` and `music search`.
            ("PlaybackCommands.swift", "Play", "runPlay"), ("SearchCommand.swift", "Search", "runSearch"),
        ]
        for (file, command, verb) in dispatching {
            let source = try String(contentsOf: commands.appendingPathComponent(file), encoding: .utf8)
            guard let firstLine = firstLineOfRun(command, in: source)
            else { return XCTFail("\(command) not found in \(file)") }
            XCTAssertTrue(firstLine.contains("try \(verb)("),
                          "\(command).run() must start with try \(verb)(; it starts with: \(firstLine)")
            XCTAssertEqual(firstStatement(ofFunction: verb, in: source).map { $0.hasPrefix("try cliDispatch(") }, true,
                           "\(verb) must start with try cliDispatch(")
        }

        let playback = try String(contentsOf: commands.appendingPathComponent("PlaybackCommands.swift"), encoding: .utf8)
        guard let decl = playback.range(of: "struct Now: ParsableCommand"),
              let run = playback.range(of: "func run() throws {\n", range: decl.upperBound..<playback.endIndex),
              let end = playback.range(of: "\n    }\n", range: run.upperBound..<playback.endIndex)
        else { return XCTFail("Now not found") }
        let body = playback[run.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("isTTY()"), "Now keeps its TTY check")
        XCTAssertTrue(body.contains("try runNow("), "Now dispatches through runNow")
        XCTAssertLessThan(body.range(of: "isTTY()")!.lowerBound, body.range(of: "try runNow(")!.lowerBound,
                          "the TTY check comes first")
        XCTAssertEqual(firstStatement(ofFunction: "runNow", in: playback).map { $0.hasPrefix("try cliDispatch(") }, true)
    }

    private func firstLineOfRun(_ command: String, in source: String) -> String? {
        guard let decl = source.range(of: "struct \(command): ParsableCommand"),
              let run = source.range(of: "func run() throws {\n", range: decl.upperBound..<source.endIndex)
        else { return nil }
        return String(source[run.upperBound...].prefix { $0 != "\n" })
    }

    /// The first statement of top-level `func <name>(`, trimmed.
    private func firstStatement(ofFunction name: String, in source: String) -> String? {
        guard let decl = source.range(of: "\nfunc \(name)("),
              let open = source.range(of: "{\n", range: decl.upperBound..<source.endIndex)
        else { return nil }
        return String(source[open.upperBound...].prefix { $0 != "\n" })
            .trimmingCharacters(in: .whitespaces)
    }
}

import ArgumentParser
import XCTest
@testable import music

/// DoD 13 and ruling 12.14 at the call sites. `ActionRoutingTests` proves the
/// matrix refuses; these prove the CLI asks it, first, from every verb that can
/// change playback or would read Music.app's current track.
final class CLIBridgeGateTests: XCTestCase {

    // MARK: - The decision

    func testPlaybackVerbsRefuseWithTheRulingsWordsOnBridge() {
        let verbs: [MusicTUIAction] = [.cliPlayResume, .playPause, .next, .previous, .stop, .seek,
                                       .persistentShuffleMode, .persistentRepeatMode,
                                       .radioStationPlay, .playlistTemp]
        for action in verbs {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source), cliPlaybackDeferredInV1, "\(action)")
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source),
                           "Bridge output is selected, but CLI playback is not supported in v1. Use MusicTUI or switch Output to Music.app.")
        }
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
        XCTAssertThrowsError(try refuseInBridge(.cliPlayResume, mode: .source)) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
        XCTAssertNoThrow(try refuseInBridge(.cliPlayResume, mode: .musicApp))
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
            ("PlaybackCommands.swift", "Play"), ("PlaybackCommands.swift", "Pause"),
            ("PlaybackCommands.swift", "Skip"), ("PlaybackCommands.swift", "Back"),
            ("PlaybackCommands.swift", "Stop"), ("PlaybackCommands.swift", "Seek"),
            ("PlaybackCommands.swift", "Shuffle"), ("PlaybackCommands.swift", "Repeat_"),
            ("RadioCommands.swift", "RadioPlay"), ("PlaylistCommands.swift", "PlaylistTemp"),
            ("DiscoveryCommands.swift", "Similar"), ("DiscoveryCommands.swift", "Suggest"),
            ("DiscoveryCommands.swift", "NewReleases"), ("LoveCommands.swift", "Love"),
            ("LoveCommands.swift", "Unlove"), ("RemoveCommand.swift", "Remove"),
            ("AddCommand.swift", "Add"),
        ]
        for (file, command) in gated {
            let source = try String(contentsOf: commands.appendingPathComponent(file), encoding: .utf8)
            guard let decl = source.range(of: "struct \(command): ParsableCommand"),
                  let run = source.range(of: "func run() throws {\n", range: decl.upperBound..<source.endIndex)
            else { return XCTFail("\(command) not found in \(file)") }
            let firstLine = source[run.upperBound...].prefix { $0 != "\n" }
            XCTAssertTrue(firstLine.contains("try refuseInBridge("),
                          "\(command).run() must ask the Bridge gate first; it starts with: \(firstLine)")
        }
    }
}

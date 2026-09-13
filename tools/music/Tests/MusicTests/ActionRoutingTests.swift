// tools/music/Tests/MusicTests/ActionRoutingTests.swift
//
// Source Mode v1 section 6, encoded as a type rather than a table nobody checks.
//
// Codex's B1 was that "every playback action routes or refuses" is unfalsifiable
// while the set is open. A CaseIterable action enum closes it: the test below
// fails if anyone adds an action without deciding its route, which is the
// property DoD 3 actually needs.
import XCTest
@testable import music

final class ActionRoutingTests: XCTestCase {

    /// The gate for DoD 3. Every action, both modes, no gaps.
    func testEveryActionHasADefinedRouteInBothModes() {
        for action in MusicTUIAction.allCases {
            for mode in [PlaybackMode.musicApp, .source] {
                let route = routeAction(action, in: mode)
                if case .refused(let reason) = route {
                    XCTAssertFalse(reason.isEmpty,
                                   "\(action) refused in \(mode) with no reason")
                }
            }
        }
    }

    /// Binding rule 1: an install that never opens Output behaves exactly as it
    /// ships. So nothing is refused in Music.app mode.
    func testNothingIsRefusedInMusicAppMode() {
        for action in MusicTUIAction.allCases {
            if case .refused(let reason) = routeAction(action, in: .musicApp) {
                XCTFail("\(action) refused in Music.app mode: \(reason)")
            }
        }
    }

    /// Binding rule 3 and DoD 3: no PLAYBACK action reaches Music.app in Source
    /// Mode. It is either served by the source or refused.
    func testNoPlaybackActionReachesMusicAppInSourceMode() {
        for action in MusicTUIAction.allCases where action.touchesPlayback {
            let route = routeAction(action, in: .source)
            XCTAssertNotEqual(route, .musicApp,
                              "\(action) would reach Music.app in Source Mode")
        }
    }

    /// Anthony's rulings, spot-checked so a later edit cannot quietly reverse
    /// one. Each of these was decided rather than defaulted.
    func testAnthonysRulingsHold() {
        // 12.2: artist expands to songs, so it is served rather than blocked.
        XCTAssertEqual(routeAction(.cliPlayArtist, in: .source), .source)
        // 6.5: collection shuffle is served; persistent mode is refused.
        XCTAssertEqual(routeAction(.collectionShuffle, in: .source), .source)
        guard case .refused = routeAction(.persistentShuffleMode, in: .source) else {
            return XCTFail("persistent shuffle mode must be refused in v1")
        }
        // 12.1 + rule 9: the Library LISTING stays on AppleScript in both modes.
        XCTAssertEqual(routeAction(.libraryListing, in: .source), .musicApp)
        XCTAssertEqual(routeAction(.searchLibrary, in: .source), .musicApp)
        // AirPlay stays MusicTUI's, and does not act in Source Mode.
        guard case .refused = routeAction(.airplayRoute, in: .source) else {
            return XCTFail("AirPlay must not act in Source Mode")
        }
        // Library writes are refused; MusicTUI's own favourites are not.
        guard case .refused = routeAction(.loveTrack, in: .source) else {
            return XCTFail("love is an Apple Music library write")
        }
        XCTAssertEqual(routeAction(.radioFavourite, in: .source), .unaffected,
                       "radio favourites write MusicTUI's own StationStore")
    }

    /// `mix` creates and populates a playlist, which Codex reproduced at
    /// MixCommand.swift. It is a write, not a brokered read.
    func testMixIsAWriteNotARead() {
        guard case .refused = routeAction(.cliMix, in: .source) else {
            return XCTFail("mix creates a playlist and must be refused")
        }
    }

    // MARK: - The spec, transcribed independently of routeAction

    /// Only the route's kind; refusal wording is free to change.
    private enum Kind { case source, musicApp, unaffected, refused }

    private func kind(_ route: ActionRoute) -> Kind {
        switch route {
        case .source: return .source
        case .musicApp: return .musicApp
        case .unaffected: return .unaffected
        case .refused: return .refused
        }
    }

    /// Source Mode's expected outcome for every action, read row by row from
    /// section 6 of the revision 5 spec as amended by ruling 12.7, NOT from
    /// routeAction.
    ///
    /// Codex B4 (2026-09-13): the tests above prove every action gets SOME route,
    /// which let routeAction refuse `eq` and `visualizer` while the spec marks
    /// them Unaffected. A dispatcher checked against routeAction would inherit
    /// that error. This table is the independent statement it is checked against.
    ///
    /// The spec's "Unaffected" means "runs as it does in Music.app mode", so a
    /// row that reads or sets Music.app state is `.musicApp` here, and
    /// `.unaffected` is kept for rows that touch neither player.
    private let specSourceMode: [MusicTUIAction: Kind] = [
        // 6.1 global keys
        .playPause: .source, .next: .source, .previous: .source,
        .collectionShuffle: .source, .volume: .refused,
        // 6.2 Now Playing
        .queueJump: .source, .seek: .source,
        .persistentShuffleMode: .refused, .persistentRepeatMode: .refused,
        .loveTrack: .refused, .genius: .refused,
        // `x` Quiet pauses the player (NowPlayingScene.swift:619). Anthony's
        // ruling 12.7, amending revision 5's "Unaffected": it pauses the source.
        .quiet: .source,
        // 6.3 scenes
        .libraryPlay: .source, .playlistPlay: .source,
        .discoverTrackPlay: .source, .discoverPlayAll: .source,
        .discoverRefresh: .source, .radioStationPlay: .source, .radioSearch: .source,
        .libraryArtistTierFilter: .unaffected, .playlistsOpenNowPlaying: .unaffected,
        // `r` retries the Library listing, which stays on AppleScript (rule 9).
        .libraryRetry: .musicApp,
        .radioFavourite: .unaffected, .radioAddURL: .unaffected,
        // 6.4 CLI
        .cliPlayResume: .source, .cliPlayIndex: .source, .cliPlayPlaylist: .source,
        .cliPlayAlbum: .source, .cliPlaySong: .source, .cliPlayArtist: .source,
        .stop: .source, .recent: .source, .newReleases: .source,
        .catalogSearch: .source, .discoverFeed: .source,
        .rotation: .refused, .similar: .refused, .suggest: .refused,
        .searchLibrary: .musicApp, .libraryListing: .musicApp, .playlistListing: .musicApp,
        .addToLibrary: .refused, .removeFromLibrary: .refused, .playlistWrite: .refused,
        .playlistTemp: .refused, .cliMix: .refused, .airplayRoute: .refused,
        // Outward, but it reads the playlist's tracks over AppleScript
        // (PlaylistCommands.swift:1033).
        .playlistShare: .musicApp,
        // Unaffected: EQ and the visualizer set Music.app state; auth writes
        // MusicTUI's own config.
        .eq: .musicApp, .visualizer: .musicApp, .auth: .unaffected,
    ]

    /// The table covers the closed set. Adding an action fails here until its
    /// spec row is written down, not only until routeAction returns something.
    func testSpecTableCoversEveryAction() {
        for action in MusicTUIAction.allCases {
            XCTAssertNotNil(specSourceMode[action], "\(action) has no spec row in this test")
        }
    }

    func testSourceModeRoutesMatchTheSpec() {
        for action in MusicTUIAction.allCases {
            guard let expected = specSourceMode[action] else { continue }
            XCTAssertEqual(kind(routeAction(action, in: .source)), expected,
                           "\(action) disagrees with spec section 6")
        }
    }

    /// Rows that act the same in both modes must route the same in both modes.
    /// Catches the `playlistShare` shape: `.unaffected` in one mode and
    /// `.musicApp` in the other for the same AppleScript code.
    func testRowsNotChangedBySourceModeRouteIdenticallyInBothModes() {
        for action in MusicTUIAction.allCases {
            let source = routeAction(action, in: .source)
            guard source == .musicApp || source == .unaffected else { continue }
            XCTAssertEqual(routeAction(action, in: .musicApp), source,
                           "\(action) is unchanged by Source Mode but routes differently")
        }
    }

    /// Quiet pauses the player, so it counts as playback for rule 3.
    func testQuietTouchesPlayback() {
        XCTAssertTrue(MusicTUIAction.quiet.touchesPlayback)
    }
}

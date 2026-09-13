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
}

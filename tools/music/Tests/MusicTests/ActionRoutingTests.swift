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
                let route = routeAction(action, in: mode, from: .tui)
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
            if case .refused(let reason) = routeAction(action, in: .musicApp, from: .tui) {
                XCTFail("\(action) refused in Music.app mode: \(reason)")
            }
        }
    }

    /// Binding rule 3 and DoD 3: no PLAYBACK action reaches Music.app in Source
    /// Mode. It is either served by the source or refused.
    func testNoPlaybackActionReachesMusicAppInSourceMode() {
        for action in MusicTUIAction.allCases where action.touchesPlayback {
            let route = routeAction(action, in: .source, from: .tui)
            XCTAssertNotEqual(route, .musicApp,
                              "\(action) would reach Music.app in Source Mode")
        }
    }

    /// Anthony's rulings, spot-checked so a later edit cannot quietly reverse
    /// one. Each of these was decided rather than defaulted.
    func testAnthonysRulingsHold() {
        // 12.2: an artist expands to SONGS rather than being blocked as
        // unplayable. Served in Music.app mode, and (slice 3 S7) dispatched to
        // Bridge from the CLI, where it plays the artist's songs too.
        XCTAssertEqual(routeAction(.cliPlayArtist, in: .musicApp, from: .cli), .musicApp)
        XCTAssertEqual(routeAction(.cliPlayArtist, in: .source, from: .cli), .source)
        // 6.5: collection shuffle is served; persistent mode is refused.
        XCTAssertEqual(routeAction(.collectionShuffle, in: .source, from: .tui), .source)
        guard case .refused = routeAction(.persistentShuffleMode, in: .source, from: .tui) else {
            return XCTFail("persistent shuffle mode must be refused in v1")
        }
        // 12.13: the queue-row jump is deferred from v1 and must refuse visibly.
        guard case .refused = routeAction(.queueJump, in: .source, from: .tui) else {
            return XCTFail("queue-row jump is deferred from v1 and must refuse")
        }
        // 12.1 + rule 9: the Library LISTING stays on AppleScript in both modes.
        XCTAssertEqual(routeAction(.libraryListing, in: .source, from: .tui), .musicApp)
        XCTAssertEqual(routeAction(.searchLibrary, in: .source, from: .tui), .musicApp)
        // AirPlay stays MusicTUI's, and does not act in Source Mode.
        guard case .refused = routeAction(.airplayRoute, in: .source, from: .tui) else {
            return XCTFail("AirPlay must not act in Source Mode")
        }
        // Library writes are refused; MusicTUI's own favourites are not.
        guard case .refused = routeAction(.loveTrack, in: .source, from: .tui) else {
            return XCTFail("love is an Apple Music library write")
        }
        XCTAssertEqual(routeAction(.radioFavourite, in: .source, from: .tui), .unaffected,
                       "radio favourites write MusicTUI's own StationStore")
    }

    /// `mix` creates and populates a playlist, which Codex reproduced at
    /// MixCommand.swift. It is a write, not a brokered read — so it must never
    /// reach the source, from any surface, in any mode. Stated this way rather
    /// than as "refused", because 12.13 defers CLI routing and a deferred verb
    /// behaves as it ships instead of being refused.
    func testMixNeverReachesTheSource() {
        for mode in [PlaybackMode.musicApp, .source] {
            for surface in InvocationSurface.allCases {
                XCTAssertNotEqual(routeAction(.cliMix, in: mode, from: surface), .source,
                                  "mix creates a playlist and must never be brokered")
            }
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
        // Ruling 12.13 deferred the queue-row jump from v1: spec 6.2 and DoD 3
        // require a VISIBLE refusal, not a source route. 933e85d predates the
        // narrowing and routed it to the source.
        .queueJump: .refused, .seek: .source,
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
        // Anthony, 2026-09-16 13:36. Explicit library management keeps working;
        // anything reading Music.app's current track refuses. These are the TUI
        // column: every one of them is CLI-only, so the CLI clause decides the
        // reachable case and these rows pin the unreachable one.
        .addToLibrary: .refused, .playlistWrite: .refused,
        .addCurrentTrackToPlaylist: .refused,
        .removeCurrentTrackFromPlaylist: .refused,
        .similarToCurrentTrack: .refused, .suggestFromCurrentTrack: .refused,
        .newReleasesLikeCurrentTrack: .refused,
        .playlistTemp: .refused, .cliMix: .refused, .airplayRoute: .refused,
        // Outward, but it reads the playlist's tracks over AppleScript
        // (PlaylistCommands.swift:1033).
        .playlistShare: .musicApp,
        // Unaffected: EQ and the visualizer set Music.app state; auth writes
        // MusicTUI's own config.
        .eq: .musicApp, .visualizer: .musicApp, .auth: .unaffected,
        // Slice 3 D7: `music now`'s read. CLI-only; its TUI row is the
        // unreachable one, pinned so it is decided rather than defaulted.
        .nowStatus: .source,
        // Slice 3 D7: `music play <words>` and `music play <Apple Music link>`.
        // CLI-only, like the other `.cliPlay*` rows; their TUI rows are
        // unreachable and decided with those rows, not defaulted.
        .cliPlayQuery: .source, .cliPlayCatalogSong: .source,
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
            XCTAssertEqual(kind(routeAction(action, in: .source, from: .tui)), expected,
                           "\(action) disagrees with spec section 6")
        }
    }

    /// Rows that act the same in both modes must route the same in both modes.
    /// Catches the `playlistShare` shape: `.unaffected` in one mode and
    /// `.musicApp` in the other for the same AppleScript code.
    func testRowsNotChangedBySourceModeRouteIdenticallyInBothModes() {
        for action in MusicTUIAction.allCases {
            let source = routeAction(action, in: .source, from: .tui)
            guard source == .musicApp || source == .unaffected else { continue }
            XCTAssertEqual(routeAction(action, in: .musicApp, from: .tui), source,
                           "\(action) is unchanged by Source Mode but routes differently")
        }
    }

    /// Quiet pauses the player, so it counts as playback for rule 3.
    func testQuietTouchesPlayback() {
        XCTAssertTrue(MusicTUIAction.quiet.touchesPlayback)
    }

    // MARK: - Ruling 12.14: the TUI/CLI distinction

    /// Rows with no invoker anywhere in the tree, named so a new one cannot
    /// appear silently. Currently EMPTY: the 2026-09-16 survey flagged
    /// `removeFromLibrary` as having none, and the row turned out to be
    /// `music remove` under a wrong name — it removes the CURRENT track from a
    /// playlist, not anything from the library. It is now
    /// `removeCurrentTrackFromPlaylist`.
    private let actionsWithNoInvoker: Set<MusicTUIAction> = []

    /// The closed set now has a second axis. An action with no declared surface
    /// cannot be reasoned about: it would silently escape both the CLI refusal
    /// gate below and the TUI coverage gate above.
    func testEveryActionDeclaresItsSurfacesOrIsAKnownPhantom() {
        for action in MusicTUIAction.allCases {
            if action.surfaces.isEmpty {
                XCTAssertTrue(actionsWithNoInvoker.contains(action),
                              "\(action) has no invoking surface and is not a recorded phantom")
            } else {
                XCTAssertFalse(actionsWithNoInvoker.contains(action),
                               "\(action) is recorded as having no invoker but declares \(action.surfaces)")
            }
        }
    }

    // MARK: - Slice 3 D7: the closed CLI clause (S6)

    /// The dispatched set after S7, as a literal: S6's `now` and five
    /// transport verbs, then S7's `music play` forms (resume, index, playlist,
    /// album, song, artist) and `search --library`. Free words and Apple Music
    /// links are NOT in it (Anthony's Q1 ruling; catalogue play deferred).
    private let s7Dispatched: Set<MusicTUIAction> = [
        .nowStatus, .playPause, .next, .previous, .seek, .stop,
        .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong, .cliPlayArtist,
        .searchLibrary,
    ]

    func testTheDispatchedSetIsExactlyS7s() {
        XCTAssertEqual(cliDispatchedOnBridge, s7Dispatched)
        XCTAssertFalse(cliDispatchedOnBridge.contains(.cliPlayQuery), "Q1: plain music play <words> refuses")
        XCTAssertFalse(cliDispatchedOnBridge.contains(.cliPlayCatalogSong), "catalogue play is deferred")
        XCTAssertFalse(cliDispatchedOnBridge.contains(.collectionShuffle))
    }

    /// D7: with Bridge selected the CLI clause is closed. Each action is
    /// dispatched, refused for the stale current track, a named exception, or
    /// refused with its not-served reason. There is no blanket default.
    func testTheCliClauseIsClosed() {
        for action in MusicTUIAction.allCases {
            let route = routeAction(action, in: .source, from: .cli)
            if s7Dispatched.contains(action) {
                XCTAssertEqual(route, .source, "\(action) is dispatched to Bridge")
            } else if action.readsMusicAppCurrentTrack {
                XCTAssertEqual(route, .refused(currentTrackIsStaleInBridge), "\(action)")
            } else if cliBridgeExceptions.contains(action) {
                XCTAssertEqual(route, routeAction(action, in: .musicApp, from: .cli),
                               "\(action) is a named exception and runs as it ships")
            } else {
                XCTAssertEqual(route, .refused(cliBridgeNotServedReason(action)), "\(action)")
            }
        }
    }

    /// S6 keeps today's behaviour for everything that is neither dispatched,
    /// a current-track reader, nor playback: those are the temporary exception
    /// set, written as a literal in ActionRouting.swift until S8 narrows it.
    func testTheExceptionSetIsEverythingNeitherDispatchedCurrentTrackNorPlayback() {
        let expected = Set(MusicTUIAction.allCases.filter {
            !s7Dispatched.contains($0) && !$0.readsMusicAppCurrentTrack && !$0.touchesPlayback
        })
        XCTAssertEqual(cliBridgeExceptions, expected)
        XCTAssertTrue(cliBridgeExceptions.isDisjoint(with: cliDispatchedOnBridge))
    }

    /// Every playback-changing CLI verb that is not dispatched still refuses
    /// in its D7 words, and none falls back to Music.app.
    func testEveryUndispatchedPlaybackCliCommandRefusesInSourceMode() {
        var checked = 0
        for action in MusicTUIAction.allCases
        where action.surfaces.contains(.cli) && action.touchesPlayback && !s7Dispatched.contains(action) {
            checked += 1
            guard case .refused(let reason) = routeAction(action, in: .source, from: .cli) else {
                XCTFail("\(action) is a playback-changing CLI verb Bridge does not serve yet; it must refuse")
                continue
            }
            XCTAssertEqual(reason, cliBridgeNotServedReason(action), "\(action)")
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// D7's wording, pinned: shuffle/repeat modes, volume and AirPlay keep the
    /// TUI table's reasons; everything else names what is not served.
    func testNotServedReasonsAreD7s() {
        for action in [MusicTUIAction.persistentShuffleMode, .persistentRepeatMode, .volume, .airplayRoute] {
            guard case .refused(let tui) = routeAction(action, in: .source, from: .tui) else {
                return XCTFail("\(action) must be refused in the TUI table")
            }
            XCTAssertEqual(cliBridgeNotServedReason(action), tui, "\(action) keeps its TUI-table reason")
        }
        XCTAssertEqual(cliBridgeNotServedReason(.persistentShuffleMode),
                       "Shuffle and repeat modes are Music.app only for now")
        XCTAssertEqual(routeAction(.cliPlayQuery, in: .source, from: .cli),
                       .refused("Bridge output is selected, and music play <words> isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app."))
        XCTAssertEqual(routeAction(.cliPlayCatalogSong, in: .source, from: .cli),
                       .refused("Bridge output is selected, and music play <Apple Music link> isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app."))
        XCTAssertEqual(cliBridgeNotServedReason(.radioStationPlay),
                       "Bridge output is selected, and music radio play isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app.")
    }

    /// 12.14's v1 sentence is deleted (S6): no source file names it or says
    /// "not supported in v1" any more.
    func testTheV1DeferralSentenceIsDeleted() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("cliPlaybackDeferredInV1"), file.lastPathComponent)
            XCTAssertFalse(text.contains("CLI playback is not supported in v1"), file.lastPathComponent)
        }
    }

    /// The other half: a CLI command that is not dispatched, not playback and
    /// not a current-track reader is UNCHANGED, as it ships (S6; S8 narrows).
    ///
    /// NOTE, for Anthony (kept from 12.14). The CLI has non-playback WRITES
    /// (`mix`, `add`, `playlist create/delete/...`); they stay with the reads,
    /// "unchanged", by his 2026-09-16 13:36 ruling on library management.
    func testNonPlaybackCliCommandsAreUnchangedInSourceMode() {
        for action in MusicTUIAction.allCases
        where action.surfaces.contains(.cli)
            && !action.touchesPlayback
            && !action.readsMusicAppCurrentTrack
            && !s7Dispatched.contains(action) {
            XCTAssertEqual(routeAction(action, in: .source, from: .cli),
                           routeAction(action, in: .musicApp, from: .cli),
                           "\(action) neither plays nor reads the current track: it must ship unchanged")
        }
    }

    /// The distinction still has to BITE for what Bridge does not serve from
    /// the CLI: a dual-surface playback action that is not dispatched is served
    /// from the TUI and refused from the CLI.
    func testTheSameActionIsServedFromTheTuiAndRefusedFromTheCli() {
        let dual = MusicTUIAction.allCases.filter {
            $0.surfaces.contains(.tui) && $0.surfaces.contains(.cli) && $0.touchesPlayback
                && !s7Dispatched.contains($0)
        }
        XCTAssertFalse(dual.isEmpty, "no undispatched dual-surface playback action: the test proves nothing")
        var served = 0
        for action in dual {
            guard case .refused = routeAction(action, in: .source, from: .cli) else {
                XCTFail("\(action) from the CLI must refuse in Source Mode")
                continue
            }
            if routeAction(action, in: .source, from: .tui) == .source { served += 1 }
        }
        XCTAssertGreaterThan(served, 0,
                             "every undispatched dual-surface playback row refuses from the TUI too")
    }

    /// The dispatched verbs are served from BOTH surfaces with Bridge selected,
    /// and still go to Music.app with Music.app selected. The one exception is
    /// `searchLibrary`, whose TUI column stays on AppleScript (ruling 12.1,
    /// rule 9): S7 changes the CLI clause only, never the TUI column.
    func testDispatchedVerbsAreServedFromBothSurfaces() {
        for action in s7Dispatched {
            XCTAssertEqual(routeAction(action, in: .source, from: .cli), .source, "\(action)")
            XCTAssertEqual(routeAction(action, in: .source, from: .tui),
                           action == .searchLibrary ? .musicApp : .source, "\(action)")
            XCTAssertEqual(routeAction(action, in: .musicApp, from: .cli), .musicApp, "\(action)")
        }
    }

    /// Every `music play` form touches playback, so Music.app mode holds the
    /// output lock for it (D6), including the two Bridge refuses.
    func testEveryPlayFormIsPlaybackAndTakesTheLock() {
        for action in [MusicTUIAction.cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum,
                       .cliPlaySong, .cliPlayArtist, .cliPlayQuery, .cliPlayCatalogSong] {
            XCTAssertTrue(action.touchesPlayback, "\(action)")
            XCTAssertTrue(requiresOutputLock(action), "\(action)")
            XCTAssertEqual(action.surfaces, [.cli], "\(action)")
        }
        XCTAssertFalse(requiresOutputLock(.searchLibrary), "a read takes no lock")
    }

    /// Music.app mode is untouched by the surface (binding rule 1): an install
    /// that never opens Output behaves exactly as it ships, from either surface.
    func testSurfaceDoesNotChangeMusicAppMode() {
        for action in MusicTUIAction.allCases {
            XCTAssertEqual(routeAction(action, in: .musicApp, from: .tui),
                           routeAction(action, in: .musicApp, from: .cli),
                           "\(action) routes differently by surface in Music.app mode")
        }
    }

    // MARK: - Anthony's ruling, 2026-09-16 13:36: the stale current track

    /// "Bridge selection should not disable unrelated library management, but
    /// nothing may silently interpret 'current track' as Music.app's stale
    /// track." While Bridge plays, Music.app's `current track` is whatever it
    /// was left on, so a verb that reads it would mutate or seed from the wrong
    /// song.
    func testEveryCurrentTrackReaderRefusesInSourceMode() {
        let expected: Set<MusicTUIAction> = [
            .loveTrack,                      // LoveCommands.swift:31, sets favorited of current track
            .removeCurrentTrackFromPlaylist, // RemoveCommand.swift:13
            .addCurrentTrackToPlaylist,      // AddCommand.swift:131
            .similarToCurrentTrack,          // DiscoveryCommands.swift:26
            .suggestFromCurrentTrack,        // DiscoveryCommands.swift:126
            .newReleasesLikeCurrentTrack,    // DiscoveryCommands.swift:219
        ]
        XCTAssertEqual(Set(MusicTUIAction.allCases.filter { $0.readsMusicAppCurrentTrack }),
                       expected,
                       "the set of current-track readers changed without a ruling")

        for action in expected where action.surfaces.contains(.cli) {
            guard case .refused(let reason) = routeAction(action, in: .source, from: .cli) else {
                return XCTFail("\(action) reads Music.app's current track and must refuse")
            }
            XCTAssertEqual(reason, currentTrackIsStaleInBridge,
                           "\(action) refused without saying why the track is wrong")
        }
    }

    /// The other half of the same ruling: explicit library management KEEPS
    /// WORKING. These name their target, so nothing can resolve to a stale
    /// track. A regression here would disable exactly what Anthony ruled must
    /// stay available.
    func testExplicitLibraryManagementKeepsWorkingFromTheCli() {
        for action in [MusicTUIAction.addToLibrary, .playlistWrite, .cliMix,
                       .similar, .suggest, .newReleases] {
            XCTAssertFalse(action.readsMusicAppCurrentTrack,
                           "\(action) is the EXPLICIT variant and must not read the current track")
            XCTAssertEqual(routeAction(action, in: .source, from: .cli),
                           routeAction(action, in: .musicApp, from: .cli),
                           "\(action) names its own target and must ship unchanged")
        }
    }

    /// `playlist temp` is refused, and for its own reason: it exists to start
    /// Music.app playback, so it is playback-changing rather than
    /// current-track-dependent. Pinned so a later edit cannot reclassify it.
    func testPlaylistTempRefusesAsPlaybackNotAsCurrentTrack() {
        XCTAssertTrue(MusicTUIAction.playlistTemp.touchesPlayback)
        XCTAssertFalse(MusicTUIAction.playlistTemp.readsMusicAppCurrentTrack)
        guard case .refused(let reason) = routeAction(.playlistTemp, in: .source, from: .cli) else {
            return XCTFail("playlist temp starts Music.app playback and must refuse")
        }
        XCTAssertEqual(reason, "Bridge output is selected, and music playlist temp isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app.")
    }

    /// A split variant pair must not both claim the same behaviour: the point of
    /// splitting was that one names its target and the other does not.
    func testSplitVariantsDisagreeAboutTheCurrentTrack() {
        for (explicit, current) in [
            (MusicTUIAction.addToLibrary, MusicTUIAction.addCurrentTrackToPlaylist),
            (.similar, .similarToCurrentTrack),
            (.suggest, .suggestFromCurrentTrack),
            (.newReleases, .newReleasesLikeCurrentTrack),
        ] {
            XCTAssertNotEqual(explicit.readsMusicAppCurrentTrack,
                              current.readsMusicAppCurrentTrack,
                              "\(explicit) and \(current) were split but classify identically")
        }
    }
}

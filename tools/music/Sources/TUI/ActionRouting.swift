// Source Mode v1's routing matrix, as a closed type.
//
// Section 6 of docs/plans/2026-09-12-source-mode-v1-spec.md, Anthony's GO
// 2026-09-13. The spec's table is the prose form; this is the enforced one.
//
// **Why a CaseIterable enum rather than a table.** Codex's Blocking finding B1
// was that "every playback action routes or refuses" cannot be falsified while
// the set of actions is open, and that revision 2's table was neither closed nor
// accurate: it refused Library `a` (an artist tier filter), refused Playlists
// `b` (opening Now Playing), classified `mix` as a read when it creates a
// playlist, and omitted `recent` and `rotation` entirely. A closed enum makes
// the gate mechanical: `ActionRoutingTests` fails if anyone adds an action
// without deciding its route.
//
// Purely presentational actions are deliberately absent: cursor movement, scene
// switching, quitting, filter typing. They touch neither player nor catalogue,
// so routing them would pad the set without making anything falsifiable.
import Foundation

/// Every MusicTUI action that touches playback, the catalogue, or the library.
/// Read from the keymaps and the CLI subcommand list, not recalled.
enum MusicTUIAction: CaseIterable, Equatable {
    // Transport, global and CLI
    case playPause, next, previous, seek, stop
    case queueJump
    case collectionShuffle          // "play this set in random order"
    case persistentShuffleMode      // Now `s`/`m`, control grid, `music shuffle`
    case persistentRepeatMode       // Now `r`, `music repeat`
    case volume

    // Playback entry points
    case libraryPlay, playlistPlay, discoverTrackPlay, discoverPlayAll, radioStationPlay
    case cliPlayResume, cliPlayIndex, cliPlayPlaylist, cliPlayAlbum, cliPlaySong, cliPlayArtist

    // Reads
    case libraryListing, playlistListing, discoverFeed, discoverRefresh
    case catalogSearch, searchLibrary, radioSearch, recent, rotation, newReleases
    case similar, suggest

    // Writes, and things that look like writes but are not
    case loveTrack, addToLibrary, removeFromLibrary
    case playlistWrite              // create/delete/add/remove/create-from/cleanup
    case playlistTemp, playlistShare
    case cliMix
    case radioFavourite, radioAddURL   // MusicTUI's OWN StationStore

    // Music.app-specific surfaces
    case genius, airplayRoute, eq, visualizer, quiet
    case libraryArtistTierFilter, playlistsOpenNowPlaying, libraryRetry

    // MusicTUI's own configuration
    case auth

    /// Whether this action drives a player. Used by the test that proves no
    /// playback action reaches Music.app in Source Mode.
    ///
    /// `quiet` is here because it pauses (NowPlayingScene.swift:619), which
    /// `933e85d` missed by classifying it from its name.
    var touchesPlayback: Bool {
        switch self {
        case .playPause, .next, .previous, .seek, .stop, .queueJump,
             .collectionShuffle, .persistentShuffleMode, .persistentRepeatMode,
             .libraryPlay, .playlistPlay, .discoverTrackPlay, .discoverPlayAll,
             .radioStationPlay, .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist,
             .cliPlayAlbum, .cliPlaySong, .cliPlayArtist, .playlistTemp, .quiet:
            return true
        default:
            return false
        }
    }
}

/// Where an action goes.
enum ActionRoute: Equatable {
    /// Served by the source app.
    case source
    /// Served by the existing Music.app path. In Source Mode this appears ONLY
    /// for rows the spec leaves as they are: the listing reads under binding
    /// rule 9's carve-out, and the Music.app settings and reads section 6.4
    /// marks Unaffected (EQ, visualizer, playlist share). Never for playback.
    case musicApp
    /// Neither player is involved: MusicTUI's own local state or navigation.
    case unaffected
    /// Not served in this mode, with a reason a person can act on. Never a
    /// silent no-op.
    case refused(String)
}

/// The matrix. Every case decided; nothing defaults.
func routeAction(_ action: MusicTUIAction, in mode: PlaybackMode) -> ActionRoute {
    // Binding rule 1: an install that never opens Output behaves exactly as it
    // ships. Everything that is not purely local goes to Music.app.
    guard mode == .source else {
        switch action {
        case .radioFavourite, .radioAddURL, .auth,
             .libraryArtistTierFilter, .playlistsOpenNowPlaying:
            return .unaffected
        default:
            return .musicApp
        }
    }

    switch action {

    // Served by the source. `quiet` is "stop here", a pause, so it pauses the
    // source: Anthony's ruling 12.7 (2026-09-13), "playback controls always
    // target the selected output mode".
    case .playPause, .next, .previous, .seek, .stop, .queueJump, .quiet,
         .libraryPlay, .playlistPlay, .discoverTrackPlay, .discoverPlayAll,
         .radioStationPlay,
         .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong,
         .discoverFeed, .discoverRefresh, .catalogSearch, .radioSearch,
         .recent, .newReleases:
        return .source

    /// Anthony's ruling 12.2: an artist expands to that artist's SONGS, matching
    /// MusicTUI's existing behaviour. `Artist` is not `PlayableMusicItem`, so
    /// the expansion is required rather than optional.
    case .cliPlayArtist:
        return .source

    /// Section 6.5. Randomising the requested ids before building the queue
    /// needs no MusicKit shuffle mode, so this is served where the persistent
    /// mode below is not.
    case .collectionShuffle:
        return .source

    // Binding rule 9's carve-out: the Library LISTING stays on AppleScript in
    // BOTH modes (Anthony's ruling 12.1), so both modes show the same library.
    // A read chosen in advance and identical in both modes is the opposite of a
    // silent fallback, which is what rule 3 forbids.
    // `r` in Library retries that same listing read.
    case .libraryListing, .playlistListing, .searchLibrary, .libraryRetry:
        return .musicApp

    // Section 6.4 marks these Unaffected: they run exactly as in Music.app
    // mode, which means AppleScript. EQ and the visualizer set Music.app state,
    // and share reads the playlist's tracks (PlaylistCommands.swift:1033) before
    // sending. Codex B4: `933e85d` refused EQ and visualizer against the spec.
    case .eq, .visualizer, .playlistShare:
        return .musicApp

    // MusicTUI's own state or navigation. Radio favourites write StationStore,
    // not the Apple Music library: refusing them would conflate any local state
    // with a library write (Codex I4). `auth` writes MusicTUI's own config.
    case .radioFavourite, .radioAddURL, .auth,
         .libraryArtistTierFilter, .playlistsOpenNowPlaying:
        return .unaffected

    // Refused, each with what to do instead.
    case .persistentShuffleMode, .persistentRepeatMode:
        return .refused("Shuffle and repeat modes are Music.app only for now")
    case .volume:
        return .refused("Volume is Music.app only; the source plays at the Mac's output level")
    case .loveTrack, .addToLibrary, .removeFromLibrary, .playlistWrite:
        return .refused("Library changes are Music.app only in this version")
    case .cliMix:
        // Codex B1: mix calls api.createPlaylist and populates it.
        return .refused("mix creates a playlist, which is Music.app only in this version")
    case .playlistTemp:
        return .refused("Temporary playlists exist to bound Music.app; the source builds its own queue")
    case .similar, .suggest:
        return .refused("Not available through the source app in this version")
    case .rotation:
        // `rotation` calls REST /v1/me/history/heavy-rotation (HistoryCommands.swift:53);
        // v1 names no brokered MusicKit route for it (Codex, 11:47).
        return .refused("Heavy rotation has no MusicTUI Source route in this version")
    case .genius:
        return .refused("Genius is a Music.app feature")
    case .airplayRoute:
        // Anthony, 2026-09-13: "airplay stays in TUI. the point of the bridge is
        // DAC not airplay."
        return .refused("AirPlay applies in Music.app mode; the source plays to the Mac's wired output")
    }
}

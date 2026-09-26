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
    /// Slice 3 D7: `music play <words>` (free words) and `music play <Apple
    /// Music link>`, split from `cliPlayResume` so the matrix can refuse them
    /// on Bridge while the other forms dispatch (Anthony's Q1 ruling; the link
    /// is catalogue play, deferred).
    case cliPlayQuery, cliPlayCatalogSong

    // Reads
    case playlistListing, discoverFeed, discoverRefresh
    case catalogSearch, searchLibrary, radioSearch, recent, rotation
    /// `music now` (and bare `music` off a TTY): the CLI's read of what the
    /// selected output is playing (slice 3, D7). A read, not playback.
    case nowStatus
    /// Slice 3 Part 2, D3. Radio's Live and Personal lists — wired by P5,
    /// which chooses a provider per fetch and drops a result whose epoch has
    /// moved on. TUI-only for now.
    case radioCatalogueBrowse
    /// Slice 3 Part 2, D3. `radio add URL`'s enrichment lookup, split from
    /// `radioAddURL` (which saves the favourite from the slug and stays
    /// MusicTUI's own state): this is the read that fills in the station's
    /// real name from whichever provider is chosen. Both surfaces since P7
    /// wired the CLI's `radio add`.
    case radioStationLookup
    // Each of these three is two verbs wearing one name: an explicit target, or
    // Music.app's current track when none is given (DiscoveryCommands.swift:20,
    // :123, :214). They are split because Anthony's 2026-09-16 ruling treats the
    // two halves differently.
    case newReleases, newReleasesLikeCurrentTrack
    case similar, similarToCurrentTrack
    case suggest, suggestFromCurrentTrack

    // Writes, and things that look like writes but are not.
    //
    // `addToLibrary` is the EXPLICIT variant (`music add <query|index|id>`);
    // `addCurrentTrackToPlaylist` is `music add --to X` with no song named
    // (AddCommand.swift:128-138). `removeCurrentTrackFromPlaylist` is
    // `music remove`, which was called `removeFromLibrary` until 2026-09-16:
    // it removes the CURRENT track from a playlist and never touches the
    // library, which is why a survey could find no library-level delete for it.
    case loveTrack, addToLibrary, addCurrentTrackToPlaylist, removeCurrentTrackFromPlaylist
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
             .cliPlayAlbum, .cliPlaySong, .cliPlayArtist, .cliPlayQuery, .cliPlayCatalogSong,
             .playlistTemp, .quiet:
            return true
        default:
            return false
        }
    }
}

extension MusicTUIAction {

    /// Whether this action resolves its target by reading **Music.app's**
    /// `current track`.
    ///
    /// Anthony, 2026-09-16 13:36: "Bridge selection should not disable unrelated
    /// library management, but nothing may silently interpret 'current track' as
    /// Music.app's stale track." While Bridge is playing, Music.app is paused on
    /// whatever it was left on, so these verbs would favourite, delete from a
    /// playlist, or seed recommendations from the WRONG song — silently, with a
    /// plausible-looking result.
    ///
    /// This is a different failure from `touchesPlayback`. A playback verb is
    /// deferred because v1 does not route the CLI (12.13/12.14); these are
    /// refused because their answer would be wrong. They need separate wording,
    /// so a person is told which problem they have hit.
    ///
    /// Decided from the code: every `current track` read under `Commands/` was
    /// enumerated, not inferred from verb names.
    var readsMusicAppCurrentTrack: Bool {
        switch self {
        case .loveTrack,                      // LoveCommands.swift:31
             .removeCurrentTrackFromPlaylist, // RemoveCommand.swift:13
             .addCurrentTrackToPlaylist,      // AddCommand.swift:131
             .similarToCurrentTrack,          // DiscoveryCommands.swift:26
             .suggestFromCurrentTrack,        // DiscoveryCommands.swift:126
             .newReleasesLikeCurrentTrack:    // DiscoveryCommands.swift:219
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

/// Where an action was invoked from. Ruling 12.14 requires that, while Bridge is
/// selected, a playback-changing CLI command refuses while the same action from
/// the TUI is served — so the route cannot be a function of the action and the
/// mode alone.
///
/// **Why a parameter and not more cases.** Twin `cliNext`, `cliStop`, `cliSeek`
/// cases would double the transport rows and model "where it was invoked from"
/// as though it were "what it is". The surface is orthogonal to the action.
///
/// A process is ONE surface, so `RoutingCoordinator` holds it rather than taking
/// it per call: a TUI call site cannot then accidentally claim to be the CLI.
enum InvocationSurface: String, CaseIterable, Equatable {
    case tui, cli
}

extension MusicTUIAction {

    /// The surfaces that can actually invoke this action, decided from the key
    /// maps and the subcommand list on 2026-09-16 — never from the case name.
    /// That rule is why `libraryArtistTierFilter` is TUI-only (`a` cycles a
    /// filter, it does not add to the library) and why `catalogSearch` is
    /// CLI-only (Library's `/` filters rows already loaded, it does not search).
    ///
    /// An EMPTY set means no invoker exists anywhere in the tree. It is not a
    /// placeholder: `ActionRoutingTests` names every such row, so a new one
    /// cannot appear without being noticed.
    var surfaces: Set<InvocationSurface> {
        switch self {

        // Both. Transport reachable from a key and a verb.
        case .playPause,            // Shell.swift:304 space / PlaybackCommands.swift:582 pause
             .next,                 // Shell.swift:321 > . F9 / PlaybackCommands.swift:591 skip
             .previous,             // Shell.swift:332 < , F7 / PlaybackCommands.swift:601 back
             .seek,                 // NowPlayingScene.swift:659 [ ] / PlaybackCommands.swift:794
             .collectionShuffle,    // Shell.swift:343 z, Library/Playlists s / PlayParser.swift:27
             .persistentShuffleMode,// NowPlayingScene.swift:754 s, :756 m / PlaybackCommands.swift:824
             .persistentRepeatMode, // NowPlayingScene.swift:758 r / PlaybackCommands.swift:855
             .volume,               // Shell.swift:306 + - = / VolumeCommands.swift:4
             .radioStationPlay,     // RadioScene.swift:160, DiscoverScene.swift:290 / RadioCommands.swift:27
             .radioSearch,          // RadioScene.swift:173 / / RadioCommands.swift:85
             .radioAddURL,          // RadioScene.swift:174 a / RadioCommands.swift:68
             .radioStationLookup,   // RadioScene.swift, `a`'s enrichment / RadioCommands.swift, runRadioAdd (P7)
             .loveTrack,           // NowPlayingScene.swift:732 l / LoveCommands.swift:8
             .playlistListing,      // Shell.swift:94 / PlaylistCommands.swift:23
             .discoverFeed,         // DiscoverScene.swift:462 / DiscoverCommands.swift:52
             .airplayRoute,         // SpeakersScene.swift:332 / SpeakerCommands.swift:48
             .eq,                   // SpeakersScene.swift:311 e / EQCommands.swift:4
             .visualizer:           // SpeakersScene.swift:314 v / VisualizerCommands.swift:4
            return [.tui, .cli]

        // TUI only.
        case .queueJump,                 // NowPlayingScene.swift:700 enter on Up Next
             .quiet,                     // NowPlayingScene.swift:21 x
             .libraryPlay,               // LibraryScene.swift:678 p, :655 enter
             .playlistPlay,              // PlaylistsScene.swift:358 p, :336 enter
             .discoverTrackPlay,         // DiscoverScene.swift:243 enter
             .discoverPlayAll,           // DiscoverScene.swift:245 p
             .discoverRefresh,           // DiscoverScene.swift:240 r
             .libraryArtistTierFilter,   // LibraryScene.swift:685 a — a FILTER, not "add"
             .playlistsOpenNowPlaying,   // PlaylistsScene.swift:362 b — navigation
             .libraryRetry,              // LibraryScene.swift:667 r, only while a read failed
             .radioFavourite,            // RadioScene.swift:172 f — toggles an existing row
             .genius,                    // NowPlayingScene.swift:760 g; no CLI verb
             // Slice 3 Part 2, D3: no CLI verb reaches it. P5 wires it from
             // RadioScene's Live/Personal lists.
             .radioCatalogueBrowse:
            return [.tui]

        // CLI only.
        case .stop,              // PlaybackCommands.swift:611; the TUI's x is quiet, a pause
             .cliPlayResume,     // PlaybackCommands.swift:292 bare `music play`
             .cliPlayIndex,      // PlaybackCommands.swift:103
             .cliPlayPlaylist,   // PlaybackCommands.swift:21
             .cliPlayAlbum,      // PlaybackCommands.swift:33
             .cliPlaySong,       // PlaybackCommands.swift:58
             .cliPlayArtist,     // PlaybackCommands.swift:11 — DECLARED, see below
             .cliPlayQuery,      // PlaybackCommands.swift, `playViaMusicApp` smart positional args
             .cliPlayCatalogSong,// PlaybackCommands.swift, `playViaMusicApp` one-arg Apple Music link
             .catalogSearch,     // SearchCommand.swift:33
             .searchLibrary,     // SearchCommand.swift:18
             .recent,            // HistoryCommands.swift:22
             .rotation,          // HistoryCommands.swift:46
             .newReleases,       // DiscoveryCommands.swift:199
             .similar,           // DiscoveryCommands.swift:4
             .suggest,           // DiscoveryCommands.swift:90
             .addToLibrary,      // AddCommand.swift:42, with a query or an id
             .addCurrentTrackToPlaylist,      // AddCommand.swift:128, --to with no song
             .removeCurrentTrackFromPlaylist, // RemoveCommand.swift:4
             .similarToCurrentTrack,          // DiscoveryCommands.swift:8, query omitted
             .suggestFromCurrentTrack,        // DiscoveryCommands.swift:123
             .newReleasesLikeCurrentTrack,    // DiscoveryCommands.swift:201, --like-current
             .nowStatus,         // PlaybackCommands.swift, struct Now (off a TTY)
             .playlistWrite,     // PlaylistCommands.swift:734 and the other five verbs
             .playlistTemp,      // PlaylistCommands.swift:1081
             .playlistShare,     // PlaylistCommands.swift:1027
             .cliMix,            // MixCommand.swift:4
             .auth:              // AuthCommands.swift:4
            return [.cli]

        }
    }
}

// MARK: - Slice 3, D7: the CLI with Bridge selected
//
// Ruling 12.14's blanket CLI deferral is reversed only for the verbs that
// dispatch. The CLI clause of `routeAction` is CLOSED: an action is dispatched
// to Bridge, refused for Music.app's stale current track, a named exception
// that runs as it ships, or refused with a reason naming what is not served.
// Nothing reaches Music.app by default.

/// The CLI actions served through Bridge while Bridge is selected. Grows by
/// score step (S6 → S7 → Part 2 P6 …); nothing else adds to it.
let cliDispatchedOnBridge: Set<MusicTUIAction> = [
    // S6: `now` and transport.
    .nowStatus, .playPause, .next, .previous, .seek, .stop,
    // S7: `music play` from Bridge's own library (D4), and `search --library`.
    // Free words (`.cliPlayQuery`) are deliberately absent: they refuse (Q1).
    .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong, .cliPlayArtist,
    .searchLibrary,
    // Part 2 P6: catalogue search (`slice.search`) and the Apple Music SONG
    // link (`slice.queue {"ids"}`, D7). Any other link classifies as words.
    .catalogSearch, .cliPlayCatalogSong,
    // Part 2 P7: `radio search` (`slice.searchStations`), `radio add`'s name
    // lookup (`slice.station`) and `radio play` (`slice.playStation`, D8: an
    // ambiguous name refuses, never auto-picks).
    .radioSearch, .radioStationLookup, .radioStationPlay,
    // Part 2 P8: `discover` (`slice.recommendations`; `--recent` refuses in
    // the Bridge body), `playlist list`/`playlist tracks` (Bridge's own
    // library; an ambiguous name refuses, never auto-picks) and `similar
    // <title>` (`slice.search`, the shipped algorithm). `suggest` and
    // `new-releases` are refused instead (Q1 default; D10's sentences).
    .discoverFeed, .playlistListing, .similar,
    // Part 2 P9 [serve]: `recent` (`slice.recentTracks`) and `rotation`
    // (`slice.heavyRotation`). D9 passed for both (B2): Bridge returned the
    // same account-level history as the REST path on three occasions.
    .recent, .rotation,
]

/// CLI actions that keep their shipped backend while Bridge is selected
/// (slice 3 S8, section 2 of the Part 1 score). Written as a literal, never
/// derived: an action added later must be placed here by decision, and
/// `CLIInventoryTests` fails until every CLI command is classified.
///
/// Only **named exceptions (E)**, not temporary: explicit library management
/// (Anthony, 2026-09-16 13:36), MusicTUI's own state, and the Music.app
/// settings spec 6.4 marks Unaffected.
///
/// The temporary **M rows** (read-only lookups) of Anthony's Q2 ruling [B]
/// (2026-09-25) are all retired: Part 2 served or refused each one (P6-P9),
/// and `CLIInventoryTests` asserts none remains. A `.catalog`/`.library` row
/// cached by a Music.app-mode read still never feeds Bridge `play N` (score
/// D3; `MigrationReadCacheTests`).
///
/// Not here: volume and speakers (refused on Bridge, S8), anything that plays,
/// the current-track readers, and TUI-only rows no CLI verb reaches.
let cliBridgeExceptions: Set<MusicTUIAction> = [
    // E: explicit library management (Anthony, 2026-09-16 13:36).
    .addToLibrary,
    .playlistWrite,
    .playlistShare,
    .cliMix,
    // E: MusicTUI's own state. `radio add` saves a local favourite in both
    // modes; its name lookup is `.radioStationLookup`, dispatched (P7).
    .radioAddURL,
    .auth,
    // E: Music.app settings (spec 6.4, Unaffected).
    .eq,
    .visualizer,
]

/// D7's reason for a CLI action Bridge does not serve. Shuffle and repeat
/// modes, volume and AirPlay keep the TUI table's reasons; everything else
/// names what is not available.
func cliBridgeNotServedReason(_ action: MusicTUIAction) -> String {
    switch action {
    case .persistentShuffleMode, .persistentRepeatMode, .volume, .airplayRoute:
        if case .refused(let why) = routeAction(action, in: .source, from: .tui) { return why }
    // Part 2 P8, Q1 default (D10, verbatim): Bridge serves no op for these,
    // so the reason names what is missing rather than "yet". The
    // current-track variants never reach here; they keep their own reason.
    case .suggest:
        return "Bridge output is selected, and music suggest needs Apple Music account reads Bridge doesn't serve. Switch Output to Music.app to use it."
    case .newReleases:
        return "Bridge output is selected, and music new-releases needs a catalogue artist lookup Bridge doesn't serve. Switch Output to Music.app to use it."
    default:
        break
    }
    return "Bridge output is selected, and \(cliBridgeNotServedWhat(action)) isn't available from the CLI on Bridge yet. Use MusicTUI, or switch Output to Music.app."
}

/// The `<what>` in D7's sentence, per action. Every case is named, so a new
/// action cannot be refused with a blank.
private func cliBridgeNotServedWhat(_ action: MusicTUIAction) -> String {
    switch action {
    // The dispatched `music play` forms never reach here from the CLI; they
    // are named anyway, so none is left blank.
    case .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum,
         .cliPlaySong, .cliPlayArtist, .collectionShuffle:
        return "music play"
    case .cliPlayQuery:             return "music play <words>"
    case .cliPlayCatalogSong:       return "music play <Apple Music link>"
    case .radioStationPlay:         return "music radio play"
    case .playlistTemp:             return "music playlist temp"
    case .persistentShuffleMode:    return "music shuffle"
    case .persistentRepeatMode:     return "music repeat"
    case .volume:                   return "music volume"
    case .airplayRoute:             return "music speaker"
    case .nowStatus:                return "music now"
    case .playPause:                return "music pause"
    case .next:                     return "music skip"
    case .previous:                 return "music back"
    case .seek:                     return "music seek"
    case .stop:                     return "music stop"
    case .catalogSearch:            return "music search"
    case .searchLibrary:            return "music search --library"
    case .radioSearch:              return "music radio search"
    case .radioAddURL:              return "music radio add"
    case .radioCatalogueBrowse:     return "the Radio tab's Live and Personal lists"
    case .radioStationLookup:       return "looking up a radio station by URL"
    case .recent:                   return "music recent"
    case .rotation:                 return "music rotation"
    case .discoverFeed:             return "music discover"
    case .newReleases, .newReleasesLikeCurrentTrack: return "music new-releases"
    case .similar, .similarToCurrentTrack:           return "music similar"
    case .suggest, .suggestFromCurrentTrack:         return "music suggest"
    case .loveTrack:                return "music love"
    case .addToLibrary, .addCurrentTrackToPlaylist:  return "music add"
    case .removeCurrentTrackFromPlaylist:            return "music remove"
    case .playlistListing:          return "music playlist list"
    case .playlistWrite:            return "changing playlists"
    case .playlistShare:            return "music playlist share"
    case .cliMix:                   return "music mix"
    case .eq:                       return "music eq"
    case .visualizer:               return "music visualizer"
    case .auth:                     return "music auth"
    // TUI-only rows: no CLI verb reaches them, but none is left unnamed.
    case .queueJump:                return "jumping to a queue row"
    case .quiet:                    return "quiet"
    case .libraryPlay:              return "playing from the Library"
    case .playlistPlay:             return "playing a playlist"
    case .discoverTrackPlay, .discoverPlayAll: return "playing from Discover"
    case .discoverRefresh:          return "refreshing Discover"
    case .libraryArtistTierFilter:  return "the Library artist filter"
    case .playlistsOpenNowPlaying:  return "opening Now Playing"
    case .libraryRetry:             return "retrying the Library"
    case .radioFavourite:           return "radio favourites"
    case .genius:                   return "Genius"
    }
}

/// Anthony's ruling of 2026-09-16. Deliberately NOT the 12.14 wording: the verb
/// is not deferred, its target is unresolvable, and naming a song fixes it.
let currentTrackIsStaleInBridge =
    "Bridge output is selected, so Music.app's current track is not what you are hearing. Name the song explicitly, or switch Output to Music.app."

/// The matrix. Every case decided; nothing defaults.
func routeAction(_ action: MusicTUIAction,
                 in mode: PlaybackMode,
                 from surface: InvocationSurface) -> ActionRoute {
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

    // Slice 3, D7: the CLI clause is closed. A dispatched verb goes to Bridge;
    // a verb that would resolve its target through Music.app's stale `current
    // track` refuses with its own reason (Anthony, 2026-09-16 13:36); a named
    // exception runs exactly as it ships; everything else, every undispatched
    // playback verb included, refuses and names what is not served. There is
    // no default to Music.app. Playback verbs are never exceptions, so
    // `playlist temp`, both a write and a way to start Music.app playing,
    // refuses as playback.
    if surface == .cli {
        if cliDispatchedOnBridge.contains(action) { return .source }
        if action.readsMusicAppCurrentTrack { return .refused(currentTrackIsStaleInBridge) }
        if cliBridgeExceptions.contains(action) { return routeAction(action, in: .musicApp, from: .cli) }
        return .refused(cliBridgeNotServedReason(action))
    }

    switch action {

    // Served by the source. `quiet` is "stop here", a pause, so it pauses the
    // source: Anthony's ruling 12.7 (2026-09-13), "playback controls always
    // target the selected output mode".
    case .playPause, .next, .previous, .seek, .stop, .quiet,
         .libraryPlay, .playlistPlay, .discoverTrackPlay, .discoverPlayAll,
         .radioStationPlay,
         .cliPlayResume, .cliPlayIndex, .cliPlayPlaylist, .cliPlayAlbum, .cliPlaySong,
         .cliPlayQuery, .cliPlayCatalogSong,
         .discoverFeed, .discoverRefresh, .catalogSearch, .radioSearch,
         .recent, .newReleases:
        return .source

    /// Slice 3, D7: `music now` reads Bridge's own status. CLI-only, so this
    /// TUI row is unreachable; it is decided, not defaulted.
    case .nowStatus:
        return .source

    /// Slice 3 Part 2, D3: Radio's Live/Personal browse and its add-by-URL
    /// station lookup are reads with no Music.app current-track dependency,
    /// so both are served the same way every other Bridge-mode TUI read is.
    /// `routing.choose` hands the caller a provider to read from AFTER this
    /// returns. From the CLI, the clause above decides: `radio add`'s lookup
    /// is dispatched (P7); the browse has no CLI invoker.
    case .radioCatalogueBrowse, .radioStationLookup:
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
    case .playlistListing, .searchLibrary, .libraryRetry:
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
        return .refused("Shuffle and repeat modes are Music.app only for now.")
    case .volume:
        return .refused("Volume is Music.app only; the source plays at the Mac's output level.")
    case .loveTrack, .addToLibrary, .addCurrentTrackToPlaylist,
         .removeCurrentTrackFromPlaylist, .playlistWrite:
        return .refused("Library changes are Music.app only in this version")
    case .cliMix:
        // Codex B1: mix calls api.createPlaylist and populates it.
        return .refused("mix creates a playlist, which is Music.app only in this version")
    case .playlistTemp:
        return .refused("Temporary playlists exist to bound Music.app; the source builds its own queue")
    case .similar, .similarToCurrentTrack, .suggest, .suggestFromCurrentTrack:
        return .refused("Not available through the source app in this version")

    /// `new-releases` itself is brokered and served; the `--like-current`
    /// variant is not, because its SEED is Music.app's current track and Bridge
    /// is what is playing. Refused for the target, not for the capability.
    case .newReleasesLikeCurrentTrack:
        return .refused(currentTrackIsStaleInBridge)
    case .rotation:
        // CLI-only: no TUI key reaches this row. From the CLI, the clause above
        // dispatches it to Bridge (`slice.heavyRotation`, Part 2 P9); this TUI
        // column stays refused (D10). Ruling 12.15: a person reads "Bridge".
        return .refused("Heavy rotation has no Bridge route in MusicTUI in this version")
    /// Ruling 12.13 (2026-09-15) deferred the queue-row jump from v1. Spec 6.2
    /// and DoD 3 require a VISIBLE refusal: `933e85d` predates the narrowing and
    /// routed it to the source, which would have shipped a jump that silently
    /// did the wrong thing against a queue the TUI cannot address yet.
    case .queueJump:
        return .refused("Jumping to a queue row is Music.app only in this version")

    case .genius:
        return .refused("Genius is a Music.app feature")
    case .airplayRoute:
        // Anthony, 2026-09-13: "airplay stays in TUI. the point of the bridge is
        // DAC not airplay."
        return .refused("AirPlay applies in Music.app mode; the source plays to the Mac's wired output.")
    }
}

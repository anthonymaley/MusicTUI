// tools/music/Sources/TUI/AlbumContainer.swift
import Foundation

/// Temporary container for a bounded CLI album play.
///
/// Shape mirrors the Discover container: "__album__ <uuid> — <title>". The uuid
/// makes the name collision proof, replacing the one second timestamp the two
/// `__temp__` creators use. The title after the separator is DISPLAY ONLY and is
/// never used as an identifier; `cleanContextName` reads it back out for Now
/// Playing.
let albumPlaylistPrefix = "__album__ "

/// Prefixes whose names carry "<uuid><separator><title>" after the prefix.
///
/// An explicit list, deliberately. A generic "strip anything uuid shaped" rule
/// would rewrite a user's own playlist name that happened to match.
let uuidCarryingPlaylistPrefixes = [discoverPlaylistPrefix, albumPlaylistPrefix]

func albumContainerName(title: String, uuid: String) -> String {
    albumPlaylistPrefix + uuid + discoverPlaylistNameSeparator + title
}

// MARK: - Lifecycle constants

/// Playback must be confirmed started before the watcher is spawned. The
/// existing `showNowPlaying` wait measures about 3.2s against a stopped player,
/// so this clears it with margin.
let albumPlaybackConfirmTimeout: TimeInterval = 5

/// How long the watcher waits for the container to become `current playlist`
/// before giving up and exiting WITHOUT deleting.
let albumWatcherArmTimeout: TimeInterval = 30

/// Bounds how long a finished container lingers. The 2026-09-01 spike proved a
/// 30s cadence stable across 900s; 15s is chosen for promptness and is still
/// only about 180 Apple Events across a 45 minute album.
let albumWatcherPollInterval: TimeInterval = 15

/// Covers any realistic single album without letting a wedged watcher live
/// forever. On timeout the watcher exits WITHOUT deleting.
let albumWatcherMaxLifetime: TimeInterval = 6 * 60 * 60

/// Above this many tracks the identity set travels in a private manifest file
/// rather than the argument list.
let albumWatcherInlineIDLimit = 200

/// Player states in which an album container is considered in use.
///
/// NOT the same as `sweepablePlayerStates`, and deliberately so: an album
/// container is resumable while paused, a Discover container is not. Do not
/// merge these two sets. See the design doc section 6.
let albumInUsePlayerStates = ["playing", "paused", "fast forwarding", "rewinding"]

// MARK: - Watcher decision

/// One poll's worth of readings. `nil` means the read threw, which is a real and
/// expected case: `current playlist` throws while stopped, and macOS 26 throws
/// -1728 on `persistent id` for some tracks.
struct AlbumWatcherObservation: Equatable {
    let playerState: String?
    let currentPlaylist: String?
    let currentTrackID: String?
    let containerName: String
    let containerTrackIDs: Set<String>
}

enum AlbumWatcherDecision: Equatable {
    case spare
    case collect
}

/// Whether the watcher may delete its container.
///
/// Identity is load bearing, not a refinement. When Autoplay carries playback
/// past the container's end, `player state` reads `playing` and
/// `current playlist` THROWS (measured 2026-09-01). A predicate on state and
/// context alone reads that as "playing, context unreadable" and spares
/// forever, so the container would survive until the max lifetime. The current
/// track's persistent ID is the signal that still works there.
///
/// Everything unreadable spares, on the same asymmetry the Discover sweep uses:
/// a wrongly spared container costs one leftover row that a later sweep
/// collects, a wrongly collected one destroys live playback.
func albumWatcherDecision(_ o: AlbumWatcherObservation) -> AlbumWatcherDecision {
    guard let state = o.playerState else { return .spare }
    if !albumInUsePlayerStates.contains(state) { return .collect }
    if let id = o.currentTrackID {
        return o.containerTrackIDs.contains(id) ? .spare : .collect
    }
    if let context = o.currentPlaylist {
        return context == o.containerName ? .spare : .collect
    }
    return .spare
}

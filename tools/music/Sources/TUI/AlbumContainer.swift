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
//
// `albumPlaybackConfirmTimeout` (a documented-but-unwired 5s constant for a
// polled "playback confirmed started" wait before spawning the watcher) was
// removed here 2026-09-01 (§16, "also fix while in these files"): nothing in
// `Sources/` ever read it. The confirm signal `playBoundedAlbum` actually
// uses is the synchronous return of `run("play playlist \"...\"")` — Music's
// `play playlist` AppleScript command does not return until the command has
// been accepted and executed, so a non-nil result already means more than
// "the play command was issued" without a separate polled wait. Design §7
// and §7.1 are amended to match; see docs/plans/2026-09-01-cli-album-scoping-design.md.

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
/// §16.2 (corrects §6.1's evaluation order — the identity-first order below
/// let a same-album-twice bug through: two containers of the same album
/// duplicate references to the SAME underlying library tracks, so their
/// captured id sets are identical, and identity alone could never tell them
/// apart). The order is now exactly this, and it is normative:
///
///   1. Music not running — handled by the caller, not this predicate (an
///      observation can't even be TAKEN without risking launching Music; see
///      `albumWatcherLifecycle`'s `isRunning` guard, §16.3).
///   2. Player state unreadable, or a value not recognised: SPARE. This
///      replaces a negative allowlist test
///      (`if !albumInUsePlayerStates.contains(state) { return .collect }`)
///      that put an unrecognised or future state value on the DELETE side —
///      the only code path in this app that deletes unattended.
///   3. Player state exactly `stopped`: COLLECT.
///   4. Context readable and DIFFERENT from the watched container: COLLECT,
///      even when the current track id belongs to the same album. This is
///      the same-album-twice fix: a readable, differing context is the one
///      signal that still distinguishes "this album, this container" from
///      "this album, some OTHER container" when both share every track id.
///   5. Context readable and MATCHING: SPARE.
///   6. Context unreadable: fall back to identity. This is the case identity
///      exists for — when Autoplay carries playback past the container's
///      end, `player state` reads `playing` and `current playlist` THROWS
///      (measured 2026-09-01), so context is useless and identity is the
///      only usable signal. Inside the set spares, outside collects,
///      unreadable identity spares.
///
/// Everything unreadable spares, on the same asymmetry the Discover sweep
/// uses: a wrongly spared container costs one leftover row that a later
/// sweep collects, a wrongly collected one destroys live playback.
func albumWatcherDecision(_ o: AlbumWatcherObservation) -> AlbumWatcherDecision {
    guard let state = o.playerState else { return .spare }                    // step 2: unreadable
    let recognised = albumInUsePlayerStates.contains(state) || state == "stopped"
    guard recognised else { return .spare }                                   // step 2: unrecognised
    if state == "stopped" { return .collect }                                 // step 3

    // From here `state` is a recognised in-use state.
    if let context = o.currentPlaylist {                                     // steps 4/5
        return context == o.containerName ? .spare : .collect
    }

    // Step 6: context unreadable — fall back to identity.
    guard let id = o.currentTrackID else { return .spare }
    return o.containerTrackIDs.contains(id) ? .spare : .collect
}

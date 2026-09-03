// Discover's play transaction, as pure decisions.
//
// The safety property this file exists to hold: Discover NEVER deletes a
// library row. A membership pre-check and a re-check after creation can prove
// a row appeared between two observations, but never that this transaction
// created it — a user adding the same catalog song in Music.app during that
// window produces the identical library id, and a sweep keyed on that
// evidence would delete music they deliberately added. Apple exposes no
// authorship for a library row, and no lock helps, because the user is not a
// transaction. So the songs this feature adds stay in the library,
// permanently. Only the temp playlist CONTAINER is ever removed later, by
// its own name prefix — exactly as the shipped `sweepQueuePlaylists` does for
// `__queue__ `.
import Foundation

let discoverPlaylistPrefix = "__discover__ "

/// The separator between the transaction uuid and the display title in a
/// Discover playlist's name: "__discover__ <uuid> — <title>". Without a
/// ledger there is no title mapping stored elsewhere, so the title has to
/// live in the name itself for Now Playing to show it.
let discoverPlaylistNameSeparator = " — "

enum DiscoverReadiness: Equatable { case wait, ready, timedOut }

/// Library adds return 202 and materialize asynchronously — about two seconds for
/// one song (docs/platform-notes.md:229). Poll until the expected count lands, or
/// give up. `>= expected` rather than `==` so an extra row from Apple's side does
/// not deadlock the poll.
func discoverReadiness(observed: Int, expected: Int,
                       elapsed: TimeInterval, timeout: TimeInterval) -> DiscoverReadiness {
    if observed >= expected { return .ready }
    return elapsed >= timeout ? .timedOut : .wait
}

// MARK: - Play from here

/// The id list for "play from here": the container sliced from the selected
/// row to its end.
///
/// This is the whole mechanism behind track-level `Enter`, and it is why the
/// feature stopped being blocked. The deferral reason recorded in the docs was
/// that the only bounded play form starts a playlist from its beginning — true,
/// and unchanged. Slicing sidesteps it rather than fighting it: the slice's
/// beginning IS the selected track, so `play playlist` on the sliced container
/// starts where the user pointed and still stops at the album's end.
///
/// An out-of-range index returns an empty slice rather than clamping. Clamping
/// would play position 1, i.e. a DIFFERENT song than the one chosen, which is
/// the single failure the design doc refuses outright ("report and play
/// nothing"). The caller's non-empty guard turns the empty slice into a toast.
func discoverPlaySlice(catalogIDs: [String], from index: Int) -> [String] {
    guard index >= 0, index < catalogIDs.count else { return [] }
    return Array(catalogIDs[index...])
}

/// The ordered AppleScript commands one Discover play emits.
///
/// Kept pure and separate so the ORDER can be asserted in a unit test; the
/// order is the part that carries the promise.
///
/// Two commands, never one block: combining a `set` with a `play` in a single
/// script is what produced parameter error -50 in the shipped playlist code
/// (see `PlaylistCommands`' "Split into separate calls" comment), so they stay
/// separate `runMusic` calls.
///
/// `disableShuffle` defaults to off at the call site that plays a whole
/// container, leaving `p` exactly as it shipped.
func discoverPlayScripts(playlistName: String, disableShuffle: Bool) -> [String] {
    let esc = escapeAppleScriptString(playlistName)
    var scripts: [String] = []
    if disableShuffle {
        scripts.append("set shuffle enabled to false")
    }
    scripts.append("play playlist \"\(esc)\"")
    return scripts
}

// MARK: - The transaction's outcome

/// What a play attempt resolved to, for the toast. The transaction itself is
/// `DiscoverLifecycleCoordinator` (DiscoverLifecycle.swift), which owns the
/// create, readiness, play and confirmation stages so that it can record
/// each transition around the real side effect; nothing here owns UI.
enum DiscoverPlayOutcome: Equatable {
    case playing(title: String)
    case needsSignIn
    /// The create request threw. This does NOT mean nothing was created:
    /// `createPlaylist` throws `noData` after a successful HTTP response whose
    /// body lacks the expected id, and a transport failure is ambiguous about
    /// server acceptance, so a container may exist. No play follows, so no
    /// deletion can interrupt playback, and a later sweep collects whatever
    /// did land.
    case createFailed(String)
    case notReady                  // materialization timed out; playlist left behind
    case playFailed(String)
}

func isExpiredToken(_ error: Error) -> Bool {
    guard let authError = error as? AuthError else { return false }
    if case .userTokenExpired = authError { return true }
    return false
}

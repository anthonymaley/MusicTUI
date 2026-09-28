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

// MARK: - A container addressed by persistent ID (SpanDAC data)

/// The same two commands as `discoverPlayScripts`, addressing the container by
/// the persistent ID SpanDAC returned for it instead of by its name. With
/// SpanDAC as MusicTUI's data source the container is made by SpanDAC on this
/// Mac (`slice.libraryEnsurePlaylist`), and it is played, read and confirmed by
/// that identity only: never by a name search, so a same-named playlist can
/// never be the one that plays.
///
/// `hex` is `persistentIDHex(fromAlias:)`'s output: sixteen uppercase hex
/// digits, so it needs no escaping.
func discoverPlayScripts(persistentID hex: String, disableShuffle: Bool) -> [String] {
    var scripts: [String] = []
    if disableShuffle {
        scripts.append("set shuffle enabled to false")
    }
    scripts.append("play (first user playlist whose persistent ID is \"\(hex)\")")
    return scripts
}

/// Track count of the container with this persistent ID. A playlist
/// AppleScript cannot see yet fails the script, which the caller reads as 0,
/// exactly as the by-name count does.
func discoverTrackCountScript(persistentID hex: String) -> String {
    "return (count of tracks of (first user playlist whose persistent ID is \"\(hex)\")) as text"
}

/// The persistent IDs of the container's tracks, in the container's own
/// order (the order it plays), for the container with this persistent ID.
/// The same output form as `containerTrackIDsScript`, so
/// `parseContainerTrackIDsInOrder` reads it.
func discoverContainerTrackIDsScript(persistentID hex: String) -> String {
    """
    set fs to (ASCII character 31)
    set pl to (first user playlist whose persistent ID is "\(hex)")
    set total to count of tracks of pl
    if total is 0 then return ""
    set ids to persistent ID of every track of pl
    set out to ""
    repeat with i from 1 to total
        set out to out & (item i of ids)
        if i < total then set out to out & fs
    end repeat
    return out
    """
}

/// True only when the container SpanDAC made holds EXACTLY the expected
/// tracks, in the expected order, each one a single identity. The expected
/// identities are SpanDAC's own lookup of the catalogue ids; each must be in
/// the library (`verifyExactTracks`, the one identity check), and the
/// container's tracks read back in its own order must equal them one for one.
/// Anything short of that, including any read that failed, is false. Never a
/// title search.
func discoverContainerHoldsExactly(catalogIDs: [String], containerHex: String,
                                   library: SpanDACLibraryAdding,
                                   tracks: PersistentIDTrackReading,
                                   containerTrackIDs: (String) -> [String]?) -> Bool {
    guard !catalogIDs.isEmpty, let aliases = try? library.lookup(catalogueIDs: catalogIDs) else { return false }
    var expected: [String] = []
    for id in catalogIDs {
        guard let alias = aliases[id] ?? nil, let hex = persistentIDHex(fromAlias: alias) else { return false }
        expected.append(hex)
    }
    guard let verified = try? verifyExactTracks(expected.map { ($0, nil) }, library: tracks),
          verified.count == expected.count else { return false }
    return containerTrackIDs(containerHex) == expected
}

/// A `PersistentIDTrackReading` over a closure (the lifecycle's seam).
struct ClosurePersistentIDReader: PersistentIDTrackReading {
    let read: ([String]) throws -> [String: [HandoffTrackHit]]
    func tracks(persistentIDs: [String]) throws -> [String: [HandoffTrackHit]] { try read(persistentIDs) }
}

/// Rule 3's confirmation read, by identity: `player state` is
/// `nowPlayingReadyState` AND the current playlist's persistent ID is the
/// container's, compared inside AppleScript. Both reads are inside `try`, so
/// an unreadable context is `notyet`, never confirmation.
func discoverConfirmationScript(persistentID hex: String) -> String {
    """
        set stateText to ""
        set ctxID to ""
        try
            set stateText to player state as text
        end try
        try
            set ctxID to persistent ID of current playlist
        end try
        if stateText is "\(nowPlayingReadyState)" and ctxID is "\(hex)" then return "\(discoverConfirmedToken)"
        return "\(discoverNotYetToken)"
        """
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
    /// SpanDAC data only: the request to make the container may or may not
    /// have been carried out (a timeout, a closed socket, a lost reply, or
    /// SpanDAC's own `outcome: unknown`). Nothing played; the person's next
    /// Enter re-sends the SAME name, which finds the playlist rather than
    /// making a second one.
    case outcomeUnknown
    /// SpanDAC data only: refused with a sentence of its own, and nothing
    /// played (a container with no persistent ID, or a SpanDAC that does not
    /// offer the library ops).
    case refused(String)
}

/// What the person reads when SpanDAC could not confirm it made the
/// container (CHOSEN wording, score C-ADD).
let discoverOutcomeUnknownText = "Couldn't confirm SpanDAC made the playlist. Press Enter again to check."

func isExpiredToken(_ error: Error) -> Bool {
    guard let authError = error as? AuthError else { return false }
    if case .userTokenExpired = authError { return true }
    return false
}

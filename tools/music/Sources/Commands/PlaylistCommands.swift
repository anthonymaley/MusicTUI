import ArgumentParser
import Foundation

struct Playlist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage playlists.",
        subcommands: [
            PlaylistList.self,
            PlaylistTracks.self,
            PlaylistCreate.self,
            PlaylistDelete.self,
            PlaylistAdd.self,
            PlaylistRemove.self,
            PlaylistShare.self,
            PlaylistTemp.self,
            PlaylistCreateFrom.self,
            PlaylistCleanup.self,
        ],
        defaultSubcommand: PlaylistList.self
    )
}

struct PlaylistList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List playlists.")
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try listPlaylists(json: json)
    }
}

struct PlaylistTracks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tracks", abstract: "List tracks in a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        try showPlaylistTracks(name: name, json: json)
    }
}

// MARK: - Shared logic (callable without ArgumentParser)

func listPlaylists(json: Bool) throws {
    let auth = AuthManager()
    if let devToken = try? auth.requireDeveloperToken(), let userToken = auth.userToken() {
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let (data, status) = try syncRun { try await api.get("/v1/me/library/playlists?limit=100") }
        if (200...299).contains(status) {
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = parsed?["data"] as? [[String: Any]] ?? []
            let playlists: [[String: Any]] = items.map { item in
                let attrs = item["attributes"] as? [String: Any] ?? [:]
                return ["id": item["id"] as? String ?? "", "name": attrs["name"] as? String ?? ""]
            }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["playlists": playlists]))
            } else {
                for pl in playlists { print(pl["name"] as? String ?? "") }
            }
            return
        }
    }

    // Fallback to AppleScript
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("get name of every playlist")
    }
    let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["playlists": names.map { ["name": $0] }]))
    } else {
        for name in names { print(name) }
    }
}

func showPlaylistTracks(name: String, json: Bool) throws {
    let auth = AuthManager()
    if let devToken = try? auth.requireDeveloperToken(), let userToken = auth.userToken() {
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let (listData, listStatus) = try syncRun { try await api.get("/v1/me/library/playlists?limit=100") }
        if (200...299).contains(listStatus) {
            let parsed = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
            let items = parsed?["data"] as? [[String: Any]] ?? []
            if let match = items.first(where: {
                let attrs = $0["attributes"] as? [String: Any] ?? [:]
                return (attrs["name"] as? String ?? "") == name
            }), let plId = match["id"] as? String {
                // Apple caps this endpoint at 100 tracks per page; walk every page
                // via offset (reusing the tested pagination helper) so a long
                // playlist returns in full instead of being silently truncated at 100.
                let trackItems: [[String: Any]] = fetchAllPages(pageSize: 100) { limit, offset in
                    guard let (d, s) = try? syncRun({
                        try await api.get("/v1/me/library/playlists/\(plId)/tracks?limit=\(limit)&offset=\(offset)")
                    }), (200...299).contains(s),
                          let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let items = parsed["data"] as? [[String: Any]] else { return [] }
                    return items
                }
                if !trackItems.isEmpty {
                    let tracks: [[String: Any]] = trackItems.enumerated().map { (i, item) in
                        let attrs = item["attributes"] as? [String: Any] ?? [:]
                        let catalogId = (attrs["playParams"] as? [String: Any])?["catalogId"] as? String ?? ""
                        return [
                            "number": i + 1,
                            "track": attrs["name"] as? String ?? "Unknown",
                            "artist": attrs["artistName"] as? String ?? "Unknown",
                            "album": attrs["albumName"] as? String ?? "",
                            "catalogId": catalogId
                        ]
                    }
                    let cache = ResultCache()
                    let songResults = tracks.map { t in
                        SongResult(
                            index: t["number"] as! Int,
                            title: t["track"] as! String,
                            artist: t["artist"] as! String,
                            album: t["album"] as! String,
                            catalogId: t["catalogId"] as? String ?? ""
                        )
                    }
                    try? cache.writeSongs(songResults)
                    if json {
                        let output = OutputFormat(mode: .json)
                        print(output.render(["playlist": name, "tracks": tracks]))
                    } else {
                        for t in tracks {
                            print("\(t["number"]!). \(t["track"]!) — \(t["artist"]!) [\(t["album"]!)]")
                        }
                    }
                    return
                }
            }
        }
    }

    // Fallback to AppleScript
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set trackList to every track of playlist "\(escapeAppleScriptString(name))"
            set output to ""
            set i to 1
            repeat with t in trackList
                if output is not "" then set output to output & linefeed
                set output to output & i & fs & name of t & fs & artist of t & fs & album of t
                set i to i + 1
            end repeat
            return output
        """)
    }
    let parsedTracks = parsePlaylistTrackLines(result)

    let cache = ResultCache()
    let songResults = parsedTracks.map { t in
        SongResult(index: t.num, title: t.title, artist: t.artist, album: t.album, catalogId: "")
    }
    try? cache.writeSongs(songResults)

    if json {
        let tracks: [[String: Any]] = parsedTracks.map { t in
            ["number": t.num, "track": t.title, "artist": t.artist, "album": t.album]
        }
        let output = OutputFormat(mode: .json)
        print(output.render(["playlist": name, "tracks": tracks]))
    } else {
        for t in parsedTracks {
            print("\(t.num). \(t.title) — \(t.artist) [\(t.album)]")
        }
    }
}

/// Which path `playlist create` should take. A developer key is needed only to
/// SEED tracks by catalog id; creating an empty playlist is pure AppleScript,
/// which this file already does for the temp-playlist machinery. Pure, for
/// testability.
enum PlaylistCreateStrategy: Equatable {
    /// Tokens present and at least one requested row is a catalog row (or no
    /// tracks requested): one API call creates and seeds in a single round
    /// trip. A create that carries tracks syncs to Music.app; an empty one
    /// does not, which is why a pure library selection never lands here.
    case rest
    /// No tokens, no tracks asked for: `make new playlist` needs no key.
    case appleScriptEmpty
    /// Tracks requested and every requested row is a library row, keyed or
    /// keyless: make the playlist with AppleScript and duplicate each owned
    /// track in.
    case appleScriptSeedFromLibrary
    /// No tokens and at least one requested row is a catalog row. Catalog ids
    /// are only reachable through the API, so refuse honestly rather than
    /// silently creating a shorter playlist.
    case needsAuthToSeed
}

func playlistCreateStrategy(hasTokens: Bool, indexCount: Int, allLibraryRows: Bool) -> PlaylistCreateStrategy {
    // A pure library selection never goes through REST, keyed or not. An
    // empty REST playlist does not reach Music.app in any window worth
    // waiting for, so AppleScript owns that case outright.
    if indexCount > 0 && allLibraryRows { return .appleScriptSeedFromLibrary }
    if hasTokens { return .rest }
    if indexCount == 0 { return .appleScriptEmpty }
    return .needsAuthToSeed
}

/// One title/artist pair from `create-from`'s alternating argument list.
struct TitleArtist: Equatable {
    let title: String
    let artist: String
}

/// Split `create-from`'s alternating `title artist title artist ...` arguments
/// into pairs. Returns nil when the list is empty or odd, which is the caller's
/// cue to print usage. Pure, for testability.
func titleArtistPairs(_ items: [String]) -> [TitleArtist]? {
    guard items.count >= 2, items.count % 2 == 0 else { return nil }
    return stride(from: 0, to: items.count, by: 2).map {
        TitleArtist(title: items[$0], artist: items[$0 + 1])
    }
}

/// Which path `playlist add` should take. A developer key is needed only to
/// reach the CATALOG. Adding a track already in the library is
/// `duplicateLibraryTrack`, which this file already uses and which has never
/// needed a token. Pure, for testability.
enum PlaylistAddStrategy: Equatable {
    /// Tokens present: unchanged behaviour, catalog and library both reachable.
    case rest
    /// No tokens: resolve the title against the library and duplicate it in.
    case appleScriptLibrary
    /// No tokens, indices given, and every index points at a library row:
    /// duplicate each owned track into the playlist.
    case appleScriptLibraryIndices
    /// No tokens and at least one index points at a catalog row. A catalog id
    /// is only reachable through the API.
    case needsAuthForIndices
}

func playlistAddStrategy(hasTokens: Bool, itemsAreIndices: Bool, allLibraryRows: Bool) -> PlaylistAddStrategy {
    if hasTokens { return .rest }
    if !itemsAreIndices { return .appleScriptLibrary }
    return allLibraryRows ? .appleScriptLibraryIndices : .needsAuthForIndices
}

/// Split cached rows by origin so each goes down its only valid route:
/// catalog rows to the API, library rows to an AppleScript duplicate. Order
/// inside each half is the order the user typed. Pure, for testability.
func partitionByOrigin(_ rows: [SongResult]) -> (catalog: [SongResult], library: [SongResult]) {
    (rows.filter { $0.origin == .catalog }, rows.filter { $0.origin == .library })
}

/// True when there is at least one row and every row is a library row. This
/// is the fact the keyless strategies need; computed once from one cache read.
func allLibraryRows(_ rows: [SongResult]) -> Bool {
    !rows.isEmpty && rows.allSatisfy { $0.origin == .library }
}

/// The single route for adding LIBRARY rows to a playlist, keyed or keyless:
/// duplicate the owned track by title and artist. Returns the rows that did
/// not land so the caller can report them; nothing is dropped silently.
func duplicateLibraryRows(_ rows: [SongResult], toPlaylist playlist: String,
                          backend: AppleScriptBackend) -> (added: [SongResult], failed: [SongResult]) {
    var added: [SongResult] = []
    var failed: [SongResult] = []
    for row in rows {
        if duplicateLibraryTrack(backend: backend, title: row.title, artist: row.artist, toPlaylist: playlist) {
            added.append(row)
        } else {
            failed.append(row)
        }
    }
    return (added, failed)
}

/// `make new playlist` via AppleScript: the keyless path shared by an empty
/// create and a library-seeded create. Never needs a token.
/// Delete by object reference, never by name. `delete playlist "X"` returns
/// -1708 ("doesn't understand the delete message") on a playlist the REST API
/// created, while the `whose` reference form deletes every playlist so named
/// regardless of origin (measured 2026-08-28). Pure so the form is pinned.
func playlistDeleteScript(name: String) -> String {
    "delete (every user playlist whose name is \"\(escapeAppleScriptString(name))\")"
}

/// Delete this app's temp containers, sparing one that is actually in use.
///
/// Same reference form as `playlistDeleteScript`: the old loop resolved each
/// name back through `delete playlist p` and hit -1708.
///
/// The sparing rule is `albumInUsePlayerStates`, NOT `sweepablePlayerStates`.
/// This command is user invoked, so a container the user is audibly listening to
/// is spared whatever its prefix, including a PAUSED one. The automatic Discover
/// sweep keeps the opposite rule on purpose: it must collect paused containers,
/// because `current playlist` outlives a pause and one row leaked per paused
/// play. Do not merge the two.
///
/// Containers only: this script never names a track or a song, so it cannot
/// reach a library row. A test pins that.
///
/// Unreadable player state fails toward sparing: if `player state` throws,
/// `playerStateText` defaults to `unreadablePlayerStateFallback` (which is in
/// `albumInUsePlayerStates`), so the container is spared. An Apple Event error
/// is never treated as "not in use"; the conservative choice is to keep the
/// container.
///
/// An unreadable playlist context aborts the sweep: if the player is in an
/// in-use state but `current playlist` throws, we cannot identify which
/// container to spare. The script returns the text "deferred" without
/// deleting anything (§16.5, corrects §11: it used to return 0, which the CLI
/// printed as "Cleaned up 0 temp playlist(s)." — indistinguishable from
/// "nothing to clean", even though this unreadable-context state is exactly
/// the measured Autoplay-bleed signature, so it is reachable precisely when a
/// user is hunting an orphan). This conforms to design spec §6.1: a readable
/// context is a precondition for collecting. An unreadable context is never
/// grounds to collect, because leaving orphans is the cheap failure; deleting
/// live playback is the expensive one. Genuine orphans are collected by the
/// next album invocation (§16.1's `albumStaleSweepScript`) or the next
/// cleanup run.
///
/// An UNRECOGNISED player state also aborts the sweep (§17.2, corrects
/// §16.1): the old shape tested positively for the four in-use states with
/// an implicit else, so any value that was neither in-use nor "stopped" fell
/// through with `keepName` empty and the loop deleted every owned temp
/// playlist, including one currently in use. `recognised` is now a positive
/// test — mirroring `albumWatcherDecision`'s idiom, and the naming
/// `sweepablePlayerStates` documents (name the states you act on, so
/// anything Apple adds later lands on the spare side by construction) — and
/// an unrecognised state returns "deferred" before the context check even
/// runs, on the same asymmetry as the rest of this file: a spared container
/// costs one leftover row a later sweep collects, a wrongly collected one
/// destroys live playback.
func playlistCleanupScript() -> String {
    albumSweepGuardedScript(prefixes: ["__temp__", albumPlaylistPrefix],
                            deferReturn: "return \"deferred\"", countDeleted: true)
}

/// §16.5: the honest outcome of `playlistCleanupScript()`. `.deferred` is the
/// unreadable-context case (§6.1/§16.5): the player is in an in-use state but
/// `current playlist` couldn't be read, so cleanup aborted without deleting
/// anything, rather than the vacuous "there was nothing to clean" `.collected(0)`
/// would otherwise imply.
///
/// `.unreadable` (§17.4) is a further, distinct degradation: the script's raw
/// return value parsed as neither "deferred" nor one of the recognised
/// outcome literals. This is not "0 deleted" — the previous shape
/// (`Int(trimmed) ?? 0`) collapsed this into `.collected(0)`, the exact same
/// misreport §16.5 fixed for the deferred/exception case, just from a
/// garbled-return-value cause instead of a caught AppleScript exception.
///
/// §20.3: FOUR outcomes, not two. Before this, `.collected(0)` was printed
/// as "Cleaned up 0 temp playlist(s)." for BOTH "nothing existed" and
/// "candidates existed but were spared" — observed live 2026-09-02, where a
/// correctly spared paused container printed exactly that, indistinguishable
/// from "there was nothing to clean". `.nothingExisted` and
/// `.sparedCandidates` are now separate cases so neither can misreport as
/// the other, and `.removed` carries the actual object count (never a
/// unique-name count — see `albumSweepGuardedScript`). Pure → tested.
enum PlaylistCleanupResult: Equatable {
    /// No playlist matched a swept prefix at all — genuinely nothing to do.
    case nothingExisted
    /// At least one playlist matched a swept prefix, but every match was the
    /// active/paused container — spared, not deleted. Distinct from
    /// `.nothingExisted` so the CLI never prints "Cleaned up 0" for this case.
    case sparedCandidates
    /// The player was in an in-use state but its container couldn't be
    /// identified, or the state itself was unrecognised: aborted before any
    /// enumeration, nothing deleted, nothing known about what exists.
    case deferred
    /// One or more playlist OBJECTS were removed (exact-name deletion can
    /// remove more than one object per captured name).
    case removed(Int)
    /// The script's raw return value parsed as none of the above.
    case unreadable
}

func parsePlaylistCleanupResult(_ raw: String) -> PlaylistCleanupResult {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed {
    case "deferred": return .deferred
    case "none": return .nothingExisted
    case "spared": return .sparedCandidates
    default:
        guard let count = Int(trimmed), count > 0 else { return .unreadable }
        return .removed(count)
    }
}

/// The §16.1 next-invocation recovery sweep, run at the START of every
/// bounded album play, BEFORE that play's own container is created. This is
/// design §6.2's path 2 — a crashed or killed watcher's orphan is recovered
/// the next time the user plays an album — which three shipped code comments
/// asserted existed before this function was written to make it true.
///
/// Deliberately narrower than `playlistCleanupScript()`:
///
/// - Sweeps `\(albumPlaylistPrefix)` containers ONLY. It must never touch
///   `__temp__`, `__discover__`, or `__queue__` — a user may be relying on a
///   `__temp__` playlist, and this runs on every single album play, not on an
///   explicit user command.
/// - Spares the current container while the player is in
///   `albumInUsePlayerStates` (playing, paused, fast forwarding, rewinding —
///   an album container is resumable while paused, same rule as
///   `playlistCleanupScript`, NOT the Discover sweep's `sweepablePlayerStates`).
/// - Unknown state or an unreadable context both fail toward sparing: on the
///   same asymmetry used throughout this feature, a wrongly spared orphan
///   costs one row a later sweep collects; a wrongly collected one destroys
///   live playback. This script aborts the ENTIRE sweep (deletes nothing) if
///   the in-use context can't be read, same shape as `playlistCleanupScript`.
///   §17.2 (corrects §16.1): "unknown state" was promised here but not
///   actually built — the original shape tested positively for the four
///   in-use states with an implicit else, so any OTHER state (not in-use,
///   not "stopped") fell through with `keepName` empty and deleted every
///   `__album__` container, including one in use. `recognised` is now an
///   explicit positive test (mirroring `albumWatcherDecision`), checked and
///   aborted on BEFORE the context-readable guard even runs.
///
/// Containers only: never names a `track` or a `song`, so it cannot reach a
/// library row. A test pins that, same as the other two sweeps in this file.
func albumStaleSweepScript() -> String {
    albumSweepGuardedScript(prefixes: [albumPlaylistPrefix], deferReturn: "return", countDeleted: false)
}

// MARK: - §18.4: one classification, one preamble

/// §18.4: `albumStaleSweepScript` and `playlistCleanupScript` used to carry
/// the same twelve-line guard preamble near-verbatim. §17.2's defect — a
/// guard nested inside a branch that never executed — existed in BOTH
/// copies and had to be fixed in both, which is the duplication already
/// costing once. `PlaylistDataSources.swift` names this shape for the
/// Discover sweep (`shouldSpareCurrentPlaylist` as the Swift twin of
/// `discoverSweepScript`'s guard, "the shape adopted after twin-drift
/// produced two shipped bugs"). This is the same idea applied to the two
/// ALBUM sweeps — which, unlike Discover, already share one in-use set
/// (`albumInUsePlayerStates`), so one Swift decision function covers both.
///
/// Unlike `shouldSpareCurrentPlaylist` (a single readable/unreadable
/// player-state question), this preamble has TWO guards in sequence — an
/// unrecognised state defers before context is even consulted, and an
/// unreadable context defers separately — so the pure twin needs both
/// inputs to be a faithful mirror rather than a partial one.
enum AlbumSweepDecision: Equatable {
    /// Player state unrecognised, or (while in an in-use state) the current
    /// playlist could not be read: abort, delete nothing.
    case deferSweep
    /// Safe to run the delete loop, sparing whichever playlist name the
    /// script resolved as `keepName` (empty when the state is "stopped" —
    /// nothing needs sparing then).
    case sweepSparingCurrent
}

/// Pure twin of the two-guard AppleScript preamble `albumSweepGuardedScript`
/// emits, over the SAME literals (`albumInUsePlayerStates`,
/// `unreadablePlayerStateFallback`) the generator uses — so the two can
/// never drift the way the two scripts already drifted from each other once
/// (§17.2). Unit-tested over a full truth table, the same shape
/// `AlbumWatcherDecisionTests` uses for `albumWatcherDecision`, rather than
/// the string-containment-only pins the two scripts had before: a pin can
/// see that a guard's literal text exists somewhere in the script, but it
/// cannot see that the guard is reachable, which is exactly what §17.2's
/// defect broke.
///
/// `playerState` is the resolved state text — nil exactly where the
/// generated script's own `try` would have failed and fallen back to
/// `unreadablePlayerStateFallback` (itself an in-use state), so nil here
/// resolves identically to passing `unreadablePlayerStateFallback` would.
/// `contextReadable` mirrors the script's own `contextReadable` variable —
/// only consulted when the state is in-use; irrelevant for "stopped"
/// (nothing to spare) and for an unrecognised state (already deferred
/// before context is ever read).
func albumSweepDecision(playerState: String?, contextReadable: Bool) -> AlbumSweepDecision {
    let state = playerState ?? unreadablePlayerStateFallback
    let recognised = albumInUsePlayerStates.contains(state) || state == "stopped"
    guard recognised else { return .deferSweep }
    if albumInUsePlayerStates.contains(state) {
        guard contextReadable else { return .deferSweep }
    }
    return .sweepSparingCurrent
}

/// The shared two-guard preamble both album sweep scripts emit, derived
/// from the exact literals `albumSweepDecision` above tests against, plus
/// each generator's own delete loop.
///
/// `prefixes` is the set of temp-playlist prefixes the delete loop matches —
/// `[albumPlaylistPrefix]` alone for the narrower, automatic stale sweep;
/// `["__temp__", albumPlaylistPrefix]` for the user-invoked general cleanup.
/// `deferReturn` is the AppleScript `return` statement text BOTH guards emit
/// when they defer: `return "deferred"` for the cleanup command (which
/// reports an honest outcome), a bare `return` for the stale sweep (which
/// has no result to report and runs silently on every album play).
/// `countDeleted` selects the cleanup command's counted, four-outcome delete
/// phase versus the stale sweep's uncounted one.
///
/// §20: snapshot, then delete. Both prior loops here deleted `pp` while
/// iterating `every user playlist`, the same live collection the deletion
/// mutated — AppleScript enumeration semantics then skip the element right
/// after the one just deleted, so one cleanup invocation collected roughly
/// half of N stale containers (measured live 2026-09-02: 4 left 2, 2 left 1).
/// Four whole-branch text reviews reasoned about this loop without executing
/// it and missed it; only a live measurement caught it.
///
/// The fix is two strictly-ordered phases:
///
/// 1. Enumerate `every user playlist` ONCE, read-only — no delete anywhere
///    in this loop — and build `eligibleNames`, a deduplicated list of exact
///    names matching a given prefix, EXCLUDING `keepName` at capture time
///    (an active/paused container is excluded from the snapshot, never
///    captured, never deleted). Only the name (a string) is kept; the live
///    playlist reference `pp` is never retained past its own iteration.
///    `matchedAny` separately records whether ANY playlist matched a prefix
///    at all, including the spared one — this is what lets the counted
///    variant tell "nothing existed" apart from "something existed but was
///    spared" once every eligible name has been captured.
/// 2. AFTER that enumeration finishes, delete each captured name using the
///    same exact-name reference form `playlistDeleteScript` already uses
///    (`every user playlist whose name is "..."`) — proven live, and immune
///    to the mutate-while-enumerating defect because it re-resolves the
///    reference fresh per name rather than walking a live collection.
///    Exact-name deletion intentionally removes ALL playlist objects sharing
///    a captured name (this is what makes the legacy same-second `__temp__`
///    collision deterministic), so the counted variant sums
///    `count of (every user playlist whose name is nm)` per name rather than
///    counting names processed — one captured name can remove more than one
///    object.
func albumSweepGuardedScript(prefixes: [String], deferReturn: String, countDeleted: Bool) -> String {
    let inUse = albumInUsePlayerStates
        .map { "playerStateText is \"\($0)\"" }
        .joined(separator: " or ")
    let prefixTest = prefixes
        .map { "(nm starts with \"\($0)\")" }
        .joined(separator: " or ")
    let deleteBody: String
    if countDeleted {
        deleteBody = """
        set deleted to 0
        repeat with nm in eligibleNames
            try
                set deleted to deleted + (count of (every user playlist whose name is nm))
                delete (every user playlist whose name is nm)
            end try
        end repeat
        if deleted > 0 then
            return deleted
        else if matchedAny then
            return "spared"
        else
            return "none"
        end if
        """
    } else {
        deleteBody = """
        repeat with nm in eligibleNames
            try
                delete (every user playlist whose name is nm)
            end try
        end repeat
        """
    }
    return """
    set keepName to ""
    set playerStateText to "\(unreadablePlayerStateFallback)"
    try
        set playerStateText to player state as text
    end try
    set recognised to (\(inUse) or playerStateText is "stopped")
    if not recognised then \(deferReturn)
    set contextReadable to true
    if \(inUse) then
        set contextReadable to false
        try
            set keepName to name of current playlist
            set contextReadable to true
        end try
    end if
    if not contextReadable then \(deferReturn)
    set eligibleNames to {}
    set matchedAny to false
    repeat with pp in (every user playlist)
        try
            set nm to name of pp
            if (\(prefixTest)) then
                set matchedAny to true
                if (nm is not keepName) and (eligibleNames does not contain nm) then
                    set end of eligibleNames to nm
                end if
            end if
        end try
    end repeat
    \(deleteBody)
    """
}

func createEmptyPlaylistViaAppleScript(name: String, backend: AppleScriptBackend) throws {
    _ = try syncRun {
        try await backend.runMusic(
            "make new playlist with properties {name:\"\(escapeAppleScriptString(name))\"}")
    }
}

struct PlaylistCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Argument(help: "Result indices to add (from last search/similar)") var indices: [Int] = []
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let auth = AuthManager()
        let devToken = try? auth.requireDeveloperToken()
        let userToken = auth.userToken()

        let (resolved, dropped) = ResultCache().lookupSongs(indices: indices)
        if !dropped.isEmpty {
            errorOut("⚠ Skipped index(es) not in the last results: \(dropped.map(String.init).joined(separator: ", "))")
        }

        switch playlistCreateStrategy(hasTokens: devToken != nil && userToken != nil,
                                      indexCount: indices.count,
                                      allLibraryRows: allLibraryRows(resolved)) {
        case .needsAuthToSeed:
            print("Adding tracks to a new playlist needs a Music User Token. Run: music auth setup")
            print("Creating an empty playlist needs no token: music playlist create \"\(name)\"")
            print("Tracks from a library search need no token: music search \"query\" --library, then music playlist create \"\(name)\" 1 2")
            throw ExitCode.failure

        case .appleScriptEmpty:
            // `make new playlist` is the same call the temp-playlist machinery
            // uses below, and it has never needed a token.
            let backend = AppleScriptBackend()
            try createEmptyPlaylistViaAppleScript(name: name, backend: backend)
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["created": name, "tracks": []]))
            } else {
                print("Created playlist '\(name)'.")
            }
            return

        case .appleScriptSeedFromLibrary:
            let backend = AppleScriptBackend()
            try createEmptyPlaylistViaAppleScript(name: name, backend: backend)
            let (added, failed) = duplicateLibraryRows(resolved, toPlaylist: name, backend: backend)
            for row in added { print("  + \(row.title) by \(row.artist)") }
            for row in failed { print("  ✗ Not in your library: \(row.title) by \(row.artist)") }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render([
                    "created": name,
                    "tracks": added.map { ["title": $0.title, "artist": $0.artist] },
                    "failed": failed.map { ["title": $0.title, "artist": $0.artist] }
                ]))
            } else if added.isEmpty {
                print("Created playlist '\(name)'.")
            } else {
                print("Created '\(name)' with \(added.count) tracks.")
            }
            return

        case .rest:
            break
        }
        // `.rest` guarantees both tokens are present.
        guard let devToken, let userToken else { return }
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
        let backend = AppleScriptBackend()

        // One API call creates the playlist and seeds the tracks — no
        // add-to-library detour, no sync sleep, no per-track AppleScript.
        let (catalogRows, libraryRows) = partitionByOrigin(resolved)
        let songs = catalogRows.filter { !$0.catalogId.isEmpty }
        let noCatalog = catalogRows.filter { $0.catalogId.isEmpty }.map(\.index)
        if !noCatalog.isEmpty {
            errorOut("⚠ Skipped track(s) with no catalog id: \(noCatalog.map(String.init).joined(separator: ", "))")
        }
        _ = try syncRun { try await api.createPlaylist(name: name, songIDs: songs.map(\.catalogId)) }

        var added: [SongResult] = []
        var failed: [SongResult] = []
        // Mixed selection only: the strategy sends a pure library selection to AppleScript, so a REST create here always carried at least one catalog track and will sync.
        if !libraryRows.isEmpty {
            guard waitForLocalPlaylist(backend: backend, name: name, minTracks: songs.count) else {
                errorOut("✗ '\(name)' did not appear in Music.app in time; library rows not added: \(libraryRows.map { "\($0.title) by \($0.artist)" }.joined(separator: ", "))")
                throw ExitCode.failure
            }
            (added, failed) = duplicateLibraryRows(libraryRows, toPlaylist: name, backend: backend)
        }

        if json {
            let output = OutputFormat(mode: .json)
            print(output.render([
                "created": name,
                "tracks": songs.map { ["title": $0.title, "artist": $0.artist] }
                    + added.map { ["title": $0.title, "artist": $0.artist] },
                "failed": failed.map { ["title": $0.title, "artist": $0.artist] }
            ]))
            return
        }
        for song in songs { print("  + \(song.title) — \(song.artist)") }
        for row in added { print("  + \(row.title) by \(row.artist)") }
        for row in failed { print("  ✗ Not in your library: \(row.title) by \(row.artist)") }
        let total = songs.count + added.count
        if total == 0 {
            print("Created playlist '\(name)'.")
        } else {
            print("Created '\(name)' with \(total) tracks.")
        }
    }
}

struct PlaylistDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Flag(name: .long, help: "Skip confirmation") var force = false
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        // Deletion is irreversible and one typo away — confirm when a human is
        // at the keyboard. Scripts (no TTY) and --force skip the prompt.
        if !force && isatty(STDIN_FILENO) != 0 {
            print("Delete playlist '\(name)'? [y/N] ", terminator: "")
            let answer = readLine() ?? ""
            guard answer.lowercased().hasPrefix("y") else {
                print("Cancelled.")
                return
            }
        }
        let backend = AppleScriptBackend()
        _ = try syncRun {
            try await backend.runMusic(playlistDeleteScript(name: name))
        }
        print(json ? "{\"deleted\":\"\(name)\"}" : "Deleted playlist '\(name)'.")
    }
}

struct PlaylistAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add track(s) to playlist.")
    @Argument(help: "Playlist name") var playlist: String
    @Argument(help: "Song title or result indices") var items: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        let auth = AuthManager()
        let devToken = try? auth.requireDeveloperToken()
        let userToken = auth.userToken()
        let backend = AppleScriptBackend()

        let ints = items.compactMap { Int($0) }
        let itemsAreIndices = ints.count == items.count && !ints.isEmpty

        var resolved: [SongResult] = []
        if itemsAreIndices {
            let lookup = ResultCache().lookupSongs(indices: ints)
            resolved = lookup.resolved
            if !lookup.dropped.isEmpty {
                errorOut("⚠ Skipped index(es) not in the last results: \(lookup.dropped.map(String.init).joined(separator: ", "))")
            }
        }

        switch playlistAddStrategy(hasTokens: devToken != nil && userToken != nil,
                                   itemsAreIndices: itemsAreIndices,
                                   allLibraryRows: allLibraryRows(resolved)) {
        case .needsAuthForIndices:
            print("Adding by result index needs a Music User Token. Run: music auth setup")
            print("Adding a track you already own needs no token: music playlist add \"\(playlist)\" \"Song Title\"")
            print("Indices from a library search need no token: music search \"query\" --library, then music playlist add \"\(playlist)\" 1 2")
            throw ExitCode.failure

        case .appleScriptLibraryIndices:
            let (added, failed) = duplicateLibraryRows(resolved, toPlaylist: playlist, backend: backend)
            for row in added { print("  + \(row.title) by \(row.artist)") }
            for row in failed { print("  ✗ Not in your library: \(row.title) by \(row.artist)") }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render([
                    "added": added.count,
                    "playlist": playlist,
                    "failed": failed.map { ["title": $0.title, "artist": $0.artist] }
                ]))
            } else {
                print("Added \(added.count) track(s) to '\(playlist)'.")
            }
            if added.isEmpty { throw ExitCode.failure }
            return

        case .appleScriptLibrary:
            let wanted = items.first ?? ""
            guard !wanted.isEmpty else {
                print("Give a song title: music playlist add \"\(playlist)\" \"Song Title\"")
                throw ExitCode.failure
            }
            let wantedArtist = items.count > 1 ? items.dropFirst().joined(separator: " ") : ""
            guard duplicateLibraryTrack(backend: backend, title: wanted,
                                        artist: wantedArtist, toPlaylist: playlist) else {
                print("Not in your library: '\(wanted)'.")
                print("Adding from the Apple Music catalog needs a Music User Token. Run: music auth setup")
                throw ExitCode.failure
            }
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["added": 1, "playlist": playlist, "track": wanted]))
            } else {
                print("Added to '\(playlist)'.")
            }
            return

        case .rest:
            break
        }
        // `.rest` guarantees both tokens are present.
        guard let devToken, let userToken else { return }
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        if itemsAreIndices {
            guard !resolved.isEmpty else {
                errorOut("✗ No valid tracks to add.")
                return
            }
            let (catalogRows, libraryRows) = partitionByOrigin(resolved)
            if !catalogRows.isEmpty {
                try addSongs(catalogRows.map { CatalogSong(id: $0.catalogId, title: $0.title, artist: $0.artist, album: $0.album) },
                             to: playlist, api: api, backend: backend)
            }
            let (added, failed) = duplicateLibraryRows(libraryRows, toPlaylist: playlist, backend: backend)
            let total = catalogRows.count + added.count
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["added": total, "playlist": playlist]))
                return
            }
            for song in catalogRows { print("  + \(song.title) — \(song.artist)") }
            for row in added { print("  + \(row.title) by \(row.artist)") }
            for row in failed { print("  ✗ Not in your library: \(row.title) by \(row.artist)") }
            print("Added \(total) track(s) to '\(playlist)'.")
            return
        }

        let title = items.first ?? ""
        let artist: String? = items.count > 1 ? items.dropFirst().joined(separator: " ") : nil

        var searchQuery = title
        if let artist = artist { searchQuery += " \(artist)" }

        let foundSongs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
        guard let song = foundSongs.first else {
            print("No results for '\(searchQuery)'")
            throw ExitCode.failure
        }
        if !json { print("Found: \(song.title) — \(song.artist)") }
        try addSongs([song], to: playlist, api: api, backend: backend)
        if json {
            let output = OutputFormat(mode: .json)
            print(output.render(["added": 1, "playlist": playlist, "track": song.title, "artist": song.artist]))
        } else {
            print("Added to '\(playlist)'.")
        }
    }
}

/// Add catalog songs to a named playlist: one direct API call when the API can
/// see the playlist (every user-created playlist — verified live); otherwise
/// the legacy fallback (add to library, wait for sync, AppleScript duplicate).
func addSongs(_ songs: [CatalogSong], to playlist: String, api: RESTAPIBackend, backend: AppleScriptBackend) throws {
    let ids = songs.map(\.id).filter { !$0.isEmpty }
    if let plID = try? syncRun({ try await api.playlistID(named: playlist) }) {
        try syncRun { try await api.addTracksToPlaylist(playlistID: plID, songIDs: ids) }
        return
    }
    try syncRun { try await api.addToLibrary(songIDs: ids) }
    withStatus("Syncing library...") {
        _ = try? syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
    }
    for song in songs {
        if !duplicateLibraryTrack(backend: backend, title: song.title, artist: song.artist, toPlaylist: playlist) {
            print("  ✗ Couldn't add: \(song.title) — \(song.artist)")
        }
    }
}

struct PlaylistRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a track from a playlist.")
    @Argument(help: "Playlist name") var playlist: String
    @Argument(help: "Track name to remove") var title: String
    func run() throws {
        let backend = AppleScriptBackend()
        let escPlaylist = escapeAppleScriptString(playlist)
        let escTitle = escapeAppleScriptString(title)
        _ = try syncRun {
            try await backend.runMusic("""
                set t to (first track of playlist "\(escPlaylist)" whose name contains "\(escTitle)")
                delete t
            """)
        }
        print("Removed '\(title)' from '\(playlist)'.")
    }
}

struct PlaylistShare: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share", abstract: "Share a playlist.")
    @Argument(help: "Playlist name") var name: String
    @Option(name: .long, help: "Send via iMessage to phone/contact") var imessage: String?
    @Option(name: .long, help: "Send via email") var email: String?
    func run() throws {
        let backend = AppleScriptBackend()
        let escName = escapeAppleScriptString(name)
        let trackList = try syncRun {
            try await backend.runMusic("""
                set trackList to every track of playlist "\(escName)"
                set output to ""
                repeat with t in trackList
                    if output is not "" then set output to output & ", "
                    set output to output & name of t & " - " & artist of t
                end repeat
                return output
            """)
        }
        let message = "Check out my playlist '\(name)': \(trackList.trimmingCharacters(in: .whitespacesAndNewlines))"

        if let recipient = imessage {
            let escaped = escapeAppleScriptString(message)
            _ = try syncRun {
                try await backend.run("""
                    tell application "Messages"
                        set targetService to 1st account whose service type = iMessage
                        set targetBuddy to participant "\(escapeAppleScriptString(recipient))" of targetService
                        send "\(escaped)" to targetBuddy
                    end tell
                """)
            }
            print("Sent to \(recipient) via iMessage.")
        } else if let addr = email {
            let escaped = escapeAppleScriptString(message)
            _ = try syncRun {
                try await backend.run("""
                    tell application "Mail"
                        set newMessage to make new outgoing message with properties {subject:"Playlist: \(escName)", content:"\(escaped)", visible:true}
                        tell newMessage
                            make new to recipient at end of to recipients with properties {address:"\(escapeAppleScriptString(addr))"}
                        end tell
                        activate
                    end tell
                """)
            }
            print("Email composed to \(addr).")
        } else {
            print("Specify --imessage or --email")
            throw ExitCode.failure
        }
    }
}

struct PlaylistTemp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "temp", abstract: "Create a temporary playlist, play it, auto-delete on cleanup.")
    @Argument(help: "Alternating title artist pairs: \"Song1\" \"Artist1\" \"Song2\" \"Artist2\"") var items: [String]
    func run() throws {
        guard items.count >= 2, items.count % 2 == 0 else {
            print("Provide alternating title artist pairs: temp \"Song\" \"Artist\" \"Song2\" \"Artist2\"")
            throw ExitCode.failure
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let name = "__temp__\(timestamp)"
        let backend = AppleScriptBackend()

        _ = try syncRun {
            try await backend.runMusic("make new playlist with properties {name:\"\(escapeAppleScriptString(name))\"}")
        }

        for i in stride(from: 0, to: items.count, by: 2) {
            duplicateLibraryTrack(backend: backend, title: items[i], artist: items[i + 1], toPlaylist: name)
        }

        // Split into separate calls to avoid parameter error -50
        _ = try syncRun {
            try await backend.runMusic("set shuffle enabled to true")
        }
        _ = try syncRun {
            try await backend.runMusic("play playlist \"\(escapeAppleScriptString(name))\"")
        }
        print("Playing temp playlist with \(items.count / 2) tracks. Run `music playlist cleanup` when done.")
    }
}

struct PlaylistCreateFrom: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-from", abstract: "Create playlist from title/artist pairs.")
    @Argument(help: "Alternating title artist title artist...") var items: [String]
    @Option(name: .long, help: "Playlist name") var name: String = "New Playlist"
    func run() throws {
        guard let pairs = titleArtistPairs(items) else {
            print("Provide alternating title artist pairs: create-from \"Song\" \"Artist\" \"Song2\" \"Artist2\"")
            throw ExitCode.failure
        }

        let auth = AuthManager()
        let devToken = try? auth.requireDeveloperToken()
        let userToken = auth.userToken()

        // No key: resolve each pair against the library instead of the catalog.
        // Creating the playlist and duplicating tracks into it are both keyless.
        if devToken == nil || userToken == nil {
            let backend = AppleScriptBackend()
            let escName = escapeAppleScriptString(name)
            _ = try syncRun {
                try await backend.runMusic("make new playlist with properties {name:\"\(escName)\"}")
            }
            var added = 0
            var missing: [TitleArtist] = []
            for pair in pairs {
                if duplicateLibraryTrack(backend: backend, title: pair.title,
                                         artist: pair.artist, toPlaylist: name) {
                    print("  + \(pair.title) — \(pair.artist)")
                    added += 1
                } else {
                    missing.append(pair)
                    print("  ✗ Not in your library: \(pair.title) — \(pair.artist)")
                }
            }
            guard added > 0 else {
                // Match the REST path's contract: nothing found, nothing left behind.
                _ = try? syncRun {
                    try await backend.runMusic("delete (every playlist whose name is \"\(escName)\")")
                }
                print("No tracks found. Playlist not created.")
                print("Finding tracks you do not own needs a Music User Token. Run: music auth setup")
                throw ExitCode.failure
            }
            print("Created '\(name)' with \(added) track(s) from your library.")
            if !missing.isEmpty {
                print("Not in your library (\(missing.count)). Reaching the Apple Music catalog needs a Music User Token.")
            }
            return
        }
        // Both tokens present.
        guard let devToken, let userToken else { return }
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var found: [CatalogSong] = []
        var failed: [(title: String, artist: String)] = []
        for pair in pairs {
            let title = pair.title
            let artist = pair.artist
            do {
                let songs = try syncRun { try await api.searchSongs(query: "\(title) \(artist)", limit: 1) }
                if let song = songs.first {
                    found.append(song)
                    print("  + \(song.title) — \(song.artist)")
                } else {
                    failed.append((title: title, artist: artist))
                    print("  ✗ Not found: \(title) — \(artist)")
                }
            } catch {
                failed.append((title: title, artist: artist))
                print("  ✗ Search failed: \(title) — \(artist)")
            }
        }

        guard !found.isEmpty else {
            print("No tracks found. Playlist not created.")
            throw ExitCode.failure
        }

        // Create + populate in one API call (no library detour, no sync sleep).
        _ = try syncRun { try await api.createPlaylist(name: name, songIDs: found.map(\.id)) }

        print("Created '\(name)' with \(found.count) tracks.")
        if !failed.isEmpty {
            print("Failed (\(failed.count)): \(failed.map { "\($0.title) — \($0.artist)" }.joined(separator: ", "))")
        }
    }
}

struct PlaylistCleanup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup", abstract: "Delete all temp playlists.")
    func run() throws {
        let backend = AppleScriptBackend()
        let result = try syncRun {
            try await backend.runMusic(playlistCleanupScript())
        }
        switch parsePlaylistCleanupResult(result) {
        case .removed(let count):
            print("Cleaned up \(count) temp playlist(s).")
        case .nothingExisted:
            print("No temp playlists to clean up.")
        case .sparedCandidates:
            // §20.3: never say "Cleaned up 0" here — that reads as "nothing to
            // clean", but a matching container DID exist; it was correctly
            // spared because it's the one currently playing or paused.
            print("Found a temp playlist, but it's currently playing or paused, so it was spared. "
                + "Nothing was deleted. Try again once playback settles, or after it stops.")
        case .deferred:
            // §16.5: never say "Cleaned up 0" here — that reads as "nothing to
            // clean", but this path means playback is active and its context
            // couldn't be read, so cleanup COULD NOT tell what's safe to
            // delete and deleted nothing.
            print("Cleanup deferred: playback is active and its container couldn't be identified, "
                + "so nothing was deleted. Try again once playback settles, or after it stops.")
        case .unreadable:
            // §17.4: never say "Cleaned up 0" here either — the script's
            // result didn't parse, so whether anything was deleted is
            // genuinely unknown; claiming 0 would misreport a non-empty
            // sweep as an empty one just as surely as the deferred case did.
            print("Cleanup ran, but its result couldn't be read, so it's unknown how many temp playlists "
                + "were removed. Run `music playlist cleanup` again, or check your library for a leftover "
                + "__temp__ or \(albumPlaylistPrefix.trimmingCharacters(in: .whitespaces)) playlist.")
        }
    }
}

/// Pure parse of the playlist-tracks AppleScript payload: one track per line,
/// fields joined by asFieldSep (ASCII 31 — titles can legally contain "|",
/// the old delimiter, which shifted artist/album and poisoned the play cache).
/// Malformed lines (wrong field count, non-numeric index) are skipped.
func parsePlaylistTrackLines(_ raw: String) -> [(num: Int, title: String, artist: String, album: String)] {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n")
        .compactMap { line in
            let parts = line.split(separator: asFieldSep, maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let num = Int(parts[0]) else { return nil }
            return (num: num, title: parts[1], artist: parts[2], album: parts[3])
        }
}

import Foundation

/// The three AppleScript-backed closures the playlist browser/scene needs,
/// plus shared caches captured inside them. Built once per browse session.
struct PlaylistDataSources {
    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)]
    let onPreview: (Int) -> [String]?
    let onTracks: (Int) -> PlaylistPreview?
    /// One-shot REST map of lowercased-trimmed playlist name → (REST id, artwork
    /// URL), for real hero covers. nil when the user isn't signed in / no dev
    /// token — the scene keeps gradients, exactly today's token-less behavior.
    /// Name matching is heuristic (same class as albumArtistSet); built-in smart
    /// playlists aren't API-visible and simply never match.
    let onArtworkMap: (() -> [String: (id: String, url: String)])?
}

/// One playlist's rail metadata, persisted between launches so the browser paints
/// instantly instead of waiting on per-playlist AppleScript (`count of tracks`,
/// `duration` — slow for large playlists). Keyed by playlist name.
struct CachedPlaylistMeta: Codable {
    let count: Int
    let durationSec: Int
    let isSmart: Bool
    let specialKind: String
}

/// On-disk cache of playlist rail metadata at `~/.config/music/playlist-meta.json`
/// (same dir as ResultCache). Best-effort: any read/write failure is silent and the
/// browser falls back to a live (background) fetch.
enum PlaylistMetaCache {
    static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/music/playlist-meta.json"
    }

    static func load() -> [String: CachedPlaylistMeta] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONDecoder().decode([String: CachedPlaylistMeta].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ dict: [String: CachedPlaylistMeta]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Parse one `onMeta` result line: "idx|count|durationSeconds|smart|specialKind".
func parsePlaylistMetaLine(_ line: Substring) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    let f = line.split(separator: "|", maxSplits: 4).map(String.init)
    guard f.count == 5, let idx = Int(f[0]) else { return nil }
    let count = Int(f[1]) ?? 0
    let dur = Int(Double(f[2]) ?? 0)
    let smart = f[3].trimmingCharacters(in: .whitespaces) == "true"
    return (idx, count, dur, smart, f[4].trimmingCharacters(in: .whitespaces))
}

func parsePlaylistMetaLine(_ line: String) -> (index: Int, count: Int, durationSec: Int, isSmart: Bool, specialKind: String)? {
    parsePlaylistMetaLine(Substring(line))
}

/// Parse the `onTracks` result: "totalCount|line\nline\n...".
func parsePlaylistTracksResult(_ result: String) -> (count: Int, lines: [String]) {
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "|", maxSplits: 1)
    let count = Int(parts.first ?? "0") ?? 0
    let lines = parts.count > 1
        ? String(parts[1]).components(separatedBy: "\n").filter { !$0.isEmpty }
        : []
    return (count, lines)
}

/// Fetch the user's playlist names (one instant AppleScript call).
/// Delete leftover "__queue__ …" temp playlists from prior sessions, sparing the one
/// currently playing — deleting the playing playlist reverts Music to the library.
/// Safe to run off-main at startup. Called once, from the shell's launch path.
///
/// Legacy cleanup, deliberately left on the old SPARE RULE: nothing in Sources/
/// creates a `__queue__ ` playlist any more, so this collects containers from
/// versions that did. The paused-container leak fixed in `discoverSweepScript`
/// below is not worth porting here, because no path feeds this prefix.
///
/// §20.12: the ENUMERATION is another matter and is now fixed. This was still a
/// `delete pp` while iterating the collection it mutated, so a launch carrying
/// several legacy orphans collected roughly half of them per run. §20.11's
/// commit called the Discover sweep "the last carrier" of that defect; that was
/// wrong, and this is why — it was the last carrier among CURRENTLY GENERATED
/// containers. Spare rule unchanged, enumeration corrected.
/// The legacy `__queue__` sweep script, extracted so it can be EXECUTED in a
/// test rather than only read. It was inline, which is why the §20 defect
/// survived here after both other sweeps were corrected.
func legacyQueueSweepScript() -> String {
    """
        set keepName to ""
        try
            set keepName to name of current playlist
        end try
        set eligibleNames to {}
        repeat with pp in (every user playlist)
            try
                set nm to name of pp
                if (nm starts with "__queue__ ") and (nm is not keepName) and (eligibleNames does not contain nm) then
                    set end of eligibleNames to nm
                end if
            end try
        end repeat
        repeat with nm in eligibleNames
            try
                delete (every user playlist whose name is nm)
            end try
        end repeat
"""
}

func sweepQueuePlaylists(backend: AppleScriptBackend) {
    _ = try? syncRun {
        try await backend.runMusic(legacyQueueSweepScript())
    }
}

/// Player states in which the current playlist is NOT in use and may be swept.
///
/// Music's `player state` has five values (sdef, read 2026-08-31): stopped,
/// playing, paused, fast forwarding, rewinding. Naming the two idle ones rather
/// than the three active ones is what makes a scrub safe, and it puts any state
/// Apple adds later on the spare side by construction.
let sweepablePlayerStates = ["paused", "stopped"]

/// Substituted when `player state` cannot be read, so an unreadable state
/// spares rather than sweeps. Must not itself be a sweepable state; a test
/// pins that.
let unreadablePlayerStateFallback = "playing"

/// True when the current playlist must be spared from a temp-container sweep.
///
/// NOT the live path — the guard that runs is the AppleScript in
/// `discoverSweepScript()`. Both derive from `sweepablePlayerStates` and a test
/// pins that the generated script keys on the same literals, so the two cannot
/// drift. This mirrors `nowPlayingReadyState` (PlaybackCommands.swift), the
/// shape adopted after twin-drift produced two shipped bugs.
///
/// The asymmetry is deliberate: a spared container costs one leftover row that
/// the next sweep collects, while a wrongly swept one reverts live playback to
/// the library. So everything unrecognised spares.
func shouldSpareCurrentPlaylist(playerState: String?) -> Bool {
    guard let state = playerState else { return true }
    return !sweepablePlayerStates.contains(state)
}

/// The capture condition of `discoverSweepScript`, as a pure decision: a
/// name is captured for deletion when it carries the Discover prefix, is not
/// the kept (current, active) playlist, and is not protected by this session.
///
/// NOT the live path, and deliberately a twin of the CAPTURE CONDITION ONLY.
/// The preamble's state read and unreadable-context deferral are pinned by the
/// whole-script execution tests, which remain the authority for that
/// behaviour; mirroring them here would be a second copy of a guard, which is
/// the drift shape this repo has shipped two bugs from. A test asserts the
/// emitted script keys on the same prefix and the same escaped list.
func discoverCaptureDecision(name: String, keepName: String, protected: [String]) -> Bool {
    name.hasPrefix(discoverPlaylistPrefix) && name != keepName && !protected.contains(name)
}

/// The names this session is still bringing up, or could not confirm as its
/// own, baked into the sweep as a literal list (Discover lifecycle design
/// §3.5). An EMPTY list emits today's script byte for byte: no variable line,
/// no empty list, no extra clause. That exact form is the regression pin, so
/// a syntactically equivalent empty-list form would break it on purpose.
private func discoverProtectedNamesPreamble(_ names: [String]) -> String {
    guard !names.isEmpty else { return "" }
    let list = names.map { "\"\(escapeAppleScriptString($0))\"" }.joined(separator: ", ")
    return "set protectedNames to {\(list)}\n"
}

private func discoverProtectedNamesClause(_ names: [String]) -> String {
    names.isEmpty ? "" : " and (protectedNames does not contain nm)"
}

/// The Discover container sweep, as text. Pure, so it can be pinned by tests.
/// Run at TUI launch and exit by `DiscoverLifecycleCoordinator`, sparing the
/// current playlist only while playback is actually active — playing,
/// scrubbing, or in a state we could not read. A paused or stopped container
/// is collected, which is the whole point: `current playlist` outlives a
/// pause, so the old spare-the-current rule never released one.
///
/// Containers only, by design: this script never says `track` or `song` and
/// never can reach a library row — it enumerates `every user playlist` and
/// `delete`s whichever ones it named, nothing else. See DiscoverPlay.swift's
/// module doc for why a sweep that could reach a track is unsafe: Apple
/// exposes no authorship for a library row, so any such cleanup risks deleting
/// music the user added themselves. The songs a Discover play adds stay,
/// permanently — only the container it created is ever removed, and only by
/// the name this app gave it. A test pins that invariant.
///
/// `current playlist` outlives both a pause and a Music.app restart (measured
/// 2026-08-31), so reading it unconditionally — as this script used to — spared
/// a paused container permanently and leaked one row per paused Discover play.
/// The state guard is what scopes "in use" to actual playback.
///
/// Deleting the current playlist while PAUSED is safe, measured 2026-08-31 over
/// a hand-built container: player state stayed `paused`, the current track and
/// player position both survived byte-identical, play resumed that same track,
/// and the source library rows were untouched. What it does cost is context —
/// `current playlist` reverts to the library, so what follows the paused track
/// is library order rather than the rest of the container.
/// §20.12: an ACTIVE state with an unreadable context now defers.
///
/// The state read falls back to `playing`, which fails toward sparing — but the
/// identity needed to spare with was then read in a bare `try`. If
/// `name of current playlist` threw, `keepName` stayed empty and the sweep
/// captured and deleted EVERY Discover container, including the one playing.
/// Measured in the harness: `state: "playing"`, unreadable context, both
/// containers gone. The state was recognised; the identity was not, and the
/// documented asymmetry above says a wrongly swept container reverts live
/// playback to the library. The album cleanup already deferred here; this did
/// not. Paused is untouched: it is sweepable and never needs a readable
/// context, so only a NON-sweepable state with an unreadable one defers.
///
/// §20.11: snapshot, then delete — the same correction the album sweeps got.
///
/// This loop used to `delete pp` while enumerating `every user playlist`, the
/// live collection the deletion mutated, so one pass collected roughly HALF the
/// matching containers (measured 2026-09-02 on a real library: four stale
/// containers, one run, two removed). It converged over repeated runs, which is
/// exactly why it never presented as a symptom — the TUI sweeps at both launch
/// and exit, so a leftover was usually collected on a later pass.
///
/// It was deliberately held back from the album wave to keep that correction
/// narrow, and because the Discover lifecycle has its own **deliberately
/// different sparing rule**: `sweepablePlayerStates` means a PAUSED container
/// is collected here, where the album cleanup spares it. That rule is untouched
/// — only the enumeration is fixed. `keepName` is still set solely in a
/// non-sweepable state, so the paused-collect behaviour is preserved, and the
/// nine tests pinning the sparing truth table still hold.
///
/// Discover lifecycle design §3.5: `protectedNames` are this session's own
/// in-flight or unconfirmed containers, which the exit sweep must never
/// collect whatever state Music reports. They are excluded in the capture
/// condition, alongside `keepName`; an empty list emits the pre-existing
/// script unchanged, byte for byte.
func discoverSweepScript(protectedNames: [String] = []) -> String {
    let activeGuard = sweepablePlayerStates
        .map { "playerStateText is not \"\($0)\"" }
        .joined(separator: " and ")
    let protectedPreamble = discoverProtectedNamesPreamble(protectedNames)
    let protectedClause = discoverProtectedNamesClause(protectedNames)
    return """
        \(protectedPreamble)set keepName to ""
        set contextReadable to true
        set playerStateText to "\(unreadablePlayerStateFallback)"
        try
            set playerStateText to player state as text
        end try
        if \(activeGuard) then
            set contextReadable to false
            try
                set keepName to name of current playlist
                set contextReadable to true
            end try
        end if
        if not contextReadable then return
        set eligibleNames to {}
        repeat with pp in (every user playlist)
            try
                set nm to name of pp
                if (nm starts with "\(discoverPlaylistPrefix)") and (nm is not keepName)\(protectedClause) and (eligibleNames does not contain nm) then
                    set end of eligibleNames to nm
                end if
            end try
        end repeat
        repeat with nm in eligibleNames
            try
                delete (every user playlist whose name is nm)
            end try
        end repeat
        """
}

/// The `__temp__` prefix as EMITTED by the two creation sites
/// (`DiscoveryCommands.swift`, `PlaylistCommands.swift`) and MATCHED by the
/// display sites below.
///
/// Named for creation deliberately, because it is NOT the single owner of this
/// string. The sweep scripts still carry their own literal `"__temp__"` in
/// their prefix lists (`PlaylistCommands.swift`, the `albumSweepGuardedScript`
/// callers), because those govern DELETION and were out of scope for the
/// display change that introduced this constant.
///
/// **Changing this value does not update the sweep matchers. Changing it alone
/// therefore BREAKS cleanup ownership**: newly created containers would no
/// longer match the old literal and would stop being collected. The
/// independent literals must remain byte-identical until the backlog
/// consolidation lands. (Sharpened by Codex, 2026-09-03: the earlier wording,
/// "does not change what gets swept", was mechanically true of the generated
/// script text and read as though editing this were safe.)
let tempPlaylistCreationPrefix = "__temp__"

/// Now Playing's stable label for a `__temp__` container. Anthony, 2026-09-03:
/// do not expose `__temp__<timestamp>` and do not reduce it to a meaningless
/// timestamp. The raw name is kept everywhere identity and cleanup need it.
let temporaryPlaylistLabel = "Temporary playlist"

/// Temp playlists this app creates and later sweeps. Hidden from the Playlists
/// rail and stripped from Now Playing, so the user never sees the plumbing.
/// A list rather than a constant: a third temp kind should be a one-line change,
/// not a third copy of the same two call sites.
let tempPlaylistPrefixes = ["__queue__ ", discoverPlaylistPrefix, albumPlaylistPrefix,
                            tempPlaylistCreationPrefix]

func isTempPlaylistName(_ name: String) -> Bool {
    tempPlaylistPrefixes.contains { name.hasPrefix($0) }
}

/// Parse the rail-names script output: one `U<US>name` (user playlist) or
/// `S<US>name` (subscription playlist) line per playlist. Pure, tested.
/// Filters obsolete temp playlists (queue, Discover, ...) so they don't clutter
/// the rail.
func parseRailPlaylistNames(_ raw: String) -> (names: [String], subscription: Set<String>) {
    var names: [String] = []
    var subscription: Set<String> = []
    for line in raw.components(separatedBy: "\n") {
        let parts = line.split(separator: asFieldSep, maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isTempPlaylistName(name) else { continue }
        names.append(name)
        if parts[0].trimmingCharacters(in: .whitespaces) == "S" { subscription.insert(name) }
    }
    return (names, subscription)
}

/// Apple-curated playlists added to the library are class `subscription
/// playlist`, NOT `user playlist` — `every user playlist` silently omits them
/// (they only ever appeared in the rail via manual duplicates). Enumerate both
/// classes in one call; downstream code resolves `playlist "name"` generically,
/// which covers both.
func fetchUserPlaylistNames(backend: AppleScriptBackend) -> (names: [String], subscription: Set<String>) {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set output to ""
            repeat with p in (every user playlist)
                if output is not "" then set output to output & linefeed
                set output to output & "U" & fs & name of p
            end repeat
            repeat with p in (every subscription playlist)
                if output is not "" then set output to output & linefeed
                set output to output & "S" & fs & name of p
            end repeat
            return output
        """)
    }) else { return ([], []) }
    return parseRailPlaylistNames(result)
}

/// Build the three data-source closures over a fixed `names` list. Each closure
/// owns its own cache. Bulk `tracks 1 thru n` fetches (never per-element) per the
/// performance lesson in docs/playbook.md.
func makePlaylistDataSources(backend: AppleScriptBackend, names: [String], artworkAPI: RESTAPIBackend? = nil) -> PlaylistDataSources {
    var trackCache: [Int: PlaylistPreview] = [:]
    var previewCacheLight: [Int: [String]] = [:]

    let onTracks: (Int) -> PlaylistPreview? = { idx in
        if let cached = trackCache[idx] { return cached }
        guard idx >= 0, idx < names.count else { return nil }
        let plName = names[idx]
        let escapedPlName = escapeAppleScriptString(plName)
        guard let trackResult = try? syncRun({
            try await backend.runMusic("""
                set n to count of tracks of playlist "\(escapedPlName)"
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(escapedPlName)"
                    set ars to artist of tracks 1 thru n of playlist "\(escapedPlName)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " — " & (item i of ars)
                    end repeat
                end if
                return (n as text) & "|" & output
            """)
        }) else { return nil }
        let parsed = parsePlaylistTracksResult(trackResult)
        let preview = PlaylistPreview(name: plName, trackCount: parsed.count, tracks: parsed.lines)
        trackCache[idx] = preview
        return preview
    }

    let onMeta: ([Int]) -> [Int: (Int, Int, Bool, String)] = { indices in
        guard !indices.isEmpty else { return [:] }
        var clauses = ""
        for idx in indices where idx >= 0 && idx < names.count {
            let esc = escapeAppleScriptString(names[idx])
            // Each playlist is independent: a failure (resolution or any property)
            // must not abort the whole batch, and each property degrades to a default
            // rather than throwing. Otherwise one bad entry blanks 8 rows.
            clauses += """
            try
                set p to playlist "\(esc)"
                set c to 0
                try
                    set c to count of tracks of p
                end try
                set d to 0
                try
                    set d to duration of p
                end try
                set sm to false
                try
                    set sm to smart of p
                end try
                set sk to "none"
                try
                    set sk to (special kind of p as text)
                end try
                set output to output & "\(idx)|" & c & "|" & d & "|" & sm & "|" & sk & linefeed
            end try

            """
        }
        guard let result = try? syncRun({
            try await backend.runMusic("""
                set output to ""
                \(clauses)
                return output
            """)
        }) else { return [:] }
        var out: [Int: (Int, Int, Bool, String)] = [:]
        for line in result.split(separator: "\n") {
            if let p = parsePlaylistMetaLine(line) {
                out[p.index] = (p.count, p.durationSec, p.isSmart, p.specialKind)
            }
        }
        return out
    }

    let onPreview: (Int) -> [String]? = { idx in
        if let c = previewCacheLight[idx] { return c }
        guard idx >= 0, idx < names.count else { return nil }
        let esc = escapeAppleScriptString(names[idx])
        guard let res = try? syncRun({
            try await backend.runMusic("""
                set total to count of tracks of playlist "\(esc)"
                set n to total
                if n > 40 then set n to 40
                set output to ""
                if n > 0 then
                    set ns to name of tracks 1 thru n of playlist "\(esc)"
                    set ars to artist of tracks 1 thru n of playlist "\(esc)"
                    repeat with i from 1 to n
                        if output is not "" then set output to output & linefeed
                        set output to output & (item i of ns) & " \u{2014} " & (item i of ars)
                    end repeat
                end if
                return output
            """)
        }) else { return nil }
        let lines = res.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").map(String.init)
        previewCacheLight[idx] = lines
        return lines
    }

    return PlaylistDataSources(
        onMeta: onMeta, onPreview: onPreview, onTracks: onTracks,
        onArtworkMap: artworkAPI.map { api in
            {
                let playlists = (try? syncRun { try await api.libraryPlaylists() }) ?? []
                var map: [String: (id: String, url: String)] = [:]
                for p in playlists {
                    guard let u = p.artworkURL else { continue }
                    map[p.name.lowercased().trimmingCharacters(in: .whitespaces)] = (p.id, u)
                }
                return map
            }
        }
    )
}

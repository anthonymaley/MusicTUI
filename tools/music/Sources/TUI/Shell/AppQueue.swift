// tools/music/Sources/TUI/Shell/AppQueue.swift
import Foundation

/// An app-owned playback queue. macOS 26.x broke `play track N of playlist X`
/// (it drops the playlist context and lets Music's Autoplay bleed into the
/// library at track end), so we no longer rely on Music's native queue for
/// playlists. Instead the app holds the ordered track list and drives playback
/// itself: play one track, let it STOP at its end (requires Music's Autoplay
/// turned off), and the poller advances to the next. This restores the full
/// up/down navigation Apple's regression took away — and is immune to it, since
/// Music is never asked to remember a queue.
struct AppQueue: Codable, Equatable {
    let playlistName: String          // source playlist, for `play track N of playlist ...`
    let tracks: [TrackListEntry]      // PLAY ORDER; each `.index` = source playlist position
    var currentIndex: Int             // 1-based position in the play order (the `tracks` array)
    /// User-facing Up Next label when the source playlist name isn't presentable —
    /// an album/artist queue plays FROM "Library" but should read "Moon Safari".
    /// Defaults to playlistName (a playlist's own name is already user-facing).
    var displayName: String? = nil

    /// Source-playlist position of the currently-playing track (what `play track N
    /// of playlist X` needs). Differs from `currentIndex` once the queue is shuffled.
    var currentSourcePosition: Int { tracks[currentIndex - 1].index }
    /// The name Now Playing shows for the queue (displayName if set, else source).
    var contextLabel: String { displayName ?? playlistName }
}

/// What auto-advance does after a play attempt errors. `step(1)` has already
/// committed the index by the time the play runs, so an unhandled failure used
/// to walk the whole remaining queue (naturalEnd stayed true every tick). The
/// gate bounds that: retry the same track (caller rolls the step back) up to
/// maxRetries, then skip past it so a permanently erroring play can't spin
/// forever. Pure → unit-tested.
enum AdvanceAction: Equatable {
    case retry
    case skip
}

struct AdvanceRetryGate {
    private(set) var failures = 0
    let maxRetries: Int
    init(maxRetries: Int = 3) { self.maxRetries = maxRetries }

    mutating func playSucceeded() { failures = 0 }

    mutating func playFailed() -> AdvanceAction {
        failures += 1
        if failures >= maxRetries { failures = 0; return .skip }
        return .retry
    }
}

/// Thread-safe holder shared between the main loop (selection, next/prev) and the
/// poller thread (auto-advance). Nil when no app-owned queue is active — playback
/// is then album/library/native and the poller falls back to Music's context.
final class AppQueueStore {
    private let lock = NSLock()
    private var queue: AppQueue?

    func set(_ value: AppQueue?) { lock.lock(); queue = value; lock.unlock() }
    func clear() { set(nil) }
    func read() -> AppQueue? { lock.lock(); defer { lock.unlock() }; return queue }
    var isActive: Bool { read() != nil }

    /// Move the play-order position by `delta`, clamped to the queue. Returns the
    /// (playlist, sourcePosition) to play, or nil if there's no queue or the step
    /// falls off either end.
    func step(_ delta: Int) -> (playlist: String, position: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queue else { return nil }
        let next = q.currentIndex + delta
        guard next >= 1, next <= q.tracks.count else { return nil }
        q.currentIndex = next
        queue = q
        return (q.playlistName, q.currentSourcePosition)
    }

    /// Jump to an absolute 1-based play-order position. Returns (playlist,
    /// sourcePosition) to play, or nil if out of range / no queue.
    func jump(to playOrderPosition: Int) -> (playlist: String, position: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queue else { return nil }
        guard playOrderPosition >= 1, playOrderPosition <= q.tracks.count else { return nil }
        q.currentIndex = playOrderPosition
        queue = q
        return (q.playlistName, q.currentSourcePosition)
    }
}

/// Play a single track by its 1-based position in a playlist. With Music's
/// Autoplay off this plays the one track and stops at its end, letting the poller
/// drive the next. `current playlist` collapsing to the library (the 26.x bug) is
/// irrelevant here — the app owns the queue, not Music.
@discardableResult
func playQueueTrack(backend: AppleScriptBackend, playlist: String, position: Int) -> Bool {
    let esc = escapeAppleScriptString(playlist)
    return (try? syncRun { try await backend.runMusic("play track \(position) of playlist \"\(esc)\"") }) != nil
}

/// Bulk-fetch a playlist's full ordered track list (name + artist per row). Two
/// bulk reads (`tracks 1 thru n`), never per-element, per the perf convention.
func fetchPlaylistTracks(backend: AppleScriptBackend, playlist: String) -> [TrackListEntry] {
    let esc = escapeAppleScriptString(playlist)
    guard let raw = try? syncRun({
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set total to count of tracks of playlist "\(esc)"
            set output to ""
            if total > 0 then
                set ns to name of tracks 1 thru total of playlist "\(esc)"
                set ars to artist of tracks 1 thru total of playlist "\(esc)"
                repeat with i from 1 to total
                    set output to output & i & fs & (item i of ns) & fs & (item i of ars)
                    if i < total then set output to output & linefeed
                end repeat
            end if
            return output
        """)
    }) else { return [] }
    var out: [TrackListEntry] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 2).map(String.init)
        guard f.count == 3, let idx = Int(f[0]) else { continue }
        out.append(TrackListEntry(index: idx, name: f[1], artist: f[2], isCurrent: false))
    }
    return out
}

/// Parse the FS-separated "index<FS>name<FS>artist" lines from
/// `fetchLibraryTracksWithPositions` into rows. Pure, so it's unit-testable.
func parseLibraryTrackPositions(_ raw: String) -> [TrackListEntry] {
    var out: [TrackListEntry] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 2).map(String.init)
        guard f.count == 3, let idx = Int(f[0]) else { continue }
        out.append(TrackListEntry(index: idx, name: f[1], artist: f[2], isCurrent: false))
    }
    return out
}

/// Fetch the library tracks matching an AppleScript `whose` clause, WITH each
/// track's position in the whole-library "Library" playlist — the (playlist,
/// position) an AppQueue needs to drive album/artist playback around the macOS
/// 26.x queue regression. A `repeat` over the filtered set (per-element reads)
/// is fine here: album/artist track counts are small, unlike a full-library bulk
/// read. `whereClause` is an AppleScript boolean over `t`, already escaped by the
/// caller.
func fetchLibraryTracksWithPositions(backend: AppleScriptBackend, whereClause: String) -> [TrackListEntry] {
    let raw = (try? syncRun {
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set out to ""
            repeat with t in (every track of playlist "Library" whose \(whereClause))
                set out to out & (index of t) & fs & (name of t) & fs & (artist of t) & linefeed
            end repeat
            return out
        """, timeout: 30)
    }) ?? ""
    return parseLibraryTrackPositions(raw)
}

/// A library track row carrying the album artist (to disambiguate a same-titled
/// album once the strict `whose` clause has missed), the cloud status (to drop
/// tracks Music can't play yet), the disc/track numbers (to play in album
/// order — the `whose` fetch yields Library position order, which can start an
/// album mid-way), and the track's own album title. Parsed from the 8-field
/// album fetch below. 0 for disc/track means Music has no number set.
///
/// `album` exists ONLY to group rows by album identity (§16.6,
/// `groupRowsByAlbum`) before an album resolution decides which single album
/// to play — a bare `album contains "<query>"` where-clause can match many
/// distinct albums, and every matched row must never be treated as one flat
/// set. It defaults to `""` for the song/artist fetches that don't need it,
/// which is indistinguishable from "no album" and therefore always groups as
/// one bucket — exactly today's un-grouped behaviour for those call sites.
struct LibraryAlbumRow: Equatable {
    let index: Int
    let name: String
    let artist: String
    let albumArtist: String
    let cloudStatus: String
    let disc: Int
    let track: Int
    let album: String

    init(index: Int, name: String, artist: String, albumArtist: String, cloudStatus: String,
         disc: Int = 0, track: Int = 0, album: String = "") {
        self.index = index
        self.name = name
        self.artist = artist
        self.albumArtist = albumArtist
        self.cloudStatus = cloudStatus
        self.disc = disc
        self.track = track
        self.album = album
    }
}

/// Parse "index<FS>name<FS>artist<FS>albumArtist<FS>cloudStatus<FS>disc<FS>track<FS>album"
/// lines (the album fetch output) into rows. Empty fields are preserved (a track
/// with no album artist keeps its column) so the eight fields stay aligned;
/// malformed lines (non-numeric index/disc/track or wrong field count — including
/// the pre-§16.6 seven-field shape, now rejected) are dropped. Pure → unit-tested.
func parseLibraryAlbumRows(_ raw: String) -> [LibraryAlbumRow] {
    var out: [LibraryAlbumRow] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 8, let idx = Int(f[0]), let disc = Int(f[5]), let track = Int(f[6]) else { continue }
        out.append(LibraryAlbumRow(index: idx, name: f[1], artist: f[2], albumArtist: f[3], cloudStatus: f[4],
                                   disc: disc, track: track, album: f[7]))
    }
    return out
}

/// Album play order for resolved rows: disc, then track number, with the fetch
/// order breaking ties only. A disc of 0 counts as disc 1 (an unset disc is the
/// only/first disc, not one before it); a track of 0 can't be placed, so those
/// rows follow the numbered ones in fetched order. Sorted over enumerated
/// offsets because Swift's sort is not documented stable.
func sortRowsByAlbumOrder(_ rows: [LibraryAlbumRow]) -> [LibraryAlbumRow] {
    func key(_ r: LibraryAlbumRow, _ offset: Int) -> (Int, Int, Int) {
        (r.disc <= 0 ? 1 : r.disc, r.track <= 0 ? Int.max : r.track, offset)
    }
    return rows.enumerated()
        .sorted { key($0.element, $0.offset) < key($1.element, $1.offset) }
        .map(\.element)
}

/// Whether Music can actually play a track with this cloud status. A denylist, NOT
/// an allowlist: local-file tracks report "unknown"/other statuses and must stay
/// playable, so only genuinely-unavailable statuses are excluded. "prerelease" was
/// verified live (on the pre-release "Mere Mortals", `play track` silently no-ops on
/// it); "removed"/"no longer available" are unavailable by definition. Pure → tested.
func isPlayableCloudStatus(_ status: String) -> Bool {
    let unplayable: Set<String> = ["prerelease", "removed", "no longer available"]
    return !unplayable.contains(status.lowercased().trimmingCharacters(in: .whitespaces))
}

/// Fold the punctuation that separates a multi-artist credit so Apple Music's
/// display form ("A, B") and the local library's stored form ("A & B") compare
/// equal: lowercase, turn "&"/"," into spaces, collapse whitespace. Deliberately
/// does NOT fold the word "and" — it appears inside real titles and single names,
/// so folding it would over-match. Pure → unit-tested.
func normalizeCredit(_ s: String) -> String {
    let swapped = s.lowercased()
        .replacingOccurrences(of: "&", with: " ")
        .replacingOccurrences(of: ",", with: " ")
    return swapped.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
}

/// Fold an album title for exact-match comparison: lowercase, trim, collapse
/// internal whitespace. Deliberately simpler than `normalizeCredit` — an album
/// title's punctuation ("Rock & Roll") is part of its identity, unlike a
/// multi-artist credit string, so it is not folded away here. Pure → tested.
func normalizeAlbumTitle(_ s: String) -> String {
    s.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        .joined(separator: " ")
}

/// One distinct album within a set of matched rows, identified by its
/// normalised (album title, album artist) pair. `displayName` keeps the
/// first UN-normalised album title seen, for an honest ambiguity message.
struct AlbumGroup: Equatable {
    let displayName: String
    let rows: [LibraryAlbumRow]
}

/// Group library rows by album identity — normalised album title AND
/// normalised album artist, so two genuinely different albums that merely
/// share a title (by different artists) are never merged, while punctuation
/// drift in the album-artist credit (the same drift `normalizeCredit`
/// tolerates everywhere else in this file) never splits one album in two.
///
/// §16.6: `music play --album "live"` runs a bare `album contains "live"`
/// fetch, which can and does match many distinct albums. This is what makes
/// that fact visible to `decideAlbumPlay` BEFORE a container is built from
/// the flattened row set — the bug this exists to close. Order-preserving,
/// so an ambiguity error message lists albums in a stable, deterministic
/// order. Pure → unit-tested.
func groupRowsByAlbum(_ rows: [LibraryAlbumRow]) -> [AlbumGroup] {
    var order: [String] = []
    var buckets: [String: [LibraryAlbumRow]] = [:]
    var display: [String: String] = [:]
    for r in rows {
        let key = normalizeAlbumTitle(r.album) + "\u{1}" + normalizeCredit(r.albumArtist)
        if buckets[key] == nil {
            order.append(key)
            display[key] = r.album
        }
        buckets[key, default: []].append(r)
    }
    let fineGroups = order.map { AlbumGroup(displayName: display[$0] ?? "", rows: buckets[$0] ?? []) }
    return collapseCompatibleAlbumArtistGroups(fineGroups)
}

/// §17.3 (corrects §16.6's grouping): collapse groups that share a
/// normalised album title when their album-artist credits are compatible —
/// one side empty, or one folds into the other under `normalizeCredit`
/// (its credit's tokens are a subset of the other's). The album-artist field
/// is not reliably uniform within one real album: it is commonly empty on
/// locally added tracks and drifts on compilations and classical releases,
/// so the fine-grained (title, album-artist) grouping above can split one
/// genuine album into two groups and return an unactionable `.ambiguous`
/// naming the same title twice. Groups whose credits are genuinely different
/// stay split, because two different albums may legitimately share a title
/// (`--artist` resolves that case).
///
/// All-or-nothing per title bucket: if ANY pair of credits in a same-titled
/// bucket is incompatible, nothing in that bucket merges. This is
/// deliberately conservative — it never lets an incompatible pair merge
/// through a third, mutually-compatible group — at the cost of not
/// collapsing a compatible subset when an unrelated album also shares the
/// title. That trade favours the same asymmetry as the rest of this feature:
/// a wrongly-kept-split album is a solvable `--artist` prompt; a wrongly
/// merged one seeds the container with the wrong tracks. Consistent with
/// `selectAlbumTracks`'s existing tolerance for per-track soloist credits
/// (a singleton album-artist set plays whole). Order-preserving. Pure →
/// unit-tested.
func collapseCompatibleAlbumArtistGroups(_ groups: [AlbumGroup]) -> [AlbumGroup] {
    var titleOrder: [String] = []
    var byTitle: [String: [AlbumGroup]] = [:]
    for g in groups {
        let titleKey = normalizeAlbumTitle(g.displayName)
        if byTitle[titleKey] == nil { titleOrder.append(titleKey) }
        byTitle[titleKey, default: []].append(g)
    }
    var result: [AlbumGroup] = []
    for titleKey in titleOrder {
        let bucket = byTitle[titleKey] ?? []
        if bucket.count > 1, albumArtistCreditsAreCompatible(bucket) {
            result.append(AlbumGroup(displayName: bucket[0].displayName, rows: bucket.flatMap { $0.rows }))
        } else {
            result.append(contentsOf: bucket)
        }
    }
    return result
}

/// Whether every pair of these groups' album-artist credits is compatible:
/// one's normalised credit tokens are a subset of the other's (the subset
/// arm, unchanged from §17.3 — "Queen" folding into "Queen & David Bowie" is
/// overwhelmingly a drifted credit for one album). Each group here is
/// already homogeneous on `normalizeCredit(albumArtist)` (that's what
/// fine-grained grouping partitioned on), so `effectiveAlbumArtistCredit`
/// represents the whole group.
func albumArtistCreditsAreCompatible(_ groups: [AlbumGroup]) -> Bool {
    let credits = groups.map(effectiveAlbumArtistCredit)
    guard credits.count > 1 else { return true }
    for i in 0..<(credits.count - 1) {
        for j in (i + 1)..<credits.count where !creditsAreCompatible(credits[i], credits[j]) {
            return false
        }
    }
    return true
}

/// §18.3 (corrects §17.3's empty arm): a group's own album-artist credit,
/// falling back to its rows' TRACK artist when that credit is empty — the
/// idiom `selectArtistTracks` already uses when matching on either credit.
///
/// §17.3 treated an empty album-artist credit as compatible with anything,
/// on the reasoning that a locally added track commonly has no album-artist
/// tag. That reasoning holds for the collapse itself, but the compatibility
/// TEST it fed read absence of evidence as evidence of sameness: in a
/// two-group title bucket the empty group is the only counterparty, so
/// nothing could ever contradict it, and a locally ripped *Greatest Hits*
/// with a blank album artist would merge with ANY other *Greatest Hits*,
/// including one by an entirely different artist.
///
/// The fix keeps the same reasoning but demands it point at real evidence: a
/// blank album-artist tag is not itself proof of a match, but the row's
/// track-artist tag usually still is — a locally ripped *Moon Safari* keeps
/// "Air" in its track artist even with a blank album artist. If every row in
/// the group agrees on one normalised track artist, that becomes the
/// group's effective credit; if the group's rows disagree (or are also
/// blank), there is genuinely no evidence, and this returns "" — which,
/// after this fix, `creditsAreCompatible` no longer treats as compatible
/// with everything. Pure → tested.
func effectiveAlbumArtistCredit(_ group: AlbumGroup) -> String {
    let ownCredit = normalizeCredit(group.rows.first?.albumArtist ?? "")
    guard ownCredit.isEmpty else { return ownCredit }
    let trackArtists = Set(group.rows.map { normalizeCredit($0.artist) }.filter { !$0.isEmpty })
    guard trackArtists.count == 1, let only = trackArtists.first else { return "" }
    return only
}

/// §19 (corrects §18.3's and §17.3's subset arm): two nonempty effective
/// credits are compatible only when they are strictly EQUAL. §18.3 already
/// closed the empty-credit arm here — an empty credit is no longer
/// automatically compatible with everything; `effectiveAlbumArtistCredit`
/// above is where "empty" gets its one real chance to resolve to actual
/// evidence (the group's track artist), and a credit that reaches this
/// function still empty stays incompatible.
///
/// The subset arm used to pass a pair when one credit's tokens were a subset
/// of the other's, on the reasoning that "Queen" folding into "Queen & David
/// Bowie" is overwhelmingly a drifted credit for one collaborative album.
/// That reasoning covers collaboration drift, but the predicate cannot tell
/// it apart from a token-prefix pair of two genuinely different single
/// artists: `{"queen"}` is a subset of `{"queen", "latifah"}`, so *Greatest
/// Hits* by Queen and *Greatest Hits* by Queen Latifah collapsed into one
/// group and seeded one container with both albums — bounded and silent,
/// with no ambiguity prompt, violating the hard invariant that a container
/// must never silently hold more than one album. Containment is not
/// identity, so it is rejected here for the same reason §18.3 rejected
/// "empty means compatible": absence of a distinguishing signal is not
/// evidence of sameness. The accepted cost is that genuine collaboration
/// drift now surfaces as `.ambiguous` too, resolvable with `--artist` — a
/// prompt the user can act on beats a container holding an album they did
/// not ask for.
private func creditsAreCompatible(_ a: String, _ b: String) -> Bool {
    guard !a.isEmpty, !b.isEmpty else { return false }
    return a == b
}

/// Pick an album's tracks from a title-only library fetch, resolving the artist in
/// Swift when the strict album+artist `whose` clause missed — Apple Music's display
/// credit having drifted from the stored album artist (comma vs ampersand, seen live
/// on the pre-release "Mere Mortals") or per-track soloist credits. One album-artist
/// group → play all of it (no ambiguity). A genuine same-title collision → the group
/// whose album artist matches the requested one (punctuation-tolerant); if none
/// matches, refuse to guess and return [] so the caller errors rather than plays the
/// wrong album. Pure → unit-tested.
func selectAlbumTracks(_ rows: [LibraryAlbumRow], requestedArtist: String) -> [LibraryAlbumRow] {
    guard !rows.isEmpty else { return [] }
    var groups: [String] = []
    for r in rows where !groups.contains(r.albumArtist) { groups.append(r.albumArtist) }
    if groups.count == 1 { return rows }
    let want = normalizeCredit(requestedArtist)
    guard let hit = groups.first(where: { normalizeCredit($0) == want }) else { return [] }
    return rows.filter { $0.albumArtist == hit }
}

/// The leading artist in a credit string, used only to build a loose `contains`
/// pre-filter for the artist fallback fetch. "A, B & C" and "A & B" both yield "A",
/// which is what lets one AppleScript clause reach every punctuation variant of a
/// credit. Pure → unit-tested.
func primaryCreditComponent(_ credit: String) -> String {
    let first = credit.split(whereSeparator: { $0 == "," || $0 == "&" }).first.map(String.init) ?? ""
    return first.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Keep the rows belonging to one artist as the REST-sourced Artists list names them.
/// A track belongs if either its own credit or its album artist folds to the requested
/// one: the first catches compilations (album artist "Various Artists"), the second
/// catches classical and collaborative albums where every track credits a different
/// soloist but the album artist is uniform — the live "Mere Mortals" case, where four
/// distinct track artists share one album artist. Exact after folding on purpose: the
/// `contains` pre-filter is loose, so this is what stops "Floating Points" swallowing
/// every collaboration it leads. Pure → unit-tested.
func selectArtistTracks(_ rows: [LibraryAlbumRow], requestedArtist: String) -> [LibraryAlbumRow] {
    let want = normalizeCredit(requestedArtist)
    return rows.filter { normalizeCredit($0.artist) == want || normalizeCredit($0.albumArtist) == want }
}

/// Pick one song from a title-scoped fetch, resolving the artist punctuation-tolerantly.
/// Refuses rather than guesses when nothing folds — same rule as selectAlbumTracks, so
/// a same-titled song by someone else never plays in place of the one asked for.
/// Pure → unit-tested.
func selectSongTrack(_ rows: [LibraryAlbumRow], requestedArtist: String) -> LibraryAlbumRow? {
    let want = normalizeCredit(requestedArtist)
    return rows.first { normalizeCredit($0.artist) == want || normalizeCredit($0.albumArtist) == want }
}

/// Resolve every library track for one artist, tolerating the drift between the
/// Artists list's REST display credit and the library's stored credits. Strict
/// `artist is` first (unchanged fast path, so nothing that plays today can regress),
/// then a loose `contains` fetch on the primary credit component narrowed in Swift.
/// Drops tracks Music silently refuses to play — the pre-release layer of the same
/// bug, which bites here exactly as it did for albums.
func resolveArtistPlaybackTracks(backend: AppleScriptBackend, artist: String) -> AlbumResolution {
    let escArtist = escapeAppleScriptString(artist)
    let strict = fetchLibraryAlbumRows(backend: backend, whereClause: "artist is \"\(escArtist)\"")
    var matched = strict
    if matched.isEmpty {
        let primary = primaryCreditComponent(artist)
        if !primary.isEmpty {
            let escPrimary = escapeAppleScriptString(primary)
            let loose = fetchLibraryAlbumRows(
                backend: backend,
                whereClause: "artist contains \"\(escPrimary)\" or album artist contains \"\(escPrimary)\"")
            matched = selectArtistTracks(loose, requestedArtist: artist)
        }
    }
    let playable = matched.filter { isPlayableCloudStatus($0.cloudStatus) }
        .map { TrackListEntry(index: $0.index, name: $0.name, artist: $0.artist, isCurrent: false) }
    return AlbumResolution(tracks: playable, matched: matched.count)
}

/// Resolve a single library song the same way: strict title+artist first, then a
/// title-only fetch disambiguated in Swift.
func resolveSongPlaybackTrack(backend: AppleScriptBackend, title: String, artist: String) -> AlbumResolution {
    let escTitle = escapeAppleScriptString(title)
    let escArtist = escapeAppleScriptString(artist)
    let strict = fetchLibraryAlbumRows(
        backend: backend, whereClause: "name is \"\(escTitle)\" and artist is \"\(escArtist)\"")
    let row = strict.first
        ?? selectSongTrack(fetchLibraryAlbumRows(backend: backend, whereClause: "name is \"\(escTitle)\""),
                           requestedArtist: artist)
    guard let hit = row else { return AlbumResolution(tracks: [], matched: 0) }
    let playable = isPlayableCloudStatus(hit.cloudStatus)
        ? [TrackListEntry(index: hit.index, name: hit.name, artist: hit.artist, isCurrent: false)]
        : []
    return AlbumResolution(tracks: playable, matched: 1)
}

/// Fetch library tracks matching a `whose` clause, WITH each track's play-order
/// position, album artist, cloud status, and disc/track numbers — the richer read
/// the album resolver needs to disambiguate a drifted artist credit, drop tracks
/// Music can't play, and queue in album order. `cloud status` is guarded per
/// track (it can throw on some local files); an unreadable status defaults to
/// "unknown", which stays playable. Disc/track reads are guarded the same way and
/// default to 0 = no number set. Same per-element read shape as
/// fetchLibraryTracksWithPositions (album track counts are small).
func fetchLibraryAlbumRows(backend: AppleScriptBackend, whereClause: String) -> [LibraryAlbumRow] {
    let raw = (try? syncRun {
        try await backend.runMusic("""
            set fs to (ASCII character 31)
            set out to ""
            repeat with t in (every track of playlist "Library" whose \(whereClause))
                set cs to "unknown"
                try
                    set cs to (cloud status of t as text)
                end try
                set dn to 0
                try
                    set dn to (disc number of t)
                end try
                set tn to 0
                try
                    set tn to (track number of t)
                end try
                set al to ""
                try
                    set al to (album of t)
                end try
                set out to out & (index of t) & fs & (name of t) & fs & (artist of t) & fs & (album artist of t) & fs & cs & fs & dn & fs & tn & fs & al & linefeed
            end repeat
            return out
        """, timeout: 30)
    }) ?? ""
    return parseLibraryAlbumRows(raw)
}

/// The outcome of resolving an album for playback: the ordered tracks that can
/// actually play, plus how many tracks the album matched before the playability
/// filter — so the caller can report "playing N of M" when a pre-release album has
/// only some of its movements available yet.
struct AlbumResolution: Equatable {
    let tracks: [TrackListEntry]
    let matched: Int
}

/// Resolve an album for playback (shared with the tracklist preview so the two never
/// diverge). Try the strict album+artist clause first — unchanged for the common
/// case, and it still disambiguates a same-titled album when the artist DOES match.
/// Only if that matches nothing fall back to matching by album title alone and
/// resolving the artist in Swift (selectAlbumTracks), so no album that plays today can
/// regress. Either way, drop tracks Music can't play yet (pre-release/removed), which
/// otherwise make `play track` silently no-op; `matched` keeps the pre-filter count
/// for the "N of M" message.
func resolveAlbumPlaybackTracks(backend: AppleScriptBackend, title: String, artist: String) -> AlbumResolution {
    let escTitle = escapeAppleScriptString(title)
    let escArtist = escapeAppleScriptString(artist)
    let strict = fetchLibraryAlbumRows(
        backend: backend,
        whereClause: "album is \"\(escTitle)\" and (artist is \"\(escArtist)\" or album artist is \"\(escArtist)\")")
    // Strict is already artist-scoped by the clause; only the title-only fallback
    // needs Swift-side disambiguation.
    let matched = strict.isEmpty
        ? selectAlbumTracks(fetchLibraryAlbumRows(backend: backend, whereClause: "album is \"\(escTitle)\""),
                            requestedArtist: artist)
        : strict
    return orderedPlayableAlbumTracks(matched)
}

/// The album resolver's single exit, shared by the strict and fallback paths:
/// sort into album order FIRST (the `whose` fetch yields Library position order,
/// which can start an album mid-way), then drop tracks Music can't play yet.
/// `matched` keeps the pre-filter count so "Playing N of M" is unaffected.
func orderedPlayableAlbumTracks(_ matched: [LibraryAlbumRow]) -> AlbumResolution {
    let playable = sortRowsByAlbumOrder(matched).filter { isPlayableCloudStatus($0.cloudStatus) }
        .map { TrackListEntry(index: $0.index, name: $0.name, artist: $0.artist, isCurrent: false) }
    return AlbumResolution(tracks: playable, matched: matched.count)
}

/// The full play-order track list the now-playing view shows, with the current
/// track marked. Unlike Music's windowed context (which paged to limit AppleScript
/// fetches), the app queue is already in memory, so we expose every track — the
/// user can scroll up to track 1 and down to the end. Each entry's `index` is the
/// play-order position so Enter can jump by it (NowPlayingScene).
func appQueueWindow(_ q: AppQueue) -> (tracks: [TrackListEntry], name: String) {
    let rows = q.tracks.enumerated().map { (i, t) in
        TrackListEntry(index: i + 1, name: t.name, artist: t.artist, isCurrent: (i + 1) == q.currentIndex)
    }
    return (rows, q.contextLabel)
}

/// Shuffle: when an app queue is active, reshuffle its play order and restart from
/// the new first track. With no app queue, fall back to toggling Music's native
/// shuffle (e.g. while browsing, affecting whatever Music plays next).
@discardableResult
func shufflePlayCurrent(backend: AppleScriptBackend, appQueue: AppQueueStore) -> Bool {
    guard let q = appQueue.read() else {
        return (try? syncRun { try await backend.runMusic("set shuffle enabled to (not shuffle enabled)") }) != nil
    }
    let reordered = q.tracks.shuffled()
    appQueue.set(AppQueue(playlistName: q.playlistName, tracks: reordered, currentIndex: 1, displayName: q.displayName))
    guard let first = reordered.first else { return false }
    return playQueueTrack(backend: backend, playlist: q.playlistName, position: first.index)
}

/// Build a fresh app queue from a playlist in shuffled order and play its first
/// track. Used by the end-of-queue "Shuffle" action to replay a finished playlist.
@discardableResult
func shufflePlayPlaylist(backend: AppleScriptBackend, appQueue: AppQueueStore, playlist: String) -> Bool {
    let tracks = fetchPlaylistTracks(backend: backend, playlist: playlist).shuffled()
    guard let first = tracks.first else { return false }
    appQueue.set(AppQueue(playlistName: playlist, tracks: tracks, currentIndex: 1))
    return playQueueTrack(backend: backend, playlist: playlist, position: first.index)
}

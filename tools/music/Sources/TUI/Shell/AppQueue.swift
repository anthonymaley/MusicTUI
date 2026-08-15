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
/// tracks Music can't play yet), and the disc/track numbers (to play in album
/// order — the `whose` fetch yields Library position order, which can start an
/// album mid-way). Parsed from the 7-field album fetch below. 0 for disc/track
/// means Music has no number set.
struct LibraryAlbumRow: Equatable {
    let index: Int
    let name: String
    let artist: String
    let albumArtist: String
    let cloudStatus: String
    let disc: Int
    let track: Int

    init(index: Int, name: String, artist: String, albumArtist: String, cloudStatus: String,
         disc: Int = 0, track: Int = 0) {
        self.index = index
        self.name = name
        self.artist = artist
        self.albumArtist = albumArtist
        self.cloudStatus = cloudStatus
        self.disc = disc
        self.track = track
    }
}

/// Parse "index<FS>name<FS>artist<FS>albumArtist<FS>cloudStatus<FS>disc<FS>track"
/// lines (the album fetch output) into rows. Empty fields are preserved (a track
/// with no album artist keeps its column) so the seven fields stay aligned;
/// malformed lines (non-numeric index/disc/track or wrong field count) are
/// dropped. Pure → unit-tested.
func parseLibraryAlbumRows(_ raw: String) -> [LibraryAlbumRow] {
    var out: [LibraryAlbumRow] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7, let idx = Int(f[0]), let disc = Int(f[5]), let track = Int(f[6]) else { continue }
        out.append(LibraryAlbumRow(index: idx, name: f[1], artist: f[2], albumArtist: f[3], cloudStatus: f[4],
                                   disc: disc, track: track))
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
                set out to out & (index of t) & fs & (name of t) & fs & (artist of t) & fs & (album artist of t) & fs & cs & fs & dn & fs & tn & linefeed
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

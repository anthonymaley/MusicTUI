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
struct AppQueue {
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

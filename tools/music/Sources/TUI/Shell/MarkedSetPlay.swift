// tools/music/Sources/TUI/Shell/MarkedSetPlay.swift
import Foundation

// MARK: - The marked set as one queue (combined play, step 3)
//
// The rows marked with `m` on the Albums and Playlists rails play as ONE
// app-owned queue, in mark order, addressed by persistent ID
// (`persistentIDQueueSource`), so the poller's advance, next/previous, Now's
// jump and the bounded end-of-queue continuation all play exactly these
// tracks. It is a temporary queue only: everything here READS. Nothing makes,
// duplicates, renames or deletes a playlist or a track.

/// The three reads a marked play makes, injected so the queue is built and
/// tested without Music.
struct MarkedSetReaders {
    /// An album's playable tracks as identity-addressed entries
    /// (`resolveAlbumPlaybackTrackIDs`).
    let album: (_ title: String, _ artist: String) -> AlbumResolution
    /// How many playlists carry exactly this name; nil when the read failed.
    let playlistsNamed: (_ name: String) -> Int?
    /// A playlist's tracks as identity-addressed entries, in playlist order;
    /// nil when the read failed (`fetchPlaylistTrackIDs`).
    let playlist: (_ name: String) -> [TrackListEntry]?

    /// The AppleScript readers. Read-only scripts, every one.
    static func live(backend: AppleScriptBackend) -> MarkedSetReaders {
        MarkedSetReaders(
            album: { resolveAlbumPlaybackTrackIDs(backend: backend, title: $0, artist: $1) },
            playlistsNamed: { name in
                guard let raw = try? backend.runMusicBlocking(playlistsNamedScript(name)) else { return nil }
                return parsePlaylistsNamedCount(raw)
            },
            playlist: { fetchPlaylistTrackIDs(backend: backend, playlist: $0) })
    }
}

/// Counts the playlists named exactly `name`, of every kind, because
/// `playlist "<name>"` (which the track read addresses) resolves against all of
/// them and silently takes the first. A read: it changes nothing.
func playlistsNamedScript(_ name: String) -> String {
    "count of (every playlist whose name is \"\(escapeAppleScriptString(name))\")"
}

/// The count `playlistsNamedScript` answers, or nil for anything that is not
/// a whole number. Pure.
func parsePlaylistsNamedCount(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let n = Int(text), n >= 0 else { return nil }
    return n
}

/// What Now Playing calls the marked set: the one item's own name, else
/// "2 albums and 1 playlist" (either half alone when the other is absent).
func markedSetDisplayName(_ items: [MarkedItem]) -> String {
    if items.count == 1 {
        switch items[0] {
        case .album(let title, _): return title
        case .playlist(let name): return name
        }
    }
    var albums = 0, playlists = 0
    for item in items {
        if case .album = item { albums += 1 } else { playlists += 1 }
    }
    func counted(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
    switch (albums, playlists) {
    case (0, let p): return counted(p, "playlist")
    case (let a, 0): return counted(a, "album")
    case (let a, let p): return "\(counted(a, "album")) and \(counted(p, "playlist"))"
    }
}

/// A marked play's queue, and how many tracks the marked set matched: every
/// queued track plus each album's songs that aren't available yet, summed
/// across the set (a playlist's tracks all count as matched and queued).
struct MarkedSetPlan: Equatable {
    let queue: AppQueue
    let matched: Int

    /// The single-album wording, over the whole set: the warning's notice,
    /// or nil when every matched track was queued (`partialAvailabilityNotice`).
    var notice: String? { partialAvailabilityNotice(queued: queue.tracks.count, matched: matched) }
    /// The play's own line, restored by a late confirmation, or nil when
    /// nothing was skipped (`partialAvailabilityPlayingLine`).
    var playingLine: String? { partialAvailabilityPlayingLine(queued: queue.tracks.count, matched: matched) }
}

/// The marked rows as one queue (`markedSetPlan`'s queue).
func markedSetQueue(_ items: [MarkedItem], shuffle: Bool, readers: MarkedSetReaders) throws -> AppQueue {
    try markedSetPlan(items, shuffle: shuffle, readers: readers).queue
}

/// The marked rows as one queue: each item's tracks, in mark order (shuffled
/// together when `shuffle`), addressed by persistent ID and labelled by
/// `markedSetDisplayName`, with the set's matched count, so an album only
/// partly available is never shortened silently. Fails closed and whole: any
/// read that fails, an album with nothing to play, a playlist that is gone,
/// empty, or shares its name with another playlist throws an `ActionError`
/// naming that item, and no queue exists. Reads stop at the first failure.
func markedSetPlan(_ items: [MarkedItem], shuffle: Bool, readers: MarkedSetReaders) throws -> MarkedSetPlan {
    guard !items.isEmpty else { throw ActionError(message: "Nothing is marked.") }
    var entries: [TrackListEntry] = []
    var matched = 0
    for item in items {
        switch item {
        case .album(let title, let artist):
            let res = readers.album(title, artist)
            if res.readFailed {
                throw ActionError(message: "Music didn't answer while reading '\(title)', so nothing played. Try again.")
            }
            guard !res.tracks.isEmpty else {
                throw ActionError(message: res.matched > 0
                    ? "'\(title)' has no tracks available to play yet, so nothing played."
                    : "Couldn't find the album '\(title)', so nothing played.")
            }
            entries += res.tracks
            matched += max(res.matched, res.tracks.count)
        case .playlist(let name):
            guard let named = readers.playlistsNamed(name) else {
                throw ActionError(message: "Music didn't answer while reading '\(name)', so nothing played. Try again.")
            }
            guard named > 0 else {
                throw ActionError(message: "Couldn't find the playlist '\(name)', so nothing played.")
            }
            guard named == 1 else {
                throw ActionError(message: "More than one playlist is named '\(name)', so nothing played. Rename one to play it with the others.")
            }
            guard let tracks = readers.playlist(name) else {
                throw ActionError(message: "Music didn't answer while reading '\(name)', so nothing played. Try again.")
            }
            guard !tracks.isEmpty else {
                throw ActionError(message: "'\(name)' has no tracks, so nothing played.")
            }
            entries += tracks
            matched += tracks.count
        }
    }
    let queue = AppQueue(playlistName: persistentIDQueueSource, tracks: shuffle ? entries.shuffled() : entries,
                         currentIndex: 1, displayName: markedSetDisplayName(items))
    return MarkedSetPlan(queue: queue, matched: matched)
}

// MARK: - Marking on the rails (combined play, step 4)

/// What a marked row shows before its name, on the Albums and Playlists rails.
let markedRowGlyph = "\u{25CF}"

/// `label` with the mark glyph in front when `marked`.
func markedRowLabel(_ label: String, marked: Bool) -> String {
    marked ? "\(markedRowGlyph) \(label)" : label
}

/// The footer line after `m`: how many are marked and what to do next.
func markedCountLine(_ count: Int) -> String {
    count == 0 ? "Nothing marked" : "Marked \(count) \u{00B7} p plays them, Esc clears"
}

/// The footer line after Esc cleared the marks.
let marksClearedLine = "Marks cleared"

// MARK: - Playing the marked set (combined play, step 5)

/// A marked play from rows read on SpanDAC data: not offered yet (the SpanDAC
/// route is a later follow-up), so it refuses before reading anything.
let markedPlayNeedsMusicTUIData =
    "Playing marked albums and playlists together needs MusicTUI's own data for now, so nothing played."

/// `p` / `s` with marks: the marked set as one queue, on the action queue.
///
/// The library album play's shape (`LibraryScene.playAlbum`), with the
/// SpanDAC hand-off's first play (`PersistentIDHandoff`): marks from SpanDAC
/// data refuse first, then `refuseOpenDataPlayBeforeReading` (a switch to
/// SpanDAC data since, or a blocked stored output), both before any read; then
/// the reads (`markedSetPlan`, all or nothing); then `routing.perform`
/// against the keypress's stamp, where the Music.app branch sets the queue
/// and plays its first entry by persistent ID, confirmed by that identity
/// (`playRequestedQueueTrack`). A first play whose script fails clears the
/// queue, so the poller is never left driving a queue that never started.
/// When a marked album is only partly available, the play says so as the
/// single-album play does: its line ("Playing N of M ..."), the warning's
/// notice, and the line a late confirmation restores, all over the whole set.
/// `.libraryPlay` routes it: it is a play from MusicTUI's own library data,
/// and it routes exactly as `.playlistPlay` does.
func playMarkedSet(_ marked: (items: [MarkedItem], source: ListSource?), shuffle: Bool,
                   backend: AppleScriptBackend, appQueue store: AppQueueStore, routing: RoutingCoordinator,
                   actions: ActionRunner, status: StatusStore, spanDACData: @escaping () -> Bool,
                   readers: MarkedSetReaders) {
    let stamp = routing.stamp
    actions.run("Play") {
        if marked.source == .bridge { throw ActionError(message: markedPlayNeedsMusicTUIData) }
        try refuseOpenDataPlayBeforeReading(.libraryPlay, routing: routing, spanDACData: spanDACData())
        let plan = try markedSetPlan(marked.items, shuffle: shuffle, readers: readers)
        let queue = plan.queue
        do {
            try routing.perform(.libraryPlay, expecting: stamp, origin: .openData(resultNumber: nil),
                musicApp: { path in
                    guard path == .shipped else { throw ActionError(message: pickASpanDACOutput) }
                    store.set(queue)
                    let title = queue.contextLabel
                    guard playRequestedQueueTrack(backend: backend, appQueue: store, playlist: queue.playlistName,
                                                  position: queue.currentSourcePosition, title: title,
                                                  notice: plan.notice, restore: plan.playingLine) else {
                        store.clear()
                        throw ActionError(message: "Couldn't play '\(title)'.")
                    }
                    // Say so rather than silently playing a shortened set.
                    if let line = plan.playingLine { status.post(line, untilStateChange: true) }
                },
                source: { _ in throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) },
                unaffected: {})
        } catch let error as SourceAppError {
            // ActionRunner reduces anything but an ActionError to "Play failed."
            throw ActionError(message: error.message)
        }
    }
}

// tools/music/Sources/TUI/Shell/MarkedSetPlay.swift
import Foundation

// MARK: - The marked set as one queue (combined play, step 3)
//
// The rows marked with `m` on the Albums and Playlists rails play as ONE
// queue, in mark order. On MusicTUI's own data it is an app-owned queue
// addressed by persistent ID (`persistentIDQueueSource`), so the poller's
// advance, next/previous, Now's jump and the bounded end-of-queue continuation
// all play exactly these tracks. On SpanDAC data it is the routed output's
// queue: one `slice.queue` of library IDs on a SpanDAC output, or the
// persistent-ID hand-off's app-owned queue on the MusicTUI output. It is a
// temporary queue only: everything here READS. Nothing makes, duplicates,
// renames or deletes a playlist or a track, in Music or in SpanDAC's library.

/// The two reads a marked play makes, injected so the queue is built and
/// tested without Music.
struct MarkedSetReaders {
    /// An album's playable tracks as identity-addressed entries
    /// (`resolveAlbumPlaybackTrackIDs`).
    let album: (_ title: String, _ artist: String) -> AlbumResolution
    /// The tracks of the playlist with this persistent ID (the one its mark
    /// captured from the rail) as identity-addressed entries, in playlist
    /// order, or `.missing` when no playlist has the ID any more; nil when the
    /// read failed (`fetchPlaylistTrackIDs`). Never a name lookup.
    let playlist: (_ persistentID: String) -> PlaylistTrackIDsRead?

    /// The AppleScript readers. Read-only scripts, every one.
    static func live(backend: AppleScriptBackend) -> MarkedSetReaders {
        MarkedSetReaders(
            album: { resolveAlbumPlaybackTrackIDs(backend: backend, title: $0, artist: $1) },
            playlist: { fetchPlaylistTrackIDs(backend: backend, playlistID: $0) })
    }
}

/// A marked playlist whose persistent ID no playlist has any more (deleted, or
/// gone from the library, since it was marked): the play refuses rather than
/// play another playlist in its place.
func markedPlaylistGoneLine(_ name: String) -> String {
    "'\(name)' is no longer in your playlists, so nothing played."
}

/// What Now Playing calls the marked set: the one item's own name, else
/// "2 albums and 1 playlist" (either half alone when the other is absent).
func markedSetDisplayName(_ items: [MarkedItem]) -> String {
    if items.count == 1 {
        switch items[0] {
        case .album(let title, _, _): return title
        case .playlist(_, let name): return name
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
        case .album(let title, let artist, _):
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
        case .playlist(let id, let name):
            // By the identity the mark captured, never by the name.
            guard let read = readers.playlist(id) else {
                throw ActionError(message: "Music didn't answer while reading '\(name)', so nothing played. Try again.")
            }
            guard case .tracks(let tracks) = read else {
                throw ActionError(message: markedPlaylistGoneLine(name))
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

/// The footer line after `m` on a rail row whose playlist ID was not read: it
/// cannot be marked, because a mark is that ID.
func playlistUnmarkableLine(_ name: String) -> String {
    "'\(name)' can't be marked: its playlist ID wasn't read, so nothing was marked."
}

/// The footer line after Esc cleared the marks.
let marksClearedLine = "Marks cleared"

// MARK: - Reading the marked set on SpanDAC data

/// What a marked play needs to play rows read on SpanDAC data: the scene's
/// SpanDAC data provider (nil once MusicTUI no longer uses SpanDAC for music
/// data), the hand-off the MusicTUI output plays through, and the wait between
/// warming retries.
struct MarkedSetSpanDAC {
    let makeProvider: () -> MusicDataProvider?
    let handoff: MusicTUIHandoff
    let sleep: (TimeInterval) -> Void

    /// No SpanDAC at all: marks from SpanDAC data refuse, as a SpanDAC list
    /// played after MusicTUI stopped using SpanDAC for music data does.
    static var unavailable: MarkedSetSpanDAC {
        MarkedSetSpanDAC(makeProvider: { nil }, handoff: RefusingHandoff(), sleep: { _ in })
    }
}

/// The marked items' songs as SpanDAC served them, in mark order, and how many
/// playlist videos SpanDAC left out of them (a queue never holds a video).
struct MarkedSetSpanDACRows: Equatable {
    var rows: [MusicRow] = []
    var skippedVideos = 0
}

/// A marked item SpanDAC could not read: the whole play fails, naming it, in
/// SpanDAC's own words.
func markedSpanDACReadFailedLine(_ name: String, _ detail: String) -> String {
    "Couldn't read '\(name)' from SpanDAC, so nothing played: \(detail)"
}

/// A marked item SpanDAC holds no playable song for.
func markedSpanDACEmptyLine(_ name: String) -> String {
    "'\(name)' has no songs SpanDAC can play, so nothing played."
}

/// A marked set whose reads did not all come from one SpanDAC snapshot (a
/// refresh landed between two items, or between two pages of one playlist):
/// refused whole, as the artist play refuses (`listedArtistAlbumRows`), never
/// played as a queue that mixes two libraries.
func markedSetSpanDACChangedLine(_ name: String) -> String {
    "SpanDAC's library changed while '\(name)' was being read, so nothing played. Try again."
}

/// A marked set whose `slice.queue` request would not fit the 64 KiB request
/// frame (`SourceAppControl.maximumRequestBytes`): refused whole, never cut short.
func markedSetTooLargeForSpanDACLine(_ songs: Int) -> String {
    "\(groupedCount(songs)) songs are more than SpanDAC can take in one queue, so nothing played. "
        + "Mark fewer albums or playlists."
}

/// Each marked item's songs read from SpanDAC, in mark order, each by the ID
/// its mark recorded (an album by SpanDAC's album ID, a playlist by SpanDAC's
/// playlist ID), never by a name. Fails closed and whole, as `markedSetPlan`
/// does: a read that fails (a playlist that is gone included, in SpanDAC's own
/// words), an album with no recorded ID, or an item with no song to play throws
/// an `ActionError` naming that item, and reads stop at the first failure. A
/// source change reported by a read (`sourceChangedNothingPlayed`) and a set
/// whose reads crossed a snapshot (`markedSetSpanDACChangedLine`) are passed on
/// as themselves: they are the whole set's, not one item's.
func markedSetSpanDACRows(_ items: [MarkedItem],
                          albumTracks: (_ albumID: String) throws -> [MusicRow],
                          playlistTracks: (_ playlistID: String) throws -> (rows: [MusicRow], skippedVideos: Int))
    throws -> MarkedSetSpanDACRows {
    guard !items.isEmpty else { throw ActionError(message: "Nothing is marked.") }
    let whole: Set<String> = [sourceChangedNothingPlayed, markedSetSpanDACChangedLine(markedSetDisplayName(items))]
    func namingFailure<T>(_ name: String, _ read: () throws -> T) throws -> T {
        try markedItemNamingFailure(name, passing: whole, read)
    }
    var out = MarkedSetSpanDACRows()
    for item in items {
        let name: String
        let read: (rows: [MusicRow], skippedVideos: Int)
        switch item {
        case .album(let title, _, let id):
            name = title
            guard !id.isEmpty else { throw ActionError(message: "Couldn't find the album '\(title)', so nothing played.") }
            read = try namingFailure(name) { (try albumTracks(id), 0) }
        case .playlist(let id, let playlistName):
            name = playlistName
            read = try namingFailure(name) { try playlistTracks(id) }
        }
        guard !read.rows.isEmpty else { throw ActionError(message: markedSpanDACEmptyLine(name)) }
        out.rows += read.rows
        out.skippedVideos += read.skippedVideos
    }
    return out
}

/// `read`, with any failure but the whole set's own (`passing`) restated as the
/// marked item's.
private func markedItemNamingFailure<T>(_ name: String, passing whole: Set<String>,
                                        _ read: () throws -> T) throws -> T {
    do {
        return try read()
    } catch let error as ActionError where whole.contains(error.message) {
        throw error
    } catch {
        let detail: String
        switch error {
        case let e as ActionError: detail = e.message
        case let e as SourceAppError: detail = e.message
        default: detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        throw ActionError(message: markedSpanDACReadFailedLine(name, detail))
    }
}

// MARK: - Playing the marked set (combined play, step 5)

/// `p` / `s` with marks: the marked set as one queue, on the action queue.
///
/// Marks from SpanDAC data play through `playMarkedSetFromSpanDAC`; marks from
/// MusicTUI's own data take the library album play's shape
/// (`LibraryScene.playAlbum`), with the SpanDAC hand-off's first play
/// (`PersistentIDHandoff`): `refuseOpenDataPlayBeforeReading` (a switch to
/// SpanDAC data since, or a blocked stored output) before any read; then the
/// reads (`markedSetPlan`, all or nothing); then `routing.perform` against the
/// keypress's stamp, where the Music.app branch sets the queue and plays its
/// first entry by persistent ID, confirmed by that identity
/// (`playRequestedQueueTrack`). A first play whose script fails clears the
/// queue, so the poller is never left driving a queue that never started.
/// When a marked album is only partly available, the play says so as the
/// single-album play does: its line ("Playing N of M ..."), the warning's
/// notice, and the line a late confirmation restores, all over the whole set.
/// `.libraryPlay` routes it: it is a play from the library, and it routes
/// exactly as `.playlistPlay` does.
func playMarkedSet(_ marked: (items: [MarkedItem], source: ListSource?), shuffle: Bool,
                   backend: AppleScriptBackend, appQueue store: AppQueueStore, routing: RoutingCoordinator,
                   actions: ActionRunner, status: StatusStore, spanDACData: @escaping () -> Bool,
                   readers: MarkedSetReaders, spanDAC: MarkedSetSpanDAC = .unavailable) {
    let stamp = routing.stamp
    actions.run("Play") {
        if marked.source == .bridge {
            try playMarkedSetFromSpanDAC(marked.items, shuffle: shuffle, stamp: stamp, routing: routing,
                                         status: status, spanDAC: spanDAC)
            return
        }
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

/// The marked set from SpanDAC data, run on the action queue: the shape of
/// `LibraryScene.playBridgeArtist`, the existing play of several SpanDAC
/// albums as one ID list.
///
/// Refuses before any read when MusicTUI no longer uses SpanDAC for music data
/// (marks never play from another data source). Reads each marked item from
/// SpanDAC on this Mac in mark order (`markedSetSpanDACRows`), inside one
/// warming budget for the whole action, and every request is fenced on both
/// sides against the keypress's stamp, as the artist play fences its own: before
/// it is sent, after it answers, and after it fails (a `warming` reply included),
/// so a switch while a read is held, during a retry's wait or between two pages
/// sends nothing further.
///
/// One snapshot for the whole set: the first read's `generation` (SpanDAC's core
/// generation, which album tracks and playlist pages both answer) is recorded,
/// and every later album read and playlist page must answer the same one; one
/// that does not refuses the whole set (`markedSetSpanDACChangedLine`), as the
/// artist play refuses, rather than read it again. Not caught: a SpanDAC that
/// restarted and reused the generation number between two reads, because
/// neither `slice.libraryAlbumTracks` nor `slice.libraryPlaylistTracks` carries
/// `library_instance`, so no read of this play can tell one SpanDAC process from
/// another; and a refresh after the last read, before the queue is sent.
///
/// Then ONE `routing.perform(.libraryPlay, origin: .spandacLibrary)`, through
/// the same two branches a single SpanDAC album or playlist play takes: a
/// SpanDAC output (this Mac's, or an iPhone's) is sent the concatenated IDs as
/// one `slice.queue {library_ids}`, shuffled together for `s`; the MusicTUI
/// output hands the rows to the persistent-ID hand-off, which builds one
/// app-owned queue (and shuffles it for `s`), with the set's skipped videos in
/// the report its confirmation carries. There is no SpanDAC container that is
/// exactly these items, so it is never a whole `slice.playLibrary`. A set whose
/// request would not fit the request frame is refused before anything is sent.
/// Everything here READS, apart from the one play: nothing is written to Music
/// or to the SpanDAC library.
private func playMarkedSetFromSpanDAC(_ items: [MarkedItem], shuffle: Bool, stamp: (epoch: Int, dataEpoch: Int),
                                      routing: RoutingCoordinator, status: StatusStore,
                                      spanDAC: MarkedSetSpanDAC) throws {
    guard let provider = spanDAC.makeProvider() else {
        throw ActionError(message: LibraryProvenance.musicAppSelectedBridgeList)
    }
    let name = markedSetDisplayName(items)
    let sleep = spanDAC.sleep
    do {
        let budget = WarmUpBudget()
        let onWarming: (TimeInterval) -> Void = { _ in
            status.post("Preparing your library \u{2014} '\(name)' will play when it's ready\u{2026}")
        }
        let stillCurrent = { routing.playOutputKind(expecting: stamp) != .stale }
        let switched = ActionError(message: sourceChangedNothingPlayed)
        let changed = ActionError(message: markedSetSpanDACChangedLine(name))
        // ONE request, fenced on both sides. A source change is reported as one,
        // never as a read that failed or went on warming after it.
        func fencedRequest<T>(_ request: () throws -> T) throws -> T {
            guard stillCurrent() else { throw switched }
            let answer: T
            do { answer = try request() } catch {
                guard stillCurrent() else { throw switched }
                throw error
            }
            guard stillCurrent() else { throw switched }
            return answer
        }
        // The snapshot the first read answered; every later read must match it.
        var snapshot: Int?
        func sameSnapshot(_ seen: Int?) -> Bool {
            guard let seen else { return false }
            guard let snapshot else { snapshot = seen; return true }
            return seen == snapshot
        }
        let read = try markedSetSpanDACRows(
            items,
            albumTracks: { albumID in
                // The fence is inside the warming retry: each attempt is fenced.
                let list = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                    try fencedRequest { try provider.albumTracks(albumID: albumID) }
                }
                guard sameSnapshot(list.generation) else { throw changed }
                return list.rows
            },
            playlistTracks: { playlistID in
                // The whole-playlist play's own walk (`for_queue`), every page,
                // each page request (and each warming retry of it) fenced.
                var rows: [MusicRow] = []
                var skippedVideos = 0
                var crossedSwitch = false
                var crossedSnapshot = false
                let failed = walkLibraryPages(
                    fetch: { cursor, limit in
                        do {
                            return try fencedRequest {
                                try provider.playlistTracksForQueue(playlistID: playlistID, cursor: cursor, limit: limit)
                            }
                        } catch let error as ActionError where error.message == sourceChangedNothingPlayed {
                            // The walk reduces any error but a provider's to
                            // "unavailable": remember what this one was.
                            crossedSwitch = true
                            throw error
                        }
                    },
                    limit: PlaylistsScene.bridgeTracksPageLimit,
                    onPage: { page in
                        guard sameSnapshot(page.generation) else { crossedSnapshot = true; return false }
                        rows += page.rows
                        skippedVideos = page.skippedVideos
                        return true
                    },
                    onRestart: { rows = []; skippedVideos = 0 },
                    onWarming: onWarming, sleep: sleep, budget: budget)
                if crossedSwitch { throw switched }
                if crossedSnapshot { throw changed }
                if let failed { throw failed }
                return (rows, skippedVideos)
            })
        let rows = read.rows
        let sent = bridgeQueueRows(rows, shuffle: shuffle, startAt: 1)
        let ids = sent.map(\.id)
        // A SpanDAC output takes the set as one request: refuse one too large
        // to send, before anything is sent, rather than cut it short.
        if routing.musicTUISpanDACStamp == nil,
           SourceAppControl.libraryQueueRequestBytes(libraryIDs: ids, startRequired: false)
               > SourceAppControl.maximumRequestBytes {
            throw ActionError(message: markedSetTooLargeForSpanDACLine(ids.count))
        }
        var skippedUnavailable = 0
        var handedOff: HandoffPlayReport?
        try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
            try routing.perform(.libraryPlay, expecting: stamp, origin: .spandacLibrary,
                musicApp: { path in
                    guard path == .handoff else { throw ActionError(message: pickASpanDACOutput) }
                    handedOff = try playThroughHandoff(spanDAC.handoff, rows: rows, startAt: 1,
                                                       startRequired: false, shuffle: shuffle, title: name,
                                                       skippedVideos: read.skippedVideos)
                },
                source: { client in
                    let played = try spanDACOutputPlayer(client).playRetainingToken(ids: ids, startRequired: false)
                    skippedUnavailable = played.skippedUnavailable
                    // SpanDAC's `row` / `next_rows` index the request sent, so a
                    // skipped song shifts nothing while they come. But a status
                    // without `next_rows` would have the sent order stand in for
                    // the player's, and it still holds the songs SpanDAC left
                    // out: recorded as an order the sent rows cannot stand in
                    // for, so Up Next lists only what SpanDAC vouches for.
                    routing.recordSpanDACPlay(sent, token: played.queueToken,
                                              shuffled: played.skippedUnavailable > 0)
                },
                unaffected: {})
        }
        if let handedOff {
            status.post(LibraryProvenance.playingOnMusicTUI(name, report: handedOff),
                        untilStateChange: handedOff.notice != nil)
            return
        }
        // The single SpanDAC playlist play's own sentence: the videos apart
        // from the songs SpanDAC could not play.
        status.post(bridgePlaylistPlayMessage(name: name, queued: ids.count, skippedVideos: read.skippedVideos,
                                              skippedUnavailable: skippedUnavailable, startAt: 1, shuffle: shuffle),
                    untilStateChange: skippedUnavailable > 0 || read.skippedVideos > 0)
    } catch let error as MusicProviderError {
        throw ActionError(message: error.errorDescription ?? "Couldn't play '\(name)' on SpanDAC.")
    } catch let error as SourceAppError {
        throw ActionError(message: error.message)
    }
}

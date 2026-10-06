// tools/music/Sources/TUI/Shell/WholeLibraryPlay.swift
import Foundation

// How a library album, artist, playlist or Songs play is sent, now that SpanDAC
// can play a container whole (`slice.playLibrary`): the decision, and the words
// a person reads about the result. Shared by the Library and Playlists scenes so
// the rule is written once.

/// How one library play goes to SpanDAC.
enum LibraryPlayPlan: Equatable {
    /// One `slice.playLibrary`: the container named, the start row by index and
    /// id (a whole or shuffled play has none), and the `list_rev` of the read
    /// the rows came from. SpanDAC refuses a play with no `list_rev`.
    case whole(start: LibraryPlayStart?, listRev: String)
    /// Today's path: the rows are read and their ids sent as one list.
    case legacy
    /// SpanDAC plays containers whole, but the `list_rev` that proves the list
    /// (and the start row's index) can only come from a read, and the scene has
    /// none yet: read, then decide again.
    case needsRows
}

/// Decides how a play goes.
///
/// `capable` is whether the OUTPUT SpanDAC lists `play.library` (the Mac's local
/// one does; a network SpanDAC does not advertise it). `rows` and `listRev` are
/// the list the person was looking at and the `list_rev` of the read that
/// produced it, when the scene has them.
///
/// - Not capable: legacy.
/// - No rows read yet: `needsRows`, because every container play sends the
///   `list_rev` of a read, and a from-row play also needs the row's index.
/// - Rows read by a SpanDAC that sent no `list_rev` cannot be proven to be the
///   list SpanDAC holds: legacy (and an empty list is the scene's own refusal).
/// - Otherwise whole, from the picked row for a from-row play and from the
///   start for a whole or shuffled one.
func libraryPlayPlan(capable: Bool, rows: [MusicRow]?, listRev: String?, startAt: Int,
                     startRequired: Bool, shuffle: Bool) -> LibraryPlayPlan {
    guard capable else { return .legacy }
    guard let rows else { return .needsRows }
    guard let listRev, !rows.isEmpty else { return .legacy }
    guard startRequired && !shuffle else { return .whole(start: nil, listRev: listRev) }
    let index = min(max(1, startAt), rows.count) - 1
    return .whole(start: LibraryPlayStart(index: index, id: rows[index].id), listRev: listRev)
}

/// Whether the OUTPUT SpanDAC (the selected one, not the data client) plays a
/// library container whole. Read before a play reads anything else. False when
/// the output is not a SpanDAC, when `stamp` (taken at the keypress) no longer
/// holds, and when the capabilities cannot be read: today's path, and for a
/// stale stamp the play then refuses in `perform` as it always has.
func outputPlaysLibraryWhole(routing: RoutingCoordinator, expecting stamp: (epoch: Int, dataEpoch: Int)) -> Bool {
    guard let client = routing.outputSourceClient(expecting: stamp) else { return false }
    return spanDACOutputPlayer(client).supportsPlayLibrary()
}

/// The footer for a whole-container play: how many are queued, and "P of R
/// queued" when SpanDAC's player holds fewer than it was asked for, then any
/// playlist videos left out and any songs SpanDAC cannot play.
func bridgeWholePlayMessage(name: String, result: SpanDACPlayResult) -> String {
    let queued = result.queued ?? 0
    var message = "Playing '\(name)' on SpanDAC \u{2014} "
    if let requested = result.requested, queued < requested {
        message += "\(groupedCount(queued)) of \(groupedCount(requested)) queued."
    } else {
        message += "\(groupedCount(queued)) queued."
    }
    let v = result.skippedVideos
    if v > 0 { message += " \(v) video\(v == 1 ? "" : "s") in this playlist skipped." }
    if result.skippedUnavailable > 0 { message += " " + bridgeUnavailableSongsNotice(result.skippedUnavailable) }
    return message
}

/// Whether that footer stays until something changes: something was left out or
/// the queue came up short.
func bridgeWholePlayNeedsAttention(_ result: SpanDACPlayResult) -> Bool {
    if result.skippedUnavailable > 0 || result.skippedVideos > 0 { return true }
    if let requested = result.requested, let queued = result.queued, queued < requested { return true }
    return false
}

/// The Songs list as it was on screen when a row was played, for a play that
/// continues through the rest of it: the row's index in the whole (unfiltered)
/// list in the order SpanDAC serves, the list itself, and its `list_rev`.
struct WholeSongsPlay {
    let index: Int
    let songs: [LibrarySong]
    let rowsByID: [String: MusicRow]
    let listRev: String

    /// The list as `MusicRow`s (the rows SpanDAC's status `row` / `next_rows`
    /// index), keeping the aliases SpanDAC sent when the walk recorded them.
    func rows() -> [MusicRow] {
        songs.map { song in
            rowsByID[song.id] ?? MusicRow(id: song.id, title: song.title, artist: song.artist,
                                          album: song.album.isEmpty ? nil : song.album, kind: .song)
        }
    }
}

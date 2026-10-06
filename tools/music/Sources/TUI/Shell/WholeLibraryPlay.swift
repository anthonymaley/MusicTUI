// tools/music/Sources/TUI/Shell/WholeLibraryPlay.swift
import Foundation

// How a library album, artist, playlist or Songs play is sent, now that SpanDAC
// can play a container whole (`slice.playLibrary`): the decision, and the words
// a person reads about the result. Shared by the Library and Playlists scenes so
// the rule is written once.

/// How one library play goes to SpanDAC.
enum LibraryPlayPlan: Equatable {
    /// One `slice.playLibrary`: the container named, the start row by index and
    /// id (a whole or shuffled play has none), and the `list_rev` of the list.
    /// SpanDAC refuses a play with no `list_rev`.
    case whole(start: LibraryPlayStart?, listRev: String)
    /// Today's path: the rows are read and their ids sent as one list.
    case legacy
}

/// Decides how a play goes.
///
/// `capable` is whether the OUTPUT SpanDAC lists `play.library` (the Mac's local
/// one does; a network SpanDAC does not advertise it). `rows` and `listRev` are
/// the list the person was looking at and its `list_rev`, when the scene has
/// them: from a read of the rows, or, for a play that needs the revision but not
/// the rows, from `slice.listRev` (then `rows` is nil).
///
/// - Not capable: legacy.
/// - A `list_rev` with no rows is enough for a whole or shuffled play, which names
///   no row. A from-row play names its row by index, so it needs the rows too.
/// - Rows read by a SpanDAC that sent no `list_rev` cannot be proven to be the
///   list SpanDAC holds: legacy (and an empty list is the scene's own refusal).
func libraryPlayPlan(capable: Bool, rows: [MusicRow]?, listRev: String?, startAt: Int,
                     startRequired: Bool, shuffle: Bool) -> LibraryPlayPlan {
    guard capable, let listRev else { return .legacy }
    let fromRow = startRequired && !shuffle
    guard let rows else { return fromRow ? .legacy : .whole(start: nil, listRev: listRev) }
    guard !rows.isEmpty else { return .legacy }
    guard fromRow else { return .whole(start: nil, listRev: listRev) }
    let index = min(max(1, startAt), rows.count) - 1
    return .whole(start: LibraryPlayStart(index: index, id: rows[index].id), listRev: listRev)
}

/// A library play, decided: how it goes, and what the scene holds of the list.
struct PlannedLibraryPlay {
    var plan: LibraryPlayPlan
    /// The rows, when they were read or were already on screen. Nil for a whole
    /// play that needed only the revision: no rows are kept for Up Next then.
    var rows: [MusicRow]?
    var listRev: String?
}

/// Reads what a library play needs, and decides how it goes.
///
/// A play that needs a `list_rev` but not the rows (a whole or shuffled play with
/// nothing cached) asks for the revision alone, `slice.listRev`, which is
/// unbounded: no listing read, so a 1,001-song artist or album plays whole, and
/// no page walk (Codex 116, finding 2). A from-row play uses the `list_rev` that
/// came with the rows on screen. A SpanDAC that cannot read a revision answers
/// `unknown_op` and the rows are read as before, and so is every output that
/// will not take the play whole.
///
/// The OUTPUT capability is read last, after any read, so a switch that crossed
/// the read builds no output client (C-EPOCH). The data provider's own capability
/// decides whether to ask it for a revision, and a MusicTUI output (the hand-off)
/// always needs the rows.
func planLibraryPlay(routing: RoutingCoordinator, stamp: (epoch: Int, dataEpoch: Int),
                     provider: MusicDataProvider, rows given: [MusicRow]?, listRev givenRev: String?,
                     startAt: Int, startRequired: Bool, shuffle: Bool, emptyMessage: String,
                     readRevision: () throws -> SpanDACListRev,
                     readRows: () throws -> (rows: [MusicRow], listRev: String?)) throws -> PlannedLibraryPlay {
    var rows = given
    var rev = givenRev
    let wantsStart = startRequired && !shuffle
    if rows == nil {
        var haveRevision = false
        if !wantsStart, routing.mode.usesSource, provider.supportsPlayLibrary() {
            do {
                let read = try readRevision()
                if read.count == 0 { throw ActionError(message: emptyMessage) }
                rev = read.listRev
                haveRevision = true
            } catch let error as MusicProviderError {
                // An older SpanDAC cannot read a revision: read the rows, as before.
                guard case .notImplemented = error else { throw error }
            }
        }
        if !haveRevision {
            let read = try readRows()
            rows = read.rows
            rev = read.listRev
        }
    }
    if let rows, rows.isEmpty { throw ActionError(message: emptyMessage) }
    var plan = libraryPlayPlan(capable: outputPlaysLibraryWhole(routing: routing, expecting: stamp),
                               rows: rows, listRev: rev, startAt: startAt,
                               startRequired: startRequired, shuffle: shuffle)
    if rows == nil, case .legacy = plan {
        // Only the revision was read and this output will not take the play whole:
        // the rows are read after all, for the id list.
        let read = try readRows()
        if read.rows.isEmpty { throw ActionError(message: emptyMessage) }
        rows = read.rows
        rev = read.listRev
        plan = .legacy
    }
    return PlannedLibraryPlay(plan: plan, rows: rows, listRev: rev)
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

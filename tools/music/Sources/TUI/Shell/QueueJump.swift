// tools/music/Sources/TUI/Shell/QueueJump.swift
import Foundation

// Enter on an Up Next row while a SpanDAC output is selected: the Now scene's
// half of `slice.queueJump` (the wire half is `SpanDACQueueJump.swift`).
//
// Runs as the `.source` branch of `RoutingCoordinator.perform(.queueJump,
// expecting: ...)`, so by the time it runs the routing boundary has already
// refused a stale epoch and the play-out gate has already refused a lapsed
// licence. What is left to decide here is whether THIS output can jump at all,
// and whether the row on screen still means what it meant at the keypress. Every
// "no" is `queueJumpRefusal` or a named refusal, thrown as an `ActionError` so
// the footer shows it; nothing here falls back to Apple's Music app, whose body
// the caller never runs on a SpanDAC route.

/// Jumps SpanDAC's player to the Up Next entry `entryIndex` of the queue Now
/// drew for `displayedToken`.
///
/// - The carrier must be the Mac's own SpanDAC (`.source`): a SpanDAC on the
///   network is refused outright, whatever it lists.
/// - `queue.jump` must be in the output's capabilities as asked NOW. A status
///   that cannot be read is the error it is, not a "yes".
/// - The play whose rows were drawn must still be the play on record, under the
///   same token (`sourceChangedNothingPlayed` otherwise): rows from another
///   queue would index the wrong songs.
/// - `entryIndex` is the entry's 1-based `index`; the wire's `row` is 0-based.
///
/// A reply for any other token, or one that is not playing, is a refusal: the
/// kept rows are the queue that was asked about, and are never re-bound.
func jumpSpanDACQueue(routing: RoutingCoordinator, client: SourceAppClient,
                      displayedToken: String?, entryIndex: Int) throws -> SpanDACQueueJumpResult {
    guard routing.mode == .source,
          let token = displayedToken,
          let row = SourceAppControl.queueJumpRow(forEntryIndex: entryIndex) else {
        throw ActionError(message: queueJumpRefusal)
    }
    guard routing.spanDACPlay()?.token == token else {
        throw ActionError(message: sourceChangedNothingPlayed)
    }
    do {
        guard try client.control.capabilities().contains(sourceQueueJumpCapability) else {
            throw ActionError(message: queueJumpRefusal)
        }
        let result = try client.control.queueJump(token: token, row: row)
        return result
    } catch let error as SourceAppError {
        throw ActionError(message: error.message)
    }
}

/// Up Next as the jump's reply describes it: the entries the Now tab draws for
/// the status the reply carried, against the rows kept for the play. Empty when
/// the kept rows no longer vouch for that status, which leaves Now to the next
/// poll.
func spanDACQueueJumpEntries(routing: RoutingCoordinator,
                             result: SpanDACQueueJumpResult) -> [TrackListEntry] {
    guard let play = routing.spanDACPlay() else { return [] }
    return spanDACQueueWindow(sent: play.rows, token: play.token, shuffled: play.shuffled,
                              status: result.status).entries
}

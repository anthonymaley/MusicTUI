// tools/music/Sources/TUI/SpanDACQueueJump.swift
import Foundation

// `slice.queueJump`: the client half of "Enter on an Up Next row".
//
// MusicTUI names the row it is showing and the queue it is showing it for;
// SpanDAC jumps its own player to that row and answers with the status it left.
// Nothing is guessed on either side: the `queue_token` is the one recorded for
// the DISPLAYED queue (`RoutingCoordinator.spanDACPlay`), so a queue another
// process replaced is refused by SpanDAC rather than jumped into, and `row` is
// the row's place in the list the play SENT, 0-based on the wire.
//
// Protocol code only: a request body, a reply decoder, and the words a person
// reads about a refusal. Contract 3, additive, advertised as `queue.jump` by the
// Mac's local Unix-socket SpanDAC alone; a SpanDAC on the network never lists it.

/// The wire op, and the capability SpanDAC lists when it serves it.
let sourceQueueJumpOp = "slice.queueJump"
let sourceQueueJumpCapability = "queue.jump"

/// What a successful jump told the client.
struct SpanDACQueueJumpResult {
    /// The status the jump left behind, decoded as `slice.status` would be.
    let status: SourceStatus
    /// The token of the assignment standing after the jump. Usually the one
    /// sent; the rows kept for the play are re-bound to it (never trusted
    /// without it).
    let queueToken: String
}

extension SourceAppControl {

    /// The request body. `row` is ZERO-based in the sent list, and the public
    /// `TrackListEntry.index` is ONE-based, so the caller converts once, here:
    /// `queueJumpRow(forEntryIndex:)`.
    static func queueJumpBody(token: String, row: Int) -> [String: Any] {
        ["op": sourceQueueJumpOp, "queue_token": token, "row": row]
    }

    /// An Up Next entry's `index` (its 1-based place in the list the play sent)
    /// as the wire's 0-based `row`. Nil for an index no entry can have.
    static func queueJumpRow(forEntryIndex index: Int) -> Int? {
        index >= 1 ? index - 1 : nil
    }

    /// `slice.queueJump {"queue_token","row"}`. A blank token or a negative row
    /// is a bug in the caller, refused here before anything is sent. It travels
    /// on the library transport: the player may have to prepare the row before
    /// SpanDAC answers, which can outlast the transport commands' 10 s.
    func queueJump(token: String, row: Int) throws -> SpanDACQueueJumpResult {
        guard Self.queueToken(token) != nil else {
            throw SourceAppError.refused("a queue jump needs the queue's token")
        }
        guard row >= 0 else {
            throw SourceAppError.refused("a queue jump needs a row of 0 or more")
        }
        let reply = try send(Self.queueJumpBody(token: token, row: row), over: libraryTransport)
        return try Self.queueJumpResult(from: reply, readingWith: self)
    }

    /// A successful reply, fail closed: a status that decodes, and a nonblank
    /// top-level `queue_token` that the embedded status echoes when it carries
    /// one. A reply missing either is a peer that broke the contract, and no
    /// rows are re-bound against it.
    static func queueJumpResult(from reply: [String: Any],
                                readingWith control: SourceAppControl) throws -> SpanDACQueueJumpResult {
        guard let wireStatus = reply["status"] as? [String: Any],
              let status = decodeStatus(wireStatus, readingWith: control) else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourceQueueJumpOp) reply has no status")
        }
        guard let token = queueToken(reply["queue_token"]),
              status.queueToken == nil || status.queueToken == token else {
            throw SourceAppError.malformedReply(
                "SpanDAC's \(sourceQueueJumpOp) reply has no queue_token, or two that differ")
        }
        return SpanDACQueueJumpResult(status: status, queueToken: token)
    }
}

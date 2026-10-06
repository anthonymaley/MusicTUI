// tools/music/Sources/TUI/SpanDACPlayLibrary.swift
import Foundation

// `slice.playLibrary`: the client half of "play a library container whole".
//
// MusicTUI names the container (an album, an artist, a playlist, or the Songs
// list) and the row it started from; SpanDAC reads the container itself and
// builds ONE whole queue. No song ids cross the wire, so the 64 KiB request
// frame no longer bounds what a play can be (Codex 106, finding 3), and the
// client's page walk before a play is no longer needed.
//
// The play also sends back the `list_rev` of the read that produced the rows on
// screen (an opaque fingerprint of the whole ordered list; for Songs, the
// snapshot generation), so SpanDAC refuses `library_changed` when the list moved
// since. A play with no `list_rev` is refused, so rows read without one stay on
// the id-list path.
//
// Protocol code only: a request body, a reply decoder, and the words a person
// reads about the result. Contract 3, additive, advertised as `play.library`
// (by the Mac's local SpanDAC only).

/// The wire op, and the capability SpanDAC lists when it serves it. The same
/// capability also says every successful play reply and `slice.status` carry
/// `queue_token`.
let sourcePlayLibraryOp = "slice.playLibrary"
let sourcePlayLibraryCapability = "play.library"

/// What a `slice.playLibrary` names.
enum LibraryPlayKind: String, Equatable {
    case album, artist, playlist, songs
}

/// The row a from-row play starts at: its 0-based index in the list SpanDAC
/// serves for that container, and the library id the client saw there. The id
/// is a check, not the key: a playlist can hold one song twice, so the row is
/// named by index, and SpanDAC refuses `library_changed` when its own row at
/// that index is not this id.
struct LibraryPlayStart: Equatable {
    let index: Int
    let id: String
}

/// What a successful play told the client about the queue it made.
struct SpanDACPlayResult: Equatable {
    /// The queue as the reply's own status reads (or, for a legacy play, the
    /// status read straight after it).
    var queue: BridgeNow.Queue
    /// Songs SpanDAC left out because it cannot play them. 0 included.
    var skippedUnavailable: Int
    /// A playlist's videos, which a queue never holds. `slice.playLibrary` only.
    var skippedVideos: Int = 0
    /// `slice.playLibrary` only: the entries the player was OBSERVED to hold,
    /// not the number asked for.
    var queued: Int? = nil
    /// `slice.playLibrary` only: how many entries SpanDAC asked the player to
    /// take (the status's `queue.requested`), so a short queue can say
    /// "796 of 800 queued".
    var requested: Int? = nil
    /// The token of the assignment standing when the play finished: the rows,
    /// Up Next and cover kept for this play are trusted only while
    /// `slice.status` echoes it. Nil from a SpanDAC that predates it.
    var queueToken: String? = nil
}

/// `slice.listRev`'s answer: the revision of the complete ordered list, and its
/// row count. No rows.
struct SpanDACListRev: Equatable {
    let listRev: String
    let count: Int
}

/// The revision-only read, served only where `play.library` is advertised.
let sourceListRevOp = "slice.listRev"

extension SourceAppControl {

    /// `slice.listRev {"kind","id"}` (no id for songs): the `list_rev` of a
    /// container's complete ordered list WITHOUT its rows. Unbounded, so a whole
    /// play of an album or artist over the listing reads' 1,000-song bound (or any
    /// list not worth reading to play) can still be proven. Its value equals the
    /// list read's `list_rev` for the same list.
    func listRev(kind: LibraryPlayKind, id: String?) throws -> SpanDACListRev {
        if kind == .songs, id != nil {
            throw SourceAppError.refused("a revision of the Songs list names no container")
        }
        if kind != .songs, (id ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw SourceAppError.refused("a revision of a \(kind.rawValue) needs its id")
        }
        var body: [String: Any] = ["op": sourceListRevOp, "kind": kind.rawValue]
        if let id { body["id"] = id }
        let reply = try send(body, over: libraryTransport)
        // Fail closed: a revision that is missing, blank or for another kind of
        // list would prove nothing about the list the play names.
        guard (reply["kind"] as? String) == kind.rawValue else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourceListRevOp) reply is for another kind of list")
        }
        guard let rev = Self.listRev(reply["list_rev"]) else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourceListRevOp) reply has no list_rev")
        }
        guard let count = Self.index(reply["count"]) else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourceListRevOp) reply has a count that is not a count")
        }
        return SpanDACListRev(listRev: rev, count: count)
    }

    /// The request body: `kind`; `id` only for a container; `start_index` and
    /// `start_id` together or not at all; `list_rev` when the rows the play
    /// started from came from a read that carried one; `shuffle` always,
    /// explicitly.
    static func playLibraryBody(kind: LibraryPlayKind, id: String?, start: LibraryPlayStart?,
                                listRev: String?, shuffle: Bool) -> [String: Any] {
        var body: [String: Any] = ["op": sourcePlayLibraryOp, "kind": kind.rawValue, "shuffle": shuffle]
        if let id { body["id"] = id }
        if let listRev { body["list_rev"] = listRev }
        if let start {
            body["start_index"] = start.index
            body["start_id"] = start.id
        }
        return body
    }

    /// Plays one library container whole. A shuffled play takes no start row
    /// (SpanDAC would refuse it `bad_request`), and a songs play names no
    /// container while the other kinds need one; each is refused here, before
    /// anything is sent, because it would be a bug in the caller rather than
    /// something to ask SpanDAC.
    ///
    /// It travels on the library transport: SpanDAC reads the container and
    /// prepares the whole queue before it answers, which can outlast the
    /// transport commands' 10 s.
    func playLibrary(kind: LibraryPlayKind, id: String?, start: LibraryPlayStart?, listRev: String?,
                     shuffle: Bool) throws -> SpanDACPlayResult {
        if shuffle && start != nil {
            throw SourceAppError.refused("a shuffled play starts at the first song of the shuffle, so it takes no start row")
        }
        if kind == .songs, id != nil {
            throw SourceAppError.refused("a play of the Songs list names no container")
        }
        if kind != .songs, (id ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw SourceAppError.refused("a play of a \(kind.rawValue) needs its id")
        }
        let reply = try send(Self.playLibraryBody(kind: kind, id: id, start: start, listRev: listRev, shuffle: shuffle),
                             over: libraryTransport)
        return try Self.playLibraryResult(from: reply, readingWith: self)
    }

    /// A successful reply, fail closed: `queued` and both skip counts are on
    /// every successful reply (0 included), so one that is missing or is not a
    /// whole non-negative number is a peer that broke the contract, never a
    /// zero. So is the token `play.library` promises: a nonblank top-level
    /// `queue_token` AND the same one in the embedded status, or the reply is
    /// malformed and no rows are kept against it (Codex 116, finding 1). The
    /// nil-token compatibility belongs to the legacy `slice.queue` path alone.
    static func playLibraryResult(from reply: [String: Any],
                                  readingWith control: SourceAppControl) throws -> SpanDACPlayResult {
        func count(_ key: String) throws -> Int {
            guard let n = index(reply[key]) else {
                throw SourceAppError.malformedReply("SpanDAC's \(sourcePlayLibraryOp) reply has a \(key) that is not a count")
            }
            return n
        }
        let queued = try count("queued")
        let unavailable = try count("skipped_unavailable")
        let videos = try count("skipped_videos")
        guard let wireStatus = reply["status"] as? [String: Any],
              let status = decodeStatus(wireStatus, readingWith: control) else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourcePlayLibraryOp) reply has no status")
        }
        guard let token = queueToken(reply["queue_token"]), status.queueToken == token else {
            throw SourceAppError.malformedReply(
                "SpanDAC's \(sourcePlayLibraryOp) reply has no queue_token, or two that differ")
        }
        return SpanDACPlayResult(queue: bridgeNow(from: status).queue,
                                 skippedUnavailable: unavailable, skippedVideos: videos,
                                 queued: queued, requested: status.queueRequested,
                                 queueToken: token)
    }

    /// `list_rev` as sent: a non-blank string, or nil (an older SpanDAC).
    static func listRev(_ raw: Any?) -> String? { queueToken(raw) }

    /// An opaque token as sent: a non-blank string, or nil. Compared for
    /// equality and nothing else.
    static func queueToken(_ raw: Any?) -> String? {
        guard let token = raw as? String, !token.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return token
    }
}

// tools/music/Sources/TUI/SpanDACLibraryRefresh.swift
import Foundation

// `slice.libraryRefresh`: ask SpanDAC to re-read the Mac's library now, and the
// completion fact that says whether it did.
//
// SpanDAC serves its held snapshot and never pushes a change, so a playlist made
// in Apple's Music app after the snapshot is missing until SpanDAC rebuilds it.
// This op starts that rebuild. It takes no fields and answers at once, naming
// what it did with the ask and the ticket the rebuild runs under:
//
//   {"ok":true,"op":"slice.libraryRefresh","outcome":"started"|"joined"|"deferred",
//    "ticket":<int>|null,"instance":"<id>"}
//
// `started` began a rebuild, `joined` found one running and attached the ask to
// it (that drain may have read the library before the person asked, so it is
// not by itself a refresh), `deferred` declined for now (no ticket). `instance`
// names the SpanDAC process; a different one later means it restarted. The rebuilt list is read
// afterwards with the ordinary paged reads, which come back flagged
// `stale`/`refreshing` until the rebuild lands (`LibraryReask`).
//
// What the rebuild came to is on `slice.status` (the Mac's Unix socket only):
//
//   "library_refresh":{"instance":"<id>","ticket":7,"result":"installed"|"failed"|"cancelled"}  or  null
//
// set atomically with the install, failure or cancellation. It is trusted only
// when its `instance` is the one the op's reply named and its `ticket` is at
// least the ask's. A list's `generation` advances on
// EVERY successful install, content changed or not, so it is never read as proof
// of anything here.
//
// Protocol code only. Additive, advertised as `library.refresh`; a SpanDAC that
// does not list it is never sent the op.

/// The wire op, and the capability SpanDAC lists when it serves it.
let sourceLibraryRefreshOp = "slice.libraryRefresh"
let sourceLibraryRefreshCapability = "library.refresh"

/// What SpanDAC did with the ask.
enum SpanDACLibraryRefreshOutcome: Equatable {
    /// A rebuild began, under this ticket, in this SpanDAC process.
    case started(ticket: Int, instance: String)
    /// A rebuild was already running; the ask is attached to its ticket.
    case joined(ticket: Int, instance: String)
    /// SpanDAC will not rebuild right now.
    case deferred
}

/// How a rebuild ended, as `slice.status` reports the latest one.
struct SpanDACLibraryRefreshCompletion: Equatable {
    enum Result: String, Equatable { case installed, failed, cancelled }
    /// The SpanDAC process that ran it.
    let instance: String
    let ticket: Int
    let result: Result
}

extension SourceAppControl {

    /// The request body: the op and nothing else.
    static func libraryRefreshBody() -> [String: Any] {
        ["op": sourceLibraryRefreshOp]
    }

    /// `slice.libraryRefresh`, on the library transport with the other library
    /// ops. A refusal (including `unknown_op`, `unlicensed`, `unauthorized`)
    /// throws like any other op's. A success reply fails closed: an outcome that
    /// is not one of the three, or a `started`/`joined` without a ticket, is
    /// malformed, never a refresh.
    func libraryRefresh() throws -> SpanDACLibraryRefreshOutcome {
        let reply = try send(Self.libraryRefreshBody(), over: libraryTransport)
        return try Self.libraryRefreshOutcome(from: reply)
    }

    static func libraryRefreshOutcome(from reply: [String: Any]) throws -> SpanDACLibraryRefreshOutcome {
        switch reply["outcome"] as? String {
        case "deferred":
            return .deferred
        case "started", "joined":
            guard let ticket = index(reply["ticket"]) else {
                throw SourceAppError.malformedReply("SpanDAC's \(sourceLibraryRefreshOp) reply has no ticket")
            }
            guard let instance = instanceID(reply["instance"]) else {
                throw SourceAppError.malformedReply("SpanDAC's \(sourceLibraryRefreshOp) reply has no instance")
            }
            return reply["outcome"] as? String == "started"
                ? .started(ticket: ticket, instance: instance) : .joined(ticket: ticket, instance: instance)
        default:
            throw SourceAppError.malformedReply("SpanDAC's \(sourceLibraryRefreshOp) reply has no outcome it knows")
        }
    }

    /// The `library_refresh` fact of `slice.status`, on the ordinary transport:
    /// nil when it is null or absent (no rebuild has ended yet, or a SpanDAC that
    /// does not carry it). Present but unreadable is malformed.
    func libraryRefreshCompletion() throws -> SpanDACLibraryRefreshCompletion? {
        let reply = try send(["op": "slice.status"])
        guard let status = reply["status"] as? [String: Any] else { return nil }
        return try Self.libraryRefreshCompletion(fromStatus: status)
    }

    static func libraryRefreshCompletion(fromStatus status: [String: Any]) throws -> SpanDACLibraryRefreshCompletion? {
        guard let raw = status["library_refresh"], !(raw is NSNull) else { return nil }
        guard let fact = raw as? [String: Any], let ticket = index(fact["ticket"]),
              let instance = instanceID(fact["instance"]),
              let result = (fact["result"] as? String).flatMap(SpanDACLibraryRefreshCompletion.Result.init(rawValue:)) else {
            throw SourceAppError.malformedReply("SpanDAC's library_refresh status is not readable")
        }
        return SpanDACLibraryRefreshCompletion(instance: instance, ticket: ticket, result: result)
    }

    /// A SpanDAC process's id: non-blank text.
    private static func instanceID(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}

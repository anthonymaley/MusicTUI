// tools/music/Sources/DJ/DJSpanDACGenreClient.swift
//
// The wire client for SpanDAC's `library.genreUnheard`: its oldest unplayed
// songs of a genre, filtered and sorted server side. It rides the existing
// `SourceAppClient` request path (the same send, the same refusal decoding as
// the library reads), and is gated on the capability: a SpanDAC that does not
// advertise it is never sent the op.
//
//   -> {"op":"library.genreUnheard","genre":"<string>","days":<1..36500>}
//   <- {"ok":true,"op":"library.genreUnheard","songs":[{"id","alias"?,"title","artist","album",
//        "last_played":Int|null}],"total":Int,"generation":Int,"instance":String}
//
// A reply that does not satisfy the contract fails the whole read: a shortened
// list is indistinguishable from a real one.
//
// The re-check at Enter is a second, cheap op, `library.resolveIDs`: it asks the
// live library whether every id the card will play still resolves, and answers
// with the instance and generation that held. It is identity, not a comparison
// with a fresh oldest-50 (which would wrongly reject songs still present when
// the ranking has moved on).
//
//   -> {"op":"library.resolveIDs","ids":["<library id>", ... up to 50]}
//   <- {"ok":true,"op":"library.resolveIDs","count":Int,"generation":Int,"instance":String}
import Foundation

let djGenreUnheardOp = "library.genreUnheard"
let djResolveIDsOp = "library.resolveIDs"

struct DJSpanDACGenreClient: DJSpanDACGenreSource {
    /// The most songs SpanDAC returns.
    static let maximumSongs = 50

    let client: SourceAppClient

    init(client: SourceAppClient) { self.client = client }

    func genreUnheard(genre: String, days: Int) throws -> DJSpanDACGenrePick {
        let reply = try read(genre: genre, days: days)
        return try Self.decode(reply, genre: genre, days: days)
    }

    /// At Enter: every id the card will play (the pick's rows) still resolves in
    /// the live SpanDAC library, under the same instance and generation the pick
    /// was read in. Anything else, or a check that cannot be made, fails whole.
    /// This narrows how stale the pick can be at Enter; a change that leaves both
    /// stamp values and every id alone is invisible to it.
    func recheck(_ pick: DJSpanDACGenrePick) throws {
        guard let instance = pick.instance, let generation = pick.generation else {
            throw DJGenreSourceError.libraryChanged
        }
        let ids = pick.rows.map(\.id)
        guard !ids.isEmpty, ids.count <= Self.maximumSongs, Set(ids).count == ids.count else {
            throw DJGenreSourceError.failed("the chosen songs can't be checked")
        }
        let reply = try ask(djResolveIDsOp, ["op": djResolveIDsOp, "ids": ids])
        guard let count = Self.int(reply["count"]), count >= 0, count <= ids.count else {
            throw Self.bad("is missing a usable count", of: djResolveIDsOp)
        }
        guard let seenGeneration = Self.int(reply["generation"]) else {
            throw Self.bad("is missing generation", of: djResolveIDsOp)
        }
        guard let seenInstance = reply["instance"] as? String,
              !seenInstance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.bad("is missing instance", of: djResolveIDsOp)
        }
        guard seenInstance == instance, seenGeneration == generation, count == ids.count else {
            throw DJGenreSourceError.libraryChanged
        }
    }

    // MARK: the request

    private func read(genre: String, days: Int) throws -> [String: Any] {
        try ask(djGenreUnheardOp, ["op": djGenreUnheardOp, "genre": genre, "days": days])
    }

    /// One op on the library transport, sent only when the SpanDAC advertises it.
    private func ask(_ op: String, _ body: [String: Any]) throws -> [String: Any] {
        let control = (client.control as? SourceAppControl)
            ?? SourceAppControl(path: client.path, transport: client.transport)
        do {
            guard try control.capabilities().contains(op) else {
                throw DJGenreSourceError.needsNewerSpanDAC
            }
            return try control.send(body, over: control.libraryTransport)
        } catch let error as DJGenreSourceError {
            throw error
        } catch let error as SourceAppError {
            throw Self.translate(error)
        }
    }

    static func translate(_ error: SourceAppError) -> DJGenreSourceError {
        switch error {
        case .unsupported: return .needsNewerSpanDAC
        case .staleGeneration: return .libraryChanged
        default: return .failed(error.message)
        }
    }

    // MARK: the reply

    private static func bad(_ what: String, of op: String = djGenreUnheardOp) -> DJGenreSourceError {
        .failed("SpanDAC's \(op == djGenreUnheardOp ? "genre" : "library check") reply \(what)")
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    static func decode(_ reply: [String: Any], genre: String, days: Int) throws -> DJSpanDACGenrePick {
        guard let items = reply["songs"] as? [[String: Any]] else { throw bad("is missing songs") }
        guard let total = int(reply["total"]), total >= items.count else {
            throw bad("is missing a usable total")
        }
        guard let generation = int(reply["generation"]) else { throw bad("is missing generation") }
        guard let instance = reply["instance"] as? String,
              !instance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw bad("is missing instance")
        }
        guard items.count <= maximumSongs else { throw bad("has more than \(maximumSongs) songs") }

        var rows: [MusicRow] = []
        for item in items {
            guard let id = item["id"] as? String, !id.isEmpty,
                  let title = item["title"] as? String,
                  let artist = item["artist"] as? String,
                  let album = item["album"] as? String else {
                throw bad("has a song without an id, title, artist or album")
            }
            // last_played must be present, an integer or null; MusicRow keeps none of it.
            guard let played = item["last_played"], played is NSNull || int(played) != nil else {
                throw bad("has a song with no readable last_played")
            }
            var alias: String?
            if let raw = item["alias"] {
                guard let text = raw as? String else { throw bad("has a song with an alias that is not text") }
                alias = text
            }
            var row = MusicRow(id: id, title: title, artist: artist, album: album, kind: .song)
            row.alias = alias
            rows.append(row)
        }
        return DJSpanDACGenrePick(rows: rows, total: total, instance: instance, generation: generation,
                                  genre: genre, days: days)
    }
}

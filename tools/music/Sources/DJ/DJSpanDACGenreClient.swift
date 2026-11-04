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
import Foundation

let djGenreUnheardOp = "library.genreUnheard"

struct DJSpanDACGenreClient: DJSpanDACGenreSource {
    /// The most songs SpanDAC returns.
    static let maximumSongs = 50

    let client: SourceAppClient

    init(client: SourceAppClient) { self.client = client }

    func genreUnheard(genre: String, days: Int) throws -> DJSpanDACGenrePick {
        let reply = try read(genre: genre, days: days)
        return try Self.decode(reply, genre: genre, days: days)
    }

    /// Re-reads the same question and requires the same instance and generation.
    /// This narrows how stale the pick can be at Enter; it does not prove the
    /// library unchanged (a change that leaves both values alone is invisible).
    func recheck(_ pick: DJSpanDACGenrePick) throws {
        guard let instance = pick.instance, let generation = pick.generation,
              let genre = pick.genre, let days = pick.days else {
            throw DJGenreSourceError.libraryChanged
        }
        let again = try Self.decode(try read(genre: genre, days: days), genre: genre, days: days)
        guard again.instance == instance, again.generation == generation else {
            throw DJGenreSourceError.libraryChanged
        }
    }

    // MARK: the request

    private func read(genre: String, days: Int) throws -> [String: Any] {
        let control = (client.control as? SourceAppControl)
            ?? SourceAppControl(path: client.path, transport: client.transport)
        do {
            guard try control.capabilities().contains(djGenreUnheardOp) else {
                throw DJGenreSourceError.needsNewerSpanDAC
            }
            return try control.send(["op": djGenreUnheardOp, "genre": genre, "days": days],
                                    over: control.libraryTransport)
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

    private static func bad(_ what: String) -> DJGenreSourceError {
        .failed("SpanDAC's genre reply \(what)")
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

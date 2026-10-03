// tools/music/Sources/TUI/SpanDACLibraryRelations.swift
//
// The client's side of `slice.libraryRelations` (album-cleanup score, step A1;
// wire in section 1.1):
//
//   -> {"ids":["940618524","940618525"],"op":"slice.libraryRelations"}
//   <- {"ok":true,"op":"slice.libraryRelations","items":[{"id":"940618524","aliases":["6006281934004365952"]},
//                                                         {"id":"940618525","aliases":[]}]}
//
// One row per requested id; `aliases` has one element per library relation
// Apple reports for that catalogue id: a persistent-ID string, or null when
// MusicKit has not resolved that relation. `[]` is "no relation".
//
// **An unreadable reply is a failure, never "none" (W3).** Reading a missing
// id, a malformed row or a stray element as "no relation" would let the album
// phase treat a song that may be his as one it added. So every shape W3 names
// throws `.failed`. This is a read: it carries no `outcome`, and nothing here
// ever throws `.outcomeUnknown`.
//
// Served on the Mac's Unix socket only; nothing is sent to a SpanDAC that has
// not said it serves the op (`offersAlbumCleanup`).
import Foundation

/// What the album phase needs `slice.status` to advertise (CH2): the ensure
/// that makes the container, the relations read, and the capability that
/// promises `duration_ms` on every row.
let spandacAlbumCleanupCapabilities = ["slice.libraryEnsurePlaylist", spandacLibraryRelationsOp,
                                       spandacCatalogPlaylistCapability]

struct SpanDACLibraryRelations: SpanDACLibraryRelationsReading {
    let path: String
    /// The command transport (10 s, W4), as every 8 s library op uses.
    let transport: (String, String) throws -> String

    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
    }

    // MARK: Capability

    /// True only when `slice.status` answers and its `capabilities` name ALL of
    /// the three strings. Anything else, including a status that cannot be
    /// read, is false.
    var offersAlbumCleanup: Bool {
        guard let line = Self.encode(["op": "slice.status"]),
              let raw = try? transport(path, line),
              let reply = Self.decode(raw), reply["ok"] as? Bool == true,
              let status = reply["status"] as? [String: Any],
              let capabilities = status["capabilities"] as? [String] else { return false }
        return spandacAlbumCleanupCapabilities.allSatisfy(capabilities.contains)
    }

    // MARK: The read

    func relations(catalogueIDs: [String]) throws -> [String: [String?]] {
        guard let line = Self.encode(["op": spandacLibraryRelationsOp, "ids": catalogueIDs]) else {
            throw SpanDACLibraryOpError.failed("Couldn't write the request to SpanDAC.")
        }
        let raw: String
        do {
            raw = try transport(path, line)
        } catch let error as SourceAppError {
            throw SpanDACLibraryOpError.failed(error.message)
        } catch {
            throw SpanDACLibraryOpError.failed(error.localizedDescription)
        }
        guard let reply = Self.decode(raw) else { throw Self.unreadable }
        if reply["ok"] as? Bool != true {
            let error = reply["error"] as? [String: Any]
            if error?["kind"] as? String == "unknown_op" { throw SpanDACLibraryOpError.notOffered }
            throw SpanDACLibraryOpError.failed(Self.detail(of: reply))
        }
        guard let rows = Self.rows(in: reply, requested: catalogueIDs) else { throw Self.unreadable }
        return rows
    }

    // MARK: Wire

    private static let unreadableText = "SpanDAC sent an unreadable reply."
    private static let unreadable = SpanDACLibraryOpError.failed(unreadableText)

    private static func encode(_ body: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The reply as an object with a boolean `ok`; nil for anything else.
    private static func decode(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] is Bool else { return nil }
        return reply
    }

    private static func detail(of reply: [String: Any]) -> String {
        let error = reply["error"] as? [String: Any]
        return error?["detail"] as? String ?? "SpanDAC refused."
    }

    /// W3: the rows of an ok reply as id -> aliases, or nil when `items` is
    /// missing or not an array; a row is not an object or lacks a string `id`;
    /// an id is repeated or unrequested, or a requested one is missing;
    /// `aliases` is missing or not an array; an element is neither a non-empty
    /// string nor null.
    private static func rows(in reply: [String: Any], requested: [String]) -> [String: [String?]]? {
        guard let items = reply["items"] as? [Any] else { return nil }
        let wanted = Set(requested)
        var rows: [String: [String?]] = [:]
        for item in items {
            guard let row = item as? [String: Any], let id = row["id"] as? String,
                  wanted.contains(id), rows[id] == nil,
                  let aliases = row["aliases"] as? [Any] else { return nil }
            var read: [String?] = []
            for element in aliases {
                switch element {
                case is NSNull: read.append(nil)
                case let text as String where !text.isEmpty: read.append(text)
                default: return nil
                }
            }
            rows[id] = read
        }
        guard rows.count == wanted.count else { return nil }
        return rows
    }
}

extension SourceAppClient {
    /// The relations read over THIS client's own path and command transport. A
    /// test's client carries a fake transport, so the read goes there and can
    /// never reach a real SpanDAC.
    func libraryRelations() -> SpanDACLibraryRelationsReading {
        SpanDACLibraryRelations(path: path, transport: transport)
    }
}

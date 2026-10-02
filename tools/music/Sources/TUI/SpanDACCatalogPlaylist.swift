// tools/music/Sources/TUI/SpanDACCatalogPlaylist.swift
//
// The two catalogue-playlist ops SpanDAC on this Mac serves, so Discover can
// play a subscription playlist from a chosen track on Apple's own library copy
// of it (score step C1; wire in section 1.1):
//
//   slice.libraryPlaylistCopies {"id":"pl.…"}  -> "copies":[{"alias":String|null}]   (READ, W3)
//   slice.libraryAddPlaylist    {"id":"pl.…"}  -> "copies":[…]                        (WRITE, W4)
//
// Both are advertised by ONE capability string, `library.catalog_playlist`, in
// `slice.status`. Additive to the slice wire; served on the Mac's Unix socket
// only.
//
// **Unknown is not failure**, the rule `SpanDACLibraryAdd` keeps. Once the add
// may have reached SpanDAC, only a classified answer is a confirmed one: a
// timeout, a closed socket, an unreadable reply and SpanDAC's own
// `"outcome":"unknown"` are all `.outcomeUnknown`, because Apple may have made
// the copy. This client reads `error.kind` (the existing private helpers
// discard it), so it has its own small send-and-classify. Nothing is ever sent
// twice here.
import Foundation

/// How long a client waits for `slice.libraryAddPlaylist`: the server's 20 s to
/// the POST's answer plus its 20 s visible wait, plus the 10 s margin the 8 s
/// ops have under the 10 s command transport (W6).
let spandacCatalogPlaylistAddTimeoutSeconds = 50

struct SpanDACCatalogPlaylist: SpanDACCatalogPlaylistOps {
    let path: String
    /// The status check and the copies read (the command transport).
    let transport: (String, String) throws -> String
    /// The add alone (a longer timeout).
    let addTransport: (String, String) throws -> String

    init(path: String,
         transport: @escaping (String, String) throws -> String,
         addTransport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
        self.addTransport = addTransport
    }

    // MARK: Capability

    /// True only when `slice.status` answers and its `capabilities` name
    /// `library.catalog_playlist`. Anything else, including a status that cannot
    /// be read, is false: nothing is sent to a SpanDAC that has not said it
    /// serves the ops.
    var offersCatalogPlaylist: Bool {
        guard let line = Self.encode(["op": "slice.status"]),
              let raw = try? transport(path, line),
              let reply = Self.decode(raw), reply["ok"] as? Bool == true,
              let status = reply["status"] as? [String: Any],
              let capabilities = status["capabilities"] as? [String] else { return false }
        return capabilities.contains(spandacCatalogPlaylistCapability)
    }

    // MARK: W3, the read

    func copies(ofCatalogPlaylist id: String) throws -> [CatalogPlaylistCopy] {
        guard let line = Self.encode(["op": "slice.libraryPlaylistCopies", "id": id]) else {
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
        guard let copies = Self.copies(in: reply) else { throw Self.unreadable }
        return copies
    }

    // MARK: W4, the write

    func addCatalogPlaylist(id: String) -> CatalogPlaylistAddOutcome {
        guard let line = Self.encode(["op": "slice.libraryAddPlaylist", "id": id]) else {
            return .refused("Couldn't write the request to SpanDAC.")
        }
        let raw: String
        do {
            raw = try addTransport(path, line)
        } catch let error as SourceAppError {
            switch error {
            case .notRunning, .socketUnavailable:
                // The connect failed, or the frame was never completed: SpanDAC
                // cannot have read this request.
                return .refused(error.message)
            default:
                return .outcomeUnknown(error.message)
            }
        } catch {
            return .outcomeUnknown(error.localizedDescription)
        }
        guard let reply = Self.decode(raw) else { return .outcomeUnknown(Self.unreadableText) }
        if reply["ok"] as? Bool == true {
            // Something may have been added, so an ok reply that cannot be read
            // as copies is unknown, never a confirmed failure.
            guard let copies = Self.copies(in: reply) else { return .outcomeUnknown(Self.unreadableText) }
            return .added(copies: copies)
        }
        let detail = Self.detail(of: reply)
        if reply["outcome"] as? String == "unknown" { return .outcomeUnknown(detail) }
        let error = reply["error"] as? [String: Any]
        switch error?["kind"] as? String {
        case "copy_appeared": return .copyAppeared
        case "unknown_op": return .notOffered
        default: return .refused(detail)
        }
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

    /// The `copies` of an ok reply, or nil when it is missing, not an array, or
    /// holds an entry that lacks an `alias` key or whose alias is neither a
    /// string nor null.
    private static func copies(in reply: [String: Any]) -> [CatalogPlaylistCopy]? {
        guard let entries = reply["copies"] as? [[String: Any]] else { return nil }
        var copies: [CatalogPlaylistCopy] = []
        for entry in entries {
            guard let alias = entry["alias"] else { return nil }
            switch alias {
            case is NSNull: copies.append(CatalogPlaylistCopy(alias: nil))
            case let text as String: copies.append(CatalogPlaylistCopy(alias: text))
            default: return nil
            }
        }
        return copies
    }
}

extension SourceAppClient {
    /// The catalogue-playlist ops over THIS client's own path: the status check
    /// and the copies read on its command transport, the add on its own longer
    /// one. A test's client carries fake transports, so the ops go to those and
    /// can never reach a real SpanDAC.
    func catalogPlaylistOps() -> SpanDACCatalogPlaylistOps {
        SpanDACCatalogPlaylist(path: path, transport: transport, addTransport: catalogPlaylistAddTransport)
    }
}

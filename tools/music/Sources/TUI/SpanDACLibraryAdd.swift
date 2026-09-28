// tools/music/Sources/TUI/SpanDACLibraryAdd.swift
//
// The library ops SpanDAC on this Mac serves, so the MusicTUI output can play
// a song or a Discover container the person does not own yet with no
// developer key (score: data route and output, C-ADD):
//
//   slice.libraryAdd            {"ids":[catalogue ids]}  -> {"ok":true}
//   slice.libraryLookup         {"ids":[catalogue ids]}  -> "items":[{"id","alias"|null}]
//   slice.libraryEnsurePlaylist {"name","ids"}           -> "created", "playlist":{"id","alias"|null}
//
// Every one is additive to the slice wire and advertised in `slice.status`'s
// `capabilities`; SpanDAC on this Mac serves them on its Unix socket only.
//
// **Unknown is not failure.** A write whose request was sent and whose answer
// cannot be classified (a timeout, a closed socket, an unreadable reply, or
// SpanDAC's own `"outcome":"unknown"`) is `outcomeUnknown`, never a confirmed
// failure: Apple may have carried it out. Nothing here retries a write by
// itself; the callers reconcile (a lookup, or the same container name again)
// before a person's retry. Only a reply without `outcome` that says `ok:false`,
// or a request that never left this process, is a confirmed failure.
import Foundation

/// Said when the connected SpanDAC does not advertise the library ops (CHOSEN
/// wording, score C-ADD).
let updateSpanDACToPlayOnMusicTUI = "Update SpanDAC on this Mac to play this on MusicTUI."

/// The three library ops, as `capabilities` names them.
let spandacLibraryOpNames = ["slice.libraryAdd", "slice.libraryLookup", "slice.libraryEnsurePlaylist"]

/// How a library op did not succeed.
enum SpanDACLibraryOpError: Error, Equatable, LocalizedError {
    /// The connected SpanDAC does not serve the op (an older SpanDAC).
    case notOffered
    /// Confirmed: nothing was sent, or SpanDAC answered `ok:false` without
    /// `outcome`. The sentence is SpanDAC's, or the transport's.
    case failed(String)
    /// The write may have been carried out. Reconcile before any retry.
    case outcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .notOffered: return updateSpanDACToPlayOnMusicTUI
        case .failed(let detail), .outcomeUnknown(let detail): return detail
        }
    }
}

/// The real `SpanDACLibraryAdding`: the three ops over the same transport
/// MusicTUI's data client uses for SpanDAC on this Mac.
struct SpanDACLibraryAdd: SpanDACLibraryAdding {
    let path: String
    let transport: (String, String) throws -> String

    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
    }

    /// True only when `slice.status` answers and its `capabilities` name all
    /// three ops. Anything else, including a status that cannot be read, is
    /// false: nothing is sent to a SpanDAC that has not said it serves them.
    var canAdd: Bool {
        guard let reply = try? read(["op": "slice.status"]),
              let status = reply["status"] as? [String: Any],
              let capabilities = status["capabilities"] as? [String] else { return false }
        return spandacLibraryOpNames.allSatisfy(capabilities.contains)
    }

    func add(catalogueIDs: [String]) throws {
        _ = try write(["op": "slice.libraryAdd", "ids": catalogueIDs])
    }

    /// Per requested id, its library persistent-ID alias, or nil when the song
    /// is not in the library. Read-only. A reply that leaves out a requested id
    /// is unreadable, never "not owned".
    func lookup(catalogueIDs: [String]) throws -> [String: String?] {
        let reply = try read(["op": "slice.libraryLookup", "ids": catalogueIDs])
        guard let items = reply["items"] as? [[String: Any]] else { throw Self.unreadable }
        var found: [String: String?] = [:]
        for item in items {
            guard let id = item["id"] as? String else { throw Self.unreadable }
            switch item["alias"] {
            case let alias as String where !alias.isEmpty: found[id] = .some(alias)
            case nil, is NSNull: found[id] = .some(nil)
            default: throw Self.unreadable
            }
        }
        guard catalogueIDs.allSatisfy({ found[$0] != nil }) else { throw Self.unreadable }
        return found
    }

    /// Ensure a library playlist with EXACTLY this name. The name is the
    /// caller's token; SpanDAC creates it only when no playlist has it, and
    /// refuses when more than one does. An `ok` reply without a playlist id is
    /// an unknown outcome: something may have been made.
    func ensurePlaylist(name: String, catalogueIDs: [String]) throws -> (created: Bool, id: String, alias: String?) {
        let reply = try write(["op": "slice.libraryEnsurePlaylist", "name": name, "ids": catalogueIDs])
        guard let created = reply["created"] as? Bool,
              let playlist = reply["playlist"] as? [String: Any],
              let id = playlist["id"] as? String, !id.isEmpty else {
            throw SpanDACLibraryOpError.outcomeUnknown(Self.unreadableText)
        }
        let alias: String?
        switch playlist["alias"] {
        case let text as String where !text.isEmpty: alias = text
        default: alias = nil
        }
        return (created, id, alias)
    }

    // MARK: Transport

    private static let unreadableText = "SpanDAC sent an unreadable reply."
    private static let unreadable = SpanDACLibraryOpError.failed(unreadableText)

    private func encode(_ body: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else {
            throw SpanDACLibraryOpError.failed("Couldn't write the request to SpanDAC.")
        }
        return line
    }

    private func decode(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] is Bool else { return nil }
        return reply
    }

    /// A read: any failure is a failure, because nothing was changed.
    private func read(_ body: [String: Any]) throws -> [String: Any] {
        let line = try encode(body)
        let raw: String
        do {
            raw = try transport(path, line)
        } catch let error as SourceAppError {
            throw SpanDACLibraryOpError.failed(error.message)
        }
        guard let reply = decode(raw) else { throw Self.unreadable }
        return try refusal(reply, unknownWhenSaid: false)
    }

    /// A write. Once the request may have reached SpanDAC, only a classified
    /// answer is a confirmed one.
    private func write(_ body: [String: Any]) throws -> [String: Any] {
        let line = try encode(body)
        let raw: String
        do {
            raw = try transport(path, line)
        } catch let error as SourceAppError {
            switch error {
            case .notRunning, .socketUnavailable:
                // The connect failed, or the frame's closing newline was never
                // written: SpanDAC cannot have read this request.
                throw SpanDACLibraryOpError.failed(error.message)
            default:
                throw SpanDACLibraryOpError.outcomeUnknown(error.message)
            }
        } catch {
            throw SpanDACLibraryOpError.outcomeUnknown(error.localizedDescription)
        }
        guard let reply = decode(raw) else { throw SpanDACLibraryOpError.outcomeUnknown(Self.unreadableText) }
        return try refusal(reply, unknownWhenSaid: true)
    }

    /// `reply` unchanged when `ok`; otherwise the refusal it carries.
    private func refusal(_ reply: [String: Any], unknownWhenSaid: Bool) throws -> [String: Any] {
        if reply["ok"] as? Bool == true { return reply }
        let error = reply["error"] as? [String: Any]
        let detail = error?["detail"] as? String ?? "SpanDAC refused."
        if unknownWhenSaid, reply["outcome"] as? String == "unknown" {
            throw SpanDACLibraryOpError.outcomeUnknown(detail)
        }
        switch error?["kind"] as? String {
        case "unknown_op": throw SpanDACLibraryOpError.notOffered
        case "unauthorized": throw SpanDACLibraryOpError.failed(SourceAppError.notAuthorized.message)
        default: throw SpanDACLibraryOpError.failed(detail)
        }
    }
}

extension SourceAppClient {
    /// The library ops over THIS client's own path and command transport, so
    /// they reach exactly the SpanDAC its other requests reach, with whatever
    /// the client wraps around that transport: the data client's bounded
    /// start-once-and-retry (`retryingOnceAfterAStart`; safe for a write,
    /// because it retries only a request that never reached a running
    /// SpanDAC). A test's client carries a fake transport, so the ops go to
    /// that fake and can never reach a real SpanDAC.
    func libraryWrites() -> SpanDACLibraryAdding {
        SpanDACLibraryAdd(path: path, transport: transport)
    }
}

// MARK: - Verifying a persistent-ID alias

/// The AppleScript read that checks one persistent ID: how many tracks carry
/// it (the library playlist first, then the first user playlist holding it;
/// one persistent ID in several playlists is one track), and the first one's
/// name. Reads only. `hex` is `persistentIDHex(fromAlias:)`'s output.
func spandacAliasVerificationScript(hex: String) -> String {
    """
    set fs to (ASCII character 31)
    set hits to (every track of playlist "Library" whose persistent ID is "\(hex)")
    set n to count of hits
    if n is 0 then
        repeat with p in (every user playlist)
            try
                set more to (every track of p whose persistent ID is "\(hex)")
                if (count of more) > 0 then
                    set hits to more
                    set n to 1
                    exit repeat
                end if
            end try
        end repeat
    end if
    if n is 0 then return "0" & fs
    return (n as text) & fs & (name of item 1 of hits)
    """
}

/// One alias, verified: it parses, exactly one track carries it, and, when a
/// title is known, that track's name equals it (CHOSEN guard, score C-HANDOFF:
/// it can only refuse). Returns the hex persistent ID and the track's name, or
/// nil for anything short of that. Never a title search.
func verifySpanDACAlias(_ alias: String, title: String?, run: ScriptRunner) -> (hex: String, name: String)? {
    guard let hex = persistentIDHex(fromAlias: alias),
          let raw = run(spandacAliasVerificationScript(hex: hex)) else { return nil }
    let fields = raw.trimmingCharacters(in: .newlines)
        .split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2, Int(fields[0].trimmingCharacters(in: .whitespaces)) == 1 else { return nil }
    let name = fields[1]
    if let title, name != title { return nil }
    return (hex, name)
}

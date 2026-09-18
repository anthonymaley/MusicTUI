import Foundation

/// Where Radio's `/` search gets its stations from.
///
/// One method, deliberately. Radio's other catalog reads (Live, Personal,
/// `resolve(id:)`) are NOT part of this seam: Anthony scoped the slice to one
/// real search, and widening it here would quietly reroute three more paths.
protocol StationSearching {
    func searchStations(term: String) throws -> [Station]
}

/// The shipping route: Apple's REST catalog with the user's developer token.
/// Unchanged behaviour, reached through the seam instead of directly.
extension RadioCatalog: StationSearching {
    func searchStations(term: String) throws -> [Station] { try search(term: term) }
}

/// What went wrong talking to the source app, in words a person reading the
/// Radio message line can act on.
enum SourceAppError: Error, Equatable {
    case notRunning
    case notAuthorized
    case refused(String)
    case unreadable
    /// The socket exists and the app is presumably alive, but it did not answer
    /// inside the read timeout. Distinct from `unreadable`: nothing arrived at
    /// all, rather than something arriving that could not be parsed.
    case timedOut
    /// The socket is there and cannot be used — wrong permissions, a stale path
    /// owned by another user. Distinct from `notRunning`, because opening the
    /// app will not fix it.
    case socketUnavailable(String)
    /// The source replied ok and did not end up playing. `ok` answers "was the
    /// request accepted"; only the status answers "is it playing" (Anthony,
    /// Blocking, 2026-09-10). A current source app reports a failed play as
    /// `ok:false` with an error (since 2026-09-13 its status never says
    /// `failed`), so this is the defensive check on an ok reply that still is
    /// not playing, kept for any source that says otherwise.
    case didNotStart(String)

    /// Deliberately short: it renders inside Radio's one-line message strip
    /// beside a `✗`, not in a log.
    var message: String {
        switch self {
        case .notRunning:    return "Bridge is not running"
        case .notAuthorized: return "Bridge has no Apple Music access"
        case .refused(let d): return "Bridge refused: \(d)"
        case .unreadable:    return "Bridge sent an unreadable reply"
        case .timedOut:      return "Bridge did not answer in time"
        case .socketUnavailable(let d): return "Bridge's control socket is unusable: \(d)"
        case .didNotStart(let s): return "Bridge did not start playback (\(s))"
        }
    }
}

/// TEMPORARY. Radio's `/` search served by the MusicTUISource app over its
/// disposable `slice.*` wire, so the search works with NO developer key.
///
/// **This whole file is slice debt and is scheduled for deletion** alongside the
/// app's `SliceProtocol`, `ControlSocket` and `ControlServer`, when the public
/// contract package exists. It carries no capability negotiation, no revisions,
/// no session handshake and no reconnect logic, and it must not grow them one
/// field at a time: that would produce a second implementation of the real
/// contract, which is the drift the shared package exists to prevent.
///
/// **It fails closed and never falls back.** If the app is absent, unauthorised
/// or refuses, the search reports that and stops. Falling back to REST would be
/// a provider-precedence decision, which Anthony reserved to himself and which
/// is explicitly not being taken here.
struct SourceAppStationSearch: StationSearching {

    /// Matches the app's own `ControlSocket.directoryURL`. Two literals rather
    /// than one shared constant, because the two live in different repositories
    /// and nothing here may depend on the private app being checked out. The
    /// cost is a real drift risk, named rather than hidden: if the app moves its
    /// socket, this reports "not running" until it is updated too.
    static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/MusicTUISource/control.sock"
    }

    /// Bounded so a wedged app cannot hang the search thread indefinitely.
    /// A catalogue round trip is normally well under a second; this is a
    /// backstop, not a tuned value, and it is UNMEASURED as a choice.
    private static let timeoutSeconds: Int = 10

    private let path: String
    private let transport: (String, String) throws -> String

    init(path: String = SourceAppStationSearch.socketPath) {
        self.path = path
        self.transport = SourceAppStationSearch.sendOverUnixSocket
    }

    /// Seam for tests: they exercise request shaping and reply decoding without
    /// a socket, which is the part that can be wrong in a way a person notices.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
    }

    func searchStations(term: String) throws -> [Station] {
        let request = SliceRequestBody(op: "slice.searchStations", term: term, limit: 25)
        guard let body = try? JSONEncoder().encode(request),
              let line = String(data: body, encoding: .utf8) else {
            throw SourceAppError.unreadable
        }

        let raw = try transport(path, line)

        guard let data = raw.data(using: .utf8),
              let reply = try? JSONDecoder().decode(SliceStationReply.self, from: data) else {
            throw SourceAppError.unreadable
        }

        guard reply.ok else {
            switch reply.error?.kind {
            case "unauthorized": throw SourceAppError.notAuthorized
            default:             throw SourceAppError.refused(reply.error?.detail ?? "no detail")
            }
        }

        // A missing `stations` key on an ok reply is a contract violation, not
        // an empty result: an honest zero-hit reply carries an empty array.
        guard let stations = reply.stations else { throw SourceAppError.unreadable }

        return stations.map {
            Station(id: $0.id, name: $0.name, url: $0.url,
                    isLive: $0.isLive, artworkURL: $0.artworkURL)
        }
    }

    // MARK: - wire types

    private struct SliceRequestBody: Encodable {
        let op: String
        let term: String
        let limit: Int
    }

    struct SliceStationReply: Decodable {
        struct Failure: Decodable {
            let kind: String
            let detail: String
        }
        struct WireStation: Decodable {
            let id: String
            let name: String
            let url: String
            let isLive: Bool?
            let artworkURL: String?
            enum CodingKeys: String, CodingKey {
                case id, name, url
                case isLive = "is_live"
                case artworkURL = "artwork_url"
            }
        }
        let ok: Bool
        let stations: [WireStation]?
        let error: Failure?
    }

    // MARK: - transport

    /// One request, one newline-terminated reply, then close. Blocking by
    /// design: the only caller already runs on a detached thread, matching the
    /// discipline the REST catalog reads use.
    static func sendOverUnixSocket(path: String, line: String) throws -> String {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SourceAppError.notRunning }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SourceAppError.notRunning }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // A connect failure is classified rather than flattened. The earlier
        // comment here argued that ECONNREFUSED and ENOENT "would add words
        // without adding an action" — true when the only consumer was Radio's
        // one-line search message, false for a readiness indicator, whose entire
        // job is to say WHICH failure this is. EACCES in particular is not fixed
        // by opening the app, so reporting it as "not running" sends a person
        // after the wrong thing.
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED:
                throw SourceAppError.notRunning
            case EACCES, EPERM:
                throw SourceAppError.socketUnavailable("permission denied")
            case ETIMEDOUT:
                throw SourceAppError.timedOut
            default:
                throw SourceAppError.socketUnavailable("connect failed (errno \(errno))")
            }
        }

        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload[sent...].withUnsafeBufferPointer {
                write(fd, $0.baseAddress, $0.count)
            }
            guard n > 0 else { throw SourceAppError.notRunning }
            sent += n
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            // A timed-out read and a truncated reply used to be one outcome, so a
            // wedged app and a broken one read identically. SO_RCVTIMEO surfaces
            // as EAGAIN/EWOULDBLOCK.
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw SourceAppError.timedOut }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if out.last == UInt8(ascii: "\n") { break }
            // The app's own frame ceiling. A reply past it is a broken peer, not
            // a big result, and reading forever is how a client wedges.
            if out.count > 64 * 1024 { throw SourceAppError.unreadable }
        }
        guard let text = String(data: out, encoding: .utf8), !text.isEmpty else {
            throw SourceAppError.unreadable
        }
        return text
    }
}

// MARK: - Playback through the source app
//
// The second half of the bridge, in this file rather than its own because it is
// the SAME disposable debt: it shares the transport and the error vocabulary
// above, and one file is one deletion when the public contract package lands.

/// Sending a chosen track to the source app to play.
///
/// One method, matching `StationSearching`'s discipline. This is not a transport
/// abstraction and must not grow into one.
protocol SourcePlaying {
    func play(catalogID: String) throws
}

/// TEMPORARY. Hands one catalog id to the MusicTUISource app over the
/// disposable `slice.*` wire, so a Discover track plays on the source rather
/// than in Music.app.
///
/// **One track, never a queue.** The wire has no queue operation, so this
/// deliberately cannot express "and then the rest of the album". Discover's
/// footer drops "from here" in this mode for exactly that reason.
///
/// **It fails closed and never falls back.** A refusal is thrown for the caller
/// to show; silently playing in Music.app instead would be the provider
/// precedence decision Anthony reserved to himself.
struct SourceAppPlayback: SourcePlaying {

    private let path: String
    private let transport: (String, String) throws -> String

    init(path: String = SourceAppStationSearch.socketPath) {
        self.path = path
        self.transport = SourceAppStationSearch.sendOverUnixSocket
    }

    /// Seam for tests: request shaping and reply decoding without a socket,
    /// which is the part that can be wrong in a way a person notices.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
    }

    func play(catalogID: String) throws {
        let request = PlayRequestBody(op: "slice.play", id: catalogID)
        guard let body = try? JSONEncoder().encode(request),
              let line = String(data: body, encoding: .utf8) else {
            throw SourceAppError.unreadable
        }

        let raw = try transport(path, line)

        guard let data = raw.data(using: .utf8),
              let reply = try? JSONDecoder().decode(PlayReply.self, from: data) else {
            throw SourceAppError.unreadable
        }

        guard reply.ok else {
            switch reply.error?.kind {
            case "unauthorized": throw SourceAppError.notAuthorized
            default:             throw SourceAppError.refused(reply.error?.detail ?? "no detail")
            }
        }

        // `ok` alone is not the answer. Before 2026-09-13 the app reported a
        // MusicKit error or its own settle timeout as a failed STATE on an ok
        // reply, so a client trusting `ok` printed "Playing" over a play that did
        // not happen. A current app replies `ok:false` with the command's own
        // failure instead, but the status is still checked independently: any
        // ok reply that is not `playing` is rejected, and a missing status is a
        // contract violation rather than a success -- the same rule the station
        // search applies to a missing array.
        guard let playback = reply.status?.playback else { throw SourceAppError.unreadable }
        guard playback == "playing" else { throw SourceAppError.didNotStart(playback) }
    }

    private struct PlayRequestBody: Encodable {
        let op: String
        let id: String
    }

    private struct PlayReply: Decodable {
        struct Failure: Decodable {
            let kind: String
            let detail: String
        }
        struct Status: Decodable {
            let playback: String
        }
        let ok: Bool
        let status: Status?
        let error: Failure?
    }
}

// MARK: - The source app, as one peer

/// Everything MusicTUI sends to the source app, reached through one value so the
/// routing coordinator hands a branch ONE client rather than a loose set.
///
/// TEMPORARY, the same slice debt as the rest of this file. It grows source-shaped
/// methods per surface as the matrix rows are routed. It deliberately holds NO
/// queue or playback state: the app owns the player, its window mutates it
/// independently of any client, and a TUI and a CLI process would each hold a
/// different copy (Codex B3, 2026-09-13).
struct SourceAppClient {
    let playback: SourcePlaying
    let stationSearch: StationSearching
    let control: SourceControlling

    init(path: String = SourceAppStationSearch.socketPath) {
        playback = SourceAppPlayback(path: path)
        stationSearch = SourceAppStationSearch(path: path)
        control = SourceAppControl(path: path)
    }

    /// Seam for tests, matching the members' own.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        playback = SourceAppPlayback(path: path, transport: transport)
        stationSearch = SourceAppStationSearch(path: path, transport: transport)
        control = SourceAppControl(path: path, transport: transport)
    }

    /// Bridge's readiness for the Output tab. Never throws: a tab that cannot
    /// render its own status is worse than one showing why.
    ///
    /// **Every failure keeps its own words.** This was `(try?  …) ?? .notRunning`,
    /// which turned a permission error, a timeout, a malformed reply and a
    /// missing app into one sentence — and printed "Bridge is not running" over a
    /// running Bridge on 2026-09-16. A `try?` here is not a shortcut; it is the
    /// defect.
    func readiness() -> SourceReadiness {
        do {
            return try control.status().readiness
        } catch {
            return SourceReadiness.from(error)
        }
    }
}

/// A Bridge row the matrix routes to the source but nothing has wired yet.
///
/// Deliberately explicit and greppable: during dogfood these are the rows still
/// to come, and a person meets a clear sentence instead of silence or a crash.
/// Every one of these must be gone before v1 is done.
func bridgeNotWiredYet(_ what: String) -> ActionError {
    ActionError(message: "\(what) is not wired to Bridge yet")
}

// MARK: - Control: status, transport and queue
//
// The rest of the bridge, in this file for the same reason as the play path: it
// is the same disposable slice debt and one file is one deletion.

/// What Bridge reports about itself. `readiness` answers the Output tab's
/// question (ruling 12.13, DoD 12); the rest is what Now needs later.
struct SourceStatus: Equatable {
    let playback: String
    let title: String?
    let artist: String?
    let readiness: SourceReadiness
    let queuePhase: String?
    let queueRequested: Int?
    let queuePresent: Int?
}

/// One Library or Playlist row, by the triple the app joins on.
///
/// No id: MusicTUI's persistent id means nothing to the app, and the app's
/// library ids are a different namespace from the catalogue ids `slice.play`
/// takes (probe 4). The triple is the only identity both sides share.
struct SourceLibraryRow: Equatable {
    let title: String
    let artist: String
    let album: String
}

/// Library or Playlist tracks as Bridge rows, or a refusal naming how many
/// could not be described.
///
/// **Whole or nothing.** A row whose album is unknown cannot be resolved, and
/// matching on two fields out of three is the wrong-track defect wearing a
/// smaller hat — so the SET is refused rather than quietly shortened. The app
/// refuses again if any row has no UNIQUE match; this refuses first if any row
/// could not even be described.
///
/// Lifted out of `PlaylistsScene` at step 2, unchanged including its wording, so
/// the Library and Playlist paths cannot drift apart on the rule.
func bridgeRows(from tracks: [TrackListEntry], named name: String) throws -> [SourceLibraryRow] {
    let rows = tracks.compactMap { track -> SourceLibraryRow? in
        guard let album = track.album else { return nil }
        return SourceLibraryRow(title: track.name, artist: track.artist, album: album)
    }
    guard rows.count == tracks.count else {
        throw ActionError(
            message: "\(tracks.count - rows.count) of \(tracks.count) tracks in '\(name)' have no album, so Bridge cannot identify them")
    }
    return rows
}

/// A Library collection as Bridge rows: the shuffle order and the start row
/// resolved the same way the Music.app branch resolves them.
///
/// **Why the start row becomes a slice.** `slice.queue` plays `ids[0]` first and
/// takes no start index, so "start at row N" can only mean "send N to the end".
/// That loses the earlier tracks from Up Next, which the Music.app branch keeps
/// — a real difference, and the same one the shipped Playlist path already
/// accepted for Enter. Shuffling ignores the start row, exactly as the
/// Music.app branch does when it resets its index to 1.
///
/// The slice is taken BEFORE the whole-or-nothing album check, so a track the
/// user did not ask to play cannot veto the play.
func bridgeCollectionRows(tracks: [TrackListEntry], shuffle: Bool, startAt: Int,
                          named name: String) throws -> [SourceLibraryRow] {
    if shuffle { return try bridgeRows(from: tracks.shuffled(), named: name) }
    guard !tracks.isEmpty else { return try bridgeRows(from: tracks, named: name) }
    let start = min(max(1, startAt), tracks.count)
    return try bridgeRows(from: Array(tracks[(start - 1)...]), named: name)
}

/// Everything MusicTUI asks Bridge to do beyond playing one catalogue id.
protocol SourceControlling {
    func status() throws -> SourceStatus
    func resume() throws
    func pause() throws
    func next() throws
    func previous() throws
    func stop() throws
    func seek(toSeconds seconds: Double) throws
    /// Relative seek. The TUI's `[` and `]` are ±30s, and `slice.seek` already
    /// takes `offset` as the alternative to `position`.
    func seek(byOffset seconds: Double) throws
    func queue(rows: [SourceLibraryRow]) throws
    func queue(catalogIDs: [String]) throws
}

struct SourceAppControl: SourceControlling {

    /// The frame the app will read. A request over this is refused HERE, with a
    /// reason naming the operation, rather than being sent to be rejected as an
    /// unparseable frame with no op attached.
    static let maximumRequestBytes = 64 * 1024

    private let path: String
    private let transport: (String, String) throws -> String

    init(path: String = SourceAppStationSearch.socketPath) {
        self.path = path
        self.transport = SourceAppStationSearch.sendOverUnixSocket
    }

    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
    }

    func status() throws -> SourceStatus {
        let reply = try send(["op": "slice.status"])
        guard let status = reply["status"] as? [String: Any],
              let playback = status["playback"] as? String else {
            throw SourceAppError.unreadable
        }
        let queue = status["queue"] as? [String: Any]
        return SourceStatus(playback: playback,
                            title: status["title"] as? String,
                            artist: status["artist"] as? String,
                            readiness: readiness(from: status),
                            queuePhase: queue?["phase"] as? String,
                            queueRequested: queue?["requested"] as? Int,
                            queuePresent: queue?["present"] as? Int)
    }

    func resume() throws   { _ = try send(["op": "slice.play"]) }
    func pause() throws    { _ = try send(["op": "slice.pause"]) }
    func next() throws     { _ = try send(["op": "slice.next"]) }
    func previous() throws { _ = try send(["op": "slice.previous"]) }
    func stop() throws     { _ = try send(["op": "slice.stop"]) }

    func seek(toSeconds seconds: Double) throws {
        _ = try send(["op": "slice.seek", "position": seconds])
    }

    func seek(byOffset seconds: Double) throws {
        _ = try send(["op": "slice.seek", "offset": seconds])
    }

    /// Hands the selected rows over for the app to resolve and play.
    ///
    /// **It never splits.** A queue is one request: chunking it would silently
    /// change what plays, which is the same class of defect as auto-picking an
    /// ambiguous row. Over budget is a refusal (Anthony, 2026-09-16 16:07).
    func queue(rows: [SourceLibraryRow]) throws {
        let body: [String: Any] = [
            "op": "slice.queue",
            "rows": rows.map { ["title": $0.title, "artist": $0.artist, "album": $0.album] },
        ]
        _ = try send(body)
    }

    /// Hands an ordered list of catalogue songs over for the app to resolve and
    /// play. The ALTERNATIVE to `rows`, never both: the app's decoder takes
    /// exactly one of `ids` or `rows` and fails the whole request otherwise.
    ///
    /// **It never splits**, for the same reason `queue(rows:)` does not, and the
    /// bounds are deliberately not duplicated here: the app owns the 100-song
    /// limit, the repeated-title rule and the unresolvable-id count, and a
    /// second copy of those numbers on this side would drift from the ones
    /// actually enforced.
    func queue(catalogIDs: [String]) throws {
        _ = try send(["op": "slice.queue", "ids": catalogIDs])
    }

    // MARK: - private

    /// Ready only when the app says it is authorised AND speaks a contract this
    /// build knows. Anything else carries the reason a person reads on Output.
    private func readiness(from status: [String: Any]) -> SourceReadiness {
        if let contract = status["contract"] as? Int, contract != sourceContractVersion {
            return .unavailable("Bridge speaks a different version (\(contract)); update one of them")
        }
        switch status["authorization"] as? String {
        case "authorized":     return .ready
        case "not_determined": return .unavailable("Bridge has not been granted Apple Music access yet")
        case "denied":         return .unavailable("Bridge was denied Apple Music access")
        case "restricted":     return .unavailable("Apple Music access is restricted on this Mac")
        default:               return .unavailable("Bridge could not read its Apple Music access")
        }
    }

    private func send(_ body: [String: Any]) throws -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else {
            throw SourceAppError.unreadable
        }
        let op = body["op"] as? String ?? "slice"
        guard line.utf8.count <= Self.maximumRequestBytes else {
            throw SourceAppError.refused(
                "\(op) is too large to send (\(line.utf8.count) bytes, limit \(Self.maximumRequestBytes))")
        }

        let raw = try transport(path, line)
        guard let replyData = raw.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              let ok = reply["ok"] as? Bool else {
            throw SourceAppError.unreadable
        }
        guard ok else {
            let error = reply["error"] as? [String: Any]
            let detail = error?["detail"] as? String ?? "no detail"
            if error?["kind"] as? String == "unauthorized" { throw SourceAppError.notAuthorized }
            throw SourceAppError.refused(detail)
        }
        return reply
    }
}

/// The `slice.*` contract this build speaks. Must match the app's
/// `sliceContractVersion`; a mismatch is reported, never worked around.
let sourceContractVersion = 1

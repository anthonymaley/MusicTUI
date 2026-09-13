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
        case .notRunning:    return "Source app is not running"
        case .notAuthorized: return "Source app has no Apple Music access"
        case .refused(let d): return "Source app refused: \(d)"
        case .unreadable:    return "Source app sent an unreadable reply"
        case .didNotStart(let s): return "Source app did not start playback (\(s))"
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

        // Any connect failure is reported as "not running". A refused or absent
        // socket is by far the likeliest case and is the one a person can act
        // on; distinguishing ECONNREFUSED from ENOENT would add words without
        // adding an action.
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SourceAppError.notRunning }

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

    init(path: String = SourceAppStationSearch.socketPath) {
        playback = SourceAppPlayback(path: path)
        stationSearch = SourceAppStationSearch(path: path)
    }

    /// Seam for tests, matching the two members' own.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        playback = SourceAppPlayback(path: path, transport: transport)
        stationSearch = SourceAppStationSearch(path: path, transport: transport)
    }
}

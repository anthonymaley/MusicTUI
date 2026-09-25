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
    /// Not ready YET, and saying when to ask again. A cold Bridge with no
    /// snapshot of the library answers this in milliseconds rather than making
    /// a caller wait out a drain on the socket timeout. It is a transient, not
    /// a refusal: a caller that treats it as one shows an empty library.
    case warming(String, retryAfter: TimeInterval)
    /// The library changed underneath a paged read. **A restart, not a
    /// refusal** — the caller starts the list again rather than telling the
    /// person their library could not be read.
    ///
    /// It is its own case because that difference drives BEHAVIOUR. It used to
    /// be recovered by matching Bridge's sentence ("the library changed while
    /// you were reading it") inside a `refused` detail, which meant a wording
    /// change on the app side would silently turn a restart into a hard error
    /// and show a person a failure where they should have got their library
    /// back. The sentence is still carried, for display only.
    case staleGeneration(String)
    /// The reply parsed as JSON, said `ok`, and does not satisfy the contract.
    ///
    /// Distinct from `unreadable`, which means nothing usable arrived at all.
    /// This is a peer that answered successfully and sent something a client
    /// must NOT treat as data — a page missing a required field, or carrying a
    /// row it cannot read. It carries what was wrong, because "Bridge sent
    /// something odd" is not something a person can act on.
    case malformedReply(String)
    /// An OLDER Bridge that does not serve this op (D6): the contract is
    /// additive, so an older peer answers `unknown_op` for the five slice-2
    /// reads rather than reading as wholly incompatible. Carries the op name;
    /// the caller decides on the KIND, never the prose, and turns this into its
    /// own "update Bridge" sentence per op.
    case unsupported(String)
    /// The play-record cursor the caller sent belongs to a record Bridge no
    /// longer has. A restart, not a refusal: the caller asks again from the
    /// beginning. Carries Bridge's sentence, for display only.
    case ledgerChanged(String)

    /// Deliberately short: it renders inside Radio's one-line message strip
    /// beside a `✗`, not in a log.
    var message: String {
        switch self {
        // Op-neutral on purpose: `send` decodes this kind for EVERY op, and only
        // the library read knows it is about a library. A surface with something
        // better to say says it from the detail this case still carries.
        case .warming:       return "Bridge is not ready yet"
        case .staleGeneration: return "Your library changed while it was being read"
        // The detail is already a whole sentence naming Bridge and the fault.
        case .malformedReply(let d): return d
        case .notRunning:    return "Bridge is not running"
        case .notAuthorized: return "Bridge has no Apple Music access"
        case .refused(let d): return "Bridge refused: \(d)"
        case .unreadable:    return "Bridge sent an unreadable reply"
        case .timedOut:      return "Bridge did not answer in time"
        case .socketUnavailable(let d): return "Bridge's control socket is unusable: \(d)"
        case .didNotStart(let s): return "Bridge did not start playback (\(s))"
        // Op-neutral, like `.warming`: a surface that can name the op (the
        // Output tab, `BridgeMusicProvider`) says something more specific from
        // the op it asked for rather than from this generic line.
        case .unsupported: return "Bridge doesn't serve that yet — update Bridge"
        case .ledgerChanged: return "Bridge's play record was replaced"
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
    static let timeoutSeconds: Int = 10

    /// A sender with a different read/write timeout, for the one op that
    /// legitimately takes longer than a transport command does.
    ///
    /// The timeout is a property of the REQUEST, not of the socket, so it is
    /// bound here into the closure rather than added to the transport
    /// signature: every existing call site keeps `sendOverUnixSocket` and its
    /// 10s unchanged, and only a caller that asks gets something else.
    static func sender(timeoutSeconds: Int) -> (String, String) throws -> String {
        { path, line in try send(path: path, line: line, timeoutSeconds: timeoutSeconds) }
    }

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
        try send(path: path, line: line, timeoutSeconds: timeoutSeconds)
    }

    private static func send(path: String, line: String, timeoutSeconds: Int) throws -> String {
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
    let discover: DiscoverFeedReading

    init(path: String = SourceAppStationSearch.socketPath) {
        playback = SourceAppPlayback(path: path)
        stationSearch = SourceAppStationSearch(path: path)
        control = SourceAppControl(path: path)
        discover = BridgeDiscoverFeed(path: path)
    }

    /// Seam for tests, matching the members' own.
    init(path: String, transport: @escaping (String, String) throws -> String) {
        playback = SourceAppPlayback(path: path, transport: transport)
        stationSearch = SourceAppStationSearch(path: path, transport: transport)
        control = SourceAppControl(path: path, transport: transport)
        discover = BridgeDiscoverFeed(path: path, transport: transport)
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
    /// Why an `invalid` queue stopped, in the app's words.
    var queueReason: String? = nil
    /// How many songs were ready before an `invalid` queue failed. **Not
    /// `queuePresent`:** on invalid the app sends `present` as nil, and this is
    /// the history that remains.
    var queueBuiltBeforeFailure: Int? = nil
    /// Playback position, 0-based within the PRESENT entries. A different
    /// quantity from `queuePresent`, which counts songs ready while building.
    var queueIndex: Int? = nil
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
    func playStation(id: String, named name: String) throws
    /// One page of the app's own MusicKit library (contract 3). `cursor` nil
    /// starts at the beginning; the cursor that comes back is opaque and goes
    /// back unread.
    func librarySongs(cursor: String?, limit: Int) throws -> MusicPage
    /// Queue exactly these library rows, by the ids a Bridge page gave us.
    /// Returns `skipped_unavailable` (Addendum U, U-R5): how many of the
    /// requested songs Bridge silently dropped because it could not
    /// establish they are playable, 0 included. 0 on every reply from an
    /// older Bridge that predates the field (D6 holds).
    ///
    /// `startRequired` (Addendum U, Bridge-as-built): `true` when the person
    /// picked a specific row to start from — Enter on a track row — `false`
    /// for a whole-collection play (`p`/`s`). Sent as an explicit
    /// `"start_required": <bool>` on EVERY call, never omitted: Codex's
    /// review (f70150a0) reports Bridge now treats an ABSENT field as a
    /// legacy request and refuses it, so the client can no longer rely on
    /// omission meaning `false` (defaulted `false` only so the one existing
    /// direct call in `BridgeMusicProviderTests`, which predates this field,
    /// keeps compiling — it still sends the key, just with `false`).
    func queue(libraryIDs: [String], startRequired: Bool) throws -> Int
    // NOTE: `SourceAppControl`'s own declaration below defaults `startRequired`
    // to `false`; a protocol requirement's default only applies to callers
    // holding a `SourceControlling`-typed value, so `BridgeMusicProviderTests`'
    // one direct, concrete-typed call needs the concrete default, not this one.
    /// One page of the app's own MusicKit albums (D1, contract 3 additive).
    func libraryAlbums(cursor: String?, limit: Int) throws -> MusicPage
    /// One page of the app's own MusicKit artists (D1).
    func libraryArtists(cursor: String?, limit: Int) throws -> MusicPage
    /// One album's tracks: complete, or refused — never paged, never partial (D2).
    func libraryAlbumTracks(albumID: String) throws -> MusicList
    /// One artist's albums (D2), for the drill-in.
    func libraryArtistAlbums(artistID: String) throws -> MusicList
    /// One artist's songs (D2): what an artist PLAYS.
    func libraryArtistSongs(artistID: String) throws -> MusicList
    /// One page of the app's own MusicKit playlists (D1, contract 3 additive).
    func libraryPlaylists(cursor: String?, limit: Int) throws -> MusicPage
    /// One page of one playlist's tracks: paged, stateless and fingerprinted
    /// (D4) — every page re-validates the WHOLE playlist against the
    /// snapshot, so a refusal always arrives on the first page, and a
    /// generation or membership change mid-walk restarts the read rather
    /// than stitching two observations together.
    ///
    /// `forQueue` (F4/C4): true only for the client's fresh whole-playlist
    /// play walk. Sent on the wire as `"for_queue": true`, and omitted
    /// entirely — never sent as an explicit `false` — otherwise, so an older
    /// Bridge (whose synthesized `Decodable` drops unknown keys) sees exactly
    /// the request it always has.
    func libraryPlaylistTracks(playlistID: String, cursor: String?, limit: Int, forQueue: Bool) throws -> MusicPage
}

struct SourceAppControl: SourceControlling {

    /// The frame the app will read. A request over this is refused HERE, with a
    /// reason naming the operation, rather than being sent to be rejected as an
    /// unparseable frame with no op attached.
    static let maximumRequestBytes = 64 * 1024

    /// How long a LIBRARY read may take, and nothing else.
    ///
    /// Measured 2026-09-23: Bridge drains its MusicKit library in ~6.4s and
    /// caches it. With the cache expired, the first page paid for that drain
    /// inline and blew the shared 10s timeout, and a person opening the Library
    /// tab saw "Bridge did not answer in time" over an empty list. Bridge now
    /// serves the last snapshot immediately and refreshes behind it, so this is
    /// a SAFETY MARGIN rather than the fix — a cold start with no snapshot at
    /// all answers `warming` in milliseconds and is retried on its own hint,
    /// not waited out on this timeout. The transport ops keep 10s, where it is
    /// generous.
    static let libraryReadTimeoutSeconds: Int = 30

    private let path: String
    private let transport: (String, String) throws -> String
    /// The same transport with a longer timeout, for the library reads and for
    /// every `slice.queue`: starting a queue can wait on the player preparing
    /// its first song, and Bridge retries that once after a cold start, which
    /// together outlast the transport commands' 10s.
    private let libraryTransport: (String, String) throws -> String

    init(path: String = SourceAppStationSearch.socketPath) {
        self.path = path
        self.transport = SourceAppStationSearch.sendOverUnixSocket
        self.libraryTransport = SourceAppStationSearch.sender(
            timeoutSeconds: SourceAppControl.libraryReadTimeoutSeconds)
    }

    init(path: String, transport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
        self.libraryTransport = transport
    }

    /// Seam for the one test that has to tell the two transports apart: which
    /// op goes down which socket is the part that can be wrong in a way a
    /// person notices.
    init(path: String, transport: @escaping (String, String) throws -> String,
         libraryTransport: @escaping (String, String) throws -> String) {
        self.path = path
        self.transport = transport
        self.libraryTransport = libraryTransport
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
                            queuePresent: queue?["present"] as? Int,
                            queueReason: queue?["reason"] as? String,
                            queueBuiltBeforeFailure: queue?["built_before_failure"] as? Int,
                            queueIndex: queue?["index"] as? Int)
    }

    /// Contract 3. The reply's rows carry MusicKit LIBRARY ids, which is the
    /// whole point: a row played by its own id needs no `(title, artist, album)`
    /// join, so the 338 rows that join could not resolve stop being a category.
    func librarySongs(cursor: String?, limit: Int = 100) throws -> MusicPage {
        try libraryPage(op: "slice.librarySongs", opName: "library", limit: limit, cursor: cursor,
                        rows: .anyKnownKind)
    }

    /// D1: MusicKit's own album entities, not song rows grouped by title —
    /// see the boundary decision in the slice-2 score.
    func libraryAlbums(cursor: String?, limit: Int = 100) throws -> MusicPage {
        try libraryPage(op: "slice.libraryAlbums", opName: "album", limit: limit, cursor: cursor,
                        rows: .exactly(.album))
    }

    /// D1.
    func libraryArtists(cursor: String?, limit: Int = 100) throws -> MusicPage {
        try libraryPage(op: "slice.libraryArtists", opName: "artist", limit: limit, cursor: cursor,
                        rows: .exactly(.artist))
    }

    /// D2: an album's tracks, complete or refused, never paged and never
    /// partial. A dropped track would silently shorten the album, so a row of
    /// the wrong or an unknown kind fails the whole read rather than being
    /// skipped (unlike the paged Songs list, where an unrecognised row kind is
    /// merely something this build does not serve yet).
    func libraryAlbumTracks(albumID: String) throws -> MusicList {
        try libraryContainer(op: "slice.libraryAlbumTracks", opName: "album tracks",
                             id: albumID, rows: .exactly(.song))
    }

    /// D2.
    func libraryArtistAlbums(artistID: String) throws -> MusicList {
        try libraryContainer(op: "slice.libraryArtistAlbums", opName: "artist albums",
                             id: artistID, rows: .exactly(.album))
    }

    /// D2: every song of the artist; Bridge refuses over its queue bound
    /// (F5: since counting availability before refusing, this can now return
    /// more than 100 rows — the client applies no row bound of its own).
    func libraryArtistSongs(artistID: String) throws -> MusicList {
        try libraryContainer(op: "slice.libraryArtistSongs", opName: "artist songs",
                             id: artistID, rows: .exactly(.song))
    }

    /// D1: MusicKit's own playlist entities, alphabetical (SourceCore's own
    /// order, not Music.app's).
    func libraryPlaylists(cursor: String?, limit: Int = 100) throws -> MusicPage {
        try libraryPage(op: "slice.libraryPlaylists", opName: "playlist", limit: limit, cursor: cursor,
                        rows: .exactly(.playlist))
    }

    /// D4: paged and STATELESS — Bridge re-reads and re-validates the whole
    /// playlist on every page, so a `stale_generation` can arrive on any page,
    /// not only the first. Rows are byte-for-byte the `slice.librarySongs`
    /// row shape, in the playlist's own order, with repeats kept; a row of
    /// any other kind is `malformedReply`, never dropped, for the same
    /// fail-closed reason as the container reads.
    ///
    /// `forQueue` (F4/C4): sent as `"for_queue": true` only when true — never
    /// an explicit `false` — so an older Bridge that predates the field sees
    /// today's request unchanged.
    func libraryPlaylistTracks(playlistID: String, cursor: String?, limit: Int = 500,
                               forQueue: Bool = false) throws -> MusicPage {
        try libraryPage(op: "slice.libraryPlaylistTracks", opName: "playlist tracks", limit: limit,
                        cursor: cursor, id: playlistID, rows: .exactly(.song),
                        readsSkippedVideos: true, forQueue: forQueue)
    }

    /// Which row kinds a paged list or a container read accepts, and what it
    /// does with anything else.
    ///
    /// **`.anyKnownKind` is Songs alone**, unchanged from before this slice: any
    /// row this build recognises is accepted whatever its kind, and only a kind
    /// this build has never heard of is dropped (the Discover precedent).
    ///
    /// **`.exactly(kind)` is every op D1/D2 add.** A row of any OTHER kind —
    /// recognised or not — is `malformedReply`, never dropped: a dropped album,
    /// artist or track would silently shorten a list or an album with nothing
    /// to say why, which the fail-closed rule for the library path exists to
    /// prevent.
    private enum LibraryRowPolicy {
        case anyKnownKind
        case exactly(MusicRow.Kind)
    }

    /// One row, decoded under `policy`, or the reason the whole read fails.
    private func libraryRow(_ item: [String: Any], opName: String,
                            policy: LibraryRowPolicy) throws -> MusicRow? {
        switch (policy, readMusicRow(item)) {
        case (.anyKnownKind, .row(let row)):
            return row
        case (.anyKnownKind, .unknownKind):
            return nil
        case (.exactly(let kind), .row(let row)) where row.kind == kind:
            return row
        case (.exactly, .row(let row)):
            throw SourceAppError.malformedReply(
                "Bridge's \(opName) list contains a row of kind \(row.kind.rawValue)")
        case (.exactly, .unknownKind(let kind)):
            throw SourceAppError.malformedReply("Bridge's \(opName) list contains a row of kind \(kind)")
        case (_, .malformed(let what)):
            throw SourceAppError.malformedReply("Bridge's \(opName) page contains \(what)")
        }
    }

    /// FAIL CLOSED, shared by every paged library list (`slice.librarySongs`,
    /// `slice.libraryAlbums`, `slice.libraryArtists`). Every field the contract
    /// requires is required here, and a page that does not satisfy it is
    /// refused rather than read as a SHORTER LIBRARY. That is the whole risk on
    /// this op: a truncated or half-written page is indistinguishable from a
    /// genuine last page unless the client insists on the contract, and a
    /// person would be shown a library missing rows with nothing to tell them
    /// so. It matters more the moment these frames cross a network to an iPad.
    private func libraryPage(op: String, opName: String, limit: Int, cursor: String?,
                             id: String? = nil, rows policy: LibraryRowPolicy,
                             readsSkippedVideos: Bool = false, forQueue: Bool = false) throws -> MusicPage {
        var body: [String: Any] = ["op": op, "limit": limit]
        if let cursor { body["cursor"] = cursor }
        if let id { body["id"] = id }
        // Additive (F4/C4): sent only when true, never an explicit `false` —
        // an older Bridge's synthesized `Decodable` drops an unknown key, so
        // omitting it entirely keeps today's request byte-for-byte for every
        // OTHER caller of this shared helper.
        if forQueue { body["for_queue"] = true }
        let reply = try send(body, over: libraryTransport)

        guard let items = reply["items"] as? [[String: Any]] else {
            throw SourceAppError.malformedReply("Bridge's \(opName) page is missing items")
        }
        guard let generation = reply["generation"] as? Int else {
            throw SourceAppError.malformedReply("Bridge's \(opName) page is missing generation")
        }
        guard let total = reply["total"] as? Int else {
            throw SourceAppError.malformedReply("Bridge's \(opName) page is missing total")
        }
        // A MISSING key and an explicit null are different claims: null says
        // "this is the last page", absent says nothing at all. Read as one they
        // were the same thing, so a page that lost its cursor ended the walk
        // and the rest of the library silently did not exist. `JSONSerialization`
        // gives `NSNull` for an explicit null and nothing for an absent key,
        // which is exactly the distinction needed.
        guard let cursorValue = reply["next_cursor"] else {
            throw SourceAppError.malformedReply("Bridge's \(opName) page is missing next_cursor")
        }
        let nextCursor: String?
        switch cursorValue {
        case is NSNull:            nextCursor = nil          // terminal, and says so
        case let text as String:   nextCursor = text
        default:
            throw SourceAppError.malformedReply(
                "Bridge's \(opName) page has a next_cursor that is neither text nor null")
        }

        var rows: [MusicRow] = []
        for item in items {
            if let row = try libraryRow(item, opName: opName, policy: policy) { rows.append(row) }
        }

        // C1a (D9/D11): ONLY `slice.libraryPlaylistTracks` carries this field,
        // and only that op requires it. An absent or negative count is a
        // malformed reply rather than a silent 0, because a missing count
        // would hide a skip from the person — the whole reason Revision 3
        // exists is that a skip must always be STATED.
        var skippedVideos = 0
        if readsSkippedVideos {
            guard let raw = reply["skipped_videos"] else {
                throw SourceAppError.malformedReply("Bridge's \(opName) page is missing skipped_videos")
            }
            guard let skipped = raw as? Int, skipped >= 0 else {
                throw SourceAppError.malformedReply(
                    "Bridge's \(opName) page has a skipped_videos that is not a count")
            }
            skippedVideos = skipped
        }

        // `clamped` is deliberately not read: a page carries the rows it
        // carries, and the walk follows `next_cursor`, never the limit it sent,
        // so a clamped page needs no special case. `stale` and `refreshing`
        // describe the SNAPSHOT this page came from — information about
        // freshness, not a failure, and never a reason to refuse a page. They
        // are the one pair NOT required here: absent means "not stated", they
        // drive no behaviour, and a wrong default cannot produce a wrong
        // library.
        return MusicPage(rows: rows,
                         nextCursor: nextCursor,
                         total: total,
                         generation: generation,
                         stale: reply["stale"] as? Bool ?? false,
                         refreshing: reply["refreshing"] as? Bool ?? false,
                         skippedVideos: skippedVideos)
    }

    /// Shared by the three container reads. Complete or refused — `generation`
    /// and `items` are required, and there is no `total` or `next_cursor` to
    /// read (section 2: container replies carry neither).
    private func libraryContainer(op: String, opName: String, id: String,
                                  rows policy: LibraryRowPolicy) throws -> MusicList {
        let reply = try send(["op": op, "id": id], over: libraryTransport)

        guard let generation = reply["generation"] as? Int else {
            throw SourceAppError.malformedReply("Bridge's \(opName) reply is missing generation")
        }
        guard let items = reply["items"] as? [[String: Any]] else {
            throw SourceAppError.malformedReply("Bridge's \(opName) reply is missing items")
        }
        var rows: [MusicRow] = []
        for item in items {
            if let row = try libraryRow(item, opName: opName, policy: policy) { rows.append(row) }
        }
        return MusicList(rows: rows, generation: generation,
                         stale: reply["stale"] as? Bool ?? false,
                         refreshing: reply["refreshing"] as? Bool ?? false)
    }

    /// Contract 3. **The point of the whole seam:** a row Bridge served is
    /// played back by the id Bridge gave it, so nothing is matched on
    /// `(title, artist, album)` and the 338 rows that join could not resolve
    /// stop being a category. An id the app no longer holds refuses the WHOLE
    /// queue rather than shortening it.
    ///
    /// Addendum U (U-R5/U-R6): decodes `skipped_unavailable` from a
    /// SUCCESSFUL reply — absent (an older Bridge) reads 0, exactly like a
    /// field this build has never required; present but not a non-negative
    /// Int STRICTLY LESS than the number of ids sent is malformed, the same
    /// "unreadable" discipline every other required-on-success field in this
    /// file follows.
    ///
    /// **Booleans are rejected, not silently accepted as 0/1.** `JSONSerialization`
    /// bridges a JSON `true`/`false` to an `NSNumber` that `as? Int` happily
    /// unwraps (Codex's review, f2ac2693) — `CFGetTypeID` is the reliable way
    /// to tell a genuine CFBoolean apart from a CFNumber that merely bridges
    /// to one; `as? Int` alone cannot.
    ///
    /// **The count is bounded by what was sent.** A successful, non-empty
    /// queue keeps at least one song (an all-unavailable request refuses
    /// instead — U-R4), so `skipped_unavailable` equal to or greater than
    /// `libraryIDs.count` is not a count Bridge could honestly have sent.
    ///
    /// `startRequired` defaults to `false` so the one direct call in
    /// `BridgeMusicProviderTests` — a transport-wiring test unconcerned with
    /// Addendum U — keeps compiling; the default still sends the key, it
    /// just sends `false`.
    ///
    /// `start_required` is sent EXPLICITLY on every call, never omitted:
    /// Codex's review (f70150a0) reports Bridge now treats an ABSENT field as
    /// a legacy request and refuses it, so omission-means-false no longer
    /// holds.
    func queue(libraryIDs: [String], startRequired: Bool = false) throws -> Int {
        let body: [String: Any] = ["op": "slice.queue", "library_ids": libraryIDs, "start_required": startRequired]
        let reply = try send(body, over: libraryTransport)
        guard let raw = reply["skipped_unavailable"] else { return 0 }
        guard CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(),
              let skipped = raw as? Int, skipped >= 0, skipped < libraryIDs.count else {
            throw SourceAppError.malformedReply("Bridge's queue reply has a skipped_unavailable that is not a count")
        }
        return skipped
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
        _ = try send(body, over: libraryTransport)
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
        _ = try send(["op": "slice.queue", "ids": catalogIDs], over: libraryTransport)
    }

    /// Play ONE station natively on Bridge.
    ///
    /// Its own op, not a widening of `slice.play`: that op's contract is one
    /// catalogue SONG, and a station is a different item kind - endless, with no
    /// queue, confirmed by a rule of its own because it plays tracks rather than
    /// itself.
    ///
    /// **`name` travels for the refusal, not for playback.** A station Apple's
    /// catalogue does not carry (BBC Radio 1 is the known case) cannot have its
    /// name learned by the app, and that is precisely the station whose refusal
    /// has to name it. Ruling 17: refused, never fallen back.
    func playStation(id: String, named name: String) throws {
        _ = try send(["op": "slice.playStation", "id": id, "name": name])
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

    // Internal, not private: `BridgeDiscoverFeed` sends through it rather than
    // carrying a third copy of the frame limit and the refusal decoding.
    func send(_ body: [String: Any]) throws -> [String: Any] {
        try send(body, over: transport)
    }

    func send(_ body: [String: Any],
              over transport: (String, String) throws -> String) throws -> [String: Any] {
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
            switch error?["kind"] as? String {
            case "unauthorized":
                throw SourceAppError.notAuthorized
            case "warming":
                // The ONE refusal that carries a number, so it cannot survive as
                // a detail string. `retry_after` is the app's own hint; a reply
                // that omits it still means "ask again", so a default stands in
                // rather than turning a transient into a hard failure.
                throw SourceAppError.warming(detail,
                                             retryAfter: (error?["retry_after"] as? Double) ?? 1.0)
            case "stale_generation":
                // Decoded on the KIND. The detail travels for display; nothing
                // decides anything by reading it.
                throw SourceAppError.staleGeneration(detail)
            case "ledger_changed":
                // The finished-plays cursor belongs to a play record that has
                // been replaced. A restart from the beginning, decided on the
                // kind; the detail is for display only.
                throw SourceAppError.ledgerChanged(detail)
            case "unknown_op":
                // An OLDER Bridge that predates this op (D6, additive contract).
                // Carries the op name, not the prose, so the caller can say
                // which capability is missing rather than "Bridge refused".
                throw SourceAppError.unsupported(op)
            case "unavailable":
                // Addendum U (U-R4): "None of those songs are available to
                // Bridge." and "'<title>' isn't available to Bridge." —
                // decoded on the kind explicitly (not left to fall into
                // `default` unnoticed) so the mapping is intentional and its
                // own test pins it, even though the outcome is the same as
                // `default`'s: the detail shown verbatim, never reduced to a
                // generic failure.
                throw SourceAppError.refused(detail)
            // `too_large`, `not_in_library` and `library_changed` (D2/D4) are
            // not decoded on their kind: each already carries the sentence a
            // person should read verbatim (section 2), and none of them
            // changes what the client does next the way `warming`,
            // `stale_generation` and `unknown_op` do.
            default:
                throw SourceAppError.refused(detail)
            }
        }
        return reply
    }
}

// MARK: - Finished plays
//
// The same disposable slice debt as the rest of this file, and the same fail
// closed discipline as the library pages: a page that breaks the contract is
// refused whole, never read as fewer plays. A play read wrongly here is a play
// counted twice, or never, in the Music.app library.

extension SourceAppControl: CompletedPlaysReading {

    /// One page of library songs Bridge played to the end, oldest first.
    ///
    /// `ledgerID` nil is sent as an explicit JSON null: "I have no cursor yet".
    /// The bounds on `after` and `limit` are Bridge's to enforce and are not
    /// duplicated here; an out-of-range request comes back as a refusal.
    func completedPlays(ledgerID: String?, after: Int, limit: Int) throws -> CompletedPlaysPage {
        let body: [String: Any] = [
            "op": "slice.completedPlays",
            "ledger_id": ledgerID.map { $0 as Any } ?? NSNull(),
            "after": after,
            "limit": limit,
        ]
        let reply = try send(body)
        return try Self.completedPlaysPage(from: reply, ledgerID: ledgerID, after: after, limit: limit)
    }

    /// Reads and checks one page against what was asked for. Every key is
    /// required, and the page must be exactly the plays after the cursor, in
    /// order, with a consistent cursor and `more`.
    static func completedPlaysPage(from reply: [String: Any], ledgerID requested: String?,
                                   after: Int, limit: Int) throws -> CompletedPlaysPage {
        func bad(_ what: String) -> SourceAppError {
            .malformedReply("Bridge's play record page \(what)")
        }

        guard let ledger = reply["ledger_id"] as? String else { throw bad("is missing ledger_id") }
        guard let latest = strictInt(reply["latest_seq"]), latest >= 0 else {
            throw bad("is missing latest_seq")
        }
        guard let nextAfter = strictInt(reply["next_after"]) else { throw bad("is missing next_after") }
        guard let more = strictBool(reply["more"]) else { throw bad("is missing more") }
        guard let items = reply["plays"] as? [[String: Any]] else { throw bad("is missing plays") }

        // A reply for a different record than the cursor names would apply the
        // cursor to plays it does not describe. A replaced record is refused as
        // such; an ok reply for another one is a broken peer.
        if let requested, requested != ledger {
            throw bad("belongs to a different play record than the one asked for")
        }
        guard items.count <= limit else { throw bad("holds more plays than were asked for") }

        var plays: [CompletedPlayRecord] = []
        plays.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let play = try completedPlay(item, bad: bad)
            // Exactly the plays after the cursor: contiguous, no gaps, no
            // repeats, none already consumed.
            guard play.seq == after + 1 + index else {
                throw bad("has play \(play.seq) where \(after + 1 + index) belongs")
            }
            plays.append(play)
        }

        guard nextAfter == (plays.last?.seq ?? after) else {
            throw bad("has a next_after that is not its last play")
        }
        guard nextAfter <= latest else { throw bad("has a next_after past its latest_seq") }
        guard more == (nextAfter < latest) else { throw bad("has a more that disagrees with its cursor") }
        guard !(more && plays.isEmpty) else { throw bad("is empty while saying there is more") }

        return CompletedPlaysPage(ledgerID: ledger, latestSeq: latest, nextAfter: nextAfter,
                                  more: more, plays: plays)
    }

    /// One play record. `alias` must be present as text or an explicit null;
    /// an absent key is not the same claim as "no alias". `duration_s` and
    /// `position_s` are evidence for Bridge's own decision and are not read.
    private static func completedPlay(_ item: [String: Any],
                                       bad: (String) -> SourceAppError) throws -> CompletedPlayRecord {
        guard let seq = strictInt(item["seq"]), seq >= 1 else { throw bad("has a play with no seq") }
        func text(_ key: String) throws -> String {
            guard let value = item[key] as? String else { throw bad("has play \(seq) with no \(key)") }
            return value
        }
        let alias: String?
        switch item["alias"] {
        case is NSNull:            alias = nil
        case let value as String:  alias = value
        case nil:                  throw bad("has play \(seq) with no alias")
        default:                   throw bad("has play \(seq) with an alias that is neither text nor null")
        }
        let stamp = try text("completed_at")
        guard let completedAt = completedAtFormatter.date(from: stamp) else {
            throw bad("has play \(seq) with an unreadable completed_at")
        }
        return CompletedPlayRecord(seq: seq, playID: try text("play_id"), alias: alias,
                                   libraryID: try text("library_id"),
                                   title: try text("title"), artist: try text("artist"),
                                   completedAt: completedAt, end: try text("end"))
    }

    /// ISO-8601 UTC with fractional seconds, as the feed writes it.
    private static let completedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A JSON integer, never a JSON boolean: `JSONSerialization` bridges both to
    /// `NSNumber`, and `as? Int` alone would read `true` as 1.
    private static func strictInt(_ value: Any?) -> Int? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    /// A JSON boolean, never a number that happens to be 0 or 1.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}

/// The `slice.*` contract this build speaks. Must match the app's
/// `sliceContractVersion`; a mismatch is reported, never worked around.
///
/// 2: `slice.containerTracks` carries `kind`. A contract-1 app ignores it and
/// answers a playlist as a missing album, so that pairing must read as
/// incompatible rather than ready (Codex B1, 2026-09-19).
///
/// 3: paged library reads (`slice.librarySongs`) and a `capabilities` array in
/// status, for "two modes, two libraries" (2026-09-23). A contract-2 app cannot
/// serve a Bridge-mode Library at all, so that pairing must read as incompatible
/// rather than fall back to AppleScript rows — which is the join this version
/// exists to delete.
let sourceContractVersion = 3

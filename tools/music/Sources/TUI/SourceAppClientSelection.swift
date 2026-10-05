// Which source client a selected output means: the ONE factory.
//
// The pairing design, section 4.2: the places that used to build
// `SourceAppClient()` for "the source" now ask here, so the Mac's own SpanDAC
// (the Unix socket) and a SpanDAC on the network (paired TLS) are chosen in
// one place and every `SourceControlling` method above them is untouched.
//
// This is the OUTPUT's client. Music DATA never comes through it: the data
// client is always SpanDAC on this Mac (`SourceAppClient.macData(starter:)`,
// composed by `RoutingCoordinator.live`), even when the output is a network
// SpanDAC, which is an output only.
import Foundation

extension SourceAppClient {

    /// The client for `mode`.
    ///
    /// - `.source` (and `.musicApp`, for the callers that ask about the Mac's
    ///   own SpanDAC whatever is selected): the Unix socket, exactly as before.
    /// - `.networkSource(id)`: the paired TLS link to that SpanDAC, and
    ///   nothing else. There is no fallback to the Mac's socket or to
    ///   Music.app: a SpanDAC that cannot be used says so and stops.
    ///
    /// `licence`, when given, is told every reply the Mac's socket client
    /// returns (`observingLicence`): `RoutingCoordinator.live` passes its
    /// one cache so SpanDAC's serving bit is learned from replies that already
    /// go by. A network SpanDAC's client is never wrapped: it says nothing
    /// about the Mac's licence. Nil builds exactly the client it always did.
    ///
    /// `outputQueues`, when given, is told every reply a NETWORK SpanDAC's
    /// client returns, so whether that output's own queue is loaded is known
    /// from that output alone (Codex review 98, finding 5). The Mac's client
    /// never feeds it.
    static func selected(for mode: PlaybackMode,
                         pairs: SpanDACPairedStore = SpanDACPairedStore(),
                         licence: SpanDACServingCache? = nil,
                         outputQueues: SpanDACOutputQueues? = nil) -> SourceAppClient {
        switch mode {
        case .musicApp, .source:
            return mac(observing: licence)
        case .networkSource(let sourceID):
            return network(sourceID: sourceID, pairs: pairs, outputQueues: outputQueues)
        }
    }

    /// The Mac's own SpanDAC over its Unix socket. With `licence` nil this is
    /// `SourceAppClient()` itself. Otherwise the same three transports, each
    /// with its own timeout as the default client has them, every one wrapped
    /// so `licence` sees each reply; the bytes and errors are unchanged. It
    /// never starts SpanDAC.
    static func mac(observing licence: SpanDACServingCache?) -> SourceAppClient {
        guard let licence else { return SourceAppClient() }
        return SourceAppClient(
            path: SourceAppStationSearch.socketPath,
            transport: observingLicence(SourceAppStationSearch.sendOverUnixSocket, cache: licence),
            libraryTransport: observingLicence(
                SourceAppStationSearch.sender(timeoutSeconds: SourceAppControl.libraryReadTimeoutSeconds),
                cache: licence),
            catalogPlaylistAddTransport: observingLicence(
                SourceAppStationSearch.sender(timeoutSeconds: spandacCatalogPlaylistAddTimeoutSeconds),
                cache: licence))
    }

    /// The Mac's own SpanDAC for the one `slice.status` read made when a
    /// process is composed, on a short deadline of its own
    /// (`licencePrimeTimeoutSeconds`) so a wedged SpanDAC holds that read for
    /// seconds, not the command transport's ten. Every reply is told to
    /// `licence`. It never starts SpanDAC.
    static func macLicencePrime(observing licence: SpanDACServingCache) -> SourceAppClient {
        SourceAppClient(path: SourceAppStationSearch.socketPath,
                        transport: observingLicence(
                            SourceAppStationSearch.sender(timeoutSeconds: licencePrimeTimeoutSeconds),
                            cache: licence))
    }

    /// The same, for the mode `store` holds now.
    static func selected(from store: PlaybackModeStore,
                         pairs: SpanDACPairedStore = SpanDACPairedStore()) -> SourceAppClient {
        selected(for: store.mode(), pairs: pairs)
    }

    /// A client whose every request goes to the paired SpanDAC `sourceID` over
    /// TLS, one connection per request. The pair is looked up at EACH request,
    /// so a forget is honoured at once and a missing pair fails closed.
    ///
    /// The same two timeouts as the Unix client: 10 s for commands, 30 s for
    /// the library reads and `slice.queue`.
    ///
    /// `outputQueues`, when given, sees every reply (`observingOutputQueue`);
    /// the bytes and errors are unchanged.
    static func network(sourceID: String,
                        pairs: SpanDACPairedStore,
                        outputQueues: SpanDACOutputQueues? = nil,
                        makeTransport: @escaping (SpanDACPairRecord) -> SpanDACTLSTransport = { SpanDACTLSTransport(record: $0) })
                        -> SourceAppClient {
        func sender(_ timeoutSeconds: Int) -> (String, String) throws -> String {
            let send: (String, String) throws -> String = { _, line in
                switch pairs.lookup(sourceID) {
                case .failure(let failure):
                    throw SourceAppError.link(failure)
                case .success(let record):
                    return try makeTransport(record).exchange(line, timeout: TimeInterval(timeoutSeconds))
                }
            }
            guard let outputQueues else { return send }
            return observingOutputQueue(send, sourceID: sourceID, queues: outputQueues)
        }
        return SourceAppClient(path: "spandac:\(sourceID)",
                               transport: sender(SourceAppStationSearch.timeoutSeconds),
                               libraryTransport: sender(SourceAppControl.libraryReadTimeoutSeconds))
    }

    /// A client whose every request fails with `failure`, never touching a
    /// socket: for a composition that was not given a way to reach a SpanDAC.
    static func failing(_ failure: SpanDACLinkFailure) -> SourceAppClient {
        SourceAppClient(path: "spandac:unavailable", transport: { _, _ in throw SourceAppError.link(failure) })
    }
}

/// How long the composition-time licence read waits for SpanDAC on this Mac.
/// A status on a healthy local socket answers in milliseconds; this is a
/// backstop against a wedged app, UNMEASURED as a choice. Timing out leaves
/// serving unknown, which is today's behaviour.
let licencePrimeTimeoutSeconds = 2

/// Whether each iPhone/iPad SpanDAC output's OWN queue was loaded the last
/// time that output answered (Codex review 98, finding 5). The Mac's
/// `SpanDACServingCache` says whether the Mac serves and whether the MAC's
/// queue is loaded; it says nothing about an iPhone or iPad, so a play-out
/// on one is recorded only from this.
///
/// Fed by the network clients' replies (`observingOutputQueue`), from any
/// thread, hence the lock. Never observed reads as not loaded: no evidence
/// grants no play-out.
final class SpanDACOutputQueues {
    private let lock = NSLock()
    private var loaded: [String: Bool] = [:]

    init() {}

    /// A `slice.status` reply records whether a queue is built or building
    /// and has not stopped (the same rule the Mac's cache uses); a
    /// `nothing_loaded` refusal records not loaded. Anything else, including
    /// a line that does not parse, changes nothing.
    func observe(sourceID: String, replyLine: String) {
        guard let data = replyLine.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = reply["ok"] as? Bool else { return }
        let now: Bool
        if ok {
            guard let status = reply["status"] as? [String: Any],
                  let playback = status["playback"] as? String else { return }
            let phase = (status["queue"] as? [String: Any])?["phase"] as? String
            now = (phase == "building" || phase == "complete") && playback != "stopped" && playback != "idle"
        } else {
            guard (reply["error"] as? [String: Any])?["kind"] as? String == "nothing_loaded" else { return }
            now = false
        }
        lock.lock(); loaded[sourceID] = now; lock.unlock()
    }

    /// True only when this output's own last status showed its queue loaded.
    func isLoaded(_ sourceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded[sourceID] ?? false
    }

    /// Drops what is known about `sourceID`, so only a later reply from it
    /// can say its queue is loaded.
    func forget(_ sourceID: String) {
        lock.lock(); loaded[sourceID] = nil; lock.unlock()
    }
}

/// A transport that reports every reply it returns to `queues` under
/// `sourceID` and otherwise changes nothing: the same bytes come back, and an
/// error from the transport is thrown as it was, unobserved.
func observingOutputQueue(_ transport: @escaping (String, String) throws -> String,
                          sourceID: String,
                          queues: SpanDACOutputQueues) -> (String, String) throws -> String {
    { path, line in
        let reply = try transport(path, line)
        queues.observe(sourceID: sourceID, replyLine: reply)
        return reply
    }
}

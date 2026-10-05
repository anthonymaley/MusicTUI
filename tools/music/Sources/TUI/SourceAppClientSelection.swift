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
    static func selected(for mode: PlaybackMode,
                         pairs: SpanDACPairedStore = SpanDACPairedStore(),
                         licence: SpanDACServingCache? = nil) -> SourceAppClient {
        switch mode {
        case .musicApp, .source:
            return mac(observing: licence)
        case .networkSource(let sourceID):
            return network(sourceID: sourceID, pairs: pairs)
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
    static func network(sourceID: String,
                        pairs: SpanDACPairedStore,
                        makeTransport: @escaping (SpanDACPairRecord) -> SpanDACTLSTransport = { SpanDACTLSTransport(record: $0) })
                        -> SourceAppClient {
        func sender(_ timeoutSeconds: Int) -> (String, String) throws -> String {
            { _, line in
                switch pairs.lookup(sourceID) {
                case .failure(let failure):
                    throw SourceAppError.link(failure)
                case .success(let record):
                    return try makeTransport(record).exchange(line, timeout: TimeInterval(timeoutSeconds))
                }
            }
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

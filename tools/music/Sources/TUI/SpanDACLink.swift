// The paired link from MusicTUI to SpanDAC on another device (the pairing
// design, sections 3.3 and 4.2): one TLS connection per request, the same
// `slice.*` lines the Mac's own socket carries, and nothing else.
//
// **TLS 1.2 ECDHE-PSK, suite 0xCCAC, and nothing weaker.** The key is the
// pair's `K_pair`; the identity is its `psk_id` in hex, an opaque token naming
// no device and no person. Apple's public API cannot do TLS 1.3 with a
// pre-shared key, and a client that appends 0xCCAC still offers the
// non-forward-secret PSK suites, so the negotiated suite is READ after `.ready`
// and anything but TLS 1.2 with 0xCCAC is dropped before a byte is sent.
//
// **A TLS refusal is final.** Network.framework reports a refused handshake as
// `.waiting(.tls(status))`, never `.failed` (21/21 in the spike), so waiting on
// it would sit out the whole timeout. It is cancelled at once and reported by
// its OSStatus: an unknown identity means the SpanDAC removed this Mac.
//
// **Connect by address, not by Bonjour name.** Connecting to the Bonjour
// service endpoint hid a TLS refusal for 20-40 s behind a generic wait (6/6,
// measured on the source's side); connecting to the resolved address reported
// it in milliseconds. So each request resolves the service to host and port
// (the port can change when the SpanDAC restarts its listener) and connects to
// a numeric address.
//
// **Fail closed.** A selected SpanDAC that cannot be found, reached, agreed
// with or read from returns its error and stops. Nothing here knows any other
// output exists.
import dnssd
import Foundation
import Network
import Security

// MARK: - Failures, in words

/// Why a request to a paired SpanDAC did not get an answer.
enum SpanDACLinkFailure: Error, Equatable {
    /// No pair for this SpanDAC in `paired.json` (forgotten, or never paired).
    case notPaired
    /// `paired.json` exists and cannot be used safely.
    case pairingsUnavailable(String)
    /// Its Bonjour service did not resolve: it is not on this network.
    case notFound
    /// Found, but the connection was refused or timed out: the app is asleep
    /// or closed on the device.
    case asleep
    /// The TLS handshake was refused, with its OSStatus.
    case refused(OSStatus)
    /// A handshake that completed on anything but TLS 1.2 with 0xCCAC.
    case unsafeCipher
    /// Connected and sent, and no reply came in time.
    case noAnswer
    /// This process forgot the SpanDAC while the request was open.
    case forgotten

    /// The sentence a person reads (CLI output, the footer, the Output tab's
    /// selection refusal).
    var sentence: String {
        switch self {
        case .notPaired: return "This Mac is not paired with that SpanDAC; pair it from the Output tab."
        case .pairingsUnavailable(let why): return why
        case .notFound: return "SpanDAC was not found on this network."
        case .asleep: return "SpanDAC is asleep or closed; open it on the device."
        case .refused(let status): return SpanDACLinkFailure.refusalSentence(status)
        case .unsafeCipher: return "SpanDAC negotiated an unsafe cipher; update it"
        case .noAnswer: return "SpanDAC did not answer in time."
        case .forgotten: return "SpanDAC was forgotten on this Mac."
        }
    }

    /// The Output tab's short note beside the row.
    var note: String {
        switch self {
        case .notPaired: return "not paired · Enter to pair"
        case .pairingsUnavailable: return "pairings unavailable · see ~/.config/music/spandac"
        case .notFound: return "not found on this network"
        case .asleep: return "asleep or closed · open SpanDAC on the device"
        case .refused(let status): return SpanDACLinkFailure.refusalSentence(status)
        case .unsafeCipher: return "unsafe cipher · update SpanDAC"
        case .noAnswer: return "did not answer in time"
        case .forgotten: return "forgotten"
        }
    }

    /// Section 3.3 item 9: the three refusals the handshake can end in, each
    /// with what to do. Any other status is a refusal too, named by number.
    static func refusalSentence(_ status: OSStatus) -> String {
        switch status {
        case -9864: return "SpanDAC no longer recognises this Mac; pair again"
        case -9820, -9846: return "The pairing secret does not match; forget and pair again"
        case -9858: return "SpanDAC refused the connection"
        default: return "SpanDAC refused the connection (TLS \(status))"
        }
    }
}

// MARK: - The suite rule

enum SpanDACTLSPolicy {
    /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`.
    static let requiredSuite: UInt16 = 0xCCAC

    /// What a completed handshake must have agreed, checked after `.ready`
    /// and before the request line is written.
    static func isAcceptable(version: tls_protocol_version_t, suite: UInt16) -> Bool {
        version == .TLSv12 && suite == requiredSuite
    }

    /// The client's TLS settings for one pair.
    static func clientOptions(pskIdentity: String, pairKey: Data) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: requiredSuite)!)
        // A resumed session would skip the PSK selection the SpanDAC uses to
        // refuse a removed pair; never offer one.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_renegotiation_enabled(options, false)
        sec_protocol_options_add_pre_shared_key(options, dispatchData(pairKey), dispatchData(Data(pskIdentity.utf8)))
        return tls
    }

    static func dispatchData(_ bytes: Data) -> __DispatchData {
        bytes.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

// MARK: - Open connections, by SpanDAC

/// Every connection this process has open to a SpanDAC, keyed by its
/// `spandac_id`, so forgetting a SpanDAC cancels them at once (section 3.3
/// item 5). In this version a connection lives for one request, so this is
/// the guard a persistent connection would need, built and tested now.
///
/// A request in flight in ANOTHER MusicTUI process (a CLI command) is not
/// reachable from here: it completes or times out within its bound, and its
/// next request fails at the handshake once the SpanDAC has removed this Mac.
final class SpanDACLinkRegistry {
    static let shared = SpanDACLinkRegistry()

    private let lock = NSLock()
    private var open: [String: [UUID: () -> Void]] = [:]

    /// Registers `cancel` under `sourceID`; the token unregisters it.
    func register(_ sourceID: String, cancel: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock(); open[sourceID, default: [:]][token] = cancel; lock.unlock()
        return token
    }

    func unregister(_ sourceID: String, _ token: UUID) {
        lock.lock()
        open[sourceID]?[token] = nil
        if open[sourceID]?.isEmpty == true { open[sourceID] = nil }
        lock.unlock()
    }

    /// Cancels every connection open to `sourceID`. Returns how many.
    @discardableResult
    func cancelAll(_ sourceID: String) -> Int {
        lock.lock()
        let cancels = open.removeValue(forKey: sourceID) ?? [:]
        lock.unlock()
        cancels.values.forEach { $0() }
        return cancels.count
    }

    func openCount(_ sourceID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return open[sourceID]?.count ?? 0
    }
}

// MARK: - Finding it: Bonjour service to a numeric address

/// Where a SpanDAC's service is right now.
struct SpanDACServiceLocation: Equatable {
    /// The Bonjour host target, e.g. `Anthonys-iPad.local.`.
    let hostName: String
    let port: UInt16
    /// The TXT record, decoded as key=value strings.
    let txt: [String: String]
    let interfaceIndex: UInt32
}

protocol SpanDACResolving {
    /// Resolves a `_spandac._tcp` service instance to its host and port.
    func locate(serviceName: String, timeout: TimeInterval) -> SpanDACServiceLocation?
    /// The host's numeric addresses, IPv4 first.
    func addresses(of location: SpanDACServiceLocation, timeout: TimeInterval) -> [String]
}

/// DNS-SD (`dns_sd.h`), synchronously, with a deadline: resolve the service,
/// then look the host up. Blocking by design, like the Unix transport; every
/// caller is already off the input thread.
struct SpanDACBonjourResolver: SpanDACResolving {

    static let serviceType = "_spandac._tcp."
    static let domain = "local."

    func locate(serviceName: String, timeout: TimeInterval) -> SpanDACServiceLocation? {
        final class Box { var location: SpanDACServiceLocation? }
        let box = Box()
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(box).toOpaque()
        let status = DNSServiceResolve(&ref, 0, 0, serviceName, Self.serviceType, Self.domain, { _, _, interface, error, _, host, port, txtLength, txt, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            guard box.location == nil else { return }
            let bytes = txt.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
            box.location = SpanDACServiceLocation(hostName: String(cString: host), port: UInt16(bigEndian: port),
                                                  txt: SpanDACTXT.decode(bytes), interfaceIndex: interface)
        }, context)
        guard status == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        Self.process(ref, timeout: timeout) { box.location != nil }
        return box.location
    }

    func addresses(of location: SpanDACServiceLocation, timeout: TimeInterval) -> [String] {
        final class Box { var v4: [String] = []; var v6: [String] = []; var complete = false }
        let box = Box()
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(box).toOpaque()
        let status = DNSServiceGetAddrInfo(&ref, 0, location.interfaceIndex,
                                           DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
                                           location.hostName, { _, flags, _, error, _, address, _, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            if error == kDNSServiceErr_NoError, let address, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
               let text = SpanDACBonjourResolver.numericHost(address) {
                if address.pointee.sa_family == sa_family_t(AF_INET) { box.v4.append(text) } else { box.v6.append(text) }
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.complete = true }
        }, context)
        guard status == kDNSServiceErr_NoError, let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }
        // An IPv4 answer is enough; otherwise wait for the batch to finish.
        Self.process(ref, timeout: timeout) { !box.v4.isEmpty || (box.complete && !box.v6.isEmpty) }
        return box.v4 + box.v6
    }

    /// Runs the DNS-SD reply loop until `done` or the deadline.
    private static func process(_ ref: DNSServiceRef, timeout: TimeInterval, until done: () -> Bool) {
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, Int32(max(1, min(remaining, 1) * 1000)))
            if ready < 0 && errno != EINTR { return }
            if ready > 0 { guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { return } }
        }
    }

    /// A numeric host string for a socket address, with an IPv6 scope where
    /// there is one (`fe80::1%en0`).
    static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_family == sa_family_t(AF_INET)
                               ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

/// The TXT record SpanDAC publishes (section 3.3 item 3): `v=1`, `contract=3`,
/// `id=<spandac_id>`, `name=<device name>`, and, only while the device is
/// accepting pairing, `pair=1` and `pairport=<n>`. Unauthenticated and
/// eventually consistent: a hint, never a reason to call anything ready, and
/// `pair=1` is an invitation to try, never proof the device will accept.
struct SpanDACTXT: Equatable {
    let sourceID: String
    let name: String
    let contract: Int?
    /// The pairing port, only while the device advertises pairing.
    let pairingPort: UInt16?

    /// Nil unless `v=1` and `id` is a canonical id and `name` is usable.
    init?(_ txt: [String: String]) {
        guard txt["v"] == "1", let id = txt["id"], SpanDACPair.isCanonicalID(id),
              let name = txt["name"], SpanDACPair.isValidName(name) else { return nil }
        sourceID = id
        self.name = name
        contract = txt["contract"].flatMap { Int($0) }
        if txt["pair"] == "1", let port = txt["pairport"].flatMap({ UInt16($0) }), port > 0 {
            pairingPort = port
        } else {
            pairingPort = nil
        }
    }

    /// DNS TXT wire format: length-prefixed `key=value` strings.
    static func decode(_ bytes: Data) -> [String: String] {
        var out: [String: String] = [:]
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let length = Int(bytes[index])
            index = bytes.index(after: index)
            guard let end = bytes.index(index, offsetBy: length, limitedBy: bytes.endIndex) else { break }
            if let item = String(data: bytes[index..<end], encoding: .utf8), let eq = item.firstIndex(of: "=") {
                let key = String(item[..<eq]).lowercased()
                if out[key] == nil { out[key] = String(item[item.index(after: eq)...]) }
            }
            index = end
        }
        return out
    }
}

// MARK: - One request over TLS

/// Sends one line to a paired SpanDAC and reads one line back.
struct SpanDACTLSTransport {

    let record: SpanDACPairRecord
    var resolver: SpanDACResolving = SpanDACBonjourResolver()
    var registry: SpanDACLinkRegistry = .shared
    /// Bounds on the steps before the request is sent. A resolve or a
    /// handshake takes milliseconds on a LAN; these are backstops, CHOSEN,
    /// NOT MEASURED as limits.
    var resolveTimeout: TimeInterval = 3
    var handshakeTimeout: TimeInterval = 5
    /// TEST SEAM: connect here instead of resolving the service.
    var fixedEndpoint: (host: String, port: UInt16)? = nil

    /// The `(path, line) -> reply` closure every `SourceControlling` method is
    /// built on; the path is ignored (the record says where to go).
    func sender(timeoutSeconds: Int) -> (String, String) throws -> String {
        { _, line in try exchange(line, timeout: TimeInterval(timeoutSeconds)) }
    }

    func exchange(_ line: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let host: String, port: UInt16
        if let fixed = fixedEndpoint {
            (host, port) = fixed
        } else {
            guard let location = resolver.locate(serviceName: record.serviceName,
                                                 timeout: min(resolveTimeout, max(0.1, deadline.timeIntervalSinceNow))),
                  let address = resolver.addresses(of: location,
                                                   timeout: min(resolveTimeout, max(0.1, deadline.timeIntervalSinceNow))).first
            else { throw SourceAppError.link(.notFound) }
            (host, port) = (address, location.port)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw SourceAppError.link(.notFound) }

        let parameters = NWParameters(tls: SpanDACTLSPolicy.clientOptions(pskIdentity: record.pskID,
                                                                          pairKey: record.pairKey),
                                      tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let exchange = Exchange(connection: connection, line: line)
        let token = registry.register(record.sourceID) { exchange.finish(.failure(.link(.forgotten))) }
        defer { registry.unregister(record.sourceID, token) }
        return try exchange.run(handshakeDeadline: min(deadline, Date().addingTimeInterval(handshakeTimeout)),
                                deadline: deadline)
    }

    /// One connection's life, driven by Network.framework's callbacks on a
    /// private queue and awaited by the caller's thread.
    private final class Exchange {

        enum Failure: Error, Equatable {
            case link(SpanDACLinkFailure)
            /// A reply arrived and was not a usable line.
            case unreadable
        }

        private let connection: NWConnection
        private let line: String
        private let queue = DispatchQueue(label: "spandac.link")
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Result<String, Failure>?
        private var ready = false
        private var received = Data()

        init(connection: NWConnection, line: String) {
            self.connection = connection
            self.line = line
        }

        private var isReady: Bool {
            lock.lock(); defer { lock.unlock() }
            return ready
        }

        func run(handshakeDeadline: Date, deadline: Date) throws -> String {
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            connection.start(queue: queue)
            // First bound: the handshake. A peer that never completes one is
            // reported like one that refused the connection. Second bound: the
            // reply, inside the request's own timeout.
            if done.wait(timeout: .now() + max(0, handshakeDeadline.timeIntervalSinceNow)) == .timedOut {
                if !isReady {
                    finish(.failure(.link(.asleep)))
                } else if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
                    finish(.failure(.link(.noAnswer)))
                }
            }
            lock.lock(); let result = outcome; lock.unlock()
            switch result {
            case .success(let reply)?: return reply
            case .failure(.unreadable)?: throw SourceAppError.unreadable
            case .failure(.link(let failure))?: throw SourceAppError.link(failure)
            case nil: throw SourceAppError.link(.noAnswer)
            }
        }

        /// The first outcome wins; the connection is cancelled either way.
        func finish(_ result: Result<String, Failure>) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = result
            lock.unlock()
            connection.cancel()
            done.signal()
        }

        private func handle(_ state: NWConnection.State) {
            switch state {
            case .ready:
                // The suite check, before a byte of the request is written.
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                    finish(.failure(.link(.unsafeCipher)))
                    return
                }
                let negotiated = metadata.securityProtocolMetadata
                let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(negotiated)
                let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(negotiated).rawValue
                guard SpanDACTLSPolicy.isAcceptable(version: version, suite: suite) else {
                    finish(.failure(.link(.unsafeCipher)))
                    return
                }
                lock.lock(); ready = true; lock.unlock()
                connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(.failure(.link(.noAnswer))) }
                })
                receive()
            case .waiting(let error):
                switch error {
                case .tls(let status):
                    // Final: a refused handshake never turns into a success by
                    // waiting (section 3.3 item 9).
                    finish(.failure(.link(.refused(status))))
                case .posix(let code) where code == .ECONNREFUSED:
                    // Nothing is listening at the address the service resolved
                    // to right now.
                    finish(.failure(.link(.asleep)))
                default:
                    // Any other wait (no route yet) keeps waiting, inside the
                    // bounded timeout.
                    break
                }
            case .failed(let error):
                if case .tls(let status) = error {
                    finish(.failure(.link(.refused(status))))
                } else {
                    finish(.failure(.link(isReady ? .noAnswer : .asleep)))
                }
            case .cancelled:
                // Only `finish` or the registry cancels; the registry's is a
                // forget.
                finish(.failure(.link(.forgotten)))
            default:
                break
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.received.append(data) }
                if let newline = self.received.firstIndex(of: UInt8(ascii: "\n")) {
                    guard let text = String(data: self.received[..<newline], encoding: .utf8), !text.isEmpty else {
                        self.finish(.failure(.unreadable))
                        return
                    }
                    self.finish(.success(text))
                    return
                }
                // The Unix transport's own frame ceiling.
                if self.received.count > 64 * 1024 { self.finish(.failure(.unreadable)); return }
                if error != nil || isComplete {
                    // Closed with no reply: a SpanDAC that removed this Mac
                    // mid-session closes without a word.
                    self.finish(.failure(.link(.noAnswer)))
                    return
                }
                self.receive()
            }
        }
    }
}

// tools/music/Tests/MusicTests/SpanDACLinkTests.swift
//
// The paired TLS link, against a loopback TLS-PSK peer written in this test
// (a few lines answering one line; it is not SpanDAC). What is pinned: the
// happy path, each handshake refusal mapped to its sentence promptly (never
// waited on), the suite check dropping a non-forward-secret suite BEFORE a
// byte is sent, the forget registry cancelling an open request, and the
// failure words the Output tab and the CLI show.
import Network
import Security
import XCTest
@testable import music

final class SpanDACLinkTests: XCTestCase {

    private let identity = String(repeating: "c0", count: 16)
    private let key = Data((0..<32).map { UInt8($0) })
    private let sourceID = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"

    private func record(identity: String? = nil, key: Data? = nil) -> SpanDACPairRecord {
        SpanDACPairRecord(sourceID: sourceID, sourceName: "Loopback", pskID: identity ?? self.identity,
                          pairKey: key ?? self.key, serviceName: sourceID, pairedAt: Date())
    }

    private func transport(_ server: LoopbackPSKServer?, record: SpanDACPairRecord? = nil,
                           port: UInt16? = nil, registry: SpanDACLinkRegistry = SpanDACLinkRegistry()) -> SpanDACTLSTransport {
        var t = SpanDACTLSTransport(record: record ?? self.record())
        t.fixedEndpoint = ("127.0.0.1", port ?? server!.port)
        t.registry = registry
        return t
    }

    private func failure(_ body: () throws -> String) -> SpanDACLinkFailure? {
        do {
            _ = try body()
            XCTFail("expected a failure")
            return nil
        } catch SourceAppError.link(let failure) {
            return failure
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    // MARK: - Happy path

    func testAPairedRequestGetsItsReplyOverTLS12WithTheForwardSecretSuite() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key,
                                           reply: #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[]}}"#)
        defer { server.stop() }
        let t = transport(server)
        let client = SourceAppClient(path: "spandac:test", transport: t.sender(timeoutSeconds: 5))
        XCTAssertEqual(client.readiness(), .ready)
        XCTAssertEqual(server.requests, [#"{"op":"slice.status"}"#])
        XCTAssertEqual(server.negotiatedSuites, [0xCCAC])
    }

    // MARK: - Refusals are final, and in words

    /// An identity the peer does not hold: refused at the handshake, reported
    /// at once as "pair again", never waited on.
    func testAnUnknownIdentityIsRefusedAtOnceAsPairAgain() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: "{}")
        defer { server.stop() }
        let started = Date()
        let got = failure { try transport(server, record: record(identity: String(repeating: "0f", count: 16))).exchange("x", timeout: 10) }
        XCTAssertEqual(got, .refused(-9864))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a TLS refusal must not be waited on")
        XCTAssertEqual(got?.sentence, "SpanDAC no longer recognises this Mac; pair again")
        XCTAssertEqual(server.requests, [])
    }

    /// The right identity with the wrong key: refused as a secret mismatch.
    func testAWrongKeyIsRefusedAsASecretMismatch() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: "{}")
        defer { server.stop() }
        let started = Date()
        let got = failure { try transport(server, record: record(key: Data(repeating: 1, count: 32))).exchange("x", timeout: 10) }
        XCTAssertEqual(got, .refused(-9820))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(got?.sentence, "The pairing secret does not match; forget and pair again")
        XCTAssertEqual(server.requests, [])
    }

    /// A peer that holds the key but negotiates the non-forward-secret suite
    /// (0x00A8) completes the handshake; the client drops it before writing a
    /// single byte, and says so.
    func testANonForwardSecretSuiteIsDroppedBeforeAnythingIsSent() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: "{}", suite: 0x00A8)
        defer { server.stop() }
        let got = failure { try transport(server).exchange(#"{"op":"slice.play"}"#, timeout: 5) }
        XCTAssertEqual(got, .unsafeCipher)
        XCTAssertEqual(got?.sentence, "SpanDAC negotiated an unsafe cipher; update it")
        XCTAssertEqual(server.negotiatedSuites, [0x00A8], "the peer did reach .ready on 0x00A8")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.applicationBytes, 0, "not one application byte may reach a peer on a non-FS suite")
    }

    /// Each OSStatus the handshake can end in has its sentence (3.3 item 9).
    func testEachRefusalStatusHasItsSentence() {
        XCTAssertEqual(SpanDACLinkFailure.refusalSentence(-9864), "SpanDAC no longer recognises this Mac; pair again")
        XCTAssertEqual(SpanDACLinkFailure.refusalSentence(-9820), "The pairing secret does not match; forget and pair again")
        XCTAssertEqual(SpanDACLinkFailure.refusalSentence(-9846), "The pairing secret does not match; forget and pair again")
        XCTAssertEqual(SpanDACLinkFailure.refusalSentence(-9858), "SpanDAC refused the connection")
        XCTAssertEqual(SpanDACLinkFailure.refusalSentence(-9824), "SpanDAC refused the connection (TLS -9824)")
        XCTAssertEqual(SourceReadiness.from(SourceAppError.link(.refused(-9864))),
                       .unavailable("SpanDAC no longer recognises this Mac; pair again"))
        XCTAssertEqual(SourceAppError.link(.refused(-9864)).message, "SpanDAC no longer recognises this Mac; pair again")
    }

    func testOnlyTLS12WithTheForwardSecretSuiteIsAcceptable() {
        XCTAssertTrue(SpanDACTLSPolicy.isAcceptable(version: .TLSv12, suite: 0xCCAC))
        XCTAssertFalse(SpanDACTLSPolicy.isAcceptable(version: .TLSv12, suite: 0x00A8))
        XCTAssertFalse(SpanDACTLSPolicy.isAcceptable(version: .TLSv12, suite: 0x00AE))
        XCTAssertFalse(SpanDACTLSPolicy.isAcceptable(version: .TLSv13, suite: 0xCCAC))
    }

    // MARK: - Not there, not answering

    func testNothingListeningIsAsleepOrClosed() throws {
        // A port that was just listening and is not any more.
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: "{}")
        let port = server.port
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        let got = failure { try transport(nil, port: port).exchange("x", timeout: 10) }
        XCTAssertEqual(got, .asleep)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(got?.note, "asleep or closed on the iPad · open it there")
    }

    func testAPeerThatClosesWithoutAReplyIsNoAnswer() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: nil, closeAfterRequest: true)
        defer { server.stop() }
        XCTAssertEqual(failure { try transport(server).exchange("x", timeout: 5) }, .noAnswer)
    }

    func testAPeerThatNeverAnswersTimesOutInsideTheBound() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: nil)
        defer { server.stop() }
        let started = Date()
        XCTAssertEqual(failure { try transport(server).exchange("x", timeout: 1) }, .noAnswer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAnOversizedReplyIsUnreadable() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: String(repeating: "x", count: 70_000))
        defer { server.stop() }
        XCTAssertThrowsError(try transport(server).exchange("x", timeout: 5)) {
            XCTAssertEqual($0 as? SourceAppError, .unreadable)
        }
    }

    // MARK: - Forget cancels what is open

    /// Forgetting a SpanDAC cancels a request this process has open to it,
    /// at once (3.3 item 5), and the registry is empty afterwards.
    func testForgettingCancelsAnOpenRequestAtOnce() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: nil)
        defer { server.stop() }
        let registry = SpanDACLinkRegistry()
        let t = transport(server, registry: registry)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(registry.openCount(self.sourceID), 1)
            XCTAssertEqual(registry.cancelAll(self.sourceID), 1)
        }
        let started = Date()
        XCTAssertEqual(failure { try t.exchange("x", timeout: 10) }, .forgotten)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(registry.openCount(sourceID), 0)
    }

    func testAFinishedRequestLeavesNothingRegistered() throws {
        let server = try LoopbackPSKServer(identity: identity, key: key, reply: #"{"ok":true}"#)
        defer { server.stop() }
        let registry = SpanDACLinkRegistry()
        _ = try transport(server, registry: registry).exchange("x", timeout: 5)
        XCTAssertEqual(registry.openCount(sourceID), 0)
        XCTAssertEqual(registry.cancelAll(sourceID), 0)
    }

    func testTheRegistryCancelsOnlyTheForgottenSpanDAC() {
        let registry = SpanDACLinkRegistry()
        var cancelled: [String] = []
        _ = registry.register("A") { cancelled.append("A1") }
        _ = registry.register("A") { cancelled.append("A2") }
        let b = registry.register("B") { cancelled.append("B") }
        XCTAssertEqual(registry.cancelAll("A"), 2)
        XCTAssertEqual(Set(cancelled), ["A1", "A2"])
        registry.unregister("B", b)
        XCTAssertEqual(registry.cancelAll("B"), 0)
    }

    // MARK: - The TXT record

    private func wire(_ items: [String]) -> Data {
        var out = Data()
        for item in items { out.append(UInt8(item.utf8.count)); out.append(Data(item.utf8)) }
        return out
    }

    func testTheTXTRecordIsReadAsAHintOnly() {
        let open = SpanDACTXT.decode(wire(["v=1", "contract=3", "id=\(sourceID)", "name=Anthony’s iPad", "pair=1", "pairport=51456"]))
        let txt = SpanDACTXT(open)
        XCTAssertEqual(txt?.sourceID, sourceID)
        XCTAssertEqual(txt?.name, "Anthony’s iPad")
        XCTAssertEqual(txt?.contract, 3)
        XCTAssertEqual(txt?.pairingPort, 51456)

        let closed = SpanDACTXT(SpanDACTXT.decode(wire(["v=1", "contract=3", "id=\(sourceID)", "name=iPad", "pairport=51456"])))
        XCTAssertNil(closed?.pairingPort, "a pairing port counts only while pair=1")
        XCTAssertNotNil(closed)

        XCTAssertNil(SpanDACTXT(SpanDACTXT.decode(wire(["v=2", "id=\(sourceID)", "name=iPad"]))))
        XCTAssertNil(SpanDACTXT(SpanDACTXT.decode(wire(["v=1", "id=\(sourceID.lowercased())", "name=iPad"]))))
        XCTAssertNil(SpanDACTXT(SpanDACTXT.decode(wire(["v=1", "id=\(sourceID)"]))))
        XCTAssertEqual(SpanDACTXT.decode(Data([200, 65])), [:], "a truncated record reads as nothing")
    }
}

/// A loopback TLS 1.2 PSK peer for these tests: accepts one identity and key,
/// negotiates `suite`, records what it was sent, and answers each line with
/// `reply` (nil: never answers). Listens on 127.0.0.1 only.
final class LoopbackPSKServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-psk")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _requests: [String] = []
    private var _suites: [UInt16] = []
    private var _bytes = 0
    private(set) var port: UInt16 = 0

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var negotiatedSuites: [UInt16] { lock.lock(); defer { lock.unlock() }; return _suites }
    var applicationBytes: Int { lock.lock(); defer { lock.unlock() }; return _bytes }

    init(identity: String, key: Data, reply: String?, suite: UInt16 = 0xCCAC, closeAfterRequest: Bool = false) throws {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: suite)!)
        sec_protocol_options_add_pre_shared_key(options, SpanDACTLSPolicy.dispatchData(key),
                                                SpanDACTLSPolicy.dispatchData(Data(identity.utf8)))
        sec_protocol_options_set_pre_shared_key_selection_block(options, { _, offered, complete in
            let text = offered.map { String(data: Data(($0 as DispatchData).map { $0 }), encoding: .utf8) } ?? nil
            complete(text == identity ? offered : nil)
        }, DispatchQueue(label: "loopback-psk-select"))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] connection in
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.stateUpdateHandler = { [unowned self] state in
                guard case .ready = state else { return }
                if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    let s = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
                    self.lock.lock(); self._suites.append(s); self.lock.unlock()
                }
                self.read(connection, buffer: Data(), reply: reply, closeAfterRequest: closeAfterRequest)
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw SourceAppError.link(.notFound)
        }
        self.port = port
    }

    private func read(_ connection: NWConnection, buffer: Data, reply: String?, closeAfterRequest: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
                self.lock.lock(); self._bytes += data.count; self.lock.unlock()
            }
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
                self.lock.lock(); self._requests.append(line); self.lock.unlock()
                if closeAfterRequest { connection.cancel(); return }
                if let reply {
                    connection.send(content: Data((reply + (reply.count > 65_536 ? "" : "\n")).utf8),
                                    completion: .contentProcessed { _ in })
                }
                return
            }
            if error == nil && !done { self.read(connection, buffer: buffer, reply: reply, closeAfterRequest: closeAfterRequest) }
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let open = connections; lock.unlock()
        open.forEach { $0.cancel() }
    }
}

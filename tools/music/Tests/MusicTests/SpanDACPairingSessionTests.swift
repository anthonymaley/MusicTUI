// tools/music/Tests/MusicTests/SpanDACPairingSessionTests.swift
//
// A whole pairing over real TCP on loopback: the controller's session against
// a source written in these tests (`TestSource`, from the primitives). Pins
// the framing, the y/n, the save-before-done rule, and the one ordering the
// source's side measured: success is reported only once the source has
// CLOSED the pairing connection (it restarts its paired listener first).
import Network
import XCTest
@testable import music

/// Plain-TCP pairing responder on 127.0.0.1: feeds each line to `TestSource`
/// and writes its reply. After `done` it waits `closeDelay`, then closes.
final class LoopbackPairingPeer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-pair")
    private let source: TestSource
    private let closeDelay: TimeInterval
    /// Answer the controller's confirm with this abort instead (the iPad's
    /// "Not this").
    private let rejectConfirm: Bool
    private let abortAtHello: String?
    private let lock = NSLock()
    private var _closedAt: Date?
    private(set) var port: UInt16 = 0
    var closedAt: Date? { lock.lock(); defer { lock.unlock() }; return _closedAt }

    init(source: TestSource, closeDelay: TimeInterval = 0.3, rejectConfirm: Bool = false, abortAtHello: String? = nil) throws {
        self.source = source
        self.closeDelay = closeDelay
        self.rejectConfirm = rejectConfirm
        self.abortAtHello = abortAtHello
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw SourceAppError.link(.notFound)
        }
        self.port = port
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer + (data ?? Data())
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
                buffer.removeSubrange(...newline)
                let t = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["t"] as? String
                if t == "hello", let reason = self.abortAtHello {
                    self.write(connection, #"{"t":"abort","reason":"\#(reason)"}"#)
                    self.close(connection, after: 0.1)
                    return
                }
                if t == "confirm", self.rejectConfirm {
                    self.write(connection, #"{"t":"abort","reason":"rejected"}"#)
                    self.close(connection, after: 0.1)
                    return
                }
                if t == "abort" { self.close(connection, after: 0); return }
                if let reply = self.source.handle(line) { self.write(connection, reply) }
                if t == "done" { self.close(connection, after: self.closeDelay); return }
            }
            if error == nil && !done { self.read(connection, buffer) }
        }
    }

    private func write(_ connection: NWConnection, _ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func close(_ connection: NWConnection, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) {
            self.lock.lock(); self._closedAt = Date(); self.lock.unlock()
            connection.cancel()
        }
    }

    func stop() { listener.cancel() }
}

final class SpanDACPairingSessionTests: XCTestCase {

    private final class Events {
        private let lock = NSLock()
        private var _all: [SpanDACPairingEvent] = []
        private var finishedAt: Date?
        let finished = DispatchSemaphore(value: 0)
        let code = DispatchSemaphore(value: 0)
        var all: [SpanDACPairingEvent] { lock.lock(); defer { lock.unlock() }; return _all }
        var finishTime: Date? { lock.lock(); defer { lock.unlock() }; return finishedAt }
        func add(_ e: SpanDACPairingEvent) {
            lock.lock(); _all.append(e)
            if case .finished = e { finishedAt = Date() }
            lock.unlock()
            if case .finished = e { finished.signal() }
            if case .code = e { code.signal() }
        }
        var result: Result<SpanDACPairResult, SpanDACPairFailure>? {
            for e in all.reversed() { if case .finished(let r) = e { return r } }
            return nil
        }
    }

    private func source() -> TestSource {
        TestSource(id: "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F", name: "Loopback iPad",
                   privateKey: .init(), nonce: SpanDACPair.freshNonce())
    }

    private func begin(_ port: UInt16, events: Events, save: @escaping (SpanDACPairResult) -> String? = { _ in nil })
        -> SpanDACPairingHandle {
        SpanDACNetworkPairing(fixedHost: "127.0.0.1", closeWait: 5)
            .begin(serviceName: "unused", port: port, controllerID: UUID().uuidString,
                   controllerName: "MusicTUI on Test Mac", save: save, events: events.add)
    }

    /// y on both sides: the same code on both screens, the pair saved before
    /// `done`, and success reported only after the source closed.
    func testAPairingOverTCPSavesAndWaitsForTheSourceToClose() throws {
        let src = source()
        let responder = try LoopbackPairingPeer(source: src, closeDelay: 0.4)
        defer { responder.stop() }
        let events = Events()
        var saved: SpanDACPairResult?
        let handle = begin(responder.port, events: events, save: { saved = $0; return nil })
        XCTAssertEqual(events.code.wait(timeout: .now() + 5), .success)
        guard case .code(let code, let name)? = events.all.first else { return XCTFail("no code: \(events.all)") }
        XCTAssertEqual(code, src.codeShown, "both screens show the same code")
        XCTAssertEqual(name, "Loopback iPad")
        handle.answer(matches: true)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 8), .success)
        guard case .success(let pair)? = events.result else { return XCTFail("\(events.all)") }
        XCTAssertEqual(pair, saved)
        XCTAssertEqual(pair.pairKey, src.pairKey)
        XCTAssertEqual(pair.pskID, src.pskIdentity)
        XCTAssertTrue(src.gotDone, "the source got done")
        XCTAssertTrue(events.all.contains(.confirming))
        let closed = try XCTUnwrap(responder.closedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(events.finishTime), closed,
                                    "success must wait for the source to close the pairing connection")
    }

    func testAnsweringNoSavesNothingAndTheSourceSeesRejected() throws {
        let src = source()
        let responder = try LoopbackPairingPeer(source: src)
        defer { responder.stop() }
        let events = Events()
        var saves = 0
        let handle = begin(responder.port, events: events, save: { _ in saves += 1; return nil })
        XCTAssertEqual(events.code.wait(timeout: .now() + 5), .success)
        handle.answer(matches: false)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.result, .failure(.codesDiffer))
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(src.gotDone)
    }

    /// The iPad's "Not this" after the controller's y: nothing is saved.
    func testTheIPadsNotThisSavesNothing() throws {
        let responder = try LoopbackPairingPeer(source: source(), rejectConfirm: true)
        defer { responder.stop() }
        let events = Events()
        var saves = 0
        let handle = begin(responder.port, events: events, save: { _ in saves += 1; return nil })
        XCTAssertEqual(events.code.wait(timeout: .now() + 5), .success)
        handle.answer(matches: true)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.result, .failure(.codesDiffer))
        XCTAssertEqual(saves, 0)
    }

    /// A save that fails sends no `done`, so the source keeps nothing either.
    func testAFailedSaveSendsNoDone() throws {
        let src = source()
        let responder = try LoopbackPairingPeer(source: src)
        defer { responder.stop() }
        let events = Events()
        let handle = begin(responder.port, events: events, save: { _ in "disk full" })
        XCTAssertEqual(events.code.wait(timeout: .now() + 5), .success)
        handle.answer(matches: true)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.result, .failure(.notSaved("disk full")))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(src.gotDone)
    }

    /// The device's three "not now" refusals each keep their own failure, so
    /// the Output tab can show why without calling the device pairable again.
    func testAClosedWindowOrABusySourceIsSaidInWords() throws {
        for (reason, failure) in [("closed", SpanDACPairFailure.windowClosed), ("busy", .busy), ("too_many", .tooMany)] {
            let responder = try LoopbackPairingPeer(source: source(), abortAtHello: reason)
            defer { responder.stop() }
            let events = Events()
            _ = begin(responder.port, events: events)
            XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(events.result, .failure(failure), reason)
        }
    }

    /// Nothing listening on the pairing port: the device is not ready to pair
    /// (its listener is gone, e.g. the app went to the background).
    func testNothingListeningIsAClosedWindow() throws {
        let responder = try LoopbackPairingPeer(source: source())
        let port = responder.port
        responder.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let events = Events()
        _ = begin(port, events: events)
        XCTAssertEqual(events.finished.wait(timeout: .now() + 12), .success)
        XCTAssertEqual(events.result, .failure(.windowClosed))
    }

    func testCancelEndsTheSession() throws {
        let responder = try LoopbackPairingPeer(source: source())
        defer { responder.stop() }
        let events = Events()
        let handle = begin(responder.port, events: events)
        XCTAssertEqual(events.code.wait(timeout: .now() + 5), .success)
        handle.cancel()
        XCTAssertEqual(events.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.result, .failure(.cancelled))
    }
}

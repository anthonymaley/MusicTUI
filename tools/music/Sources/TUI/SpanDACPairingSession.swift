// One `spandac-pair/1` session over the network: the controller state machine
// (`SpanDACPairingController`) driven over a plain TCP connection to the
// SpanDAC's pairing port, which is open only while the device is pairable
// (in the foreground and accepting). A refused connect means it is not.
//
// What this adds to the pure half: the connection, one-line framing (4,096
// bytes at most), the per-phase timeouts, the person's y/n, the save, and
// one rule from the source's side (measured when the source was built): after
// `done`, WAIT for the source to close the pairing connection before the
// first TLS request. The source restarts its paired listener to take the new
// key and closes the pairing connection once that listener is ready; a TLS
// request sent before then was refused (connection refused, 3/3).
import Foundation
import Network

enum SpanDACPairingEvent: Equatable {
    /// Show the code and the SpanDAC's name, and ask y/n.
    case code(String, sourceName: String)
    /// The person said y; waiting for the SpanDAC's own confirmation (its
    /// "Matches" tap).
    case confirming
    case finished(Result<SpanDACPairResult, SpanDACPairFailure>)
}

extension SpanDACPairFailure: Error {}

/// What the Output tab holds while a session runs.
protocol SpanDACPairingHandle: AnyObject {
    func answer(matches: Bool)
    func cancel()
}

protocol SpanDACPairingDriving {
    /// Starts a session with the SpanDAC whose pairing port is `port` on the
    /// host its service resolves to. `save` writes the pair and returns nil,
    /// or why it could not. Events arrive on a private queue.
    func begin(serviceName: String, port: UInt16, controllerID: String, controllerName: String,
               save: @escaping (SpanDACPairResult) -> String?,
               events: @escaping (SpanDACPairingEvent) -> Void) -> SpanDACPairingHandle
}

/// The live driver: Network.framework, plain TCP.
struct SpanDACNetworkPairing: SpanDACPairingDriving {
    var resolver: SpanDACResolving = SpanDACBonjourResolver()
    /// TEST SEAM: connect here instead of resolving the service.
    var fixedHost: String? = nil
    /// How long to wait for the source to close after `done` (section 3.5:
    /// ten seconds for `done`).
    var closeWait: TimeInterval = 10

    func begin(serviceName: String, port: UInt16, controllerID: String, controllerName: String,
               save: @escaping (SpanDACPairResult) -> String?,
               events: @escaping (SpanDACPairingEvent) -> Void) -> SpanDACPairingHandle {
        let session = Session(controller: SpanDACPairingController(controllerID: controllerID, controllerName: controllerName),
                              save: save, events: events, closeWait: closeWait)
        session.queue.async {
            let host: String
            if let fixedHost {
                host = fixedHost
            } else if let location = resolver.locate(serviceName: serviceName, timeout: 5),
                      let address = resolver.addresses(of: location, timeout: 5).first {
                host = address
            } else {
                session.end(.failure(.broken("SpanDAC was not found on this network")))
                return
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                session.end(.failure(.broken("the pairing port is not usable")))
                return
            }
            session.connect(NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp))
        }
        return session
    }

    /// One session. Every state change happens on `queue`.
    final class Session: SpanDACPairingHandle {
        let queue = DispatchQueue(label: "spandac.pairing")
        private var controller: SpanDACPairingController
        private let save: (SpanDACPairResult) -> String?
        private let events: (SpanDACPairingEvent) -> Void
        private let closeWait: TimeInterval
        private var connection: NWConnection?
        private var buffer = Data()
        private var timer: DispatchWorkItem?
        private var ended = false
        /// Set once the pair is saved and `done` sent: now only the close is
        /// awaited.
        private var paired: SpanDACPairResult?
        /// A running session keeps itself alive until it ends, whether or not
        /// the caller still holds its handle.
        private var keepAlive: Session?

        init(controller: SpanDACPairingController, save: @escaping (SpanDACPairResult) -> String?,
             events: @escaping (SpanDACPairingEvent) -> Void, closeWait: TimeInterval) {
            self.controller = controller
            self.save = save
            self.events = events
            self.closeWait = closeWait
            keepAlive = self
        }

        func connect(_ connection: NWConnection) {
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.apply(self.controller.start())
                    self.receive()
                case .waiting(let error), .failed(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        // Nothing listening: the device is not ready to pair.
                        self.end(.failure(.windowClosed))
                    } else if case .failed = state {
                        self.end(.failure(.broken("\(error)")))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            // The connect itself is bounded like a protocol step.
            arm(SpanDACPairingController.stepTimeout)
        }

        func answer(matches: Bool) {
            queue.async { self.apply(self.controller.personAnswered(matches: matches)) }
        }

        func cancel() {
            queue.async {
                guard !self.ended else { return }
                let outputs = self.controller.cancel()
                self.apply(outputs.isEmpty ? [.failed(.cancelled)] : outputs)
            }
        }

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self, !self.ended else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(data: self.buffer[..<newline], encoding: .utf8) ?? ""
                    self.buffer.removeSubrange(...newline)
                    self.apply(self.controller.receive(line))
                    if self.ended { return }
                }
                if self.buffer.count > SpanDACPair.maximumLineBytes {
                    self.apply(self.controller.receive(String(repeating: "x", count: SpanDACPair.maximumLineBytes + 1)))
                    return
                }
                if isComplete || error != nil {
                    // The close that follows `done` is the success signal.
                    if let paired = self.paired {
                        self.end(.success(paired))
                    } else {
                        self.apply(self.controller.disconnected())
                    }
                    return
                }
                self.receive()
            }
        }

        private func apply(_ outputs: [SpanDACPairingController.Output]) {
            guard !ended else { return }
            for output in outputs {
                switch output {
                case .send(let line):
                    connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
                case .showCode(let code, let name):
                    events(.code(code, sourceName: name))
                case .save(let result):
                    apply(controller.saved(save(result)))
                    return
                case .paired(let result):
                    // `done` is on its way; wait for the source to close.
                    paired = result
                    arm(closeWait)
                    return
                case .failed(let failure):
                    end(.failure(failure))
                    return
                }
            }
            if controller.phase == .awaitingConfirm { events(.confirming) }
            if let timeout = controller.timeout { arm(timeout) }
        }

        private func arm(_ seconds: TimeInterval) {
            timer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.ended else { return }
                if let paired = self.paired {
                    // Saved on both sides; the source was slow to close. The
                    // pair stands; the first request may meet a listener that
                    // is still restarting and will say so in words.
                    self.end(.success(paired))
                } else if self.connection?.state != .ready {
                    self.end(.failure(.timedOut))
                } else {
                    self.apply(self.controller.timedOut())
                }
            }
            timer = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        func end(_ result: Result<SpanDACPairResult, SpanDACPairFailure>) {
            queue.async {
                guard !self.ended else { return }
                self.ended = true
                self.timer?.cancel()
                defer { self.keepAlive = nil }
                // Let a final abort line leave before the close.
                let connection = self.connection
                self.queue.asyncAfter(deadline: .now() + 0.2) { connection?.cancel() }
                self.events(.finished(result))
            }
        }
    }
}

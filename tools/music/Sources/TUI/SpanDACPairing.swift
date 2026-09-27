// The controller's half of `spandac-pair/1`: how MusicTUI pairs with SpanDAC
// on an iPad by comparing a six-digit code shown on both screens.
//
// Written from the protocol text (the pairing design, section 3.5), not from
// the source's implementation: the two ends are checked against the SAME
// published vector file (`Tests/MusicTests/Fixtures/spandac-pair-1-vectors.json`),
// never against each other.
//
// In one paragraph: each side picks a fresh P-256 key and a 32-byte nonce and
// sends a commitment to them (a SHA-256 hash) before revealing either, so a
// party in the middle cannot choose its values after seeing ours. From the ECDH
// secret and a transcript of everything said, HKDF derives the pair's TLS key
// (`K_pair`), its opaque TLS identity (`psk_id`), two confirmation keys and a
// four-byte value reduced to the six digits both screens show. Each side then
// proves it derived the same secret with an HMAC over the transcript, and only
// then is anything saved.
//
// Pure: no sockets, no clock, no files. `SpanDACPairingSession` drives it over
// the network and `SpanDACPairedStore` keeps the result.
import CryptoKit
import Foundation

// MARK: - Primitives

enum SpanDACPair {

    static let protocolName = "spandac-pair/1"

    /// The longest line either side may send, newline excluded. A longer line
    /// aborts the session.
    static let maximumLineBytes = 4096

    /// Which side wrote a commitment or a confirmation. Bound into both, so a
    /// value computed by one role is never accepted as the other's.
    enum Role: UInt8 {
        case controller = 0x00
        case source = 0x01
    }

    // MARK: Encodings

    /// `LP(x)`: a two-byte big-endian length, then `x`. Every field this is
    /// applied to is validated to far less than 65,535 bytes first.
    static func lp(_ bytes: Data) -> Data {
        precondition(bytes.count <= Int(UInt16.max), "LP field too long")
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        out.append(bytes)
        return out
    }

    static func lp(_ text: String) -> Data { lp(Data(text.utf8)) }

    /// Base64url without padding (RFC 4648 section 5), as every byte string is
    /// sent on the wire.
    static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: the URL alphabet only, no padding, no whitespace, and a length
    /// that is a whole number of bytes. Anything else is nil, which aborts.
    static func fromBase64url(_ text: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)
        guard text.unicodeScalars.allSatisfy(alphabet.contains), text.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        guard let data = Data(base64Encoded: standard), base64url(data) == text else { return nil }
        return data
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func fromHex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    // MARK: Validation (before anything is hashed)

    /// A canonical uppercase UUID string, exactly 36 characters.
    static func isCanonicalID(_ id: String) -> Bool {
        id.utf8.count == 36 && UUID(uuidString: id)?.uuidString == id
    }

    /// 1 to 64 UTF-8 bytes and no control characters.
    static func isValidName(_ name: String) -> Bool {
        let bytes = name.utf8.count
        guard bytes >= 1, bytes <= 64 else { return false }
        return !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// A name this Mac can offer: control characters dropped, then cut to 64
    /// UTF-8 bytes on a character boundary. Nil only if nothing is left.
    static func fittedName(_ raw: String) -> String? {
        var kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }))
        kept = kept.trimmingCharacters(in: .whitespaces)
        while kept.utf8.count > 64 { kept.removeLast() }
        return isValidName(kept) ? kept : nil
    }

    /// A peer's public key: X9.63 uncompressed, exactly 65 bytes starting 0x04,
    /// on the curve. A compressed key, any other length, or a point CryptoKit
    /// rejects is nil, which aborts the session.
    static func publicKey(x963 bytes: Data) -> P256.KeyAgreement.PublicKey? {
        guard bytes.count == 65, bytes.first == 0x04 else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: bytes)
    }

    // MARK: Derivations

    /// `SHA256("spandac-commit/1" || role || LP(pk) || LP(n))`.
    static func commitment(role: Role, publicKey: Data, nonce: Data) -> Data {
        var input = Data("spandac-commit/1".utf8)
        input.append(role.rawValue)
        input.append(lp(publicKey))
        input.append(lp(nonce))
        return Data(SHA256.hash(data: input))
    }

    /// `T`: the protocol name, then every value either side contributed, in a
    /// fixed order with the controller's before the source's.
    static func transcript(cid: String, sid: String, cname: String, sname: String,
                           pkC: Data, pkS: Data, nC: Data, nS: Data) -> Data {
        var t = Data(protocolName.utf8)
        for field in [lp(cid), lp(sid), lp(cname), lp(sname), lp(pkC), lp(pkS), lp(nC), lp(nS)] {
            t.append(field)
        }
        return t
    }

    /// Everything the pair is built from, derived from the ECDH secret `Z` and
    /// the transcript.
    struct Keys: Equatable {
        /// The TLS 1.2 pre-shared key for every later connection.
        let pairKey: Data
        /// The pair's TLS identity, 16 bytes, sent as 32 lowercase hex characters.
        let pskID: Data
        let confirmKeyController: Data
        let confirmKeySource: Data
        /// Four bytes, reduced to the six-digit code.
        let sas: Data
        let salt: Data

        /// The identity string the client presents in the handshake.
        var pskIdentity: String { SpanDACPair.hex(pskID) }

        /// `UInt32(bigEndian: sas) mod 1_000_000`.
        var code: Int {
            let value = sas.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Int(value % 1_000_000)
        }

        /// Six digits with leading zeros.
        var codeDigits: String { String(format: "%06d", code) }

        /// As both screens show it: `NNN NNN`.
        var codeDisplay: String {
            let digits = codeDigits
            return "\(digits.prefix(3)) \(digits.suffix(3))"
        }
    }

    static func derive(z: Data, transcript: Data) -> Keys {
        let salt = Data(SHA256.hash(data: transcript))
        func hkdf(_ info: String, _ length: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: z), salt: salt,
                                   info: Data(info.utf8), outputByteCount: length)
                .withUnsafeBytes { Data($0) }
        }
        return Keys(pairKey: hkdf("spandac-pair/1 psk", 32),
                    pskID: hkdf("spandac-pair/1 psk-id", 16),
                    confirmKeyController: hkdf("spandac-pair/1 confirm-c", 32),
                    confirmKeySource: hkdf("spandac-pair/1 confirm-s", 32),
                    sas: hkdf("spandac-pair/1 sas", 4),
                    salt: salt)
    }

    /// The raw ECDH shared secret: the 32-byte x-coordinate.
    static func sharedSecret(_ privateKey: P256.KeyAgreement.PrivateKey,
                             _ peer: P256.KeyAgreement.PublicKey) throws -> Data {
        try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }

    /// `HMAC(K, "spandac-confirm/1" || role || T)`.
    static func confirmation(key: Data, role: Role, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: confirmationInput(role: role, transcript: transcript),
                                             using: SymmetricKey(data: key)))
    }

    /// Checked in constant time.
    static func isValidConfirmation(_ mac: Data, key: Data, role: Role, transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: confirmationInput(role: role, transcript: transcript),
                                               using: SymmetricKey(data: key))
    }

    private static func confirmationInput(role: Role, transcript: Data) -> Data {
        var input = Data("spandac-confirm/1".utf8)
        input.append(role.rawValue)
        input.append(transcript)
        return input
    }

    /// 32 bytes from the system CSPRNG.
    static func freshNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

// MARK: - Messages

/// One line of `spandac-pair/1`, as the controller sends or reads it.
enum SpanDACPairMessage: Equatable {
    case hello(id: String, name: String)
    case commit(Data)
    case reveal(publicKey: Data, nonce: Data)
    case confirm(Data)
    case done
    case abort(String)

    /// Abort reasons (section 3.5). Only `busy` and `closed` are not failures.
    enum Reason {
        static let closed = "closed", busy = "busy", version = "version", format = "format",
                   commit = "commit", confirm = "confirm", timeout = "timeout",
                   rejected = "rejected", tooMany = "too_many"
    }

    /// The controller's lines. Built by hand, in a fixed key order, so the same
    /// inputs always produce the same bytes (the published transcript's).
    func controllerLine() -> String {
        switch self {
        case .hello(let id, let name):
            return Self.json([("t", .text("hello")), ("v", .number(1)), ("cid", .text(id)), ("cname", .text(name))])
        case .commit(let h):
            return Self.json([("t", .text("commit")), ("h", .text(SpanDACPair.base64url(h)))])
        case .reveal(let pk, let n):
            return Self.json([("t", .text("reveal")), ("pk", .text(SpanDACPair.base64url(pk))),
                              ("n", .text(SpanDACPair.base64url(n)))])
        case .confirm(let mac):
            return Self.json([("t", .text("confirm")), ("mac", .text(SpanDACPair.base64url(mac)))])
        case .done:
            return Self.json([("t", .text("done"))])
        case .abort(let reason):
            return Self.json([("t", .text("abort")), ("reason", .text(reason))])
        }
    }

    /// Why a line from the source could not be read.
    enum ParseFailure: Error, Equatable {
        /// A `hello` whose `v` is not 1.
        case version
        /// Anything else: not JSON, too long, an unknown `t`, a missing or
        /// ill-formed field.
        case format
    }

    /// A line the SOURCE sent. Its `hello` carries `sid` and `sname`; byte
    /// strings are strict base64url with the lengths the protocol fixes; ids
    /// and names are validated here, before anything is hashed.
    static func parseSourceLine(_ line: String) -> Result<SpanDACPairMessage, ParseFailure> {
        guard line.utf8.count <= SpanDACPair.maximumLineBytes,
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = object["t"] as? String else { return .failure(.format) }
        func bytes(_ key: String, _ length: Int) -> Data? {
            guard let text = object[key] as? String, let value = SpanDACPair.fromBase64url(text),
                  value.count == length else { return nil }
            return value
        }
        switch t {
        case "hello":
            guard let v = object["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID() else {
                return .failure(.format)
            }
            guard v.intValue == 1, v.doubleValue == 1 else { return .failure(.version) }
            guard let sid = object["sid"] as? String, SpanDACPair.isCanonicalID(sid),
                  let sname = object["sname"] as? String, SpanDACPair.isValidName(sname) else {
                return .failure(.format)
            }
            return .success(.hello(id: sid, name: sname))
        case "commit":
            guard let h = bytes("h", 32) else { return .failure(.format) }
            return .success(.commit(h))
        case "reveal":
            guard let pk = bytes("pk", 65), let n = bytes("n", 32) else { return .failure(.format) }
            return .success(.reveal(publicKey: pk, nonce: n))
        case "confirm":
            guard let mac = bytes("mac", 32) else { return .failure(.format) }
            return .success(.confirm(mac))
        case "abort":
            guard let reason = object["reason"] as? String else { return .failure(.format) }
            return .success(.abort(reason))
        default:
            return .failure(.format)
        }
    }

    private enum Value {
        case text(String)
        case number(Int)
    }

    private static func json(_ fields: [(String, Value)]) -> String {
        let body = fields.map { key, value -> String in
            switch value {
            case .text(let s): return "\"\(key)\":\(quote(s))"
            case .number(let n): return "\"\(key)\":\(n)"
            }
        }
        return "{" + body.joined(separator: ",") + "}"
    }

    /// A JSON string: quote, backslash and control characters escaped, all
    /// other characters as themselves (UTF-8 on the wire).
    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - The controller's session

/// What a finished pairing leaves on this Mac.
struct SpanDACPairResult: Equatable {
    let sourceID: String
    let sourceName: String
    let pskID: String
    let pairKey: Data
}

/// Why a pairing ended with nothing saved, in words for the status line.
enum SpanDACPairFailure: Equatable {
    /// The iPad's pairing window is not open.
    case windowClosed
    /// The iPad is pairing with someone else.
    case busy
    /// The iPad speaks another pairing version.
    case version
    /// The person answered "n", the iPad answered "Not this", or the codes or
    /// confirmations did not match: the MITM outcome and the honest mismatch
    /// read the same, because the protocol cannot tell them apart.
    case codesDiffer
    /// A step did not arrive in time.
    case timedOut
    /// The iPad sent something this build cannot read, or aborted for a
    /// reason with no sentence of its own.
    case broken(String)
    /// The connection dropped mid-session.
    case disconnected
    /// The pair could not be written on this Mac, so nothing was confirmed.
    case notSaved(String)
    /// The person cancelled on this Mac.
    case cancelled

    /// The status-line sentence (section 4.3).
    var sentence: String {
        switch self {
        case .windowClosed: return "SpanDAC is not ready to pair. Tap Pair with MusicTUI on the iPad, then try again."
        case .busy: return "SpanDAC is pairing with another Mac; try again in a moment."
        case .version: return "SpanDAC uses a different pairing version; update MusicTUI or SpanDAC."
        case .codesDiffer: return "Codes differ; nothing was paired. Try again from the iPad."
        case .timedOut: return "Pairing timed out; nothing was paired. Try again from the iPad."
        case .broken(let why): return "Pairing failed (\(why)); nothing was paired."
        case .disconnected: return "The iPad closed the pairing connection; nothing was paired."
        case .notSaved(let why): return "Couldn't save the pairing on this Mac (\(why)); nothing was paired."
        case .cancelled: return "Pairing cancelled; nothing was paired."
        }
    }
}

/// The controller's `spandac-pair/1` state machine (section 3.5, role C).
///
/// Fed lines, the person's answer and timeouts; answers with lines to send and
/// what to show. It never persists: it hands back `.save` and waits for the
/// driver to say whether the write succeeded, because `done` must only follow
/// a pair that is really on disk (the source keeps its copy only on `done`).
struct SpanDACPairingController {

    enum Phase: Equatable {
        case idle
        case awaitingHello
        case awaitingCommit
        case awaitingReveal
        /// The code is on screen; waiting for the person's y or n.
        case awaitingPerson
        /// `MC` sent; waiting for the source's confirmation.
        case awaitingConfirm
        /// `MS` verified; waiting for the driver to save.
        case saving
        case finished
        case failed
    }

    enum Output: Equatable {
        case send(String)
        /// Show `code` (as `NNN NNN`) and the source's name, and ask y/n.
        case showCode(code: String, sourceName: String)
        /// Write this pair, then call `saved(_:)`.
        case save(SpanDACPairResult)
        case paired(SpanDACPairResult)
        case failed(SpanDACPairFailure)
    }

    /// Ten seconds for each of messages 1 to 6 (section 3.5, Limits).
    static let stepTimeout: TimeInterval = 10
    /// The confirm phase is bounded by the source's 120 s window.
    static let confirmTimeout: TimeInterval = 120

    private(set) var phase: Phase = .idle

    let controllerID: String
    let controllerName: String
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var nonce: Data
    private var publicKey: Data { privateKey.publicKey.x963Representation }

    private var sourceID = ""
    private var sourceName = ""
    private var sourceCommitment = Data()
    private var transcript = Data()
    private var keys: SpanDACPair.Keys?

    /// How long the driver may wait for the next input in this phase; nil
    /// when nothing is awaited.
    var timeout: TimeInterval? {
        switch phase {
        case .awaitingHello, .awaitingCommit, .awaitingReveal: return Self.stepTimeout
        case .awaitingPerson, .awaitingConfirm: return Self.confirmTimeout
        case .idle, .saving, .finished, .failed: return nil
        }
    }

    /// `privateKey` and `nonce` are injectable only so the published vectors
    /// can be reproduced; production passes neither.
    init(controllerID: String, controllerName: String,
         privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
         nonce: Data = SpanDACPair.freshNonce()) {
        self.controllerID = controllerID
        self.controllerName = controllerName
        self.privateKey = privateKey
        self.nonce = nonce
    }

    /// Message 1. Refuses to start with an id or name the protocol would
    /// reject, so the source never sees one.
    mutating func start() -> [Output] {
        guard phase == .idle else { return [] }
        guard SpanDACPair.isCanonicalID(controllerID), SpanDACPair.isValidName(controllerName) else {
            phase = .failed
            return [.failed(.broken("this Mac's name or id is not usable"))]
        }
        phase = .awaitingHello
        return [.send(SpanDACPairMessage.hello(id: controllerID, name: controllerName).controllerLine())]
    }

    /// One line from the source.
    mutating func receive(_ line: String) -> [Output] {
        guard phase != .idle, phase != .finished, phase != .failed, phase != .saving else { return [] }
        let message: SpanDACPairMessage
        switch SpanDACPairMessage.parseSourceLine(line) {
        case .success(let parsed): message = parsed
        case .failure(.version): return fail(.version, abort: SpanDACPairMessage.Reason.version)
        case .failure(.format): return fail(.broken("unreadable message"), abort: SpanDACPairMessage.Reason.format)
        }
        if case .abort(let reason) = message {
            phase = .failed
            return [.failed(Self.failure(forSourceAbort: reason))]
        }
        switch (phase, message) {
        case (.awaitingHello, .hello(let sid, let sname)):
            sourceID = sid
            sourceName = sname
            phase = .awaitingCommit
            let h = SpanDACPair.commitment(role: .controller, publicKey: publicKey, nonce: nonce)
            return [.send(SpanDACPairMessage.commit(h).controllerLine())]
        case (.awaitingCommit, .commit(let h)):
            sourceCommitment = h
            phase = .awaitingReveal
            return [.send(SpanDACPairMessage.reveal(publicKey: publicKey, nonce: nonce).controllerLine())]
        case (.awaitingReveal, .reveal(let pkS, let nS)):
            // Message 6: the source's reveal must open the commitment it sent
            // BEFORE it saw ours, under the source's role byte.
            guard SpanDACPair.commitment(role: .source, publicKey: pkS, nonce: nS) == sourceCommitment else {
                return fail(.codesDiffer, abort: SpanDACPairMessage.Reason.commit)
            }
            guard let peer = SpanDACPair.publicKey(x963: pkS),
                  var z = try? SpanDACPair.sharedSecret(privateKey, peer) else {
                return fail(.broken("the iPad's key is not usable"), abort: SpanDACPairMessage.Reason.format)
            }
            transcript = SpanDACPair.transcript(cid: controllerID, sid: sourceID, cname: controllerName,
                                                sname: sourceName, pkC: publicKey, pkS: pkS, nC: nonce, nS: nS)
            let derived = SpanDACPair.derive(z: z, transcript: transcript)
            // Zeroise what this code holds. CryptoKit's own copies are out of
            // reach; the private key goes when this value does.
            z.resetBytes(in: 0..<z.count)
            nonce.resetBytes(in: 0..<nonce.count)
            keys = derived
            phase = .awaitingPerson
            return [.showCode(code: derived.codeDisplay, sourceName: sourceName)]
        case (.awaitingConfirm, .confirm(let ms)):
            guard let keys, SpanDACPair.isValidConfirmation(ms, key: keys.confirmKeySource, role: .source,
                                                            transcript: transcript) else {
                return fail(.codesDiffer, abort: SpanDACPairMessage.Reason.confirm)
            }
            phase = .saving
            return [.save(SpanDACPairResult(sourceID: sourceID, sourceName: sourceName,
                                            pskID: keys.pskIdentity, pairKey: keys.pairKey))]
        default:
            // Out of order, or a message the controller never receives.
            return fail(.broken("message out of order"), abort: SpanDACPairMessage.Reason.format)
        }
    }

    /// Message 9: the person's y (the codes match) or n.
    mutating func personAnswered(matches: Bool) -> [Output] {
        guard phase == .awaitingPerson, let keys else { return [] }
        guard matches else { return fail(.codesDiffer, abort: SpanDACPairMessage.Reason.rejected) }
        phase = .awaitingConfirm
        let mc = SpanDACPair.confirmation(key: keys.confirmKeyController, role: .controller, transcript: transcript)
        return [.send(SpanDACPairMessage.confirm(mc).controllerLine())]
    }

    /// Message 11's second half, after the driver tried to write the pair.
    /// Only a pair that is on disk earns `done`; a failed write sends nothing,
    /// so the source, which keeps its copy only on `done`, keeps nothing.
    mutating func saved(_ error: String?) -> [Output] {
        guard phase == .saving, let keys else { return [] }
        if let error {
            phase = .failed
            return [.failed(.notSaved(error))]
        }
        phase = .finished
        return [.send(SpanDACPairMessage.done.controllerLine()),
                .paired(SpanDACPairResult(sourceID: sourceID, sourceName: sourceName,
                                          pskID: keys.pskIdentity, pairKey: keys.pairKey))]
    }

    /// The phase's timeout passed with nothing received.
    mutating func timedOut() -> [Output] {
        guard timeout != nil else { return [] }
        return fail(.timedOut, abort: SpanDACPairMessage.Reason.timeout)
    }

    /// The connection closed under a live session.
    mutating func disconnected() -> [Output] {
        guard phase != .idle, phase != .finished, phase != .failed else { return [] }
        phase = .failed
        return [.failed(.disconnected)]
    }

    /// The person cancelled (Esc) before the session finished.
    mutating func cancel() -> [Output] {
        guard phase != .idle, phase != .finished, phase != .failed, phase != .saving else { return [] }
        return fail(.cancelled, abort: SpanDACPairMessage.Reason.rejected)
    }

    private mutating func fail(_ failure: SpanDACPairFailure, abort reason: String) -> [Output] {
        phase = .failed
        return [.send(SpanDACPairMessage.abort(reason).controllerLine()), .failed(failure)]
    }

    static func failure(forSourceAbort reason: String) -> SpanDACPairFailure {
        switch reason {
        case SpanDACPairMessage.Reason.closed: return .windowClosed
        case SpanDACPairMessage.Reason.busy: return .busy
        case SpanDACPairMessage.Reason.version: return .version
        case SpanDACPairMessage.Reason.rejected, SpanDACPairMessage.Reason.commit,
             SpanDACPairMessage.Reason.confirm: return .codesDiffer
        case SpanDACPairMessage.Reason.timeout: return .timedOut
        case SpanDACPairMessage.Reason.tooMany: return .broken("too many failed attempts; open the window again")
        default: return .broken("the iPad aborted: \(reason)")
        }
    }
}

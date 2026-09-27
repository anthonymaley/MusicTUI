// tools/music/Tests/MusicTests/SpanDACPairingTests.swift
//
// The controller's half of `spandac-pair/1` against the published vector file,
// `Fixtures/spandac-pair-1-vectors.json`. That file is protocol data shared by
// both ends: each end is written against the protocol text and must reproduce
// every field, so a transcript encoded differently fails HERE, not at the first
// TLS handshake with a real iPad.
import CryptoKit
import XCTest
@testable import music

final class SpanDACPairingTests: XCTestCase {

    // MARK: - Fixture

    private static let vectors: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spandac-pair-1-vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func object(_ path: String...) -> [String: Any] {
        var node: Any = Self.vectors
        for key in path { node = (node as! [String: Any])[key]! }
        return node as! [String: Any]
    }

    private func hex(_ dict: [String: Any], _ key: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard let text = dict[key] as? String, let data = SpanDACPair.fromHex(text) else {
            XCTFail("no hex field \(key)", file: file, line: line)
            return Data()
        }
        return data
    }

    private struct Inputs {
        let cid, sid, cname, sname: String
        let dC, dS, nC, nS: Data
    }

    private func inputs(_ dict: [String: Any]) -> Inputs {
        Inputs(cid: dict["cid"] as! String, sid: dict["sid"] as! String,
               cname: dict["cname"] as! String, sname: dict["sname"] as! String,
               dC: hex(dict, "dC"), dS: hex(dict, "dS"), nC: hex(dict, "nC"), nS: hex(dict, "nS"))
    }

    private func key(_ scalar: Data) -> P256.KeyAgreement.PrivateKey {
        try! P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
    }

    /// Everything one side derives from a set of inputs, computed here from
    /// the primitives alone.
    private struct Derived {
        let pkC, pkS, hc, hs, transcript, z: Data
        let keys: SpanDACPair.Keys
        let mc, ms: Data
    }

    private func derive(_ i: Inputs) -> Derived {
        let c = key(i.dC), s = key(i.dS)
        let pkC = c.publicKey.x963Representation, pkS = s.publicKey.x963Representation
        let t = SpanDACPair.transcript(cid: i.cid, sid: i.sid, cname: i.cname, sname: i.sname,
                                       pkC: pkC, pkS: pkS, nC: i.nC, nS: i.nS)
        let z = try! SpanDACPair.sharedSecret(c, s.publicKey)
        let keys = SpanDACPair.derive(z: z, transcript: t)
        return Derived(pkC: pkC, pkS: pkS,
                       hc: SpanDACPair.commitment(role: .controller, publicKey: pkC, nonce: i.nC),
                       hs: SpanDACPair.commitment(role: .source, publicKey: pkS, nonce: i.nS),
                       transcript: t, z: z, keys: keys,
                       mc: SpanDACPair.confirmation(key: keys.confirmKeyController, role: .controller, transcript: t),
                       ms: SpanDACPair.confirmation(key: keys.confirmKeySource, role: .source, transcript: t))
    }

    // MARK: - The base vector, every field

    func testTheFixtureIsThePublishedProtocolData() {
        XCTAssertEqual(Self.vectors["protocol"] as? String, "spandac-pair/1")
    }

    /// "Every scalar and nonce is SHA-256 of its *_label": the inputs are
    /// reproducible from their labels, not arbitrary bytes.
    func testEveryScalarAndNonceIsTheSHA256OfItsLabel() {
        for dict in [object("base", "inputs"), object("mitm", "inputs")] {
            for (name, value) in dict where name.hasSuffix("_label") {
                let field = String(name.dropLast("_label".count))
                XCTAssertEqual(hex(dict, field), Data(SHA256.hash(data: Data((value as! String).utf8))), field)
            }
        }
    }

    func testTheBaseVectorReproducesEveryField() {
        let base = object("base")
        let i = inputs(base["inputs"] as! [String: Any])
        let expected = base["expected"] as! [String: Any]
        let d = derive(i)

        XCTAssertEqual(d.pkC, hex(expected, "pkC"))
        XCTAssertEqual(d.pkS, hex(expected, "pkS"))
        XCTAssertEqual(d.hc, hex(expected, "HC"))
        XCTAssertEqual(d.hs, hex(expected, "HS"))
        XCTAssertEqual(d.transcript, hex(expected, "T"))
        XCTAssertEqual(d.z, hex(expected, "Z"))
        XCTAssertEqual(d.keys.salt, hex(expected, "salt"))
        XCTAssertEqual(d.keys.pairKey, hex(expected, "K_pair"))
        XCTAssertEqual(d.keys.pskID, hex(expected, "psk_id"))
        XCTAssertEqual(d.keys.pskIdentity, expected["psk_identity"] as? String)
        XCTAssertEqual(d.keys.confirmKeyController, hex(expected, "K_conf_C"))
        XCTAssertEqual(d.keys.confirmKeySource, hex(expected, "K_conf_S"))
        XCTAssertEqual(d.keys.sas, hex(expected, "sas"))
        XCTAssertEqual(d.keys.code, expected["code"] as? Int)
        XCTAssertEqual(d.keys.codeDigits, expected["code_digits"] as? String)
        XCTAssertEqual(d.keys.codeDisplay, expected["code_display"] as? String)
        XCTAssertEqual(d.mc, hex(expected, "MC"))
        XCTAssertEqual(d.ms, hex(expected, "MS"))
        // The identity is 32 lowercase hex characters (the TLS PSK identity).
        XCTAssertEqual(d.keys.pskIdentity.count, 32)
        XCTAssertEqual(d.keys.pskIdentity, d.keys.pskIdentity.lowercased())
    }

    // MARK: - The recorded exchange, driven through the controller

    private func recordedExchange() -> [(from: String, line: String)] {
        (object("base")["exchange"] as! [[String: String]]).map { ($0["from"]!, $0["line"]!) }
    }

    /// The controller, given the vector's private scalar and nonce, sends the
    /// recorded C lines byte for byte and accepts the recorded S lines.
    func testTheControllerReproducesTheRecordedExchangeByteForByte() {
        let i = inputs(object("base", "inputs"))
        let expected = object("base", "expected")
        var c = SpanDACPairingController(controllerID: i.cid, controllerName: i.cname,
                                         privateKey: key(i.dC), nonce: i.nC)
        var sent: [String] = []
        var shown: [SpanDACPairingController.Output] = []
        func take(_ outputs: [SpanDACPairingController.Output]) {
            for output in outputs {
                if case .send(let line) = output { sent.append(line) } else { shown.append(output) }
            }
        }
        take(c.start())
        for (from, line) in recordedExchange() where from == "S" {
            take(c.receive(line))
            if c.phase == .awaitingPerson { take(c.personAnswered(matches: true)) }
        }
        XCTAssertEqual(c.phase, .saving)
        let pair = SpanDACPairResult(sourceID: i.sid, sourceName: i.sname,
                                     pskID: expected["psk_identity"] as! String, pairKey: hex(expected, "K_pair"))
        XCTAssertEqual(shown, [.showCode(code: expected["code_display"] as! String, sourceName: i.sname), .save(pair)])
        take(c.saved(nil))
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(sent, recordedExchange().filter { $0.from == "C" }.map(\.line))
        XCTAssertEqual(shown.last, .paired(pair))
    }

    // MARK: - Single flips

    /// Changing any ONE of the eight bound inputs changes the code and the key:
    /// nothing the transcript carries can be altered without both screens and
    /// the pair's secret moving with it.
    func testEachSingleFlipChangesTheCodeAndTheKey() {
        let baseExpected = object("base", "expected")
        let flips = Self.vectors["single_flips"] as! [[String: Any]]
        XCTAssertEqual(Set(flips.map { $0["field"] as! String }),
                       ["pkC", "pkS", "nC", "nS", "cid", "sid", "cname", "sname"])
        for flip in flips {
            let field = flip["field"] as! String
            let i = inputs(flip["inputs"] as! [String: Any])
            let expected = flip["expected"] as! [String: Any]
            let d = derive(i)
            XCTAssertEqual(d.keys.code, expected["code"] as? Int, field)
            XCTAssertEqual(d.keys.pairKey, hex(expected, "K_pair"), field)
            XCTAssertEqual(d.keys.pskID, hex(expected, "psk_id"), field)
            XCTAssertEqual(d.keys.sas, hex(expected, "sas"), field)
            XCTAssertEqual(d.transcript, hex(expected, "T"), field)
            XCTAssertEqual(d.pkC, hex(expected, "pkC"), field)
            XCTAssertEqual(d.pkS, hex(expected, "pkS"), field)
            XCTAssertNotEqual(d.keys.code, baseExpected["code"] as? Int, field)
            XCTAssertNotEqual(d.keys.pairKey, hex(baseExpected, "K_pair"), field)
        }
    }

    // MARK: - MITM

    /// An attacker between C and S runs two sessions. The two screens show
    /// different codes, and C's confirmation from its session fails S's check
    /// in the other: nothing is paired with the attacker unless a person
    /// confirms two different codes.
    func testAManInTheMiddleEndsWithTwoDifferentCodesAndARefusedConfirmation() {
        let base = inputs(object("base", "inputs"))
        let m = object("mitm", "inputs")
        let cToM = derive(Inputs(cid: base.cid, sid: base.sid, cname: base.cname, sname: base.sname,
                                 dC: base.dC, dS: hex(m, "dM1"), nC: base.nC, nS: hex(m, "nM1")))
        let mToS = derive(Inputs(cid: base.cid, sid: base.sid, cname: base.cname, sname: base.sname,
                                 dC: hex(m, "dM2"), dS: base.dS, nC: hex(m, "nM2"), nS: base.nS))
        let expectedCM = object("mitm", "c_to_m"), expectedMS = object("mitm", "m_to_s")

        XCTAssertEqual(cToM.pkS, hex(expectedCM, "pkM1"))
        XCTAssertEqual(cToM.transcript, hex(expectedCM, "T"))
        XCTAssertEqual(cToM.keys.code, expectedCM["code"] as? Int)
        XCTAssertEqual(cToM.keys.pairKey, hex(expectedCM, "K_pair"))
        XCTAssertEqual(cToM.mc, hex(expectedCM, "MC"))
        XCTAssertEqual(mToS.pkC, hex(expectedMS, "pkM2"))
        XCTAssertEqual(mToS.transcript, hex(expectedMS, "T"))
        XCTAssertEqual(mToS.keys.code, expectedMS["code"] as? Int)
        XCTAssertEqual(mToS.keys.pairKey, hex(expectedMS, "K_pair"))
        XCTAssertEqual(mToS.keys.confirmKeyController, hex(expectedMS, "K_conf_C"))

        XCTAssertNotEqual(cToM.keys.code, mToS.keys.code, "code_C must differ from code_S")
        XCTAssertNotEqual(cToM.keys.pairKey, mToS.keys.pairKey)
        XCTAssertFalse(SpanDACPair.isValidConfirmation(cToM.mc, key: mToS.keys.confirmKeyController,
                                                       role: .controller, transcript: mToS.transcript),
                       "C's MC relayed into the other session must fail S's check")
    }

    /// The same, as sessions: the controller talks to an attacker playing the
    /// source, the real source talks to the attacker playing a controller.
    /// The controller's screen and the source's screen disagree.
    func testTheControllerSessionShowsADifferentCodeFromTheSourceItNeverReached() {
        let base = inputs(object("base", "inputs"))
        let m = object("mitm", "inputs")
        let attackerAsSource = TestSource(id: base.sid, name: base.sname, privateKey: key(hex(m, "dM1")), nonce: hex(m, "nM1"))
        let real = TestSource(id: base.sid, name: base.sname, privateKey: key(base.dS), nonce: base.nS)
        var controller = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname,
                                                  privateKey: key(base.dC), nonce: base.nC)
        var attackerAsController = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname,
                                                            privateKey: key(hex(m, "dM2")), nonce: hex(m, "nM2"))
        let controllerCode = runUntilCode(&controller, attackerAsSource)
        let sourceCode = runUntilCode(&attackerAsController, real)
        XCTAssertEqual(controllerCode, "443 146")
        XCTAssertEqual(sourceCode, "306 041")
        XCTAssertNotEqual(controllerCode, sourceCode)
        XCTAssertEqual(real.codeShown, sourceCode, "the source shows its own session's code")
    }

    // MARK: - Role separation and key encoding

    /// A commitment computed with the other role's byte is not accepted, so a
    /// source cannot reflect the controller's own commitment back at it.
    func testACommitmentUnderTheWrongRoleByteIsRefused() {
        let base = inputs(object("base", "inputs"))
        let sep = object("role_separation")
        let d = derive(base)
        XCTAssertEqual(SpanDACPair.commitment(role: .source, publicKey: d.pkC, nonce: base.nC),
                       hex(sep, "HC_with_source_role_byte"))
        XCTAssertEqual(SpanDACPair.commitment(role: .controller, publicKey: d.pkS, nonce: base.nS),
                       hex(sep, "HS_with_controller_role_byte"))
        XCTAssertNotEqual(hex(sep, "HC_with_source_role_byte"), d.hc)
        XCTAssertNotEqual(hex(sep, "HS_with_controller_role_byte"), d.hs)

        // Reflection: the source commits with the CONTROLLER's role byte over
        // its own key and nonce, then reveals them. The controller refuses.
        var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname,
                                         privateKey: key(base.dC), nonce: base.nC)
        _ = c.start()
        _ = c.receive(SpanDACPairTestLines.hello(base.sid, base.sname))
        _ = c.receive(SpanDACPairTestLines.commit(hex(sep, "HS_with_controller_role_byte")))
        let out = c.receive(SpanDACPairTestLines.reveal(d.pkS, base.nS))
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"commit"}"#), .failed(.codesDiffer)])
        XCTAssertEqual(c.phase, .failed)
    }

    /// A reveal whose key is 33 bytes (compressed) aborts with `format`.
    func testACompressedKeyInARevealAborts() {
        let base = inputs(object("base", "inputs"))
        let compressed = object("compressed_key")
        var c = controllerAtReveal(base)
        let out = c.receive(compressed["reveal_line"] as! String)
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"format"}"#), .failed(.broken("unreadable message"))])
        XCTAssertNil(SpanDACPair.publicKey(x963: hex(compressed, "pkS_compressed")))
    }

    func testARevealThatDoesNotOpenTheCommitmentAborts() {
        let base = inputs(object("base", "inputs"))
        var c = controllerAtReveal(base)
        let d = derive(base)
        var otherNonce = base.nS
        otherNonce[0] ^= 0x01
        let out = c.receive(SpanDACPairTestLines.reveal(d.pkS, otherNonce))
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"commit"}"#), .failed(.codesDiffer)])
    }

    /// The source's confirmation is checked; a wrong one aborts with
    /// `confirm` and nothing is handed to the store.
    func testAWrongSourceConfirmationAbortsAndNothingIsSaved() {
        let base = inputs(object("base", "inputs"))
        var c = controllerAtPerson(base)
        _ = c.personAnswered(matches: true)
        var ms = derive(base).ms
        ms[5] ^= 0x80
        let out = c.receive(SpanDACPairTestLines.confirm(ms))
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"confirm"}"#), .failed(.codesDiffer)])
        XCTAssertFalse(out.contains { if case .save = $0 { return true } else { return false } })
    }

    /// "n" sends `rejected` and saves nothing.
    func testAnsweringNoRejectsAndSavesNothing() {
        let base = inputs(object("base", "inputs"))
        var c = controllerAtPerson(base)
        XCTAssertEqual(c.personAnswered(matches: false),
                       [.send(#"{"t":"abort","reason":"rejected"}"#), .failed(.codesDiffer)])
        XCTAssertEqual(c.phase, .failed)
        XCTAssertEqual(c.receive(SpanDACPairTestLines.confirm(derive(base).ms)), [])
    }

    /// A pair that could not be written is never confirmed with `done`, so
    /// the source, which keeps its copy only on `done`, keeps nothing either.
    func testAFailedSaveSendsNoDone() {
        let base = inputs(object("base", "inputs"))
        var c = controllerAtPerson(base)
        _ = c.personAnswered(matches: true)
        _ = c.receive(SpanDACPairTestLines.confirm(derive(base).ms))
        XCTAssertEqual(c.saved("disk full"), [.failed(.notSaved("disk full"))])
        XCTAssertEqual(c.phase, .failed)
    }

    // MARK: - Order, versions, limits

    func testAMessageOutOfOrderAborts() {
        let base = inputs(object("base", "inputs"))
        var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname)
        _ = c.start()
        let out = c.receive(SpanDACPairTestLines.commit(Data(repeating: 1, count: 32)))
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"format"}"#), .failed(.broken("message out of order"))])
    }

    func testAHelloWithAnotherVersionAbortsWithVersion() {
        let base = inputs(object("base", "inputs"))
        var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname)
        _ = c.start()
        let out = c.receive(#"{"t":"hello","v":2,"sid":"\#(base.sid)","sname":"iPad"}"#)
        XCTAssertEqual(out, [.send(#"{"t":"abort","reason":"version"}"#), .failed(.version)])
    }

    func testAnUnknownTypeALongLineAndBadFieldsAbortWithFormat() {
        let base = inputs(object("base", "inputs"))
        let bad = [
            #"{"t":"hi"}"#,
            "not json",
            #"{"t":"hello","v":1,"sid":"\#(base.sid.lowercased())","sname":"iPad"}"#,
            #"{"t":"hello","v":1,"sid":"\#(base.sid)","sname":""}"#,
            #"{"t":"hello","v":1,"sid":"\#(base.sid)","sname":"\#(String(repeating: "x", count: 65))"}"#,
            #"{"t":"hello","v":1,"sid":"\#(base.sid)","sname":"a\u0007b"}"#,
            #"{"t":"hello","v":true,"sid":"\#(base.sid)","sname":"iPad"}"#,
            #"{"t":"hello","v":1,"sid":"\#(base.sid)","sname":"iPad","pad":"\#(String(repeating: "x", count: 4096))"}"#,
        ]
        for line in bad {
            var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname)
            _ = c.start()
            XCTAssertEqual(c.receive(line).first, .send(#"{"t":"abort","reason":"format"}"#), line)
            XCTAssertEqual(c.phase, .failed, line)
        }
    }

    /// Padding, the standard alphabet and a wrong length are all refused.
    func testByteStringsAreStrictUnpaddedBase64url() {
        XCTAssertNil(SpanDACPair.fromBase64url("AAAA="))
        XCTAssertNil(SpanDACPair.fromBase64url("ab+/"))
        XCTAssertNil(SpanDACPair.fromBase64url("A"))
        XCTAssertNil(SpanDACPair.fromBase64url("AB C"))
        XCTAssertEqual(SpanDACPair.fromBase64url("_-8"), Data([0xFF, 0xEF]))
        XCTAssertEqual(SpanDACPair.base64url(Data([0xFF, 0xEF])), "_-8")
    }

    func testTheSourcesAbortsBecomeSentences() {
        XCTAssertEqual(SpanDACPairingController.failure(forSourceAbort: "closed"), .windowClosed)
        XCTAssertEqual(SpanDACPairingController.failure(forSourceAbort: "busy"), .busy)
        XCTAssertEqual(SpanDACPairingController.failure(forSourceAbort: "rejected"), .codesDiffer)
        XCTAssertEqual(SpanDACPairingController.failure(forSourceAbort: "timeout"), .timedOut)
        XCTAssertEqual(SpanDACPairFailure.codesDiffer.sentence, "Codes differ; nothing was paired. Try again from the iPad.")
    }

    /// Ten seconds for messages 1 to 6; the confirm phase is bounded by the
    /// window; a timeout aborts with `timeout`.
    func testTimeoutsFollowThePhase() {
        let base = inputs(object("base", "inputs"))
        var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname)
        XCTAssertNil(c.timeout)
        _ = c.start()
        XCTAssertEqual(c.timeout, 10)
        var atPerson = controllerAtPerson(base)
        XCTAssertEqual(atPerson.timeout, 120)
        XCTAssertEqual(atPerson.timedOut(), [.send(#"{"t":"abort","reason":"timeout"}"#), .failed(.timedOut)])
        XCTAssertNil(atPerson.timeout)
    }

    func testTheControllerWillNotStartWithANameTheProtocolRejects() {
        var c = SpanDACPairingController(controllerID: UUID().uuidString, controllerName: "")
        XCTAssertEqual(c.start(), [.failed(.broken("this Mac's name or id is not usable"))])
        XCTAssertEqual(SpanDACPair.fittedName("Mac\u{7}\n Studio"), "Mac Studio")
        XCTAssertEqual(SpanDACPair.fittedName(String(repeating: "é", count: 40))?.utf8.count, 64)
    }

    /// A whole session against an independent source built from the
    /// primitives: both screens show the same code, and both ends hold the
    /// same key under the same identity.
    func testAHonestSessionAgreesOnCodeKeyAndIdentity() {
        let source = TestSource(id: UUID().uuidString, name: "Test iPad",
                                privateKey: P256.KeyAgreement.PrivateKey(), nonce: SpanDACPair.freshNonce())
        var c = SpanDACPairingController(controllerID: UUID().uuidString, controllerName: "MusicTUI on Test Mac")
        let code = runUntilCode(&c, source)
        XCTAssertEqual(code, source.codeShown)
        var pending = c.personAnswered(matches: true)
        var result: SpanDACPairResult?
        while let output = pending.first {
            pending.removeFirst()
            switch output {
            case .send(let line):
                if let reply = source.handle(line) { pending += c.receive(reply) }
            case .save(let pair):
                result = pair
                pending += c.saved(nil)
            default: break
            }
        }
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(result?.pairKey, source.pairKey)
        XCTAssertEqual(result?.pskID, source.pskIdentity)
        XCTAssertTrue(source.gotDone)
    }

    // MARK: - Helpers

    private func controllerAtReveal(_ base: Inputs) -> SpanDACPairingController {
        let d = derive(base)
        var c = SpanDACPairingController(controllerID: base.cid, controllerName: base.cname,
                                         privateKey: key(base.dC), nonce: base.nC)
        _ = c.start()
        _ = c.receive(SpanDACPairTestLines.hello(base.sid, base.sname))
        _ = c.receive(SpanDACPairTestLines.commit(d.hs))
        XCTAssertEqual(c.phase, .awaitingReveal)
        return c
    }

    private func controllerAtPerson(_ base: Inputs) -> SpanDACPairingController {
        var c = controllerAtReveal(base)
        _ = c.receive(SpanDACPairTestLines.reveal(derive(base).pkS, base.nS))
        XCTAssertEqual(c.phase, .awaitingPerson)
        return c
    }

    /// Drives the controller against `source` until the code is on screen.
    private func runUntilCode(_ c: inout SpanDACPairingController, _ source: TestSource) -> String? {
        var pending = c.start()
        while let output = pending.first {
            pending.removeFirst()
            switch output {
            case .send(let line):
                if let reply = source.handle(line) { pending += c.receive(reply) }
            case .showCode(let code, _):
                return code
            default:
                return nil
            }
        }
        return nil
    }
}

/// Source lines for tests, in the protocol's own encoding.
enum SpanDACPairTestLines {
    static func hello(_ sid: String, _ sname: String) -> String {
        #"{"t":"hello","v":1,"sid":"\#(sid)","sname":"\#(sname)"}"#
    }
    static func commit(_ h: Data) -> String { #"{"t":"commit","h":"\#(SpanDACPair.base64url(h))"}"# }
    static func reveal(_ pk: Data, _ n: Data) -> String {
        #"{"t":"reveal","pk":"\#(SpanDACPair.base64url(pk))","n":"\#(SpanDACPair.base64url(n))"}"#
    }
    static func confirm(_ mac: Data) -> String { #"{"t":"confirm","mac":"\#(SpanDACPair.base64url(mac))"}"# }
}

/// A minimal source side, written in this test from the primitives, so a
/// whole session can run with no network and no second implementation of the
/// controller. It answers every step at once (the person taps "Matches").
final class TestSource {
    let id: String
    let name: String
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let nonce: Data
    private var cid = "", cname = "", hc = Data(), pkC = Data(), nC = Data(), transcript = Data()
    private var keys: SpanDACPair.Keys?
    private(set) var codeShown: String?
    private(set) var gotDone = false
    var pairKey: Data? { keys?.pairKey }
    var pskIdentity: String? { keys?.pskIdentity }

    init(id: String, name: String, privateKey: P256.KeyAgreement.PrivateKey, nonce: Data) {
        self.id = id; self.name = name; self.privateKey = privateKey; self.nonce = nonce
    }

    func handle(_ line: String) -> String? {
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let pk = privateKey.publicKey.x963Representation
        switch object["t"] as! String {
        case "hello":
            cid = object["cid"] as! String; cname = object["cname"] as! String
            return SpanDACPairTestLines.hello(id, name)
        case "commit":
            hc = SpanDACPair.fromBase64url(object["h"] as! String)!
            return SpanDACPairTestLines.commit(SpanDACPair.commitment(role: .source, publicKey: pk, nonce: nonce))
        case "reveal":
            pkC = SpanDACPair.fromBase64url(object["pk"] as! String)!
            nC = SpanDACPair.fromBase64url(object["n"] as! String)!
            guard SpanDACPair.commitment(role: .controller, publicKey: pkC, nonce: nC) == hc else {
                return #"{"t":"abort","reason":"commit"}"#
            }
            transcript = SpanDACPair.transcript(cid: cid, sid: id, cname: cname, sname: name,
                                                pkC: pkC, pkS: pk, nC: nC, nS: nonce)
            let z = try! SpanDACPair.sharedSecret(privateKey, SpanDACPair.publicKey(x963: pkC)!)
            keys = SpanDACPair.derive(z: z, transcript: transcript)
            codeShown = keys!.codeDisplay
            return SpanDACPairTestLines.reveal(pk, nonce)
        case "confirm":
            let mc = SpanDACPair.fromBase64url(object["mac"] as! String)!
            guard let keys, SpanDACPair.isValidConfirmation(mc, key: keys.confirmKeyController,
                                                            role: .controller, transcript: transcript) else {
                return #"{"t":"abort","reason":"confirm"}"#
            }
            return SpanDACPairTestLines.confirm(SpanDACPair.confirmation(key: keys.confirmKeySource,
                                                                         role: .source, transcript: transcript))
        case "done":
            gotDone = true
            return nil
        default:
            return nil
        }
    }
}

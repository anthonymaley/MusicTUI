// tools/music/Tests/MusicTests/SpanDACStatusOutputTests.swift
//
// `slice.status` may carry an `output` object saying whether a DAC is on the
// SpanDAC's output. Absent (an older SpanDAC) is read exactly as before; an
// explicit `unknown` or `not_connected` is never ready, so neither the Output
// tab, the routing transaction nor the CLI can play through it. No socket, no
// SpanDAC: a fake transport answers.
import XCTest
@testable import music

final class SpanDACStatusOutputTests: XCTestCase {

    private func control(_ reply: String) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: { _, _ in reply })
    }

    private func status(_ output: String?) -> String {
        let tail = output.map { #","output":\#($0)"# } ?? ""
        return #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[]\#(tail)}}"#
    }

    private func dict(_ output: String?) -> [String: Any] {
        let reply = try! JSONSerialization.jsonObject(with: Data(status(output).utf8)) as! [String: Any]
        return reply["status"] as! [String: Any]
    }

    func testStatusOutputIsParsed() throws {
        let connected = try control(status(#"{"dac":"connected","name":"SSL 2+","max_rate_hz":192000}"#)).status()
        XCTAssertEqual(connected.output, SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192000))
        XCTAssertEqual(connected.readiness, .ready)

        let noRate = try control(status(#"{"dac":"connected","name":"USB Audio"}"#)).status()
        XCTAssertEqual(noRate.output, SourceOutputInfo(dac: .connected, name: "USB Audio", maxRateHz: nil))

        let none = try control(status(#"{"dac":"not_connected"}"#)).status()
        XCTAssertEqual(none.output, SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil))

        let unknown = try control(status(#"{"dac":"unknown"}"#)).status()
        XCTAssertEqual(unknown.output, SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil))
    }

    /// A name or rate beside a DAC that is not connected is ignored: only a
    /// connected DAC is named.
    func testANameIsKeptOnlyForAConnectedDAC() throws {
        let odd = try control(status(#"{"dac":"not_connected","name":"Speaker","max_rate_hz":48000}"#)).status()
        XCTAssertEqual(odd.output, SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil))
    }

    /// An `output` this build cannot read is treated as unknown: never ready,
    /// so it cannot fall through to a speaker.
    func testAnUnreadableOutputIsUnknownNeverReady() throws {
        for odd in [#"{"dac":"maybe"}"#, #"{}"#, #""connected""#] {
            let s = try control(status(odd)).status()
            XCTAssertEqual(s.output?.dac, .unknown, odd)
            XCTAssertNotEqual(s.readiness, .ready, odd)
        }
    }

    func testNoDACMakesTheSpanDACNotReady() throws {
        let c = control(status(nil))
        XCTAssertEqual(c.readiness(from: dict(#"{"dac":"not_connected"}"#)), .unavailable("plug in your DAC"))
        XCTAssertEqual(try control(status(#"{"dac":"not_connected"}"#)).status().readiness,
                       .unavailable("plug in your DAC"))
        XCTAssertFalse(SourceReadiness.unavailable("plug in your DAC").canSelect)
    }

    /// Compatibility: a reply with no `output` key is read exactly as today,
    /// readiness from authorization and contract only.
    func testAStatusWithoutOutputIsReadAsBefore() throws {
        let s = try control(status(nil)).status()
        XCTAssertNil(s.output)
        XCTAssertEqual(s.readiness, .ready)
        let denied = #"{"ok":true,"status":{"playback":"idle","authorization":"denied","contract":3}}"#
        XCTAssertEqual(try control(denied).status().readiness, .unavailable("SpanDAC was denied Apple Music access"))
        XCTAssertNil(try control(denied).status().output)
    }

    /// An explicit `unknown` is a new SpanDAC that has not read its DAC yet:
    /// not ready, and the row stays `.checking` with "checking the DAC".
    func testAnExplicitUnknownDACIsNotReadyAndShowsChecking() throws {
        let c = control(status(nil))
        XCTAssertEqual(c.readiness(from: dict(#"{"dac":"unknown"}"#)),
                       .unavailable("SpanDAC is still checking for a DAC"))

        let id = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
        let record = SpanDACPairRecord(sourceID: id, sourceName: "Studio iPad", pskID: String(repeating: "ab", count: 16),
                                       pairKey: Data(repeating: 1, count: 32), serviceName: id, pairedAt: Date())
        let rows = spandacOutputRows(paired: [record], seen: [],
                                     probes: [id: .unavailable("SpanDAC is still checking for a DAC")],
                                     outputs: [id: SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil)],
                                     pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(rows.first?.state, .checking)
        XCTAssertEqual(rows.first?.note, "checking the DAC")
        XCTAssertEqual(rows.first?.ready, false)
    }
}

// tools/music/Tests/MusicTests/RouteVerifierTests.swift
import XCTest
@testable import music

final class RouteVerifierTests: XCTestCase {
    // MARK: - netstat parse

    // Real `netstat -an -p tcp` output captured in the 2026-07-11 spike.
    static let routedFixture = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    tcp4       0      0  192.168.1.154.53948    192.168.1.112.7000     ESTABLISHED
    tcp4       0      0  192.168.1.154.54361    192.168.1.112.7000     ESTABLISHED
    tcp4       0      0  192.168.1.154.54364    192.168.1.112.61540    ESTABLISHED
    tcp4       0      0  192.168.1.154.54366    192.168.1.112.61542    ESTABLISHED
    tcp4       0      0  192.168.1.154.53210    192.168.1.81.7000      ESTABLISHED
    tcp4       0      0  192.168.1.154.53055    160.79.104.10.443      ESTABLISHED
    tcp6       0      0  fe80::42f:55f3:7.62559 fe80::cfc:8b4a:f.57371 ESTABLISHED
    tcp4       0      0  192.168.1.154.63988    192.168.1.49.22        CLOSE_WAIT
    udp4       0      0  *.5353                 *.*
    """

    func testParsesEstablishedTCPLines() {
        let conns = parseNetstatTCP(Self.routedFixture)
        // 7 ESTABLISHED lines (CLOSE_WAIT and udp excluded)
        XCTAssertEqual(conns.count, 7)
        XCTAssertEqual(conns[0], TCPConnection(localPort: 53948, remoteIP: "192.168.1.112", remotePort: 7000))
    }

    func testFiltersByRemoteIP() {
        let conns = parseNetstatTCP(Self.routedFixture).filter { $0.remoteIP == "192.168.1.112" }
        XCTAssertEqual(conns.count, 4)
        XCTAssertEqual(conns.filter { $0.remotePort == 7000 }.count, 2)
    }

    func testParsesIPv6AddressLastDotSplit() {
        let conns = parseNetstatTCP(Self.routedFixture).filter { $0.remoteIP.hasPrefix("fe80") }
        XCTAssertEqual(conns, [TCPConnection(localPort: 62559, remoteIP: "fe80::cfc:8b4a:f", remotePort: 57371)])
    }

    func testGarbageAndEmptyInputYieldNothing() {
        XCTAssertEqual(parseNetstatTCP("").count, 0)
        XCTAssertEqual(parseNetstatTCP("not netstat output\nat all").count, 0)
    }

    // MARK: - hostname candidates (pure)

    func testHostnameCandidates() {
        XCTAssertEqual(BonjourSpeakerResolver.hostnameCandidates(for: "Kitchen"),
                       ["kitchen.local"])
        XCTAssertEqual(BonjourSpeakerResolver.hostnameCandidates(for: "Living Room"),
                       ["living-room.local", "livingroom.local"])
    }

    // MARK: - verdicts (injectable connection source)

    /// Sequence-driven fake: each call to the source returns the next snapshot.
    private func verifier(snapshots: [[TCPConnection]]) -> RouteVerifier {
        let box = LockedBox<[[TCPConnection]]>(snapshots)
        return RouteVerifier(
            resolver: FixedResolver(),
            connectionSource: {
                var all = box.get()
                let next = all.count > 1 ? all.removeFirst() : all[0]
                box.set(all)
                return next
            },
            pollInterval: 0  // no sleeping in tests
        )
    }

    private struct FixedResolver: SpeakerIPResolving {
        func resolveIP(forSpeaker name: String) -> String? { "192.168.1.112" }
    }

    private let standing = TCPConnection(localPort: 53948, remoteIP: "192.168.1.112", remotePort: 7000)
    private let newControl = TCPConnection(localPort: 54361, remoteIP: "192.168.1.112", remotePort: 7000)
    private let newData1 = TCPConnection(localPort: 54364, remoteIP: "192.168.1.112", remotePort: 61540)
    private let newData2 = TCPConnection(localPort: 54366, remoteIP: "192.168.1.112", remotePort: 61542)

    func testEstablishmentVerifiedWhenTwoNewConnectionsAppear() throws {
        let v = verifier(snapshots: [[standing], [standing, newControl, newData1, newData2]])
        let baseline = try v.snapshot(ip: "192.168.1.112")
        let verdict = try v.verifyEstablishment(ip: "192.168.1.112", baseline: baseline, timeout: 1)
        XCTAssertTrue(verdict.verified)
        XCTAssertTrue(verdict.evidence.contains("3 new connection"), verdict.evidence)
    }

    func testEstablishmentFailsWhenNothingAppears() throws {
        let v = verifier(snapshots: [[standing]])
        let baseline = try v.snapshot(ip: "192.168.1.112")
        let verdict = try v.verifyEstablishment(ip: "192.168.1.112", baseline: baseline, timeout: 0.05)
        XCTAssertFalse(verdict.verified)
        XCTAssertTrue(verdict.evidence.contains("no new"), verdict.evidence)
    }

    func testSteadyStateVerifiedOnDoubleControlConnection() throws {
        let v = verifier(snapshots: [[standing, newControl, newData1]])
        let verdict = try v.steadyState(ip: "192.168.1.112")
        XCTAssertTrue(verdict.verified)
    }

    func testSteadyStateNotVerifiedOnLingeringConnectionsOnly() throws {
        // Spike: a just-derouted device keeps ONE :7000 conn + stale data conns.
        let v = verifier(snapshots: [[standing, newData1, newData2]])
        let verdict = try v.steadyState(ip: "192.168.1.112")
        XCTAssertFalse(verdict.verified)
        XCTAssertNotNil(verdict.advisory)
    }
}

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

    func testSplitAddressPortStripsZoneSuffix() {
        let split = splitAddressPort("fe80::1%lo0.7000")
        XCTAssertEqual(split?.ip, "fe80::1")
        XCTAssertEqual(split?.port, 7000)
    }

    // MARK: - truncated-address matching

    // Real `netstat -an -p tcp` output captured live 2026-07-13: a routed,
    // audibly-playing Sonos arc whose session runs over link-local IPv6.
    // netstat truncates the address to its column width — the device's full
    // resolved IP is fe80::3a42:bff:fed4:da1e.
    static let sonosFixture = """
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    tcp6       0      0  fe80::42f:55f3:7.61521 fe80::3a42:bff:f.7000  ESTABLISHED
    tcp6       0      0  fe80::42f:55f3:7.61518 fe80::3a42:bff:f.7000  ESTABLISHED
    tcp6       0      0  fe80::42f:55f3:7.61524 fe80::3a42:bff:f.7102  ESTABLISHED
    tcp6       0      0  fe80::42f:55f3:7.61519 fe80::3a42:bff:f.7127  ESTABLISHED
    tcp4       0      0  192.168.1.154.65447    192.168.1.112.7000     ESTABLISHED
    """

    func testRemoteIPMatchesExactAndTruncated() {
        // Exact IPv4 — the pre-existing behavior.
        XCTAssertTrue(remoteIPMatches("192.168.1.112", resolved: "192.168.1.112"))
        XCTAssertFalse(remoteIPMatches("192.168.1.113", resolved: "192.168.1.112"))
        // Truncated IPv6 row vs full resolved address.
        XCTAssertTrue(remoteIPMatches("fe80::3a42:bff:f", resolved: "fe80::3a42:bff:fed4:da1e"))
        // A complete-but-different shorter IPv6 must not ride the prefix rule.
        XCTAssertFalse(remoteIPMatches("fe80::1", resolved: "fe80::1a2b:3c4d:5e6f:7081"))
        // IPv4 never truncates — prefix matching must not apply.
        XCTAssertFalse(remoteIPMatches("192.168.1.1", resolved: "192.168.1.112"))
        // Row longer than the resolved address can't be a truncation of it.
        XCTAssertFalse(remoteIPMatches("fe80::3a42:bff:fed4:da1e", resolved: "fe80::3a42:bff:f"))
    }

    func testSteadyStateVerifiesTruncatedIPv6Fingerprint() throws {
        // End-to-end for the 2026-07-13 Sonos false-heal: 2 control + 2 data
        // connections exist but under truncated addresses; steadyState asked
        // about the full resolved IP must still see them.
        let v = verifier(snapshots: [parseNetstatTCP(Self.sonosFixture)])
        let verdict = try v.steadyState(ip: "fe80::3a42:bff:fed4:da1e")
        XCTAssertTrue(verdict.verified, verdict.evidence)
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

    func testSteadyStateNotVerifiedOnControlOnlyGhostFingerprint() throws {
        // Constructed ghost shape: control handshakes complete (2× :7000) but
        // no session/data connections — must NOT pass the fast path.
        let v = verifier(snapshots: [[standing, newControl]])
        let verdict = try v.steadyState(ip: "192.168.1.112")
        XCTAssertFalse(verdict.verified)
        XCTAssertNotNil(verdict.advisory)
    }

    func testEstablishmentVerifiedOnLaterPoll() throws {
        // The retry loop itself is under test: empty deltas for the first two
        // polls; fresh connections only on the third.
        let v = verifier(snapshots: [[standing], [standing], [standing], [standing, newControl, newData1]])
        let baseline = try v.snapshot(ip: "192.168.1.112")
        let verdict = try v.verifyEstablishment(ip: "192.168.1.112", baseline: baseline, timeout: 1)
        XCTAssertTrue(verdict.verified)
        XCTAssertTrue(verdict.evidence.contains("2 new connection"), verdict.evidence)
    }

    func testEstablishmentSurvivesTransientSnapshotError() throws {
        let calls = LockedBox<Int>(0)
        let v = RouteVerifier(
            resolver: FixedResolver(),
            connectionSource: {
                let n = calls.get() + 1
                calls.set(n)
                if n == 2 { throw NetstatError(status: 1) }
                return n < 4 ? [self.standing] : [self.standing, self.newControl, self.newData1]
            },
            pollInterval: 0)
        let baseline = try v.snapshot(ip: "192.168.1.112")
        let verdict = try v.verifyEstablishment(ip: "192.168.1.112", baseline: baseline, timeout: 1)
        XCTAssertTrue(verdict.verified)
    }

    func testEstablishmentThrowsWhenEverySampleFails() {
        let v = RouteVerifier(resolver: FixedResolver(),
                              connectionSource: { throw NetstatError(status: 1) },
                              pollInterval: 0)
        XCTAssertThrowsError(try v.verifyEstablishment(ip: "192.168.1.112", baseline: [], timeout: 0.05))
    }

    // MARK: - 2026-10-31: withheld table, IPv6 sessions, honest check()

    // Exactly what unprivileged netstat printed under the Studio's tmux server
    // on macOS 27.0.1 (`netstat -an`; `-p tcp` printed nothing at all).
    static let withheldFixture = """
    Active Multipath Internet connections
    Proto/ID  Flags      Local Address          Foreign Address        (state)
    Active LOCAL (UNIX) domain sockets
    """

    func testATableWithNoTCPRowsIsUnavailableNotEmpty() {
        XCTAssertThrowsError(try parseNetstatTCPChecked("")) { XCTAssertTrue($0 is ConnectionTableUnavailable) }
        XCTAssertThrowsError(try parseNetstatTCPChecked(Self.withheldFixture)) { XCTAssertTrue($0 is ConnectionTableUnavailable) }
        XCTAssertEqual(try parseNetstatTCPChecked(Self.routedFixture).count, 7)
    }

    private let arcV4 = "192.168.1.208"
    private let arcAll = "192.168.1.208,fe80::3a42:bff:fed4:da1e"
    // netstat's truncated form of the Arc's link-local address (probe rows).
    private func arcRow(_ local: Int, _ remote: Int) -> TCPConnection {
        TCPConnection(localPort: local, remoteIP: "fe80::3a42:bff:f", remotePort: remote)
    }

    private func source(_ snapshots: [[TCPConnection]], resolver: SpeakerIPResolving = FixedResolver()) -> RouteVerifier {
        let box = LockedBox<[[TCPConnection]]>(snapshots)
        return RouteVerifier(resolver: resolver, connectionSource: {
            var all = box.get()
            let next = all.count > 1 ? all.removeFirst() : all[0]
            box.set(all)
            return next
        }, pollInterval: 0)
    }

    func testSnapshotMatchesEveryAddressOfTheSpeaker() throws {
        let v = source([[arcRow(56296, 7000), TCPConnection(localPort: 1, remoteIP: "192.168.1.208", remotePort: 7000)]])
        XCTAssertEqual(try v.snapshot(ip: arcAll).count, 2)
        XCTAssertEqual(try v.snapshot(ip: arcV4).count, 1)
    }

    // The probe's routed Arc: standing :7000 + :7132, then + :7000 + :7101.
    func testAnIPv6SessionVerifiesWhenAllAddressesAreKnown() throws {
        let standing = [arcRow(56296, 7000), arcRow(56297, 7132)]
        let routed = standing + [arcRow(65426, 7000), arcRow(65428, 7101)]
        let v = source([standing, routed])
        let baseline = try v.snapshot(ip: arcAll)
        guard case .verified = v.check(ip: arcAll, baseline: baseline, timeout: 0.2) else {
            return XCTFail("routed IPv6 session should verify")
        }
    }

    func testAnUnreadableTableIsNotCheckedNeverFailed() {
        let v = RouteVerifier(resolver: FixedResolver(), connectionSource: { throw ConnectionTableUnavailable() }, pollInterval: 0)
        guard case .notChecked = v.check(ip: arcAll, baseline: [], timeout: 0.2) else {
            return XCTFail("an unreadable table must not be a failed route")
        }
    }

    func testARealNegativeStillFails() {
        let v = source([[standing]])
        guard case .failed = v.check(ip: "192.168.1.112", baseline: [standing], timeout: 0.2) else {
            return XCTFail("no new connections on a readable table is a real negative")
        }
    }

    func testJoinAddressesStripsZonesAndDuplicates() {
        XCTAssertEqual(joinAddresses(["192.168.1.208", "fe80::3a42:bff:fed4:da1e%en0", "fe80::3a42:bff:fed4:da1e%en1"]),
                       "192.168.1.208,fe80::3a42:bff:fed4:da1e")
        XCTAssertNil(joinAddresses([]))
        XCTAssertEqual(speakerAddresses("192.168.1.112"), ["192.168.1.112"])
    }

    // Codex 2026-10-31: one readable empty sample then failed reads is an
    // incomplete window — unknown, never an authoritative "no".
    func testANegativeWindowWithAFailedReadIsUnknown() {
        let calls = LockedBox<Int>(0)
        let v = RouteVerifier(resolver: FixedResolver(), connectionSource: {
            calls.update { $0 += 1 }
            if calls.get() > 1 { throw ConnectionTableUnavailable() }
            return [self.standing]
        }, pollInterval: 0)
        XCTAssertThrowsError(try v.verifyEstablishment(ip: "192.168.1.112", baseline: [standing], timeout: 0.05))
    }

    // MARK: - speaker wake triage

    private struct NoAddress: SpeakerIPResolving { func resolveIP(forSpeaker name: String) -> String? { nil } }

    func testWakeTriageNeverCallsUnknownBroken() {
        let unreadable = RouteVerifier(resolver: FixedResolver(), connectionSource: { throw ConnectionTableUnavailable() }, pollInterval: 0)
        var t = triageWakeTargets(["Kitchen"], verifier: unreadable)
        XCTAssertTrue(t.broken.isEmpty); XCTAssertEqual(t.unknown.map { $0.0 }, ["Kitchen"])

        let unresolved = RouteVerifier(resolver: NoAddress(), connectionSource: { [] }, pollInterval: 0)
        t = triageWakeTargets(["Kitchen"], verifier: unresolved)
        XCTAssertTrue(t.broken.isEmpty); XCTAssertEqual(t.unknown.map { $0.0 }, ["Kitchen"])

        let lingering = source([[standing]])
        t = triageWakeTargets(["Kitchen"], verifier: lingering)
        XCTAssertEqual(t.broken, ["Kitchen"]); XCTAssertTrue(t.unknown.isEmpty)

        let routed = source([[standing, newControl, newData1]])
        t = triageWakeTargets(["Kitchen"], verifier: routed)
        XCTAssertEqual(t.verified, ["Kitchen"]); XCTAssertTrue(t.broken.isEmpty)
    }
}

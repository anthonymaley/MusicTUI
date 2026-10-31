// tools/music/Tests/MusicTests/RouteHealerTests.swift
import XCTest
@testable import music

final class RouteHealerTests: XCTestCase {
    func testTier3MessageNamesManualFixAndEvidence() {
        let msg = RouteHealer.honestFailureMessage(
            speaker: "Kitchen", ip: "192.168.1.112",
            evidence: "no session traffic after 2 heal attempts",
            networkReading: "1 connection to 192.168.1.112, no control pair",
            scriptingClaims: "selected=true active=false")
        XCTAssertTrue(msg.contains("NOT verified"))
        XCTAssertTrue(msg.contains("click the AirPlay icon in Music"))
        XCTAssertTrue(msg.contains("deselect and reselect Kitchen"))
        XCTAssertTrue(msg.contains("192.168.1.112"))
        XCTAssertTrue(msg.contains("selected=true active=false"))
        // The network field carries the real fingerprint, distinct from the
        // summary line — it used to echo `evidence` in both slots.
        XCTAssertTrue(msg.contains("network: 1 connection to 192.168.1.112, no control pair"))
    }

    func testOutcomeReportsTierUsed() {
        let healed = RouteHealer.Outcome(healed: true, tierUsed: 1, failure: nil)
        XCTAssertEqual(healed.tierUsed, 1)
        XCTAssertNil(healed.failure)
    }

    // MARK: - tier escalation (backend seam + injected verifier)

    /// Records scripts and can fail the first N list-writes, so a tier can be
    /// forced to fail its reroute and escalate. The seam is synchronous and the
    /// healer calls it serially, so LockedBox guards against no contention; it
    /// keeps the fake safe if a test ever drives it from more than one thread.
    private final class FakeScripting: MusicScripting, @unchecked Sendable {
        let scripts = LockedBox<[String]>([])
        private let failListWrites: LockedBox<Int>
        init(failListWrites: Int = 0) { self.failListWrites = LockedBox(failListWrites) }
        func runMusicBlocking(_ script: String, timeout: TimeInterval) throws -> String {
            scripts.set(scripts.get() + [script])
            var fail = false
            if script.contains("set current AirPlay devices"), failListWrites.get() > 0 {
                failListWrites.set(failListWrites.get() - 1)
                fail = true
            }
            if fail { throw AppleScriptBackend.ScriptError.executionFailed("fake list-write failure") }
            return ""
        }
    }

    private struct FixedResolver: SpeakerIPResolving {
        func resolveIP(forSpeaker name: String) -> String? { "192.168.1.112" }
    }

    private let standing = TCPConnection(localPort: 53948, remoteIP: "192.168.1.112", remotePort: 7000)
    private let newControl = TCPConnection(localPort: 54361, remoteIP: "192.168.1.112", remotePort: 7000)
    private let newData = TCPConnection(localPort: 54364, remoteIP: "192.168.1.112", remotePort: 61540)

    /// Sequence-driven connection source: each read returns the next snapshot
    /// (last one persists once exhausted), same shape as RouteVerifierTests.
    private func verifier(_ snapshots: [[TCPConnection]]) -> RouteVerifier {
        let box = LockedBox<[[TCPConnection]]>(snapshots)
        return RouteVerifier(resolver: FixedResolver(), connectionSource: {
            var all = box.get()
            let next = all.count > 1 ? all.removeFirst() : all[0]
            box.set(all)
            return next
        }, pollInterval: 0)
    }

    private func healer(_ backend: FakeScripting, _ v: RouteVerifier) -> RouteHealer {
        RouteHealer(backend: backend, verifier: v, delay: { _ in }, verifyTimeout: 0.05)
    }

    func testHealsAtTier1WhenFirstRerouteVerifies() {
        // baseline read, then established conns appear → tier-1 verify passes.
        let outcome = healer(FakeScripting(), verifier([[standing], [standing, newControl, newData]]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertTrue(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 1)
    }

    func testEscalatesToTier2WhenTier1ListWriteFails() {
        let backend = FakeScripting(failListWrites: 1)  // tier-1 away-write fails → escalate
        // read1 = tier-1 baseline; read2 = tier-2 baseline; read3+ = established.
        let outcome = healer(backend, verifier([[standing], [standing], [standing, newControl, newData]]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertTrue(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 2)
        XCTAssertTrue(backend.scripts.get().contains { $0.contains("pause") },
                      "tier 2 brackets the reroute with a transport cycle")
    }

    func testFallsToTier3WhenNoRerouteVerifies() {
        // Established conns never appear → both tiers fail → honest tier-3.
        let outcome = healer(FakeScripting(), verifier([[standing]]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "selected=true active=false")
        XCTAssertFalse(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 3)
        XCTAssertNotNil(outcome.failure)
        XCTAssertTrue(outcome.failure!.contains("NOT verified"))
    }

    func testFallsToTier3WhenEveryListWriteFails() {
        let backend = FakeScripting(failListWrites: 99)  // both tiers' away-writes fail
        let outcome = healer(backend, verifier([[standing]]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertFalse(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 3)
    }

    // MARK: - unknown observations stop the ladder (Codex 2026-10-31)

    private func scripted(_ reads: [Result<[TCPConnection], Error>]) -> RouteVerifier {
        let box = LockedBox(reads)
        return RouteVerifier(resolver: FixedResolver(), connectionSource: {
            var all = box.get()
            let next = all.count > 1 ? all.removeFirst() : all[0]
            box.set(all)
            return try next.get()
        }, pollInterval: 0)
    }

    func testAnUnreadableBaselineMakesNoRouteWrite() {
        let backend = FakeScripting()
        let outcome = healer(backend, scripted([.failure(ConnectionTableUnavailable())]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertFalse(outcome.healed)
        XCTAssertTrue(backend.scripts.get().isEmpty, "\(backend.scripts.get())")
        XCTAssertTrue(outcome.failure?.contains("route not checked") == true)
    }

    func testAnUnreadableTableAfterTier1NeverReachesTier2() {
        let backend = FakeScripting()
        // tier-1 baseline readable, then every read fails after the reroute.
        let outcome = healer(backend, scripted([.success([standing]), .failure(ConnectionTableUnavailable())]))
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertFalse(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 1)
        XCTAssertFalse(backend.scripts.get().contains { $0.contains("pause") }, "no tier-2 transport cycle")
        // The away-and-back pair still ran, so the group is restored.
        XCTAssertEqual(backend.scripts.get().filter { $0.contains("set current AirPlay devices") }.count, 2)
    }

    // MARK: - Codex round 3 (2026-10-31)

    /// Every list-write after the first fails: the away-write lands, the
    /// back-write (and its retry) do not.
    private final class BackWriteFails: MusicScripting, @unchecked Sendable {
        let scripts = LockedBox<[String]>([])
        func runMusicBlocking(_ script: String, timeout: TimeInterval) throws -> String {
            scripts.set(scripts.get() + [script])
            let writes = scripts.get().filter { $0.contains("set current AirPlay devices") }.count
            if script.contains("set current AirPlay devices"), writes > 1 {
                throw AppleScriptBackend.ScriptError.executionFailed("fake back-write failure")
            }
            return ""
        }
    }

    func testAFailedBackWriteIsRetriedOnceThenReportedWithoutTier2() {
        let backend = BackWriteFails()
        let outcome = RouteHealer(backend: backend, verifier: verifier([[standing]]), delay: { _ in }, verifyTimeout: 0.05)
            .heal(target: "Kitchen", ip: "192.168.1.112", groupNames: ["Kitchen", "Deck"],
                  computerName: "Mac", scriptingClaims: "x")
        XCTAssertFalse(outcome.healed)
        XCTAssertEqual(outcome.tierUsed, 1)
        XCTAssertTrue(outcome.failure?.contains("the Mac may be the only output") == true, "\(String(describing: outcome.failure))")
        XCTAssertEqual(backend.scripts.get().filter { $0.contains("set current AirPlay devices") }.count, 3, "away + back + one retry")
        XCTAssertFalse(backend.scripts.get().contains { $0.contains("pause") })
    }

    // A heal moves the whole group: with one member unknown, nothing is rerouted.
    func testAMixedGroupWithAnUnknownMemberIsNeverRerouted() {
        let backend = FakeScripting()
        let lines = verifyAndHealRoutes(
            speakers: ["Kitchen", "Deck"], scripting: backend, computerName: "Mac",
            baselines: ["Kitchen": [standing]], ips: ["Kitchen": "192.168.1.112"],  // Deck: no address
            verifier: verifier([[standing]]), claims: { _ in "x" },
            healer: RouteHealer(backend: backend, verifier: verifier([[standing]]), delay: { _ in }, verifyTimeout: 0.05))
        XCTAssertFalse(backend.scripts.get().contains { $0.contains("set current AirPlay devices") }, "\(backend.scripts.get())")
        XCTAssertTrue(lines.contains { $0.contains("Kitchen NOT verified") }, "\(lines)")
    }

    // Automatic healing is off (3.24.2): even a real negative on a fully
    // known group is reported with the manual fix and nothing is rerouted.
    func testARealNegativeIsReportedAndNeverRerouted() {
        let backend = FakeScripting()
        let lines = verifyAndHealRoutes(
            speakers: ["Kitchen"], scripting: backend, computerName: "Mac",
            baselines: ["Kitchen": [standing]], ips: ["Kitchen": "192.168.1.112"],
            verifier: verifier([[standing]]), claims: { _ in "x" })
        XCTAssertTrue(backend.scripts.get().isEmpty, "\(backend.scripts.get())")
        XCTAssertTrue(lines.contains { $0.contains("Kitchen NOT verified") && $0.contains("deselect and reselect Kitchen") }, "\(lines)")
    }

    // Readable table, but every row is to another address of the device (the
    // Arc's IPv6 session vs its resolved IPv4): unknown, never healed.
    func testNoRowsToTheResolvedAddressIsUnknownNotBroken() {
        let v6Only = [TCPConnection(localPort: 56296, remoteIP: "fe80::3a42:bff:f", remotePort: 7000),
                      TCPConnection(localPort: 65428, remoteIP: "fe80::3a42:bff:f", remotePort: 7101)]
        let v = RouteVerifier(resolver: FixedResolver(), connectionSource: { v6Only }, pollInterval: 0)
        guard case .notChecked = v.check(ip: "192.168.1.208", baseline: [], timeout: 0.05) else {
            return XCTFail("an address with no rows at all must be unknown")
        }
        let t = triageWakeTargets(["Sonos arc"], verifier: RouteVerifier(
            resolver: ArcV4(), connectionSource: { v6Only }, pollInterval: 0))
        XCTAssertTrue(t.broken.isEmpty)
        XCTAssertEqual(t.unknown.map { $0.0 }, ["Sonos arc"])
    }

    private struct ArcV4: SpeakerIPResolving { func resolveIP(forSpeaker name: String) -> String? { "192.168.1.208" } }
}

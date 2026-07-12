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
    /// forced to fail its reroute and escalate. Uses LockedBox (sync accessors)
    /// rather than a raw lock — locking directly in an async body is the pattern
    /// TimeoutFlag/LockedBox exist to avoid. Calls are serial (syncRun blocks),
    /// so the box is only here to satisfy the async-context rule, not contention.
    private final class FakeScripting: MusicScripting, @unchecked Sendable {
        let scripts = LockedBox<[String]>([])
        private let failListWrites: LockedBox<Int>
        init(failListWrites: Int = 0) { self.failListWrites = LockedBox(failListWrites) }
        func runMusic(_ script: String, timeout: TimeInterval) async throws -> String {
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
}

# AirPlay Verify-and-Heal (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every AirPlay route operation ends either verified with network evidence or in an honest failure naming the manual fix — never "selected and hoped."

**Architecture:** Two new backend units in the Swift CLI: `RouteVerifier` (resolves a speaker's IP via Bonjour, reads the system TCP table, and issues verdicts from connection *churn* — the only signal that never lied in the 2026-07-11 spike) and `RouteHealer` (evidence-ordered escalation: away-and-back list-write mid-play → stop/start-bracketed reset → honest failure). Scripting read-backs (`selected`, `active`, `current AirPlay devices`) are advisory only. Spec: `docs/superpowers/specs/2026-07-11-airplay-robustness-design.md`.

**Tech Stack:** Swift 5.9 package (macOS 14 target), XCTest, Foundation `Process` (netstat shell-out), `getaddrinfo` + Network.framework `NWBrowser` (Bonjour), existing `AppleScriptBackend`/`syncRun` plumbing.

**Repo rules that bind every task:** work directly on `main` (project convention); **push after every commit**; routing and playback stay in separate osascript calls (parameter-error-50 rule); `docs/playbook.md` and `TODO.md` are symlinks into the vault — edit them at `~/eolas/vault/apple-music/repo/…` (Write/Edit tools refuse symlinks); vault changes commit to `~/eolas`, not this repo.

**Run all tests with:** `cd /Users/anthonymaley/apple-music/tools/music && swift test 2>&1 | tail -5` (158 green before this plan).

---

## File structure

| File | Responsibility |
|---|---|
| `tools/music/Sources/Backends/RouteVerifier.swift` (create) | TCP-connection model, netstat parse (pure), netstat read, verdicts (delta + steady-state) |
| `tools/music/Sources/Backends/SpeakerIPResolver.swift` (create) | Bonjour name→IP: `getaddrinfo` fast path, `NWBrowser` fallback, protocol seam |
| `tools/music/Sources/Backends/RouteHealer.swift` (create) | Heal tiers 1-3 + the shared verify-and-heal orchestration used by CLI and TUI |
| `tools/music/Sources/Commands/SpeakerCommands.swift` (modify) | `verify` parser keyword + verb, paused-deferral on add/remove/exclusive, verify-first `wake` |
| `tools/music/Sources/Commands/PlaybackCommands.swift` (modify) | Play-path integration (baseline → route → play → verify → heal) |
| `tools/music/Sources/TUI/Shell/SpeakersScene.swift` (modify) | Toggle verify toast |
| `tools/music/Tests/MusicTests/RouteVerifierTests.swift` (create) | Parser + verdict tests with spike-captured fixtures |
| `tools/music/Tests/MusicTests/RouteHealerTests.swift` (create) | Tier-3 message rendering, tier-decision logic |
| `tools/music/Tests/MusicTests/SmartParserTests.swift` (modify) | `verify` keyword parsing |
| `scripts/airplay-live-probe.sh` (create) | Gated live probe: route → verify establish → route away → verify teardown |

---

### Task 1: TCP connection model + netstat parser (pure)

**Files:**
- Create: `tools/music/Sources/Backends/RouteVerifier.swift`
- Create: `tools/music/Tests/MusicTests/RouteVerifierTests.swift`

- [ ] **Step 1: Write the failing tests**

The fixture lines are REAL spike captures from 2026-07-11 (Kitchen=192.168.1.112, Master=192.168.1.81).

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/anthonymaley/apple-music/tools/music && swift test --filter RouteVerifierTests 2>&1 | tail -5`
Expected: compile FAILURE — `TCPConnection` and `parseNetstatTCP` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/Backends/RouteVerifier.swift
//
// Network ground truth for AirPlay routes. The 2026-07-11 spike proved every
// scripting read-back (`selected`, `active`, `current AirPlay devices`) lies
// in at least one live failure mode; established TCP connections to the
// device never did. Full evidence: docs/superpowers/specs/2026-07-11-
// airplay-robustness-design.md.
import Foundation

/// AirPlay control port. The Mac keeps ONE standing control connection to
/// every AirPlay device on the LAN; a ROUTED device shows a second :7000
/// connection plus fresh high-port data connections (HomePod-verified).
let airplayControlPort = 7000

struct TCPConnection: Hashable {
    let localPort: Int
    let remoteIP: String
    let remotePort: Int
}

/// Pure parse of `netstat -an -p tcp` output → ESTABLISHED connections.
/// macOS address format is `ip.port` with a dot separator — split on the
/// LAST dot so IPv6 colons and multi-dot IPv4 both survive.
func parseNetstatTCP(_ raw: String) -> [TCPConnection] {
    raw.components(separatedBy: "\n").compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 6,
              fields[0].hasPrefix("tcp"),
              fields[5] == "ESTABLISHED",
              let local = splitAddressPort(fields[3]),
              let remote = splitAddressPort(fields[4]) else { return nil }
        return TCPConnection(localPort: local.port, remoteIP: remote.ip, remotePort: remote.port)
    }
}

/// `192.168.1.112.7000` → ("192.168.1.112", 7000); `fe80::1.62559` → ("fe80::1", 62559)
func splitAddressPort(_ addr: String) -> (ip: String, port: Int)? {
    guard let lastDot = addr.lastIndex(of: "."),
          let port = Int(addr[addr.index(after: lastDot)...]) else { return nil }
    return (String(addr[..<lastDot]), port)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RouteVerifierTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit and push**

```bash
cd /Users/anthonymaley/apple-music
git add tools/music/Sources/Backends/RouteVerifier.swift tools/music/Tests/MusicTests/RouteVerifierTests.swift
git commit -m "feat(verify): TCP connection model + netstat parser with spike fixtures"
git push
```

---

### Task 2: Live TCP-table reader

**Files:**
- Modify: `tools/music/Sources/Backends/RouteVerifier.swift` (append)

No unit test — this is the thin I/O shell around the tested parser (same pattern as `fetchSpeakerDevices` over `parseSpeakerDeviceBlocks`).

- [ ] **Step 1: Append the reader**

```swift
// Append to tools/music/Sources/Backends/RouteVerifier.swift

/// All ESTABLISHED TCP connections, system-wide. netstat shows every
/// socket without root — the AirPlay session is held by a system daemon,
/// not the Music process (spike: Music holds zero TCP sockets).
func readEstablishedTCPConnections() throws -> [TCPConnection] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return parseNetstatTCP(String(data: data, encoding: .utf8) ?? "")
}
```

- [ ] **Step 2: Build + smoke-check by hand**

Run: `swift build 2>&1 | tail -3` — expected: `Build complete!`
Then: `netstat -an -p tcp | grep -c ESTABLISHED` — expected: a positive number (sanity that the source command works on this Mac).

- [ ] **Step 3: Commit and push**

```bash
git add tools/music/Sources/Backends/RouteVerifier.swift
git commit -m "feat(verify): live TCP-table reader via netstat"
git push
```

---

### Task 3: Bonjour speaker-IP resolver

**Files:**
- Create: `tools/music/Sources/Backends/SpeakerIPResolver.swift`

The `network address` AirPlay-device property is NOT the Wi-Fi MAC (absent from ARP and NDP — spike-verified); never use it. Spike-verified resolution: `kitchen.local → 192.168.1.112`, `master.local → 192.168.1.81`.

No unit test for the live paths (they need the LAN); the protocol seam is what tests inject through.

- [ ] **Step 1: Write the resolver**

```swift
// tools/music/Sources/Backends/SpeakerIPResolver.swift
//
// Speaker name → IP. Fast path: mDNS hostname guess (<name>.local — spike-
// verified for single-word HomePod names). Fallback: browse _airplay._tcp
// and match the service INSTANCE name (which IS the speaker name), then
// resolve by opening a throwaway connection to the advertised endpoint.
import Foundation
import Network

protocol SpeakerIPResolving {
    /// nil = could not resolve; callers degrade to an honest "can't verify" note.
    func resolveIP(forSpeaker name: String) -> String?
}

struct BonjourSpeakerResolver: SpeakerIPResolving {
    func resolveIP(forSpeaker name: String) -> String? {
        for candidate in Self.hostnameCandidates(for: name) {
            if let ip = Self.resolveHostname(candidate) {
                verbose("resolved \(name) → \(ip) via \(candidate)")
                return ip
            }
        }
        if let ip = Self.browseAirPlayIP(name: name) {
            verbose("resolved \(name) → \(ip) via _airplay._tcp browse")
            return ip
        }
        return nil
    }

    /// "Living Room" → ["living-room.local", "livingroom.local"]
    static func hostnameCandidates(for name: String) -> [String] {
        let lower = name.lowercased()
        let hyphenated = lower.replacingOccurrences(of: " ", with: "-")
        let stripped = lower.replacingOccurrences(of: " ", with: "")
        var out = [hyphenated + ".local"]
        if stripped != hyphenated { out.append(stripped + ".local") }
        return out
    }

    static func resolveHostname(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                          &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Browse _airplay._tcp for an instance whose name matches the speaker,
    /// then resolve its endpoint by connecting (the connection is to the
    /// AirPlay control port, which accepts and drops connections all day —
    /// the Mac itself keeps standing ones; harmless).
    static func browseAirPlayIP(name: String, timeout: TimeInterval = 4.0) -> String? {
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: "local."), using: .tcp)
        let found = LockedBox<NWEndpoint?>(nil)
        let sema = DispatchSemaphore(value: 0)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                if case let .service(sname, _, _, _) = r.endpoint,
                   sname.caseInsensitiveCompare(name) == .orderedSame {
                    found.set(r.endpoint)
                    sema.signal()
                    return
                }
            }
        }
        browser.start(queue: .global())
        _ = sema.wait(timeout: .now() + timeout)
        browser.cancel()
        guard let endpoint = found.get() else { return nil }

        let conn = NWConnection(to: endpoint, using: .tcp)
        let ip = LockedBox<String?>(nil)
        let rsema = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let ep = conn.currentPath?.remoteEndpoint, case let .hostPort(host, _) = ep {
                    switch host {
                    case .ipv4(let a): ip.set("\(a)")
                    case .ipv6(let a): ip.set("\(a)")
                    default: break
                    }
                }
                rsema.signal()
            case .failed, .cancelled:
                rsema.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = rsema.wait(timeout: .now() + timeout)
        conn.cancel()
        // Network.framework may suffix IPv6 with a zone (%en0) — strip it,
        // netstat prints bare addresses.
        guard let raw = ip.get() else { return nil }
        if let zone = raw.firstIndex(of: "%") { return String(raw[..<zone]) }
        return raw
    }
}

/// Minimal thread-safe box for the semaphore-bridged Bonjour callbacks
/// (same shape as TimeoutFlag in AppleScriptBackend.swift).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3` — expected `Build complete!`
(The live resolution check against spike ground truth happens in Task 5 step 4: `music speaker verify Kitchen` must print `192.168.1.112`.)

- [ ] **Step 3: Add hostname-candidate unit test**

Append to `RouteVerifierTests.swift`:

```swift
    // MARK: - hostname candidates (pure)

    func testHostnameCandidates() {
        XCTAssertEqual(BonjourSpeakerResolver.hostnameCandidates(for: "Kitchen"),
                       ["kitchen.local"])
        XCTAssertEqual(BonjourSpeakerResolver.hostnameCandidates(for: "Living Room"),
                       ["living-room.local", "livingroom.local"])
    }
```

Run: `swift test --filter RouteVerifierTests 2>&1 | tail -3` — expected: 5 tests, 0 failures.

- [ ] **Step 4: Commit and push**

```bash
git add tools/music/Sources/Backends/SpeakerIPResolver.swift tools/music/Tests/MusicTests/RouteVerifierTests.swift
git commit -m "feat(verify): Bonjour speaker-IP resolver (hostname fast path + _airplay._tcp browse)"
git push
```

---

### Task 4: RouteVerifier verdicts (delta + steady-state)

**Files:**
- Modify: `tools/music/Sources/Backends/RouteVerifier.swift` (append)
- Modify: `tools/music/Tests/MusicTests/RouteVerifierTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RouteVerifierTests 2>&1 | tail -5`
Expected: compile FAILURE — `RouteVerifier`, `RouteVerdict` not defined.

- [ ] **Step 3: Implement**

```swift
// Append to tools/music/Sources/Backends/RouteVerifier.swift

struct RouteVerdict {
    let verified: Bool
    /// Human-readable network evidence ("3 new connections to 192.168.1.112 …").
    let evidence: String
    /// Optional context for failure output (scripting claims, fingerprint caveats).
    let advisory: String?
}

struct RouteVerifier {
    var resolver: SpeakerIPResolving = BonjourSpeakerResolver()
    var connectionSource: () throws -> [TCPConnection] = readEstablishedTCPConnections
    /// Seconds between polls in verifyEstablishment. 0 in tests.
    var pollInterval: TimeInterval = 0.5

    func snapshot(ip: String) throws -> Set<TCPConnection> {
        Set(try connectionSource().filter { $0.remoteIP == ip })
    }

    /// Delta mode: after a route operation, poll until fresh connections
    /// appear beyond the baseline. Spike-observed establishment ≤1s on every
    /// real route; ≥2 new connections is the verified fingerprint (new :7000
    /// + data ports on HomePods).
    func verifyEstablishment(ip: String, baseline: Set<TCPConnection>,
                             timeout: TimeInterval = 5.0) throws -> RouteVerdict {
        let deadline = Date().addingTimeInterval(timeout)
        var lastNew = 0
        repeat {
            let now = try snapshot(ip: ip)
            let fresh = now.subtracting(baseline)
            lastNew = fresh.count
            if fresh.count >= 2 {
                return RouteVerdict(
                    verified: true,
                    evidence: "\(fresh.count) new connections to \(ip) (ports \(fresh.map { String($0.remotePort) }.sorted().joined(separator: ", ")))",
                    advisory: nil)
            }
            if pollInterval > 0 { Thread.sleep(forTimeInterval: pollInterval) }
        } while Date() < deadline
        return RouteVerdict(
            verified: false,
            evidence: lastNew == 0
                ? "no new connections to \(ip) within \(Int(timeout))s"
                : "only \(lastNew) new connection to \(ip) within \(Int(timeout))s (verified fingerprint is ≥2)",
            advisory: nil)
    }

    /// Steady-state mode (the `speaker verify` verb): no baseline available,
    /// so use the routed fingerprint — two :7000 control connections.
    /// HomePod-verified; other device classes are an open question (spec §Open
    /// questions), so the failure advisory says what pattern was looked for.
    func steadyState(ip: String) throws -> RouteVerdict {
        let conns = try snapshot(ip: ip)
        let control = conns.filter { $0.remotePort == airplayControlPort }.count
        if control >= 2 {
            return RouteVerdict(
                verified: true,
                evidence: "\(control) control connections + \(conns.count - control) other to \(ip)",
                advisory: nil)
        }
        return RouteVerdict(
            verified: false,
            evidence: "\(conns.count) connections to \(ip), \(control) on control port \(airplayControlPort)",
            advisory: "verified fingerprint is ≥2 control connections (HomePod-verified pattern; lingering post-route connections do not count)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RouteVerifierTests 2>&1 | tail -3`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit and push**

```bash
git add tools/music/Sources/Backends/RouteVerifier.swift tools/music/Tests/MusicTests/RouteVerifierTests.swift
git commit -m "feat(verify): RouteVerifier delta and steady-state verdicts"
git push
```

---

### Task 5: `music speaker verify [name]` verb

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`
- Modify: `tools/music/Tests/MusicTests/SmartParserTests.swift` (append)

- [ ] **Step 1: Write the failing parser tests**

Append to `SmartParserTests.swift` (this file already tests `SpeakerParser`):

```swift
    func testVerifyKeywordParsesBare() {
        XCTAssertEqual(SpeakerParser.parse(["verify"]), .verify(name: nil))
    }

    func testVerifyKeywordParsesWithName() {
        XCTAssertEqual(SpeakerParser.parse(["verify", "Living", "Room"]), .verify(name: "Living Room"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SmartParserTests 2>&1 | tail -3`
Expected: compile FAILURE — no `.verify` case.

- [ ] **Step 3: Add the case, keyword, and verb**

In `SpeakerCommands.swift`, add to `SpeakerAction` (after `case wake(name: String?)`, line 14):

```swift
    case verify(name: String?)
```

In `SpeakerParser.parse`, after the `wake` block (line 24):

```swift
        if args.count >= 1 && args[0].lowercased() == "verify" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .verify(name: name)
        }
```

In `runSpeakerSmart`'s switch, add a new case (after `case .wake`, before the closing brace at line 163):

```swift
    case .verify(let name):
        try runSpeakerVerify(name: name, backend: backend, json: json)
```

Then append the verb implementation at the end of the "Shared logic" section (after `runSpeakerSmart`, around line 164):

```swift
/// Read-only network-truth verdict for a routed speaker. No name = verify
/// every device the scripting layer claims is selected (advisory claims are
/// printed alongside — they can lie; the network verdict is the answer).
func runSpeakerVerify(name: String?, backend: AppleScriptBackend, json: Bool) throws {
    let devices = try fetchSpeakerDevices()
    let targets: [String]
    if let name = name {
        targets = [try resolveSpeakerName(name, backend: backend)]
    } else {
        targets = devices
            .filter { ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer") }
            .compactMap { $0["name"] as? String }
        guard !targets.isEmpty else {
            print("No non-local speakers are selected. Nothing to verify.")
            return
        }
    }

    let verifier = RouteVerifier()
    var results: [[String: Any]] = []
    for target in targets {
        let claimed = devices.first { ($0["name"] as? String) == target }?["selected"] as? Bool ?? false
        guard let ip = verifier.resolver.resolveIP(forSpeaker: target) else {
            results.append(["name": target, "verified": false, "ip": "",
                            "evidence": "could not resolve IP via Bonjour — cannot verify",
                            "claimedSelected": claimed])
            continue
        }
        let verdict = try verifier.steadyState(ip: ip)
        var row: [String: Any] = ["name": target, "verified": verdict.verified, "ip": ip,
                                  "evidence": verdict.evidence, "claimedSelected": claimed]
        if let advisory = verdict.advisory { row["advisory"] = advisory }
        results.append(row)
    }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["results": results]))
        return
    }
    for r in results {
        let mark = (r["verified"] as? Bool == true) ? "✓" : "✗"
        print("\(mark) \(r["name"]!) — \(r["evidence"]!) (scripting claims selected: \(r["claimedSelected"]!))")
        if let advisory = r["advisory"] { print("  \(advisory)") }
    }
}
```

Also update the `SpeakerSmart` `@Argument` help string (line 53) to include the new keyword:

```swift
    @Argument(help: "Speaker name, index, volume, or keyword (stop/only/list/wake/verify)") var args: [String] = []
```

- [ ] **Step 4: Run the full suite, then live-verify against spike ground truth**

Run: `swift test 2>&1 | tail -3` — expected: all green (160 tests now).
Then, with Kitchen routed (it is on this Mac): `swift run music speaker verify Kitchen`
Expected: a `✓` or `✗` line with `192.168.1.112` — the IP MUST match the spike's ground truth. If the Bonjour resolve returns nothing, that's a Task 3 bug; stop and fix there.

- [ ] **Step 5: Commit and push**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift tools/music/Tests/MusicTests/SmartParserTests.swift
git commit -m "feat(speaker): music speaker verify — network-truth route verdict"
git push
```

---

### Task 6: RouteHealer tiers + shared verify-and-heal flow

**Files:**
- Create: `tools/music/Sources/Backends/RouteHealer.swift`
- Create: `tools/music/Tests/MusicTests/RouteHealerTests.swift`

- [ ] **Step 1: Write the failing tests (message rendering + outcome shape)**

```swift
// tools/music/Tests/MusicTests/RouteHealerTests.swift
import XCTest
@testable import music

final class RouteHealerTests: XCTestCase {
    func testTier3MessageNamesManualFixAndEvidence() {
        let msg = RouteHealer.honestFailureMessage(
            speaker: "Kitchen", ip: "192.168.1.112",
            evidence: "no new connections to 192.168.1.112 within 5s",
            scriptingClaims: "selected=true active=false")
        XCTAssertTrue(msg.contains("NOT verified"))
        XCTAssertTrue(msg.contains("click the AirPlay icon in Music"))
        XCTAssertTrue(msg.contains("deselect and reselect Kitchen"))
        XCTAssertTrue(msg.contains("192.168.1.112"))
        XCTAssertTrue(msg.contains("selected=true active=false"))
    }

    func testOutcomeReportsTierUsed() {
        let healed = RouteHealer.Outcome(healed: true, tierUsed: 1, failure: nil)
        XCTAssertEqual(healed.tierUsed, 1)
        XCTAssertNil(healed.failure)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RouteHealerTests 2>&1 | tail -3`
Expected: compile FAILURE — `RouteHealer` not defined.

- [ ] **Step 3: Implement**

```swift
// tools/music/Sources/Backends/RouteHealer.swift
//
// Evidence-ordered heal ladder (spec §Heal ladder). Dropped with evidence:
// re-issuing `set selected` (no-op against a live broken state), list-writing
// the same device (no-op, zero churn), UI-scripting the popover (macOS 26
// chrome is AX-invisible). Tier 1 is the programmatic equivalent of the
// user's manual popover fix; tier 2 adds a transport cycle (UNVERIFIED in
// the spike — validated by scripts/airplay-live-probe.sh before reliance).
import Foundation

struct RouteHealer {
    struct Outcome {
        let healed: Bool
        /// 0 = verify passed with no heal; 1/2 = tier that healed; 3 = honest failure.
        let tierUsed: Int
        /// The tier-3 message when healed == false.
        let failure: String?
    }

    let backend: AppleScriptBackend
    let verifier: RouteVerifier

    /// Heal a target whose establishment verify failed. `groupNames` is the
    /// FULL intended output set (heals must not shrink a multi-speaker group);
    /// `computerName` is the local device (kind == "computer").
    /// Mid-play only — callers guarantee playback is running (routing issued
    /// while paused is untrusted by design; spec §Ordering rule).
    func heal(target: String, ip: String, groupNames: [String], computerName: String,
              scriptingClaims: String) -> Outcome {
        // Tier 1: away-and-back list-write. Routing stays its own osascript
        // call (parameter-error-50 rule).
        if runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: false) {
            return Outcome(healed: true, tierUsed: 1, failure: nil)
        }
        // Tier 2: same, bracketed by a transport cycle.
        if runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: true) {
            return Outcome(healed: true, tierUsed: 2, failure: nil)
        }
        return Outcome(healed: false, tierUsed: 3,
                       failure: Self.honestFailureMessage(
                           speaker: target, ip: ip,
                           evidence: "no session traffic after 2 heal attempts",
                           scriptingClaims: scriptingClaims))
    }

    private func runTier(away: [String], back: [String], ip: String, pauseBracket: Bool) -> Bool {
        func listWrite(_ names: [String]) -> Bool {
            let list = names
                .map { "AirPlay device \"\(escapeAppleScriptString($0))\"" }
                .joined(separator: ", ")
            return (try? syncRun {
                try await backend.runMusic("set current AirPlay devices to {\(list)}")
            }) != nil
        }
        guard let baseline = try? verifier.snapshot(ip: ip) else { return false }
        if pauseBracket { _ = try? syncRun { try await backend.runMusic("pause") } }
        guard listWrite(away) else { return false }
        // HomePods need a beat to tear down; 1.5s matches resetAirPlaySpeakers.
        Thread.sleep(forTimeInterval: 1.5)
        guard listWrite(back) else { return false }
        if pauseBracket { _ = try? syncRun { try await backend.runMusic("play") } }
        let verdict = (try? verifier.verifyEstablishment(ip: ip, baseline: baseline)) 
        return verdict?.verified ?? false
    }

    static func honestFailureMessage(speaker: String, ip: String,
                                     evidence: String, scriptingClaims: String) -> String {
        """
        ✗ Route to \(speaker) NOT verified: \(evidence).
          Manual fix that works: click the AirPlay icon in Music, deselect and reselect \(speaker).
          (network: \(evidence) [\(ip)] · scripting claims: \(scriptingClaims))
        """
    }
}

/// Shared post-play verification pass (CLI play path, speaker commands, TUI).
/// `baselines`/`ips` are captured BEFORE routing. Returns printable lines.
func verifyAndHealRoutes(speakers: [String], backend: AppleScriptBackend,
                         baselines: [String: Set<TCPConnection>],
                         ips: [String: String],
                         verifier: RouteVerifier = RouteVerifier()) -> [String] {
    var lines: [String] = []
    let devices = (try? fetchSpeakerDevices()) ?? []
    let computerName = devices.first { ($0["kind"] as? String) == "computer" }?["name"] as? String
        ?? "Computer"
    let healer = RouteHealer(backend: backend, verifier: verifier)

    for speaker in speakers {
        guard let ip = ips[speaker], let baseline = baselines[speaker] else {
            lines.append("· \(speaker): could not resolve IP via Bonjour — routed but unverified.")
            continue
        }
        let verdict = (try? verifier.verifyEstablishment(ip: ip, baseline: baseline))
            ?? RouteVerdict(verified: false, evidence: "verification errored", advisory: nil)
        if verdict.verified {
            lines.append("✓ \(speaker) verified (\(verdict.evidence))")
            continue
        }
        // Advisory context for the failure path: what the (lying) scripting
        // layer claims right now.
        let claims = (try? syncRun {
            try await backend.runMusic("""
                get "selected=" & (selected of AirPlay device "\(escapeAppleScriptString(speaker))" as text) & \
                " active=" & (active of AirPlay device "\(escapeAppleScriptString(speaker))" as text)
            """)
        })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
        let outcome = healer.heal(target: speaker, ip: ip, groupNames: speakers,
                                  computerName: computerName, scriptingClaims: claims)
        if outcome.healed {
            lines.append("✓ \(speaker) verified after heal (tier \(outcome.tierUsed))")
        } else {
            lines.append(outcome.failure ?? "✗ \(speaker) NOT verified")
        }
    }
    return lines
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: all green (162 tests).

- [ ] **Step 5: Commit and push**

```bash
git add tools/music/Sources/Backends/RouteHealer.swift tools/music/Tests/MusicTests/RouteHealerTests.swift
git commit -m "feat(heal): RouteHealer tier ladder + shared verify-and-heal flow"
git push
```

---

### Task 7: Play-path integration

**Files:**
- Modify: `tools/music/Sources/Commands/PlaybackCommands.swift:143-192`

- [ ] **Step 1: Capture baselines before routing**

In `PlaybackCommands.swift`, immediately BEFORE the routing block at line 148 (`if !parsed.speakers.isEmpty {`), insert:

```swift
            // Verify-and-heal support: capture per-speaker network baselines
            // BEFORE routing so establishment shows as churn afterward. A
            // failed resolve degrades to an honest "unverified" note later —
            // never a blocked play.
            var routeBaselines: [String: Set<TCPConnection>] = [:]
            var routeIPs: [String: String] = [:]
            if !parsed.speakers.isEmpty {
                let verifier = RouteVerifier()
                for speaker in parsed.speakers {
                    if let ip = verifier.resolver.resolveIP(forSpeaker: speaker) {
                        routeIPs[speaker] = ip
                        routeBaselines[speaker] = (try? verifier.snapshot(ip: ip)) ?? []
                    }
                }
            }
```

- [ ] **Step 2: Verify after playback starts**

The routing block (lines 148-178) and the play/strategy block (lines 186-192 and onward) stay as they are — routing is still *issued* before play (no wrong-speaker blast), just no longer *trusted*. Find the end of the play dispatch — after the `if strategies.isEmpty { … } else { … }` block completes and before `showNowPlaying` — and insert:

```swift
            // Routing issued while paused is untrusted (2/2 spike corruptions
            // came from it): verify AFTER playback starts, heal mid-play.
            if !parsed.speakers.isEmpty {
                for line in verifyAndHealRoutes(speakers: parsed.speakers, backend: backend,
                                                baselines: routeBaselines, ips: routeIPs) {
                    print(line)
                }
            }
```

- [ ] **Step 3: Build + full suite**

Run: `swift test 2>&1 | tail -3` — expected: all green.

- [ ] **Step 4: Live smoke (this Mac, Kitchen at current volume)**

Run: `swift run music play in the kitchen`
Expected: playback resumes on Kitchen and output contains `✓ Kitchen verified (…new connections…)`. Then `swift run music pause`.

- [ ] **Step 5: Commit and push**

```bash
git add tools/music/Sources/Commands/PlaybackCommands.swift
git commit -m "feat(play): verify-and-heal named-speaker routes after playback starts"
git push
```

---

### Task 8: speaker add/remove/exclusive integration + paused deferral

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift` (cases `.add`, `.addWithVolume`, `.exclusive` in `runSpeakerSmart`)

- [ ] **Step 1: Add the shared post-route hook**

Append near `runSpeakerVerify` in `SpeakerCommands.swift`:

```swift
/// Post-route verification for speaker commands. Playing → full verify-and-
/// heal. Paused → honest deferral (paused routing can't be network-verified
/// and is the spike-observed corruption trigger; the play path re-verifies).
func verifyRouteOrDefer(speaker: String, backend: AppleScriptBackend,
                        baseline: Set<TCPConnection>?, ip: String?) {
    let state = ((try? syncRun {
        try await backend.runMusic("player state as text")
    }) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard state == "playing" else {
        print("Route set; will verify on next play.")
        return
    }
    guard let ip = ip, let baseline = baseline else {
        print("· \(speaker): could not resolve IP via Bonjour — routed but unverified.")
        return
    }
    for line in verifyAndHealRoutes(speakers: [speaker], backend: backend,
                                    baselines: [speaker: baseline], ips: [speaker: ip]) {
        print(line)
    }
}
```

- [ ] **Step 2: Wire into the three routing cases**

In `case .add(let name)` (line 81), replace the body with:

```swift
    case .add(let name):
        let resolved = try resolveSpeakerName(name, backend: backend)
        let verifier = RouteVerifier()
        let ip = verifier.resolver.resolveIP(forSpeaker: resolved)
        let baseline = ip.flatMap { try? verifier.snapshot(ip: $0) }
        _ = try syncRun {
            try await backend.runMusic("set selected of AirPlay device \"\(escapeAppleScriptString(resolved))\" to true")
        }
        print("Added \(resolved).")
        verifyRouteOrDefer(speaker: resolved, backend: backend, baseline: baseline, ip: ip)
```

Apply the same shape to `.addWithVolume` (baseline captured before the two writes, `verifyRouteOrDefer` after the volume line prints) and `.exclusive` (baseline before the select-first write, `verifyRouteOrDefer` after `print("Switched to \(resolved) only.")`). `.remove` and `.indices` stay unchanged (removal needs no establishment verify; indices are the bulk quick-picker — deferring those to the play path keeps them fast).

- [ ] **Step 3: Build + suite + live smoke**

Run: `swift test 2>&1 | tail -3` — all green.
Live (player paused): `swift run music speaker Kitchen` → expected `Added Kitchen.` then `Route set; will verify on next play.`

- [ ] **Step 4: Commit and push**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift
git commit -m "feat(speaker): verify-and-heal on add/exclusive while playing, honest deferral while paused"
git push
```

---

### Task 9: verify-first `speaker wake`

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift` (`case .wake`, lines 137-163, and `resetAirPlaySpeakers`, line 298)

- [ ] **Step 1: Parameterize the reset**

Change `resetAirPlaySpeakers`'s signature (line 298) to accept an optional filter:

```swift
func resetAirPlaySpeakers(backend: AppleScriptBackend, only: Set<String>? = nil) -> [SpeakerSnapshot] {
```

and extend the `nonLocal` filter (line 304):

```swift
    let nonLocal = devices.filter {
        ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer")
            && (only == nil || only!.contains($0["name"] as! String))
    }
```

- [ ] **Step 2: Verify before resetting in `case .wake`**

Replace the reset call (lines 151-153) with:

```swift
        // Verify first — only reset what the network says is actually broken.
        // (Blind reset tore down healthy routes too.)
        let verifier = RouteVerifier()
        let devices = (try? fetchSpeakerDevices()) ?? []
        let routed = devices
            .filter { ($0["selected"] as? Bool == true) && ($0["kind"] as? String != "computer") }
            .compactMap { $0["name"] as? String }
        var broken: Set<String> = []
        for speaker in routed {
            guard let ip = verifier.resolver.resolveIP(forSpeaker: speaker) else {
                broken.insert(speaker)   // can't verify → treat as suspect
                continue
            }
            if !((try? verifier.steadyState(ip: ip))?.verified ?? false) {
                broken.insert(speaker)
            } else {
                print("✓ \(speaker) verified — leaving it alone.")
            }
        }
        if broken.isEmpty && !routed.isEmpty {
            print("All routed speakers verified. Nothing to reset.")
            return
        }
        let reset = withStatus("Resetting AirPlay speakers...") {
            resetAirPlaySpeakers(backend: backend, only: broken.isEmpty ? nil : broken)
        }
```

(The named-wake select at lines 138-150 stays as is — waking a specific sleeping speaker still selects it first.)

- [ ] **Step 3: Build + suite + live smoke**

Run: `swift test 2>&1 | tail -3` — all green.
Live (Kitchen routed + playing): `swift run music speaker wake` → expected `✓ Kitchen verified — leaving it alone.` and `All routed speakers verified. Nothing to reset.`

- [ ] **Step 4: Commit and push**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift
git commit -m "feat(speaker): wake verifies first and resets only broken routes"
git push
```

---

### Task 10: TUI toggle verify toast

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/SpeakersScene.swift:397-405` (`setSelected`)

- [ ] **Step 1: Add verification to the toggle action**

Replace `setSelected` with:

```swift
    private func setSelected(_ row: SpeakerRow) {
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        let active = row.active
        actions.run("Speaker") {
            // Baseline BEFORE the write so establishment shows as churn.
            let verifier = RouteVerifier()
            let ip = active ? verifier.resolver.resolveIP(forSpeaker: name) : nil
            let baseline = ip.flatMap { try? verifier.snapshot(ip: $0) }
            try require((try? syncRun { try await self.backend.runMusic("set selected of AirPlay device \"\(esc)\" to \(active)") }) != nil,
                        "Couldn't \(active ? "add" : "remove") '\(name)'.")
            // Verify additions while playing; short timeout — this runs on
            // the serial action queue and must not stall the shell.
            if active, let ip = ip, let baseline = baseline,
               ((try? syncRun { try await self.backend.runMusic("player state as text") }) ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines) == "playing" {
                let verdict = try? verifier.verifyEstablishment(ip: ip, baseline: baseline, timeout: 3.0)
                try require(verdict?.verified ?? true,
                            "'\(name)' selected but route NOT verified — try r (reset) or: music speaker verify")
            }
        }
    }
```

(No heal in the TUI toggle — the toast points at the existing reset key and the verify verb; a 2×1.5s heal dance would freeze the action queue. The CLI paths own healing.)

- [ ] **Step 2: Build + suite**

Run: `swift test 2>&1 | tail -3` — all green.

- [ ] **Step 3: Commit and push**

```bash
git add tools/music/Sources/TUI/Shell/SpeakersScene.swift
git commit -m "feat(tui): verify toast on speaker toggle while playing"
git push
```

---

### Task 11: Live probe script + ghost-capture protocol

**Files:**
- Create: `scripts/airplay-live-probe.sh`
- Modify: `~/eolas/vault/apple-music/repo/docs/playbook.md` (vault path — the repo path is a symlink)

- [ ] **Step 1: Write the probe script**

```bash
#!/bin/bash
# Gated live probe for the AirPlay verify-and-heal stack. Run BY HAND on a
# Mac with real speakers — it plays ~10s of audio on the named speaker.
# Usage: scripts/airplay-live-probe.sh [speaker-name]   (default: Kitchen)
set -euo pipefail
SPEAKER="${1:-Kitchen}"
MUSIC="swift run --package-path tools/music music"

echo "== 1. route + play + verify (expect: ✓ verified) =="
$MUSIC play in the "$SPEAKER"
sleep 2

echo "== 2. steady-state verify (expect: ✓) =="
$MUSIC speaker verify "$SPEAKER"

echo "== 3. route away (expect next verify to FAIL: lingering conns only) =="
# "MacBook" contains-matches the real device name — its curly apostrophe
# (Anthony’s) makes the full name hostile to shell quoting.
$MUSIC speaker set "MacBook"
sleep 3
$MUSIC speaker verify "$SPEAKER" || true

echo "== 4. route back + verify + pause =="
$MUSIC play in the "$SPEAKER"
sleep 2
$MUSIC speaker verify "$SPEAKER"
$MUSIC pause
echo "== probe complete — read the ✓/✗ marks above =="
```

- [ ] **Step 2: Make it executable, run it live, read the output**

Run: `chmod +x scripts/airplay-live-probe.sh && scripts/airplay-live-probe.sh Kitchen`
Expected: step 1-2 print ✓ verified; step 3 prints ✗ (not verified); step 4 prints ✓ again. Tier-2 heal validation (spec requirement — it was untested in the spike): if any step's establishment verify fails and heals, note which tier fired.

- [ ] **Step 3: Add the ghost-capture protocol + gotchas to the playbook**

Append to the vault playbook (`~/eolas/vault/apple-music/repo/docs/playbook.md`) Gotchas section:

```markdown
- **AirPlay scripting read-backs all lie (2026-07-11 spike).** `selected` false-positives on ghosts; `active` is event-latched (true only when a route establishes mid-play — audio can flow with active:false); `current AirPlay devices` can wedge permanently empty after a route-while-paused. The network table (established TCP conns to the device IP) is the only signal that never lied. `music speaker verify` reads it.
- **Route-while-paused is the corruption trigger** (2/2 spike corruptions). Routes are issued paused (avoids wrong-speaker blast) but only *trusted* after a mid-play verify.
- **Ghost-capture protocol:** ghosts don't reproduce on demand. When one next occurs naturally (speaker selected, no audio), BEFORE touching anything run `music speaker verify --json` and save the output — it captures the ghost's network fingerprint and confirms (or refutes) the verifier's core assumption that ghost = no data connections.
```

- [ ] **Step 4: Commit both repos and push**

```bash
cd /Users/anthonymaley/apple-music
git add scripts/airplay-live-probe.sh
git commit -m "feat(probe): gated AirPlay live-probe script"
git push
cd ~/eolas
git add vault/apple-music/repo/docs/playbook.md
git commit -m "apple-music: AirPlay signal-truth gotchas + ghost-capture protocol"
git push
```

---

### Task 12: Docs + version bump + final green run

**Files:**
- Modify: `skills/music/SKILL.md`, `README.md`, `docs/guide.md`
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (two fields), `tools/music/Sources/Music.swift` (version → `3.3.0` in all four, per CLAUDE.md Version Strategy)

- [ ] **Step 1: Doc updates**

In each doc, find the speakers/AirPlay section and add: the `music speaker verify [name]` verb (network-truth verdict), the automatic `✓ verified` on named-speaker plays, the paused deferral note ("route set; will verify on next play"), the wake behavior change (verifies first, resets only broken routes), and the honest-failure message shape with the manual popover fix. Keep each doc's existing voice and formatting; this is additive, not a rewrite.

- [ ] **Step 2: Version bump — all four locations**

`3.2.2 → 3.3.0` (new verb + new behavior, no breaking changes):
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version` AND `plugins[0].version`
- `tools/music/Sources/Music.swift` → `CommandConfiguration(version:)`

- [ ] **Step 3: Full suite + rebuild the installed CLI**

Run: `swift test 2>&1 | tail -3` — all green (target: 165+).
Run: `scripts/install.sh` — expected: installs the 3.3.0 binary; `music --version` prints `3.3.0`.

- [ ] **Step 4: Commit and push**

```bash
git add skills/music/SKILL.md README.md docs/guide.md .claude-plugin/ tools/music/Sources/Music.swift
git commit -m "3.3.0: AirPlay verify-and-heal — network-truth route verification"
git push
```

---

## Self-review notes (already applied)

- Spec coverage: verifier (T1-4), verify verb (T5), heal ladder + honest failure (T6), play path (T7), speaker cmds + deferral (T8), wake (T9), TUI (T10), live probe + ghost protocol (T11), docs (T12). Tier-2 validation lives in T11 step 2 (spec flagged it untested).
- The `.remove`/`.indices` exclusions in T8 and the no-heal TUI decision in T10 are deliberate scope choices, stated inline.
- Type names consistent: `TCPConnection`, `RouteVerdict`, `RouteVerifier`, `RouteHealer`, `verifyAndHealRoutes`, `verifyRouteOrDefer` — grep before renaming anything.

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

// MARK: - Parsing (pure)

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
    var ip = String(addr[..<lastDot])
    // netstat can print zoned link-local (fe80::1%lo0); the resolver strips
    // zones on its side (SpeakerIPResolver), so strip here too or the two
    // sides never compare equal.
    if let zone = ip.firstIndex(of: "%") { ip = String(ip[..<zone]) }
    return (ip, port)
}

/// netstat truncates addresses to its column width and no macOS flag widens
/// it — a routed Sonos arc's link-local IPv6 session printed as
/// `fe80::3a42:bff:f` for resolved IP fe80::3a42:bff:fed4:da1e (live,
/// 2026-07-13), so exact matching false-failed the route and fired the heal
/// ladder for nothing. IPv6 rows may therefore prefix-match; IPv4 always
/// fits the column and stays exact. Known cost: two devices sharing a long
/// vendor-derived prefix could cross-match — a false "verified", the
/// annoying-not-dangerous direction (same posture as the stale-IP cache).
func remoteIPMatches(_ row: String, resolved: String) -> Bool {
    if row == resolved { return true }
    return row.count >= 12
        && row.count < resolved.count
        && row.contains(":")
        && resolved.hasPrefix(row)
}

// MARK: - Live reader

/// netstat failing must throw — silently returning an empty table would read
/// as "no connections to the device", a false broken-route verdict.
struct NetstatError: Error, LocalizedError {
    let status: Int32
    var errorDescription: String? { "netstat exited with status \(status) — cannot read the connection table" }
}

/// All ESTABLISHED TCP connections, system-wide. netstat shows every
/// socket without root — the AirPlay session is held by a system daemon,
/// not the Music process (spike: Music holds zero TCP sockets).
func readEstablishedTCPConnections() throws -> [TCPConnection] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NetstatError(status: process.terminationStatus)
    }
    return parseNetstatTCP(String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Verdicts

struct RouteVerdict {
    let verified: Bool
    /// Human-readable network evidence ("3 new connections to 192.168.1.112 …").
    let evidence: String
    /// Optional context for failure output (scripting claims, fingerprint caveats).
    let advisory: String?
}

/// Serial use per call site — one instance must not be shared across concurrent callers (connectionSource is not @Sendable).
struct RouteVerifier {
    var resolver: SpeakerIPResolving = CachingSpeakerResolver()
    var connectionSource: () throws -> [TCPConnection] = readEstablishedTCPConnections
    /// Seconds between polls in verifyEstablishment. 0 is for tests only — with the live netstat source it would busy-spin.
    var pollInterval: TimeInterval = 0.5

    func snapshot(ip: String) throws -> Set<TCPConnection> {
        Set(try connectionSource().filter { remoteIPMatches($0.remoteIP, resolved: ip) })
    }

    /// Delta mode: after a route operation, poll until fresh connections
    /// appear beyond the baseline. Spike-observed establishment ≤1s on every
    /// real route; ≥2 new connections is the verified fingerprint (new :7000
    /// + data ports on HomePods).
    func verifyEstablishment(ip: String, baseline: Set<TCPConnection>,
                             timeout: TimeInterval = 5.0) throws -> RouteVerdict {
        let deadline = Date().addingTimeInterval(timeout)
        var lastNew = 0
        var sampled = false
        var lastError: Error?
        repeat {
            do {
                let now = try snapshot(ip: ip)
                sampled = true
                let fresh = now.subtracting(baseline)
                lastNew = fresh.count
                if fresh.count >= 2 {
                    return RouteVerdict(
                        verified: true,
                        evidence: "\(fresh.count) new connections to \(ip) (ports \(fresh.map { $0.remotePort }.sorted().map(String.init).joined(separator: ", ")))",
                        advisory: nil)
                }
            } catch {
                // One bad netstat sample must not discard the whole polling
                // window — keep polling toward the deadline. If EVERY sample
                // failed we throw below instead of faking a "no connections"
                // verdict (a netstat outage is not evidence of a dead route).
                lastError = error
            }
            if pollInterval > 0 { Thread.sleep(forTimeInterval: pollInterval) }
        } while Date() < deadline
        if !sampled, let err = lastError { throw err }
        return RouteVerdict(
            verified: false,
            evidence: lastNew == 0
                ? "no new connections to \(ip) within \(Int(timeout))s"
                : "only \(lastNew) new connection to \(ip) within \(Int(timeout))s (verified fingerprint is ≥2)",
            advisory: nil)
    }

    /// Steady-state mode (the `speaker verify` verb and the fast path): no
    /// baseline available, so use the routed fingerprint — two :7000 control
    /// connections PLUS at least one data connection. Control-only patterns
    /// are excluded: a ghost whose control handshake completed but whose
    /// session never negotiated would show exactly that shape. HomePod- and
    /// Sonos-verified (live 2026-07-13: playing Sonos arc = 2 control + 2
    /// data over IPv6); TVs/AppleTV remain an open question (spec §Open
    /// questions), so the failure advisory says what pattern was looked for.
    func steadyState(ip: String) throws -> RouteVerdict {
        let conns = try snapshot(ip: ip)
        let control = conns.filter { $0.remotePort == airplayControlPort }.count
        let data = conns.count - control
        if control >= 2 && data >= 1 {
            return RouteVerdict(
                verified: true,
                evidence: "\(control) control connections + \(data) other to \(ip)",
                advisory: nil)
        }
        return RouteVerdict(
            verified: false,
            evidence: "\(conns.count) connections to \(ip): \(control) control, \(data) data",
            advisory: "verified fingerprint is ≥2 control connections plus ≥1 data connection (HomePod/Sonos-verified pattern; lingering or control-only connections do not count)")
    }
}

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

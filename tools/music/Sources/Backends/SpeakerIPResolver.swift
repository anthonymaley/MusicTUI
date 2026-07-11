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

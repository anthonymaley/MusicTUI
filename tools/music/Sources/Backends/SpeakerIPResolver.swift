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
        // Race every strategy at once and take the first answer. The old serial
        // order made non-`.local` names (AirPods/Sonos/TV) pay the full hostname
        // timeouts before the browse — the path that actually resolves them —
        // had even started. Concurrency collapses that ~6s tax; a HomePod's
        // `<name>.local` still wins in well under a second.
        var strategies: [() -> String?] = []
        for candidate in Self.hostnameCandidates(for: name) {
            strategies.append {
                guard let ip = Self.resolveHostname(candidate) else { return nil }
                verbose("resolved \(name) → \(ip) via \(candidate)")
                return ip
            }
        }
        strategies.append {
            guard let ip = Self.browseAirPlayIP(name: name) else { return nil }
            verbose("resolved \(name) → \(ip) via _airplay._tcp browse")
            return ip
        }
        return Self.raceToFirstNonNil(strategies, timeout: 5.0)
    }

    /// Run every producer concurrently and return the first non-nil result, or
    /// nil if all finish empty. Bounded by an overall deadline. The winning
    /// producer signals immediately; losers run to completion on their own
    /// background threads and their results are discarded (the same
    /// abandon-the-worker discipline `resolveHostname` uses for getaddrinfo).
    static func raceToFirstNonNil(_ producers: [() -> String?], timeout: TimeInterval) -> String? {
        guard !producers.isEmpty else { return nil }
        let box = LockedBox<String?>(nil)
        let winner = OneShotFlag()
        let sema = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for produce in producers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if let ip = produce(), winner.claim() {
                    box.set(ip)
                    sema.signal()
                }
            }
        }
        // Backstop signal for the all-empty case (no producer ever claims).
        group.notify(queue: .global()) { sema.signal() }
        _ = sema.wait(timeout: .now() + timeout)
        return box.get()
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

    /// getaddrinfo has no cancellation API — run it on a background queue and
    /// bound the wait, matching the browse path's timeout discipline. On
    /// timeout the worker thread is abandoned (it finishes and exits on its
    /// own); real LAN resolutions answer in well under a second.
    static func resolveHostname(_ host: String, timeout: TimeInterval = 1.0) -> String? {
        let box = LockedBox<String?>(nil)
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            // IPv4-only by design: all spike evidence is IPv4; IPv6-only devices fall through to the browse path.
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { sema.signal(); return }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                box.set(String(cString: buffer))
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + timeout)
        return box.get()
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
                    // May signal more than once if results keep changing before cancel lands — harmless, nothing waits twice.
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
        conn.stateUpdateHandler = { [weak conn] state in
            switch state {
            case .ready:
                if let ep = conn?.currentPath?.remoteEndpoint, case let .hostPort(host, _) = ep {
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

/// Read-through cache over any resolver. name→IP is memoized in ResultCache —
/// on disk, because the CLI is a fresh process per invocation and an in-memory
/// cache would never hit across `music play` calls. A stale IP degrades to an
/// honest "unverified" note (heals target speakers by name, not IP), so a TTL
/// is a sufficient guard against DHCP churn.
struct CachingSpeakerResolver: SpeakerIPResolving {
    let inner: SpeakerIPResolving
    let cache: ResultCache
    let ttl: TimeInterval

    init(inner: SpeakerIPResolving = BonjourSpeakerResolver(),
         cache: ResultCache = ResultCache(),
         ttl: TimeInterval = 3600) {
        self.inner = inner
        self.cache = cache
        self.ttl = ttl
    }

    func resolveIP(forSpeaker name: String) -> String? {
        if let cached = cache.cachedSpeakerIP(forName: name, ttl: ttl) {
            verbose("resolved \(name) → \(cached) via cache")
            return cached
        }
        guard let ip = inner.resolveIP(forSpeaker: name) else { return nil }
        cache.rememberSpeakerIP(name: name, ip: ip)
        return ip
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

/// One-shot claim: the first caller wins (true), all subsequent callers lose
/// (false). Picks a single winner in a concurrent race.
final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

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
    static func raceToFirstNonNil(_ producers: [() -> String?], timeout: TimeInterval,
                                  grace: TimeInterval = 0.3) -> String? {
        guard !producers.isEmpty else { return nil }
        // Every answer is kept and merged: a fast IPv4-only hostname answer
        // must not discard a later browse that found the IPv6 address the
        // AirPlay session actually uses (Codex 2026-10-31). The first answer
        // starts a short grace for the others; the deadline still bounds it.
        let found = LockedBox<[String]>([])
        let firstAnswer = DispatchSemaphore(value: 0)
        let claimed = OneShotFlag()
        let group = DispatchGroup()
        for produce in producers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if let ip = produce() {
                    found.update { $0 += speakerAddresses(ip) }
                    if claimed.claim() { firstAnswer.signal() }
                }
            }
        }
        // Backstop for the all-empty case (no producer ever answers).
        group.notify(queue: .global()) { firstAnswer.signal() }
        let deadline = DispatchTime.now() + timeout
        _ = firstAnswer.wait(timeout: deadline)
        if !found.get().isEmpty {
            _ = group.wait(timeout: min(deadline, .now() + grace))
        }
        return joinAddresses(found.get())
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
            // Every family: AirPlay on macOS 27 talks to speakers over IPv6
            // link-local even when IPv4 resolves (probe 2026-10-31), so the
            // verifier needs all of a device's addresses (joinAddresses).
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, result != nil else { sema.signal(); return }
            defer { freeaddrinfo(result) }
            var found: [String] = []
            var cursor = result
            while let info = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                               &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(String(cString: buffer))
                }
                cursor = info.pointee.ai_next
            }
            box.set(joinAddresses(found))
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

        // One throwaway connection per IP family, concurrently: a single
        // connection reports whichever family won, and the AirPlay session
        // may run over the other one (2026-10-31: the Arc resolved IPv4 while
        // its session was IPv6 link-local).
        // The first family to answer bounds the wait; the other gets a short
        // grace, so a family that never connects cannot push the resolve past
        // the caller's race deadline.
        let producers = [NWProtocolIP.Options.Version.v4, .v6].map { version in
            { connectAndReadRemoteIP(endpoint, version: version, timeout: timeout) }
        }
        return raceToFirstNonNil(producers, timeout: timeout)
    }

    private static func connectAndReadRemoteIP(_ endpoint: NWEndpoint, version: NWProtocolIP.Options.Version,
                                               timeout: TimeInterval) -> String? {
        let params = NWParameters.tcp
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = version
        }
        let conn = NWConnection(to: endpoint, using: params)
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
            case .failed, .cancelled, .waiting:
                // .waiting: no path for this family right now; done, not pending.
                rsema.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = rsema.wait(timeout: .now() + timeout)
        conn.cancel()
        return ip.get()
    }
}

/// Distinct addresses, zone suffix stripped (netstat prints bare addresses;
/// Network.framework and getnameinfo add `%en0`), joined by commas for the
/// verifier (speakerAddresses). nil when there are none.
func joinAddresses(_ raw: [String]) -> String? {
    var seen: [String] = []
    for address in raw {
        var bare = address.trimmingCharacters(in: .whitespaces)
        if let zone = bare.firstIndex(of: "%") { bare = String(bare[..<zone]) }
        if !bare.isEmpty, !seen.contains(bare) { seen.append(bare) }
    }
    return seen.isEmpty ? nil : seen.joined(separator: ",")
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
/// (sync accessors, like ScriptExitArbiter in AppleScriptBackend.swift).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    /// Read-modify-write under one lock (a get-then-set pair can lose an update).
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
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
